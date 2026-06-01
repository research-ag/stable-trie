// @testmode wasi
//
// Runs the `Map` code example shown in README.md verbatim (except for the
// `mo:stable-trie/Map` import being rewritten to the in-repo relative
// path). Keeps the example in lock-step with the actual API.

import Iter "mo:core/Iter";
import Map "../src/Map";

let m = Map.empty({
  pointer_size = 2;
  aridity = 2;
  root_aridity = null;
  key_size = 3;
  value_size = 1;
});
assert (m.swap("abc", "a") == null);
assert (m.swap("aaa", "b") == null);
assert (m.swap("abc", "c") == ?"a");

assert Iter.toArray(m.entries()) == [("aaa", "b"), ("abc", "c")];

m.remove("abc");
m.remove("aaa");
