// @testmode wasi
//
// Reproduces the put_/newLeaf-fail corruption bug in src/internal/trie.mo.
//
// When `newLeaf` fails inside `put_`'s split loop (line 342), the loop has
// already allocated a new internal node `add(k)`, hung it from its parent,
// and written `old_leaf` into one of its slots — but never gets to allocate
// the new leaf for the inserted key. The function returns `null`, the
// caller sees `#err(#LimitExceeded)`, and the trie is left with a single-
// child internal node whose only non-zero child is `old_leaf`.
//
// A subsequent `delete(old_key)` then walks into the trap: `removeRec`
// removes the leaf, clears the only slot, and calls `scanChildren` on a
// node with 0 non-zero children — which trips the
// `assert lone != 0` (trie.mo:248).
//
// Setup uses `pointer_size = 2` (max_address = 2^15 = 32_768) so we can
// reach the leaf-overflow condition within a test:
//
//   - root slots 0..126: 256 leaves each at depth 2  → 32_512 leaves
//   - root slot   127  : 255 leaves (byte1 0..254)   →    255 leaves
//   - root slot   128  : 1 leaf at depth 1 (byte1 0) →      1 leaf
//   Total leaves = 32_768 = max_address.
//
// Internal nodes used ≈ 1 (root) + 128 (level-1 internals for slots
// 0..127) = 129, far below the cap. So when we now try to add (128, 1):
//   - `find` lands on the depth-1 leaf at root[128] → enter split loop.
//   - `newInternalNode` succeeds (internals far below cap).
//   - `setChild(new_internal, 0, old_leaf)` writes the old leaf at slot 0.
//   - `newLeaf` fails (leaf_count == max_address) → `addChecked` returns
//     `#err(#LimitExceeded)`. The trie is now corrupted.
//
// `delete((128, 0))` then traps. With the fix in place, `delete` should
// return `true`.

import Blob "mo:core/Blob";
import Nat8 "mo:core/Nat8";

import Map "../src/Map";

let m = Map.empty({
  pointer_size = 2;
  aridity = 256;
  root_aridity = ?256;
  key_size = 2;
  value_size = 0;
});

func key(b0 : Nat, b1 : Nat) : Blob = Blob.fromArray([Nat8.fromNat(b0), Nat8.fromNat(b1)]);

// Fill 32_512 leaves at depth 2 in slots 0..126.
var b0 = 0;
while (b0 <= 126) {
  var b1 = 0;
  while (b1 <= 255) {
    assert m.addChecked(key(b0, b1), "") == #ok();
    b1 += 1;
  };
  b0 += 1;
};

// 255 leaves at depth 2 in slot 127 (skip byte1 = 255).
var b1 = 0;
while (b1 <= 254) {
  assert m.addChecked(key(127, b1), "") == #ok();
  b1 += 1;
};

// 1 leaf at depth 1 in slot 128. Total now 32_768 = max_address.
assert m.addChecked(key(128, 0), "") == #ok();
assert m.size() == 32_768;

// Provoke the bug: `find` lands on root[128]'s depth-1 leaf, split loop
// runs, `newInternalNode` succeeds, `setChild(new, 0, old_leaf)`, then
// `newLeaf` fails → `#err(#LimitExceeded)`. Trie is now corrupted.
assert m.addChecked(key(128, 1), "") == #err(#LimitExceeded);

// size must be unchanged — no new leaf was added.
assert m.size() == 32_768;

// Bug exposure: this delete traps on scanChildren's `assert lone != 0`.
// With the fix, the failed `addChecked` above leaves the trie unchanged
// and this delete returns `true`.
assert m.delete(key(128, 0));
assert m.size() == 32_767;
