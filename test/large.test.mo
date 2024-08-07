// @testmode wasi

import Prng "mo:prng";
import Nat64 "mo:base/Nat64";
import Region "mo:base/Region";
import Debug "mo:base/Debug";
import Float "mo:base/Float";
import StableTrie "../src/Enumeration";

let key_size = 8;
let pointer_size = 6;
let k = 4;

let rng = Prng.Seiran128();
rng.init(0);

// Region full of random data
// 8 pages = 512 kB (64k keys)
let rnd1 = Region.new();
let rnd2 = Region.new();
let buf = Region.new();
assert Region.grow(rnd1, 8) != 0xffff_ffff_ffff_ffff;
assert Region.grow(rnd2, 8) != 0xffff_ffff_ffff_ffff;
assert Region.grow(buf, 1) != 0xffff_ffff_ffff_ffff;

do {
  var n = 2 ** 16;
  var pos : Nat64 = 0;
  while (n > 0) {
    Region.storeNat64(rnd1, pos, rng.next());
    Region.storeNat64(rnd2, pos, rng.next());
    n -= 1;
    pos += 8;
  };
};

let trie = StableTrie.Enumeration({
    pointer_size;
    aridity = k;
    root_aridity = null;
    key_size;
    value_size = 0;
  });

let max = 512;
var n1 = max;
var pos1 : Nat64 = 0;
// only works for key size 8
while (n1 > 0) {
  let key1 = Region.loadNat64(rnd1, pos1);
  var n2 = max;
  var pos2 : Nat64 = 0;
  while (n2 > 0) {
    let key2 = Region.loadNat64(rnd2, pos2);
    Region.storeNat64(buf, 0, key1 ^ key2);
    let key = Region.loadBlob(buf, 0, 8);
    n2 -= 1;
    pos2 += 8;
    ignore trie.add(key, "");
  };
  n1 -= 1;
  pos1 += 8;
};

Debug.print("children number: " # debug_show k);
Debug.print("pointer size: " # debug_show pointer_size);
Debug.print("keys: " # debug_show (max * max));
Debug.print("size: " # debug_show trie.size());
Debug.print("bytes per key: " # debug_show (trie.size() / (max * max)));
let s = trie.memoryStats();
let (leafs, nodes) = (s.leaf_count, s.node_count);
Debug.print("leafs (=keys): " # debug_show leafs);
Debug.print("nodes: " # debug_show nodes);
Debug.print("nodes per leaf: " # debug_show (Float.fromInt(nodes) / Float.fromInt(leafs)));
Debug.print("pointers per leaf: " # debug_show (Float.fromInt(nodes * k) / Float.fromInt(leafs)));
Debug.print("children per node: " # debug_show (Float.fromInt(nodes + leafs) / Float.fromInt(nodes)));
Debug.print("children utilization: " # debug_show (Float.fromInt(nodes + leafs) / Float.fromInt(nodes * k)));
