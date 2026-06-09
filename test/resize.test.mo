// @testmode wasi
//
// Incremental pointer-size resize: shrink 4 → 2, grow back 2 → 4. Verify
// all entries readable after each migration.

import Blob "mo:core/Blob";
import Iter "mo:core/Iter";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Nat_ "mo:core/Nat";
import _Region "mo:core/Region"; // dot-notation on `nodes_region`/`leaves_region`

import Map "../src/Map";
// Enumeration is intentionally NOT imported in this file — it would make
// every dot-notation call on a Map value ambiguous (Map and Enumeration
// share signatures for `size`, `add`, `get`, etc.). Enumeration's resize
// is exercised in resize_enum.test.mo.

func keyOf(i : Nat) : Blob = Blob.fromArray([
  Nat8.fromNat(i % 256),
  Nat8.fromNat((i / 256) % 256),
  Nat8.fromNat((i / 65536) % 256),
  Nat8.fromNat((i / 16777216) % 256),
]);

func valueOf(i : Nat) : Blob = Blob.fromArray([
  Nat8.fromNat(i % 256),
  Nat8.fromNat((i / 256) % 256),
  Nat8.fromNat((i / 65536) % 256),
  Nat8.fromNat((i / 16777216) % 256),
]);

// Drive an incremental resize to completion with a given batch size, so we
// exercise stepResize being called multiple times.
func resize(m : Map.Map, new_ps : Nat, batch : Nat) : Map.Map {
  let state = switch (m.beginResize(new_ps)) {
    case (?s) s;
    case null { assert false; loop {} };
  };
  var done = false;
  while (not done) {
    done := Map.stepResize(state, batch);
  };
  Map.completeResize(state);
};

// ─── Round-trip: pointer_size = 4 → 2 → 4 ────────────────────────────────

var m : Map.Map = Map.empty({
  pointer_size = 4;
  aridity = 4;
  root_aridity = null;
  key_size = 4;
  value_size = 4;
});

let N = 200;
for (i in Nat_.range(0, N)) {
  m.add(keyOf(i), valueOf(i));
};
assert m.size() == N;

// Shrink to pointer_size = 2 in batches of 7 (forces multiple stepResize calls).
m := resize(m, 2, 7);

assert m.size() == N;
for (i in Nat_.range(0, N)) {
  assert m.get(keyOf(i)) == ?valueOf(i);
};

// New writes after shrink.
m.add(keyOf(N), valueOf(N));
assert m.size() == N + 1;
assert m.get(keyOf(N)) == ?valueOf(N);

// Deletes work after shrink (exercises empty_nodes_list + new layout).
assert m.delete(keyOf(0));
assert m.get(keyOf(0)) == null;
m.add(keyOf(0), valueOf(0));

// Grow back to pointer_size = 4 in batches of 11.
m := resize(m, 4, 11);

assert m.size() == N + 1;
for (i in Nat_.range(0, N + 1)) {
  assert m.get(keyOf(i)) == ?valueOf(i);
};

m.add(keyOf(N + 1), valueOf(N + 1));
assert m.size() == N + 2;
assert m.get(keyOf(N + 1)) == ?valueOf(N + 1);

// Iteration still yields N+2 entries.
do {
  let entries = Iter.toArray(m.entries());
  assert entries.size() == N + 2;
};

// ─── Grow with a non-empty empty_leaves_list ──────────────────────────────
//
// Delete some keys without re-adding so that the leaves free list carries
// real entries across the next resize. Then shrink to 2, then grow back
// to 4. After both migrations, the freed slots should still be on the
// list and get reused by subsequent adds.

assert m.delete(keyOf(5));
assert m.delete(keyOf(7));
assert m.delete(keyOf(9));
let after_deletes_size = m.size();

// Shrink with non-empty leaves list.
m := resize(m, 2, 13);
assert m.size() == after_deletes_size;
assert m.get(keyOf(5)) == null;
assert m.get(keyOf(7)) == null;
assert m.get(keyOf(9)) == null;
// Still readable for everything else.
assert m.get(keyOf(0)) == ?valueOf(0);
assert m.get(keyOf(N + 1)) == ?valueOf(N + 1);

// Grow back to 4 with the leaves free list still non-empty.
m := resize(m, 4, 5);
assert m.size() == after_deletes_size;
assert m.get(keyOf(5)) == null;
assert m.get(keyOf(7)) == null;
assert m.get(keyOf(9)) == null;
assert m.get(keyOf(0)) == ?valueOf(0);
assert m.get(keyOf(N + 1)) == ?valueOf(N + 1);

// Adding three new keys should reuse the three freed slots via the
// surviving leaves free list (no new high-water leaf allocations needed).
let leaf_count_before = m.leaf_count;
m.add(keyOf(N + 2), valueOf(N + 2));
m.add(keyOf(N + 3), valueOf(N + 3));
m.add(keyOf(N + 4), valueOf(N + 4));
assert m.leaf_count == leaf_count_before; // free-list reuse, no new allocation
assert m.size() == after_deletes_size + 3;
assert m.get(keyOf(N + 2)) == ?valueOf(N + 2);
assert m.get(keyOf(N + 3)) == ?valueOf(N + 3);
assert m.get(keyOf(N + 4)) == ?valueOf(N + 4);

// ─── Refusal cases ─────────────────────────────────────────────────────────

// Helper — `?Map.ResizeState` isn't `==`-comparable (record has a `var`).
func refused(s : ?Map.ResizeState) : Bool = switch s {
  case null true;
  case _ false;
};

assert refused(m.beginResize(4)); // no-op (same pointer_size)
assert refused(m.beginResize(3)); // invalid
assert refused(m.beginResize(7)); // invalid
assert refused(m.beginResize(0)); // invalid

// ─── Edge size: empty trie ────────────────────────────────────────────────

do {
  let em = Map.empty({
    pointer_size = 1;
    aridity = 4;
    root_aridity = null;
    key_size = 1;
    value_size = 1;
  });
  assert em.size() == 0;

  // Round-trip an empty trie. node_count is just 1 (the root), so the
  // resize processes a single node.
  var em_now : Map.Map = em;
  em_now := resize(em_now, 2, 100);
  assert em_now.size() == 0;
  em_now := resize(em_now, 1, 100);
  assert em_now.size() == 0;

  // Functional afterwards.
  em_now.add("\01", "x");
  assert em_now.get("\01") == ?("x" : Blob);
};

// ─── Edge size: single entry ──────────────────────────────────────────────

do {
  let sm = Map.empty({
    pointer_size = 1;
    aridity = 4;
    root_aridity = null;
    key_size = 1;
    value_size = 1;
  });
  sm.add("\05", "y");
  assert sm.size() == 1;

  var sm_now : Map.Map = sm;
  sm_now := resize(sm_now, 2, 100);
  assert sm_now.size() == 1;
  assert sm_now.get("\05") == ?("y" : Blob);
};

// ─── batch_size = 1 (forces one node per call) ────────────────────────────

do {
  let bm = Map.empty({
    pointer_size = 1;
    aridity = 4;
    root_aridity = null;
    key_size = 1;
    value_size = 1;
  });
  for (i in Nat_.range(0, 30)) {
    bm.add(Blob.fromArray([Nat8.fromNat(i)]), Blob.fromArray([Nat8.fromNat(i)]));
  };

  var bm_now : Map.Map = bm;
  bm_now := resize(bm_now, 2, 1); // one node per stepResize call
  assert bm_now.size() == 30;
  for (i in Nat_.range(0, 30)) {
    assert bm_now.get(Blob.fromArray([Nat8.fromNat(i)])) == ?Blob.fromArray([Nat8.fromNat(i)]);
  };
};

// ─── batch_size >> node_count (one call finishes) ─────────────────────────

do {
  let lm = Map.empty({
    pointer_size = 1;
    aridity = 4;
    root_aridity = null;
    key_size = 1;
    value_size = 1;
  });
  for (i in Nat_.range(0, 10)) {
    lm.add(Blob.fromArray([Nat8.fromNat(i)]), Blob.fromArray([Nat8.fromNat(i)]));
  };

  // Single stepResize call with batch huge → done in one call.
  var lm_now : Map.Map = lm;
  let state = switch (lm_now.beginResize(2)) {
    case (?s) s;
    case null { assert false; loop {} };
  };
  let done = Map.stepResize(state, 10_000);
  assert done;
  lm_now := Map.completeResize(state);
  assert lm_now.size() == 10;
};

// ─── leaf_size refusal ────────────────────────────────────────────────────
//
// Map with key_size + value_size = 1, pointer_size = 1. leaf_size = 1.
// Growing to a pointer_size larger than leaf_size would make future
// `pushEmptyLeaf` writes overflow the leaf — refused.

do {
  let lm = Map.empty({
    pointer_size = 1;
    aridity = 4;
    root_aridity = null;
    key_size = 1;
    value_size = 0;
  });
  lm.add("\01", "");
  // leaf_size is max(1, 1) = 1; growing to any larger ps would refuse.
  assert refused(lm.beginResize(2));
  assert refused(lm.beginResize(4));
  assert refused(lm.beginResize(8));
};

// ─── Capacity exceeded refusal ────────────────────────────────────────────

do {
  let cm = Map.empty({
    pointer_size = 2;
    aridity = 4;
    root_aridity = null;
    key_size = 2;
    value_size = 0;
  });
  for (i in Nat_.range(0, 200)) {
    cm.add(Blob.fromArray([Nat8.fromNat(i % 256), Nat8.fromNat(i / 256)]), "");
  };
  // ps=1 caps leaf_count at 128. 200 > 128 → refuse.
  assert refused(cm.beginResize(1));
};

// ─── Round-trip byte-identity ─────────────────────────────────────────────
//
// After `n → m → n` (with deletes in the mix to populate both free lists)
// and no intervening writes, the used portion of both regions should be
// byte-identical to the pre-resize snapshot. Strong correctness invariant —
// any subtle off-by-one in offset arithmetic during the rewrite would
// surface here.

do {
  let rm = Map.empty({
    pointer_size = 2;
    aridity = 4;
    root_aridity = null;
    key_size = 4;
    value_size = 4;
  });
  for (i in Nat_.range(0, 30)) {
    rm.add(keyOf(i), valueOf(i));
  };
  // Delete a few entries to populate both free lists (chain-link node + freed leaf).
  assert rm.delete(keyOf(5));
  assert rm.delete(keyOf(15));
  assert rm.delete(keyOf(25));

  // Snapshot the used portion of both regions.
  let nodes_used : Nat = Nat64.toNat(rm.root_size +% (rm.node_count -% 1) *% rm.node_size);
  let leaves_used : Nat = Nat64.toNat(rm.leaf_count *% rm.leaf_size);
  let nodes_before = rm.nodes_region.loadBlob(0, nodes_used);
  let leaves_before = rm.leaves_region.loadBlob(0, leaves_used);

  // Round-trip 2 → 4 → 2.
  var rm_now : Map.Map = rm;
  rm_now := resize(rm_now, 4, 100);
  rm_now := resize(rm_now, 2, 100);

  // Used portion sizes match.
  let nodes_used_after : Nat = Nat64.toNat(rm_now.root_size +% (rm_now.node_count -% 1) *% rm_now.node_size);
  let leaves_used_after : Nat = Nat64.toNat(rm_now.leaf_count *% rm_now.leaf_size);
  assert nodes_used == nodes_used_after;
  assert leaves_used == leaves_used_after;

  // Byte-identical.
  let nodes_after = rm_now.nodes_region.loadBlob(0, nodes_used);
  let leaves_after = rm_now.leaves_region.loadBlob(0, leaves_used);
  assert nodes_before == nodes_after;
  assert leaves_before == leaves_after;
};
