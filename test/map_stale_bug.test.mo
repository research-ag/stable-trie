// @testmode wasi
//
// Regression test for a stale-pointer bug that previously existed in
// `StableTrie.Map`. The bug is now prevented by `Map.removeRec`, which
// clears the surviving leaf slot via `Layout.setChild(self, node, slot, 0)`
// before calling `Trie.pushEmptyNode` (see src/Map.mo). `Trie.pushEmptyNode`
// itself just links the node into `empty_nodes_list` — it does not clear
// any slots, so it does not need to: the clearing is a Map-removal-side
// responsibility, not a free-list responsibility.
//
// The shape of the bug, before the fix:
//
// When `removeRec` collapsed an internal node N because N had a single
// leaf child, the surviving leaf pointer was bubbled up to N's parent slot
// and N was pushed to `empty_nodes`. The push only overwrites N's slot 0
// (the linked-list link goes there); all other slots — including the slot
// that still held the bubbled-up leaf pointer — were left intact.
//
// The next time N was popped, `pop` cleared slot 0 again, but `put_` only
// writes to the two slots for the diverging keys at the split point. If
// neither happened to be the stale one, N rejoined the trie at some new
// position with a leftover leaf pointer in one of its slots — and the leaf
// at that index was reachable through two paths in the trie.
//
// Once the original leaf at that index was freed and reused by an unrelated
// key, the stale pointer silently aliased that new key's entry. `entries()`
// then visited the new entry twice, while `size()` correctly reported it
// once.
//
// The construction below uses aridity = 4 (the bug did not reproduce at
// aridity = 2, because a 2-way split always writes both slots and so
// always overwrites any stale data). With the fix in place, all three live
// entries are yielded exactly once.

import Iter "mo:core/Iter";
import StableTrie "../src/Map";

let m = StableTrie.empty({
  pointer_size = 2;
  aridity = 4;
  root_aridity = ?4;
  key_size = 1;
  value_size = 1;
});

// Step 1. Add two keys that share bits 0-5 and differ at bits 6-7 (slots 0
// and 3 of the bottom inner node). put_ builds the chain
//   root[0] -> I1 -> I2 -> I3
// with I3[0] = leafA, I3[3] = leafB.
m.add("\00", "A");
m.add("\03", "B");

// Step 2. Remove "\00". branchRoot(I3) returns leafB (the surviving leaf at
// slot 3); the cascade collapses I2 and I1 too. All three nodes are pushed to
// empty_nodes. With the fix in `Map.removeRec`, each collapsing node has its
// surviving slot cleared (`Layout.setChild(node, slot, 0)`) before being
// pushed, so I3[3] no longer carries a leftover leaf pointer.
m.remove("\00");

// Step 3. Add a fresh pair "\40", "\41" under root[1]. They share bits 0-5
// and differ at bits 6-7 (slots 0 and 1 of the bottom inner node). put_ pops
// I1, I2, I3 from empty_nodes (LIFO) and reuses I3 as the split point,
// writing leaves at slots 0 and 1. Slot 3 — which would have carried the
// stale pointer without the fix — is already 0.
m.add("\40", "C");
m.add("\41", "D");

// Step 4. Remove "\03" via its legitimate path at root[0]. The leaf slot
// (the same index that I3[3] used to point to) lands on empty_leaves.
m.remove("\03");

// Step 5. Add "\80". newLeaf pops the freed slot, so the leaf at that index
// now holds key "\80", value "X". Without the fix, I3[3] would still encode
// a pointer to that index, aliasing the new entry through a phantom path.
m.add("\80", "X");

// The trie has exactly three live entries.
assert m.size() == 3;

// With the fix in place, iteration walks each live entry exactly once —
// no phantom path through the cleared slot. Without the fix, this assert
// would fail (entries.size() == 4, size() == 3) because ("\80", "X") would
// be yielded twice.
let entries = Iter.toArray(m.entries());
assert entries.size() == m.size();
