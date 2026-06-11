// @testmode wasi

import Debug "mo:core/Debug";
import Float "mo:core/Float";
import Region "mo:core/Region";
import Seiran128 "mo:prng/Seiran128";

import StableTrie "../src/Enumeration";

let key_size = 8;
let pointer_size = 6;
let k = 4;

let rng = Seiran128.new(0);

// Region full of random data
// 8 pages = 512 kB (64k keys)
let rnd1 = Region.new();
let rnd2 = Region.new();
let buf = Region.new();
assert rnd1.grow(8) != 0xffff_ffff_ffff_ffff;
assert rnd2.grow(8) != 0xffff_ffff_ffff_ffff;
assert buf.grow(1) != 0xffff_ffff_ffff_ffff;

do {
  var n = 2 ** 16;
  var pos : Nat64 = 0;
  while (n > 0) {
    rnd1.storeNat64(pos, rng.next());
    rnd2.storeNat64(pos, rng.next());
    n -= 1;
    pos += 8;
  };
};

let trie = StableTrie.empty({
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
  let key1 = rnd1.loadNat64(pos1);
  var n2 = max;
  var pos2 : Nat64 = 0;
  while (n2 > 0) {
    let key2 = rnd2.loadNat64(pos2);
    buf.storeNat64(0, key1 ^ key2);
    let key = buf.loadBlob(0, 8);
    n2 -= 1;
    pos2 += 8;
    ignore trie.add(key, "");
  };
  n1 -= 1;
  pos1 += 8;
};

let s = trie.memoryStats();
Debug.print("children number: " # debug_show k);
Debug.print("pointer size: " # debug_show pointer_size);
Debug.print("keys: " # debug_show (max * max));
Debug.print("byte size: " # debug_show s.total_bytes);
Debug.print("bytes per key: " # debug_show (s.total_bytes / (max * max)));
let (leaves, nodes) = (s.used_leaf_count, s.used_node_count);
Debug.print("leaves (=keys): " # debug_show leaves);
Debug.print("nodes: " # debug_show nodes);
Debug.print("nodes per leaf: " # debug_show (Float.fromInt(nodes) / Float.fromInt(leaves)));
Debug.print("pointers per leaf: " # debug_show (Float.fromInt(nodes * k) / Float.fromInt(leaves)));
Debug.print("children per node: " # debug_show (Float.fromInt(nodes + leaves) / Float.fromInt(nodes)));
Debug.print("children utilization: " # debug_show (Float.fromInt(nodes + leaves) / Float.fromInt(nodes * k)));
