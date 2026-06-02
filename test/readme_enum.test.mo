// @testmode wasi
//
// Runs the `Enumeration` code example shown in README.md verbatim.

import Enumeration "../src/Enumeration";

let e = Enumeration.empty({
  pointer_size = 2;
  aridity = 2;
  root_aridity = null;
  key_size = 3;
  value_size = 1;
});
assert (e.add("abc", "a") == 0);
assert (e.add("aaa", "b") == 1);
assert (e.add("abc", "c") == 0);

// Third `add` above overwrote the value at index 0 from "a" to "c".
assert e.sliceToArray(0, 2) == [("abc", "c"), ("aaa", "b")];

assert e.removeLast() == ?("aaa", "b"); // pop most-recently-added
assert e.size() == 1;
