// @testmode wasi

import Prng "mo:prng";
import Array "mo:base/Array";
import Blob "mo:base/Blob";
import Nat8 "mo:base/Nat8";
import Nat64 "mo:base/Nat64";
import Iter "mo:base/Iter";
import Nat "mo:base/Nat";
import Debug "mo:base/Debug";
import Result "mo:base/Result";
import StableTrie "../src/Enumeration";

let rng = Prng.Seiran128();
rng.init(0);

let n = 2 ** 11;
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
        let t = Nat64.toNat(rng.next()) % key_size;
        Blob.fromArray(Array.tabulate<Nat8>(size, func(j) = if (j < t) prev[j] else Nat8.fromNat(Nat64.toNat(rng.next()) % 256)));
      };
    },
  );
};

let keys = gen(n, key_size);
let sorted = Array.sort<Blob>(keys, Blob.compare);
let revSorted = Array.reverse(sorted);
let keysAbsent = gen(n, key_size);

// Note: bits = 256 and pointers = 2 requires smaller n
let value_sizes = [0, 2];
let bits = [2, 4, 16];
let pointers = [2, 4, 5, 6, 8];
for (value_size in value_sizes.vals()) {
  let values = gen(n, value_size);
  for (bit in bits.vals()) {
    for (pointer in pointers.vals()) {
      let trie = StableTrie.Enumeration({
        pointer_size = pointer;
        aridity = bit;
        root_aridity = ?(bit ** 3);
        key_size;
        value_size;
      });

      var i = 0;
      for (key in keys.vals()) {
        assert trie.add(key, values[i]) == i;
        assert trie.size() == i + 1;
        i += 1;
      };
      
      i := 0;
      for (key in keys.vals()) {
        assert trie.get(i) == ?(key, values[i]);
        i += 1;
      };

      i := 0;

      for (key in keys.vals()) {
        assert (trie.lookup(key) == ?(values[i], i));
        i += 1;
      };

      for (key in keysAbsent.vals()) {
        assert trie.lookup(key) == null;
      };

      let vals = Iter.toArray(Iter.map<(Blob, Blob), Blob>(trie.entries(), func((a, _)) = a));
      assert vals == sorted;

      let revVals = Iter.toArray(Iter.map<(Blob, Blob), Blob>(trie.entriesRev(), func((a, _)) = a));
      assert revVals == revSorted;
    };
  };
};

func pointerMaxSizeTest() {
  let trie = StableTrie.Enumeration({
    pointer_size = 2;
    aridity = 2;
    root_aridity = null;
    key_size = 2;
    value_size = 0;
  });
  for (i in Iter.range(0, 32_000)) {
    let key = Blob.fromArray([Nat8.fromNat(i % 256), Nat8.fromNat(i / 256)]);
    if (trie.addChecked(key, "") != #ok(i)) {
      Debug.print(debug_show i);
      assert false;
    };
  };
};

pointerMaxSizeTest();

func _profile() {
  let children_number = [2, 4, 16, 256];

  let key_size = 8;
  let n = 20;
  let rng = Prng.Seiran128();
  rng.init(0);
  let keys = Array.tabulate<Blob>(
    2 ** n,
    func(i) {
      Blob.fromArray(Array.tabulate<Nat8>(key_size, func(j) = Nat8.fromNat(Nat64.toNat(rng.next()) % 256)));
    },
  );
  let _rows = Iter.map<Nat, (Text, Iter.Iter<Text>)>(
    children_number.vals(),
    func(k) {
      let first = Nat.toText(k);
      let trie = StableTrie.Enumeration({
        pointer_size = 8;
        aridity = k;
        root_aridity = ?k;
        key_size;
        value_size = 0;
      });
      let second = Iter.map<Nat, Text>(
        Iter.range(0, n),
        func(i) {
          if (i == 0) {
            ignore trie.add(keys[0], "");
          } else {
            for (j in Iter.range(2 ** (i - 1), 2 ** i - 1)) {
              assert Result.isOk(trie.addChecked(keys[j], ""));
            };
          };
          "";
          // Nat.toText(trie.size() / 2 ** i);
        },
      );
      (first, second);
    },
  );
};

// profile();
