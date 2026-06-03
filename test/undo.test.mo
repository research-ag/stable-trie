// @testmode wasi

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Iter "mo:core/Iter";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64_ "mo:core/Nat64";
import VarArray "mo:core/VarArray";
import Seiran128 "mo:prng/Seiran128";

import StableTrie "../src/Enumeration";

func genKeys(seed : Nat64, n : Nat, size : Nat) : [Blob] {
  let rng = Seiran128.new(seed);
  // Generate n distinct keys. We use the structure from main.test.mo: half are
  // random, half are derived from the previous random key with a common prefix,
  // which exercises the branching inside the trie.
  var prev : [Nat8] = [];
  Array.tabulate<Blob>(
    n,
    func(i) {
      if (i % 2 == 0) {
        prev := Array.tabulate<Nat8>(size, func(_) = Nat8.fromIntWrap(rng.next().toNat()));
        Blob.fromArray(prev);
      } else {
        let t = rng.next().toNat() % size;
        Blob.fromArray(Array.tabulate<Nat8>(size, func(j) = if (j < t) prev[j] else Nat8.fromIntWrap(rng.next().toNat())));
      };
    },
  );
};

func dedup(keys : [Blob]) : [Blob] {
  // Keep only first occurrence; preserve input order.
  let buf : [var Blob] = VarArray.repeat<Blob>("", keys.size());
  var n = 0;
  for (i in Nat.range(0, keys.size())) {
    var dup = false;
    for (j in Nat.range(0, n)) {
      if (buf[j] == keys[i]) dup := true;
    };
    if (not dup) { buf[n] := keys[i]; n += 1 };
  };
  Array.tabulate<Blob>(n, func(i) = buf[i]);
};

let key_size = 4;
let value_size = 2;
let n = 256;

let raw_keys = genKeys(0, n * 2, key_size);
let keys = dedup(raw_keys);
let raw_vals = genKeys(1, keys.size(), value_size);

let configs : [(Nat, Nat, ?Nat)] = [
  // (pointer_size, aridity, root_aridity)
  (2, 2, null),
  (2, 4, null),
  (4, 2, ?8),
  (4, 4, ?16),
  (5, 16, ?256),
  (6, 4, ?64),
  (8, 2, null),
  (8, 16, ?256),
];

func entriesInOrder(t : StableTrie.Enumeration) : [Blob] {
  Iter.toArray(Iter.map<(Blob, Blob), Blob>(t.entries(), func((k, _)) = k));
};

for ((pointer_size, aridity, root_aridity) in configs.vals()) {
  let trie = StableTrie.empty({
    pointer_size;
    aridity;
    root_aridity;
    key_size;
    value_size;
  });

  // ---------- 1. undo on empty enumeration ----------
  assert trie.removeLast() == null;
  assert trie.size() == 0;

  // ---------- 2. add a single entry, undo, observe everything empty ----------
  do {
    let stats_initial = trie.memoryStats();
    // Fresh enumeration: leaf_count = 0, node_count = 0 (regions not allocated
    // until the first add).
    assert stats_initial.used_leaf_count == 0;

    assert trie.add(keys[0], raw_vals[0]) == 0;
    assert trie.size() == 1;
    let stats_after_add = trie.memoryStats();
    assert stats_after_add.used_leaf_count == 1;
    // First add cannot create any internal nodes (the leaf is placed in an
    // empty root slot directly), so node_count == 1 (just the root).
    assert stats_after_add.used_node_count == 1;

    assert trie.removeLast() == ?(keys[0], raw_vals[0]);
    assert trie.size() == 0;
    assert trie.lookup(keys[0]) == null;
    assert trie.get(0) == null;
    assert entriesInOrder(trie) == [];

    let stats_after_undo = trie.memoryStats();
    assert stats_after_undo.used_leaf_count == 0;
    // byte_size dropped by exactly one leaf relative to after-add.
    assert stats_after_undo.byte_size + (key_size + value_size) == stats_after_add.byte_size;
    // Internal nodes that were freed leave node_count back at 1 (just root).
    assert stats_after_undo.used_node_count == 1;

    // ---------- 3. another undo on empty is a no-op ----------
    assert trie.removeLast() == null;
  };

  // Track the "fully loaded" stats across sections so we can compare against
  // them after refilling.
  var stats_full_byte_size : Nat = 0;
  var stats_full_node_count : Nat = 0;
  var stats_full_total_node_count : Nat = 0;

  // ---------- 4. add many entries, undo all in LIFO order ----------
  do {
    var i = 0;
    while (i < keys.size()) {
      assert trie.add(keys[i], raw_vals[i]) == i;
      assert trie.size() == i + 1;
      i += 1;
    };

    let stats_full = trie.memoryStats();
    assert stats_full.used_leaf_count == keys.size();
    // When no node has ever been freed, used == high water.
    assert stats_full.used_node_count == stats_full.total_node_count;
    stats_full_byte_size := stats_full.byte_size;
    stats_full_node_count := stats_full.used_node_count;
    stats_full_total_node_count := stats_full.total_node_count;

    // Sanity: every key looks up to its index.
    i := 0;
    while (i < keys.size()) {
      assert trie.lookup(keys[i]) == ?(raw_vals[i], i);
      i += 1;
    };

    // Undo all in reverse, asserting each step.
    var j = keys.size();
    while (j > 0) {
      j -= 1;
      let s_before = trie.memoryStats();
      assert trie.removeLast() == ?(keys[j], raw_vals[j]);
      assert trie.size() == j;
      assert trie.lookup(keys[j]) == null;
      assert trie.get(j) == null;
      let s_after = trie.memoryStats();
      assert s_after.used_leaf_count + 1 == s_before.used_leaf_count;
      // node_count can only decrease (or stay the same) per removeLast — never
      // grow — and it never drops below 1 (the root is never freed).
      assert s_after.used_node_count <= s_before.used_node_count;
      assert s_after.used_node_count >= 1;
      // byte_size for the leaves portion always drops by one leaf. The nodes
      // portion never changes because the region is not shrunk.
      assert s_after.byte_size + (key_size + value_size) == s_before.byte_size;
      // Remaining entries are still intact.
      var k = 0;
      while (k < j) {
        assert trie.lookup(keys[k]) == ?(raw_vals[k], k);
        assert trie.get(k) == ?(keys[k], raw_vals[k]);
        k += 1;
      };
    };

    assert trie.size() == 0;
    assert trie.removeLast() == null;
    // After undoing everything, used node count is back to just the root, but
    // the high water (total_node_count) remembers how many we allocated.
    assert trie.memoryStats().used_node_count == 1;
    assert trie.memoryStats().total_node_count == stats_full_total_node_count;
  };

  // ---------- 5. re-adding after fully draining: nodes come from empty-nodes list ----------
  do {
    // Trie has 0 leaves and only the root in use; every previously allocated
    // internal node is sitting in the empty-nodes free list.
    let s_drained = trie.memoryStats();
    assert s_drained.used_leaf_count == 0;
    assert s_drained.used_node_count == 1;

    // Re-add the same keys in the same order. Each should get the same index.
    var i = 0;
    while (i < keys.size()) {
      assert trie.add(keys[i], raw_vals[i]) == i;
      i += 1;
    };

    let s_refilled = trie.memoryStats();
    assert s_refilled.used_leaf_count == keys.size();
    // After refilling, used node count is back to the original "full" value
    // and the high water hasn't grown — every freed node was reused.
    assert s_refilled.used_node_count == stats_full_node_count;
    assert s_refilled.total_node_count == stats_full_total_node_count;
    // And byte_size is identical to the original "full" state — no new region
    // pages were grown, because every freed node was reused from the linked
    // list and every leaf reused its end-of-region slot.
    assert s_refilled.byte_size == stats_full_byte_size;
  };

  // ---------- 6. interleaved add/undo: undo last, re-add a different key ----------
  do {
    let before = trie.memoryStats();
    let last_idx = keys.size() - 1;

    assert trie.removeLast() == ?(keys[last_idx], raw_vals[last_idx]);
    assert trie.size() == last_idx;

    // After undo, the next add reclaims the same leaf index.
    let new_key = Blob.fromArray(Array.tabulate<Nat8>(key_size, func(j) = Nat8.fromNat(j + 17)));
    let new_val = Blob.fromArray(Array.tabulate<Nat8>(value_size, func(j) = Nat8.fromNat(j + 99)));

    // If the synthetic new_key happens to collide with an existing one, skip
    // this part (avoids a false negative on small key_size).
    let already = trie.lookup(new_key);
    if (already == null) {
      assert trie.add(new_key, new_val) == last_idx;
      assert trie.size() == last_idx + 1;
      assert trie.lookup(new_key) == ?(new_val, last_idx);

      // Leaf count is back to before; node_count may have grown if the new key
      // required a different branching path. byte_size grows in lockstep with
      // node_count (leaf portion is identical).
      let after = trie.memoryStats();
      assert after.used_leaf_count == before.used_leaf_count;
      assert after.used_node_count >= before.used_node_count;
      assert after.byte_size >= before.byte_size;

      // Undo the new entry to restore state.
      assert trie.removeLast() == ?(new_key, new_val);
      assert trie.lookup(new_key) == null;
    };

    // Restore the original last entry to keep the trie in a known state.
    assert trie.add(keys[last_idx], raw_vals[last_idx]) == last_idx;
  };

  // ---------- 7. partial undo (pop some), then re-add others ----------
  do {
    // Pop the last 10 (or all, if smaller) entries.
    let pop_n = if (keys.size() < 10) keys.size() else 10;
    let popped : [var (Blob, Blob)] = VarArray.repeat<(Blob, Blob)>(("", ""), pop_n);
    var i = 0;
    while (i < pop_n) {
      let cur_size = trie.size();
      let last = cur_size - 1;
      switch (trie.removeLast()) {
        case (?(k, v)) {
          popped[i] := (k, v);
          assert k == keys[last];
          assert v == raw_vals[last];
        };
        case (null) { assert false };
      };
      assert trie.size() == last;
      i += 1;
    };

    // Re-add them in original order. They get the same indices.
    i := 0;
    while (i < pop_n) {
      let target_index = keys.size() - pop_n + i;
      let (k, v) = popped[pop_n - 1 - i];
      assert trie.add(k, v) == target_index;
      i += 1;
    };

    // Final state: identical to the fully-loaded trie.
    i := 0;
    while (i < keys.size()) {
      assert trie.lookup(keys[i]) == ?(raw_vals[i], i);
      assert trie.get(i) == ?(keys[i], raw_vals[i]);
      i += 1;
    };
  };

};

// ---------- 8b. interleaved drain/refill keeps the region from growing ----------
do {
  let trie = StableTrie.empty({
    pointer_size = 4;
    aridity = 4;
    root_aridity = ?16;
    key_size = 4;
    value_size = 2;
  });
  let ks = genKeys(7, 64, 4);
  let unique_ks = dedup(ks);
  let vs = genKeys(8, unique_ks.size(), 2);

  // Initial fill.
  var i = 0;
  while (i < unique_ks.size()) {
    assert trie.add(unique_ks[i], vs[i]) == i;
    i += 1;
  };
  let full_stats = trie.memoryStats();

  // Cycle: pop half, push them back. Repeat several times. byte_size and
  // node_count should be invariant — no new allocation happens because every
  // pop returns its node to the empty-nodes list, and every subsequent push
  // pops it back out.
  let half = unique_ks.size() / 2;
  var cycle = 0;
  while (cycle < 5) {
    var k = 0;
    while (k < half) {
      assert (trie.removeLast() != null);
      k += 1;
    };
    k := 0;
    while (k < half) {
      let target = unique_ks.size() - half + k;
      assert trie.add(unique_ks[target], vs[target]) == target;
      k += 1;
    };
    let s = trie.memoryStats();
    assert s.used_leaf_count == full_stats.used_leaf_count;
    assert s.used_node_count == full_stats.used_node_count;
    assert s.byte_size == full_stats.byte_size;
    cycle += 1;
  };

  // Final state must still be consistent.
  i := 0;
  while (i < unique_ks.size()) {
    assert trie.lookup(unique_ks[i]) == ?(vs[i], i);
    i += 1;
  };

  // Full drain + assert node_count == 1.
  while (trie.size() > 0) {
    assert (trie.removeLast() != null);
  };
  assert trie.memoryStats().used_node_count == 1;
  assert trie.memoryStats().used_leaf_count == 0;

  // Refill: should match full_stats byte-for-byte (high water hasn't grown).
  i := 0;
  while (i < unique_ks.size()) {
    assert trie.add(unique_ks[i], vs[i]) == i;
    i += 1;
  };
  assert trie.memoryStats() == full_stats;
};

// ---------- 8c. collapse invariant: deleting one of a pair frees the split node ----------
//
// Add two keys that share a long prefix (so put_ builds a chain of internal
// nodes terminating in a node with two leaves). After removeLast removes one
// of the leaves, Map-style collapse should bubble the surviving leaf all the
// way back up to the root, freeing every node in the chain.
do {
  let trie = StableTrie.empty({
    pointer_size = 4;
    aridity = 2;
    root_aridity = ?2;
    key_size = 4;
    value_size = 0;
  });
  // Two keys differing only in the very last bit ⇒ creates a chain of depth
  // (4 * 8 - 1 = 31) below the root.
  let kA : Blob = "\00\00\00\00";
  let kB : Blob = "\00\00\00\01";

  assert trie.add(kA, "") == 0;
  let stats_one = trie.memoryStats();
  // First add cannot create any internal nodes.
  assert stats_one.used_node_count == 1;

  assert trie.add(kB, "") == 1;
  let stats_two = trie.memoryStats();
  // Second add created a long chain of internal nodes.
  assert stats_two.used_node_count > 1;

  assert trie.removeLast() == ?(kB, "" : Blob);
  // After collapse, the chain that was built to split kA and kB is gone:
  // only the root and kA's direct leaf remain.
  let stats_one_again = trie.memoryStats();
  assert stats_one_again.used_node_count == 1;
  // The node-region high water hasn't shrunk — byte_size only dropped by one
  // leaf (kB), not by the freed internal nodes.
  assert stats_one_again.byte_size + (4 + 0) == stats_two.byte_size;

  // Re-adding kB pops nodes back off the empty list — no growth: every stat
  // matches what we had before the removeLast.
  assert trie.add(kB, "") == 1;
  assert trie.memoryStats() == stats_two;

  // Full drain still ends at node_count == 1.
  assert trie.removeLast() == ?(kB, "" : Blob);
  assert trie.removeLast() == ?(kA, "" : Blob);
  assert trie.memoryStats().used_node_count == 1;
  assert trie.memoryStats().used_leaf_count == 0;
};

// ---------- 9. undo of single leaf attached directly to root ----------
// Use a 1-byte key with aridity 256 so the root holds the leaf directly.
do {
  let trie = StableTrie.empty({
    pointer_size = 2;
    aridity = 4;
    root_aridity = ?256;
    key_size = 1;
    value_size = 0;
  });
  assert trie.add("\01", "") == 0;
  assert trie.add("\02", "") == 1;
  assert trie.removeLast() == ?("\02" : Blob, "" : Blob);
  assert trie.lookup("\02") == null;
  assert trie.lookup("\01") == ?("" : Blob, 0);
  assert trie.removeLast() == ?("\01" : Blob, "" : Blob);
  assert trie.removeLast() == null;
  assert trie.size() == 0;
  assert trie.memoryStats().used_leaf_count == 0;
};

// ---------- 10. value-size = 0 (set-like) undo ----------
do {
  let trie = StableTrie.empty({
    pointer_size = 4;
    aridity = 2;
    root_aridity = null;
    key_size = 3;
    value_size = 0;
  });
  let ks : [Blob] = ["\01\02\03", "\01\02\04", "\01\03\03", "\04\05\06"];
  for (i in Nat.range(0, ks.size())) {
    assert trie.add(ks[i], "") == i;
  };
  // Pop & re-pop pattern.
  assert trie.removeLast() == ?(ks[3], "" : Blob);
  assert trie.add(ks[3], "") == 3;
  assert trie.removeLast() == ?(ks[3], "" : Blob);
  assert trie.removeLast() == ?(ks[2], "" : Blob);
  assert trie.size() == 2;
  assert trie.lookup(ks[0]) == ?("" : Blob, 0);
  assert trie.lookup(ks[1]) == ?("" : Blob, 1);
  assert trie.lookup(ks[2]) == null;
  assert trie.lookup(ks[3]) == null;
};
