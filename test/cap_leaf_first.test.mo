// @testmode wasi
//
// Capacity-limit test: leaf pointer space fills before internal-node
// space. Uses pointer_size = 1 (max_address = 2**7 = 128).
//
// Config: aridity = 256, root_aridity = 256, key_size = 1. The trie is
// flat — every key has a unique 1-byte slot in the root node, so each
// add allocates exactly 1 leaf and 0 internal nodes. max_chain_depth
// = (1*8 - 8) / 8 = 0.
//
// What's exercised:
//   - Filling leaves to max_address with internals essentially empty
//     (node_count stays at 1, just the root).
//   - put_'s tier-1 check fails on the leaf bound while the internal
//     bound is satisfied; tier 2 fails because empty_leaves_list is
//     empty; tier 3 (precise) confirms no leaf room → #err.
//   - The trie is left untouched on #err: size, counters, and the
//     entries iter are unchanged from before the failed add.
//   - delete + re-add reuses the freed leaf slot via empty_leaves_list
//     (leaf_count high-water stays at max_address; the new entry
//     lives at the same physical index as the removed one).

import Iter "mo:core/Iter";
import Blob "mo:core/Blob";
import Nat8 "mo:core/Nat8";

import Map "../src/Map";

let m = Map.empty({
  pointer_size = 1;
  aridity = 256;
  root_aridity = ?256;
  key_size = 1;
  value_size = 1;
});

func key(b : Nat) : Blob = Blob.fromArray([Nat8.fromNat(b)]);

// Fill all 128 leaf slots — one per root slot 0..127. Trapping `add`
// is safe here because each one is a fresh key with empty target slot.
var i = 0;
while (i < 128) {
  m.add(key(i), "v");
  i += 1;
};

// Inspect: every leaf used, no internal nodes beyond root, no freed
// slots on either list.
assert m.size() == 128;
assert m.leaf_count == 128; // == max_address
assert m.node_count == 1; // only the root
assert m.empty_leaves_list.count == 0;
assert m.empty_nodes_list.count == 0;

// The 129th add would overflow the leaf pointer space. addChecked
// returns #err and the trie stays untouched.
assert m.addChecked(key(200), "v") == #err(#LimitExceeded);
assert m.size() == 128;
assert m.leaf_count == 128;
assert m.node_count == 1;
assert m.empty_leaves_list.count == 0;
assert m.get(key(200)) == null;

// Iteration still yields exactly the 128 originally-added entries in
// ascending key order.
do {
  let entries = Iter.toArray(m.entries());
  assert entries.size() == 128;
  var j = 0;
  while (j < 128) {
    assert entries[j] == (key(j), "v");
    j += 1;
  };
};

// Delete one entry. leaf_count stays at the high-water mark; the freed
// slot lands on empty_leaves_list.
let removed = m.delete(key(0));
assert removed;
assert m.size() == 127;
assert m.leaf_count == 128; // high-water unchanged
assert m.empty_leaves_list.count == 1;
assert m.node_count == 1;

// Re-attempt the previously-failing add. Now there's room (via the
// free list), so it succeeds. leaf_count stays at the high-water
// mark; the freed slot is reused.
m.add(key(200), "x");
assert m.size() == 128;
assert m.leaf_count == 128;
assert m.empty_leaves_list.count == 0;
assert m.node_count == 1;

// Final invariant: live entries match the set we expect.
assert m.get(key(0)) == null;
assert m.get(key(200)) == ?"x";
do {
  let entries = Iter.toArray(m.entries());
  assert entries.size() == m.size();
  // Spot-check sorted order: key(1) is first, key(200) is last.
  assert entries[0] == (key(1), "v");
  assert entries[entries.size() - 1] == (key(200), "x");
};
