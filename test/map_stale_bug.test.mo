// @testmode wasi
//
// Demonstrates a latent stale-pointer bug in StableTrie.Map.
//
// When `removeRec` collapses an internal node N because N has a single leaf
// child, the surviving leaf pointer is bubbled up to N's parent slot and N is
// pushed to `empty_nodes`. The push, however, only overwrites N's slot 0 (it
// stores the linked-list link there). All other slots — including the slot
// that still holds the bubbled-up leaf pointer — are left intact.
//
// The next time N is popped, `pop` clears slot 0 again, but `put_` only
// writes to the two slots for the diverging keys at the split point. If
// neither of those slots happens to be the stale one, N rejoins the trie at
// some new position with a leftover leaf pointer in one of its slots — and
// the leaf at that index is now reachable through two paths in the trie.
//
// Once the original leaf at that index is freed and reused by an unrelated
// key, the stale pointer silently aliases that new key's entry. `entries()`
// then visits the new entry twice, while `size()` correctly reports it once.
//
// The construction below uses aridity = 4 (it does not reproduce at aridity
// = 2, because a 2-way split always writes both slots and so always
// overwrites any stale data).

import Iter "mo:core/Iter";
import StableTrie "../src/Map";

let m = StableTrie.Map({
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
m.put("\00", "A");
m.put("\03", "B");

// Step 2. Remove "\00". branchRoot(I3) returns leafB (the surviving leaf at
// slot 3); the cascade collapses I2 and I1 too. All three nodes are pushed to
// empty_nodes. CRITICAL: when I3 is pushed, push only overwrites slot 0 —
// slot 3 still contains the leafB pointer.
ignore m.remove("\00");

// Step 3. Add a fresh pair "\40", "\41" under root[1]. They share bits 0-5
// and differ at bits 6-7 (slots 0 and 1 of the bottom inner node). put_ pops
// I1, I2, I3 from empty_nodes (LIFO) and reuses I3 as the split point,
// writing leaves at slots 0 and 1. Slot 3 (the stale pointer) is never
// touched — `pop` only cleared slot 0.
m.put("\40", "C");
m.put("\41", "D");

// Step 4. Remove "\03" via its legitimate path at root[0]. The leaf slot
// (the index that I3[3] still points to) lands on empty_leaves.
ignore m.remove("\03");

// Step 5. Add "\80". newLeaf pops the freed slot, so the leaf at that index
// now holds key "\80", value "X". I3[3] still encodes a pointer to that
// same index — silently aliasing root[2].
m.put("\80", "X");

// The trie has exactly three live entries.
assert m.size() == 3;

// But iteration walks every non-zero slot, so it traverses I3[3] AND root[2]
// and yields ("\80", "X") twice — giving 4 items total.
let entries = Iter.toArray(m.entries());
assert entries.size() == m.size();
