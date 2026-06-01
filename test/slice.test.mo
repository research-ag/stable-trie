// @testmode wasi
//
// Covers Enumeration.sliceToArray and Enumeration.range for the cases the
// 0.0.8/0.1.0 `slice` got wrong — non-zero `left` and the empty slice.

import Iter "mo:core/Iter";

import Enumeration "../src/Enumeration";

let e = Enumeration.empty({
  pointer_size = 2;
  aridity = 4;
  root_aridity = null;
  key_size = 1;
  value_size = 1;
});

assert e.add("\00", "A") == 0;
assert e.add("\01", "B") == 1;
assert e.add("\02", "C") == 2;
assert e.add("\03", "D") == 3;
assert e.add("\04", "E") == 4;
assert e.size() == 5;

// ─── sliceToArray ─────────────────────────────────────────────────────────

// Full slice — left=0 (the case the old buggy `slice` happened to handle).
assert e.sliceToArray(0, 5) == [
  ("\00", "A"),
  ("\01", "B"),
  ("\02", "C"),
  ("\03", "D"),
  ("\04", "E"),
];

// Slices starting at left > 0 — the case the old `slice` got wrong.
assert e.sliceToArray(1, 4) == [("\01", "B"), ("\02", "C"), ("\03", "D")];
assert e.sliceToArray(2, 3) == [("\02", "C")];
assert e.sliceToArray(4, 5) == [("\04", "E")];

// Empty slices.
assert e.sliceToArray(0, 0) == [];
assert e.sliceToArray(3, 3) == [];
assert e.sliceToArray(5, 5) == []; // at the boundary

// ─── range (lazy iterator) ────────────────────────────────────────────────

// Same checks, but via the lazy iterator.
assert Iter.toArray(e.range(0, 5)) == [
  ("\00", "A"),
  ("\01", "B"),
  ("\02", "C"),
  ("\03", "D"),
  ("\04", "E"),
];
assert Iter.toArray(e.range(1, 4)) == [("\01", "B"), ("\02", "C"), ("\03", "D")];
assert Iter.toArray(e.range(2, 3)) == [("\02", "C")];
assert Iter.toArray(e.range(4, 5)) == [("\04", "E")];

assert Iter.toArray(e.range(0, 0)) == [];
assert Iter.toArray(e.range(3, 3)) == [];
assert Iter.toArray(e.range(5, 5)) == [];

// Range can be advanced one at a time.
do {
  let it = e.range(2, 5);
  assert it.next() == ?("\02", "C");
  assert it.next() == ?("\03", "D");
  assert it.next() == ?("\04", "E");
  assert it.next() == null;
  assert it.next() == null; // idempotent past end
};
