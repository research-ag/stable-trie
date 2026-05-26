// @testmode wasi

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Nat_ "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64_ "mo:core/Nat64";
import Iter "mo:core/Iter";
import Prng "mo:prng";

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
        prev := Array.tabulate<Nat8>(size, func(j) = Nat8.fromIntWrap(rng.next().toNat()));
        Blob.fromArray(prev);
      } else {
        Blob.fromArray(Array.tabulate<Nat8>(size, func(j) = if (j + 1 < size) prev[j] else if (prev[j] == 255) 0 else prev[j] + 1));
      };
    },
  );
};

let keys = gen(n, key_size);
let delete_keys = gen(n, key_size);
let sorted = keys.sort();
let revSorted = sorted.reverse();
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
        assert trie.size() == i + 1;
        i += 1;
      };
      assert trie.memoryStats().total_leaf_count == n;

      i := 0;
      for (key in delete_keys.vals()) {
        trie.put(key, values[i]);
        assert trie.size() == keys.size() + i + 1;
        i += 1;
      };
      assert trie.memoryStats().total_leaf_count == 2 * n;

      i := 0;
      for (key in delete_keys.vals()) {
        assert trie.remove(key) == ?values[i];
        assert trie.size() == (2 * n - i - 1 : Nat);
        i += 1;
      };
      assert trie.memoryStats().total_leaf_count == 2 * n;

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
      assert trie.size() == 0;
      assert trie.memoryStats().total_leaf_count == 2 * n;

      do {
        let vals = Iter.toArray(Iter.map<(Blob, Blob), Blob>(trie.entries(), func((a, _)) = a));
        assert vals == [];

        let revVals = Iter.toArray(Iter.map<(Blob, Blob), Blob>(trie.entriesRev(), func((a, _)) = a));
        assert revVals == [];
      };

      let before = trie.memoryStats();
      i := 0;
      for (key in keys.vals()) {
        trie.put(key, values[i]);
        i += 1;
      };
      assert trie.size() == n;
      assert trie.memoryStats().total_leaf_count == 2 * n;
      assert trie.memoryStats().total_node_count == before.total_node_count;
    };
  };
};

do {
  let trie = StableTrie.Map({
    pointer_size = 2;
    aridity = 4;
    root_aridity = null;
    key_size = 1;
    value_size = 0;
  });
  let keys = Array.tabulate<Blob>(256, func(i) = Blob.fromArray([i.toNat8()]));
  for (key in keys.vals()) {
    trie.put(key, "");
  };
  for (key in keys.vals()) {
    assert trie.get(key) == ?"";
  };
  for (key in keys.vals()) {
    trie.delete(key);
  };
  for (key in keys.vals()) {
    assert trie.get(key) == null;
  };
};

// Legacy StableData round-trip. Pre-0.0.9 `Map.StableData` carried
// `empty_nodes` as a required field on Map's extension; the current schema
// moves it onto `Base.StableData` as an optional. Build a StableData with
// `empty_nodes = null` (the value Motoko's stable-type widening would produce
// for data that predates the field) and verify unshare accepts it and the
// Map still functions.
do {
  let source = StableTrie.Map({
    pointer_size = 2;
    aridity = 4;
    root_aridity = null;
    key_size = 1;
    value_size = 1;
  });
  source.put("\01", "A");
  source.put("\02", "B");
  source.put("\03", "C");
  // Removing a key populates empty_leaves so the share round-trip is
  // non-trivial.
  ignore source.remove("\02");

  let s = source.share();
  let legacy : StableTrie.StableData = {
    nodes = s.nodes;
    leaves = s.leaves;
    node_count = s.node_count;
    leaf_count = s.leaf_count;
    empty_nodes = null; // legacy: field absent in v0.0.8 storage
    empty_leaves = s.empty_leaves;
  };

  let restored = StableTrie.Map({
    pointer_size = 2;
    aridity = 4;
    root_aridity = null;
    key_size = 1;
    value_size = 1;
  });
  restored.unshare(legacy);

  assert restored.size() == 2;
  assert restored.get("\01") == ?"A";
  assert restored.get("\02") == null;
  assert restored.get("\03") == ?"C";

  // empty_leaves survived; empty_nodes starts fresh. Adding a fresh key
  // should reuse the freed leaf slot, leaving total counts unchanged.
  let before = restored.memoryStats();
  restored.put("\04", "D");
  let after = restored.memoryStats();
  assert after.used_leaf_count == 3;
  assert after.total_leaf_count == before.total_leaf_count;
  assert restored.get("\04") == ?"D";

  // And remove should still cascade-collapse correctly even though we
  // started with an empty empty_nodes list.
  ignore restored.remove("\01");
  ignore restored.remove("\03");
  ignore restored.remove("\04");
  assert restored.size() == 0;
};
