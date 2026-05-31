// @testmode wasi
//
// Runs the `Map` code example shown in README.md, verbatim except for the
// added `import Iter`. Keeps the example in lock-step with the actual API.

import Iter "mo:core/Iter";
import Map "../src/Map";

let m = Map.empty({
  pointer_size = 2;
  aridity = 2;
  root_aridity = null;
  key_size = 3;
  value_size = 1;
});
assert (m.replace("abc", "a") == null);
assert (m.replace("aaa", "b") == null);
assert (m.replace("abc", "c") == ?"a");

assert Iter.toArray(m.entries()) == [("aaa", "b"), ("abc", "c")];

m.delete("abc");
m.delete("aaa");
