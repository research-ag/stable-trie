// @testmode wasi
//
// Smoke test for `pointer_size = 1`. ps=1 is allowed only for tests: it
// shrinks `max_address` to 2**7 = 128, making it cheap to construct
// scenarios that exercise the pointer-size cap. This file just sanity-
// checks that the basic CRUD paths work under ps=1 (the new branches in
// `Layout.setChild` and `LinkedList.storePointer` cover `ps == 1`).

import Iter "mo:core/Iter";

import Map "../src/Map";

let m = Map.empty({
  pointer_size = 1;
  aridity = 4;
  root_aridity = ?4;
  key_size = 1;
  value_size = 1;
});

// add, get, containsKey
assert m.swap("\00", "A") == null;
assert m.swap("\01", "B") == null;
assert m.swap("\02", "C") == null;
assert m.swap("\01", "X") == ?"B"; // overwrite
assert m.size() == 3;
assert m.get("\00") == ?"A";
assert m.get("\01") == ?"X";
assert m.get("\02") == ?"C";
assert m.get("\03") == null;
assert m.containsKey("\01");
assert not m.containsKey("\03");

// entries iteration in key order
assert Iter.toArray(m.entries()) == [("\00", "A"), ("\01", "X"), ("\02", "C")];

// remove + free-list reuse
m.remove("\01");
assert m.size() == 2;
assert m.get("\01") == null;
m.add("\05", "E");
assert m.size() == 3;
assert m.get("\05") == ?"E";
