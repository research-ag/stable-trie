// @testmode wasi
//
// Capacity-limit test: internal-node pointer space fills before leaf
// space. Uses pointer_size = 1 (max_address = 2**7 = 128).
//
// Config: aridity = 2, root_aridity = 4, key_size = 8. Binary trie:
// each level eats 1 bit. Root eats 2 bits.
// max_chain_depth = (8*8 - 2) / 1 = 62 — a pair of keys that share
// every bit except the last triggers a 62-long internal chain.
//
// What's exercised:
//   - Two pairs of fully-prefix-sharing keys (each pair in a different
//     root slot) use 2 * 62 = 124 internal-node allocations on top of
//     the root, taking node_count to 125 / max=128.
//   - One more singleton leaf in a third root slot uses 0 internals,
//     bringing the trie to (125 internals, 5 leaves) with only 3 free
//     internal slots — far short of the 62 a sixth fully-shared key
//     would need.
//   - put_'s tier 1 fails on the internal bound; tier 2 fails because
//     empty_nodes_list is empty; tier 3 (precise pre-walk) confirms
//     the chain would need 62 internals while only 3 are free → #err.
//   - The trie is left untouched on #err: every counter unchanged.
//   - Removing a key from one of the populated pairs collapses the
//     entire 62-chain back, sending 62 nodes to empty_nodes_list.
//     leaf_count stays at the high-water mark; the freed leaf goes to
//     empty_leaves_list.
//   - Re-attempting the previously-failing add now succeeds via
//     free-list reuse: 62 internals popped from empty_nodes_list,
//     1 leaf popped from empty_leaves_list. node_count and leaf_count
//     are unchanged from before the delete + re-add.

import Iter "mo:core/Iter";
import Blob "mo:core/Blob";
import Nat8 "mo:core/Nat8";

import Map "../src/Map";

let m = Map.empty({
  pointer_size = 1;
  aridity = 2;
  root_aridity = ?4;
  key_size = 8;
  value_size = 1;
});

// Helper: build an 8-byte key from (root-slot-prefix-byte, last-byte).
// `prefix` is the first byte; bytes 1..6 are zero; `last` is byte 7.
func key(prefix : Nat, last : Nat) : Blob = Blob.fromArray([
  Nat8.fromNat(prefix),
  0,
  0,
  0,
  0,
  0,
  0,
  Nat8.fromNat(last),
]);

// Three root slots, derived from the top 2 bits of byte 0:
//   0x00 → root[0]
//   0x40 → root[1]
//   0x80 → root[2]
//
// Within a given root slot, two keys with the same byte 0 and last-byte
// 0 vs 1 share all 63 bits past the root and diverge only at the last.

// Pair 1 (root[0]): triggers a 62-internal split chain.
m.add(key(0x00, 0x00), "a"); // 0 new internals, 1 new leaf
m.add(key(0x00, 0x01), "b"); // 62 new internals, 1 new leaf
assert m.node_count == 1 + 62; // root + chain
assert m.leaf_count == 2;
assert m.size() == 2;

// Pair 2 (root[2]): another 62-internal chain.
m.add(key(0x80, 0x00), "c"); // 0 new internals, 1 new leaf
m.add(key(0x80, 0x01), "d"); // 62 new internals, 1 new leaf
assert m.node_count == 1 + 2 * 62; // 125
assert m.leaf_count == 4;
assert m.size() == 4;
assert m.empty_nodes_list.count == 0;
assert m.empty_leaves_list.count == 0;

// One more singleton leaf in root[1] — no internals allocated.
m.add(key(0x40, 0x00), "e");
assert m.node_count == 125;
assert m.leaf_count == 5;
assert m.size() == 5;

// 6th key would need 62 internals to split off `e`, but only 3 are
// free (128 - 125). addChecked returns #err and the trie is untouched.
assert m.addChecked(key(0x40, 0x01), "f") == #err(#LimitExceeded);
assert m.node_count == 125;
assert m.leaf_count == 5;
assert m.size() == 5;
assert m.empty_nodes_list.count == 0;
assert m.empty_leaves_list.count == 0;
assert m.get(key(0x40, 0x01)) == null;

// Iteration still yields exactly the 5 live entries in ascending key
// order.
do {
  let entries = Iter.toArray(m.entries());
  assert entries.size() == 5;
  assert entries[0] == (key(0x00, 0x00), "a");
  assert entries[1] == (key(0x00, 0x01), "b");
  assert entries[2] == (key(0x40, 0x00), "e");
  assert entries[3] == (key(0x80, 0x00), "c");
  assert entries[4] == (key(0x80, 0x01), "d");
};

// Delete `b`: removeRec walks down through the 62-chain, removes leaf
// `b`, and the cascade collapses every node in the chain. All 62
// internals land on empty_nodes_list; the freed leaf slot lands on
// empty_leaves_list. high-water counters stay put.
assert m.delete(key(0x00, 0x01));
assert m.size() == 4;
assert m.node_count == 125; // high-water unchanged
assert m.leaf_count == 5; // high-water unchanged
assert m.empty_nodes_list.count == 62;
assert m.empty_leaves_list.count == 1;
assert m.get(key(0x00, 0x01)) == null;
assert m.get(key(0x00, 0x00)) == ?"a"; // `a` still reachable via the
// collapsed root[0] slot, which now points directly at the leaf

// Re-attempt the previously-failing add. avail_internals via tier 2 =
// (128 - 125) + 62 = 65 ≥ 62 → put proceeds. All 62 internals come
// from empty_nodes_list; the new leaf reuses the freed slot.
m.add(key(0x40, 0x01), "f");
assert m.size() == 5;
assert m.node_count == 125; // no fresh internals allocated
assert m.leaf_count == 5; // no fresh leaves allocated
assert m.empty_nodes_list.count == 0;
assert m.empty_leaves_list.count == 0;
assert m.get(key(0x40, 0x01)) == ?"f";

// Final invariant: iteration matches the new live set.
do {
  let entries = Iter.toArray(m.entries());
  assert entries.size() == m.size();
  assert entries[0] == (key(0x00, 0x00), "a"); // `b` removed
  assert entries[1] == (key(0x40, 0x00), "e");
  assert entries[2] == (key(0x40, 0x01), "f"); // newly added
  assert entries[3] == (key(0x80, 0x00), "c");
  assert entries[4] == (key(0x80, 0x01), "d");
};
