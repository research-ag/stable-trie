// @testmode wasi
//
// Coverage for Map functions not exercised elsewhere:
//   insert / insertChecked         (was-new return)
//   swapChecked                    (Result form of swap)
//   replace                        (writes-only-if-present)
//   getOrAdd / getOrAddChecked     (writes-only-if-absent)
//   values / reverseValues         (sibling iterators)
//   keys / reverseKeys             (sibling iterators)
//   isEmpty                        (Bool wrapper around size == 0)

import Iter "mo:core/Iter";

import Map "../src/Map";

let m = Map.empty({
  pointer_size = 2;
  aridity = 4;
  root_aridity = null;
  key_size = 1;
  value_size = 1;
});

// isEmpty on a fresh map.
assert m.isEmpty();
assert m.size() == 0;

// insert: returns true on new key, false on overwrite. Always writes.
assert m.insert("\01", "A"); // new
assert m.insert("\02", "B"); // new
assert not m.insert("\01", "X"); // existing → overwritten, false
assert m.get("\01") == ?"X";
assert m.size() == 2;
assert not m.isEmpty();

// insertChecked: same shape, wrapped in Result.
assert m.insertChecked("\03", "C") == #ok(true); // new
assert m.insertChecked("\01", "Y") == #ok(false); // overwrite
assert m.get("\01") == ?"Y";
assert m.size() == 3;

// swapChecked: Result form of swap.
assert m.swapChecked("\01", "Z") == #ok(?"Y"); // overwrite, returns previous
assert m.swapChecked("\04", "D") == #ok(null); // new, returns null
assert m.get("\01") == ?"Z";
assert m.get("\04") == ?"D";
assert m.size() == 4;

// replace: writes ONLY if key already present.
assert m.replace("\01", "W") == ?"Z"; // present → writes, returns prev
assert m.get("\01") == ?"W";
assert m.replace("\7f", "X") == null; // absent → no-op, returns null
assert m.get("\7f") == null;
assert not m.containsKey("\7f"); // confirm replace didn't insert
assert m.size() == 4;

// getOrAdd: writes ONLY if key absent.
assert m.getOrAdd("\05", "E") == null; // new → writes, returns null
assert m.get("\05") == ?"E";
assert m.getOrAdd("\05", "X") == ?"E"; // present → no write, returns existing
assert m.get("\05") == ?"E"; // unchanged
assert m.size() == 5;

// getOrAddChecked: same shape, wrapped in Result.
assert m.getOrAddChecked("\06", "F") == #ok(null); // new
assert m.getOrAddChecked("\06", "X") == #ok(?"F"); // present, no write
assert m.get("\06") == ?"F"; // unchanged
assert m.size() == 6;

// At this point keys/values are:
//   \01 → W
//   \02 → B
//   \03 → C
//   \04 → D
//   \05 → E
//   \06 → F

// keys / reverseKeys — iterate in ascending / descending key order.
assert Iter.toArray(m.keys()) == ["\01" : Blob, "\02", "\03", "\04", "\05", "\06"];
assert Iter.toArray(m.reverseKeys()) == ["\06" : Blob, "\05", "\04", "\03", "\02", "\01"];

// values / reverseValues — same order, value side.
assert Iter.toArray(m.values()) == ["W" : Blob, "B", "C", "D", "E", "F"];
assert Iter.toArray(m.reverseValues()) == ["F" : Blob, "E", "D", "C", "B", "W"];

// Clear and confirm isEmpty.
m.remove("\01");
m.remove("\02");
m.remove("\03");
m.remove("\04");
m.remove("\05");
m.remove("\06");
assert m.isEmpty();
assert m.size() == 0;
// Iterators on an empty map yield no elements.
assert Iter.toArray(m.values()) == ([] : [Blob]);
assert Iter.toArray(m.reverseValues()) == ([] : [Blob]);
assert Iter.toArray(m.keys()) == ([] : [Blob]);
assert Iter.toArray(m.reverseKeys()) == ([] : [Blob]);
