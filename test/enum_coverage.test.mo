// @testmode wasi
//
// Coverage for Enumeration functions not exercised elsewhere:
//   insert / insertChecked              ((Bool, Nat) return)
//   lookupOrAdd / lookupOrAddChecked    ((?V, Nat), writes-only-if-absent)
//   put                                 (O(1) by-index value overwrite)
//   at                                  (trapping by-index read — happy path only)
//   truncate                            (List.truncate semantics)
//   values / reverseValues              (sibling iterators)
//   keys / reverseKeys                  (sibling iterators)
//   isEmpty                             (wrapper around size == 0)
//
// OOB-trap paths (put with i >= size, at with i >= size) are NOT
// exercised here: a trap aborts the wasi test runner, so there's no
// way to assert "this would have trapped" from inside the test. The
// matching `get` semantics are verified instead (`get(i)` returns
// `null` for out-of-range and `at(i)` mirrors it on the in-range
// side).

import Iter "mo:core/Iter";

import Enumeration "../src/Enumeration";

let e = Enumeration.empty({
  pointer_size = 2;
  aridity = 4;
  root_aridity = null;
  key_size = 1;
  value_size = 1;
});

// isEmpty on a fresh enumeration.
assert e.isEmpty();
assert e.size() == 0;

// insert: returns (was-new, index). Always writes. Existing key
// returns the original index (insertion-order, never reassigned).
//
// We deliberately insert keys in non-sorted order so the
// key-sorted iterators below have something to actually reorder.
assert e.insert("\03", "A") == (true, 0); // new at idx 0
assert e.insert("\01", "B") == (true, 1); // new at idx 1
assert e.insert("\03", "X") == (false, 0); // existing, value overwritten
assert e.lookup("\03") == ?("X", 0);
assert e.size() == 2;
assert not e.isEmpty();

// insertChecked: same shape, wrapped in Result.
assert e.insertChecked("\02", "C") == #ok(true, 2); // new at idx 2
assert e.insertChecked("\03", "Y") == #ok(false, 0); // existing → idx 0

// lookupOrAdd: writes ONLY if key is absent. Returns (?prev, index).
assert e.lookupOrAdd("\05", "D") == (null, 3); // new → writes, returns null
assert e.lookupOrAdd("\05", "X") == (?"D", 3); // existing → no write
assert e.lookup("\05") == ?("D", 3); // unchanged

// lookupOrAddChecked.
assert e.lookupOrAddChecked("\04", "E") == #ok(null, 4); // new
assert e.lookupOrAddChecked("\04", "X") == #ok(?"E", 4); // existing, no write
assert e.lookup("\04") == ?("E", 4); // unchanged

// State so far (in insertion order, by index):
//   0 → ("\03", "Y")
//   1 → ("\01", "B")
//   2 → ("\02", "C")
//   3 → ("\05", "D")
//   4 → ("\04", "E")
assert e.size() == 5;

// put: O(1) value overwrite at index. Key at that index is unchanged.
e.put(0, "Z"); // overwrite value at idx 0 (key stays "\03")
assert e.lookup("\03") == ?("Z", 0);
assert e.at(0) == ("\03", "Z");

// at: trapping by-index read on a valid index.
assert e.at(0) == ("\03", "Z");
assert e.at(4) == ("\04", "E");

// get: matching Option-form. Out-of-range returns null (the path
// `at` would trap on — verified via `get` so we don't kill the test).
assert e.get(0) == ?("\03", "Z");
assert e.get(5) == null; // size is 5, so 5 is OOB
assert e.get(99) == null;

// Iteration by key (sorted): \01 → \02 → \03 → \04 → \05.
assert Iter.toArray(e.keys()) == ["\01" : Blob, "\02", "\03", "\04", "\05"];
assert Iter.toArray(e.reverseKeys()) == ["\05" : Blob, "\04", "\03", "\02", "\01"];

// values / reverseValues — key-sorted order, value side.
//   \01 → B, \02 → C, \03 → Z, \04 → E, \05 → D
assert Iter.toArray(e.values()) == ["B" : Blob, "C", "Z", "E", "D"];
assert Iter.toArray(e.reverseValues()) == ["D" : Blob, "E", "Z", "C", "B"];

// `range(0, size())` iterates in INSERTION order — distinct from the
// key-sorted views above.
assert Iter.toArray(e.range(0, e.size())) == [
  ("\03" : Blob, "Z" : Blob),
  ("\01", "B"),
  ("\02", "C"),
  ("\05", "D"),
  ("\04", "E"),
];

// truncate: drops entries from `newSize` onwards.
e.truncate(3); // keep indices 0..2
assert e.size() == 3;
// Surviving entries are the first three by insertion order.
assert e.at(0) == ("\03", "Z");
assert e.at(1) == ("\01", "B");
assert e.at(2) == ("\02", "C");
// Dropped keys are gone.
assert e.lookup("\05") == null;
assert e.lookup("\04") == null;
assert not e.containsKey("\05");

// truncate is a no-op when newSize >= size().
e.truncate(3);
assert e.size() == 3;
e.truncate(100); // newSize > size → also no-op
assert e.size() == 3;

// truncate(0) clears everything.
e.truncate(0);
assert e.size() == 0;
assert e.isEmpty();
// Iterators on an empty enumeration yield no elements.
assert Iter.toArray(e.values()) == ([] : [Blob]);
assert Iter.toArray(e.reverseValues()) == ([] : [Blob]);
assert Iter.toArray(e.keys()) == ([] : [Blob]);
assert Iter.toArray(e.reverseKeys()) == ([] : [Blob]);
assert Iter.toArray(e.range(0, 0)) == ([] : [(Blob, Blob)]);
