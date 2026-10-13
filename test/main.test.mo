// @testmode wasi

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64_ "mo:core/Nat64";
import Iter "mo:core/Iter";
import Result "mo:core/Result";
import Types "mo:core/Types";
import Seiran128 "mo:prng/Seiran128";

import StableTrie "../src/Enumeration";

let rng = Seiran128.new(0);

let n = 2 ** 11;
let key_size = 5;

func gen(n : Nat, size : Nat) : [Blob] {
  var prev : [Nat8] = [];
  Array.tabulate<Blob>(
    n,
    func(i) {
      if (i % 2 == 0) {
        prev := Array.tabulate<Nat8>(size, func(j) = Nat8.fromIntWrap(rng.next().toNat()));
        prev.toBlob();
      } else {
        let t = rng.next().toNat() % key_size;
        (Array.tabulate<Nat8>(size, func(j) = if (j < t) prev[j] else Nat8.fromIntWrap(rng.next().toNat()))).toBlob();
      };
    },
  );
};

let keys = gen(n, key_size);
let sorted = keys.sort();
let revSorted = sorted.reverse();
let keysAbsent = gen(n, key_size);

// Note: bits = 256 and pointers = 2 requires smaller n
let value_sizes = [0, 2];
let bits = [2, 4, 16];
let pointers = [2, 3, 4, 5, 6, 8];
for (value_size in value_sizes.values()) {
  let values = gen(n, value_size);
  for (bit in bits.values()) {
    for (pointer in pointers.values()) {
      let trie = StableTrie.empty({
        pointer_size = pointer;
        aridity = bit;
        root_aridity = ?(bit ** 3);
        key_size;
        value_size;
      });

      var i = 0;
      for (key in keys.values()) {
        assert trie.add(key, values[i]) == i;
        assert trie.size() == i + 1;
        i += 1;
      };

      i := 0;
      for (key in keys.values()) {
        assert trie.get(i) == ?(key, values[i]);
        i += 1;
      };

      i := 0;

      for (key in keys.values()) {
        assert (trie.lookup(key) == ?(values[i], i));
        i += 1;
      };

      for (key in keysAbsent.values()) {
        assert trie.lookup(key) == null;
      };

      let vals = trie.entries().map<(Blob, Blob), Blob>(func((a, _)) = a).toArray();
      assert vals == sorted;

      let revVals = trie.reverseEntries().map<(Blob, Blob), Blob>(func((a, _)) = a).toArray();
      assert revVals == revSorted;
    };
  };
};

func pointerMaxSizeTest() {
  let trie = StableTrie.empty({
    pointer_size = 2;
    aridity = 2;
    root_aridity = null;
    key_size = 2;
    value_size = 0;
  });
  for (i in Nat.range(0, 32_000 + 1)) {
    let key = [Nat8.fromIntWrap(i), (i / 256).toNat8()].toBlob();
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
  let rng = Seiran128.new(0);
  let keys = Array.tabulate<Blob>(
    2 ** n,
    func(i) {
      (Array.tabulate<Nat8>(key_size, func(j) = Nat8.fromIntWrap(rng.next().toNat()))).toBlob();
    },
  );
  let _rows = children_number.values().map<Nat, (Text, Types.Iter<Text>)>(
    func(k) {
      let first = k.toText();
      let trie = StableTrie.empty({
        pointer_size = 8;
        aridity = k;
        root_aridity = ?k;
        key_size;
        value_size = 0;
      });
      let second = Nat.range(0, n + 1).map<Nat, Text>(
        func(i) {
          if (i == 0) {
            ignore trie.add(keys[0], "");
          } else {
            for (j in Nat.range(2 ** (i - 1), 2 ** i)) {
              assert Result.isOk(trie.addChecked(keys[j], ""));
            };
          };
          "";
          // Nat.toText(trie.size() / 2 ** i);
        }
      );
      (first, second);
    }
  );
};

// profile();
