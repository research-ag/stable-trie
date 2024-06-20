// @testmode wasi

import Prng "mo:prng";
import Array "mo:base/Array";
import Blob "mo:base/Blob";
import Nat8 "mo:base/Nat8";
import Nat64 "mo:base/Nat64";
import Iter "mo:base/Iter";
import Nat "mo:base/Nat";
import StableTrie "../src/Map";

let rng = Prng.Seiran128();
rng.init(0);

let n = 2 ** 10;
let key_size = 5;

func gen(n : Nat, size : Nat) : [Blob] {
  var prev : [Nat8] = [];
  Array.tabulate<Blob>(
    n,
    func(i) {
      if (i % 2 == 0) {
        prev := Array.tabulate<Nat8>(size, func(j) = Nat8.fromNat(Nat64.toNat(rng.next()) % 256));
        Blob.fromArray(prev);
      } else {
        Blob.fromArray(Array.tabulate<Nat8>(size, func(j) = if (j + 1 < size) prev[j] else if (prev[j] == 255) 0 else prev[j] + 1));
      };
    },
  );
};

let keys = gen(n, key_size);
let delete_keys = gen(n, key_size);
let sorted = Array.sort<Blob>(keys, Blob.compare);
let revSorted = Array.reverse(sorted);
let keysAbsent = gen(n, key_size);

// Note: bits = 256 and pointers = 2 requires smaller n
let value_sizes = [3, 4];
let bits = [2, 4, 16];
let pointers = [2, 4, 5, 6, 8];
for (value_size in value_sizes.vals()) {
  let values = gen(n, value_size);
  for (bit in bits.vals()) {
    for (pointer in pointers.vals()) {
      let trie = StableTrie.Map({
        pointer_size = pointer;
        aridity = bit;
        root_aridity = ?(bit ** 3);
        key_size;
        value_size;
      });

      var i = 0;
      for (key in keys.vals()) {
        trie.put(key, values[i]);
        i += 1;
      };

      i := 0;
      for (key in delete_keys.vals()) {
        trie.put(key, values[i]);
        i += 1;
      };

      i := 0;
      for (key in delete_keys.vals()) {
        assert trie.remove(key) == ?values[i];
        i += 1;
      };

      i := 0;

      for (key in keys.vals()) {
        assert (trie.get(key) == ?values[i]);
        i += 1;
      };

      for (key in keysAbsent.vals()) {
        assert trie.get(key) == null;
      };

      for (key in delete_keys.vals()) {
        assert trie.get(key) == null;
      };

      do {
        let vals = Iter.toArray(Iter.map<(Blob, Blob), Blob>(trie.entries(), func((a, _)) = a));
        assert vals == sorted;

        let revVals = Iter.toArray(Iter.map<(Blob, Blob), Blob>(trie.entriesRev(), func((a, _)) = a));
        assert revVals == revSorted;
      };

      i := 0;
      for (key in keys.vals()) {
        assert trie.remove(key) == ?values[i];
        i += 1;
      };
      
      do {
        let vals = Iter.toArray(Iter.map<(Blob, Blob), Blob>(trie.entries(), func((a, _)) = a));
        assert vals == [];

        let revVals = Iter.toArray(Iter.map<(Blob, Blob), Blob>(trie.entriesRev(), func((a, _)) = a));
        assert revVals == [];
      };

      let before = (trie.leafCount(), trie.nodeCount());
      i := 0;
      for (key in keys.vals()) {
        trie.put(key, values[i]);
        i += 1;
      };
      assert before == (trie.leafCount(), trie.nodeCount());
    };
  };
};
