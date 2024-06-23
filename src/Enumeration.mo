import Blob "mo:base/Blob";
import Nat64 "mo:base/Nat64";
import Nat "mo:base/Nat";
import Array "mo:base/Array";
import Iter "mo:base/Iter";

import Base "base";

module {
  public type StableData = Base.StableData;

  /// Bidirectional enumeration of any keys s in the order they are added.
  /// For a map from keys to index `Nat` it is implemented as trie in stable memory.
  /// for a map from index `Nat` to keys the implementation is a consecutive interval of stable memory.
  ///
  /// Arguments:
  /// + `pointer_size` is size of pointer of address space, first bit is reserved for internal use,
  ///   so max amount of nodes in stable trie is `2 ** (pointer_size * 8 - 1)`. Should be one of 2, 4, 5, 6, 8.
  /// + `aridity` is amount of children of any non leaf node except in trie. Should be one of 2, 4, 16, 256.
  /// + `root_aridity` is amount of children of root node.
  /// + `key_size` and `value_size` are sizes of key and value which should be constant per one instance of `Enumeration`
  ///
  /// Example:
  /// ```motoko
  /// let e = StableTrie.Enumeration({
  ///   pointer_size = 2;
  ///   aridity = 2;
  ///   root_aridity = null;
  ///   key_size = 2;
  ///   value_size = 0;
  /// });
  /// ```
  public class Enumeration(args : Base.Args) {
    let base : Base.StableTrieBase = Base.StableTrieBase(args);

    /// Add `key` and `value` to enumeration. Returns null if pointer size limit exceeded. Returns `size` if the key in new to the enumeration
    /// or rewrites value and returns index of key in enumeration otherwise.
    ///
    /// Example:
    /// ```motoko
    /// let e = StableTrie.Enumeration({
    ///   pointer_size = 2;
    ///   aridity = 2;
    ///   root_aridity = null;
    ///   key_size = 2;
    ///   value_size = 1;
    /// });
    /// assert(e.put("abc", "a") == ?0);
    /// assert(e.put("aaa", "b") == ?1);
    /// assert(e.put("abc", "c") == ?0);
    /// ```
    /// Runtime: O(key_size) acesses to stable memory.
    public func put(key : Blob, value : Blob) : ?Nat {
      let { leaves; nodes } = base.regions();
      let leaves_region = leaves.region;
      let nodes_region = nodes.region;

      let ?(_, leaf) = base.put_(nodes, leaves, nodes_region, leaves_region, key) else return null;
      base.setValue(leaves_region, leaf, value);
      ?Nat64.toNat(leaf);
    };

    /// Add `key` and `value` to enumeration.
    /// Returns null if pointer size limit exceeded.
    /// Rewrites value if key is already present. First return value `size` is if the key in new to the enumeration
    /// or index of key in enumeration otherwise. Second return is old value if new wasn't added or a new one otherwise.
    ///
    /// Example:
    /// ```motoko
    /// let e = StableTrie.Enumeration({
    ///   pointer_size = 2;
    ///   aridity = 2;
    ///   root_aridity = null;
    ///   key_size = 2;
    ///   value_size = 1;
    /// });
    /// assert(e.replace("abc", "a") == ?("a", 0);
    /// assert(e.replace("aaa", "b") == ?("b", 1));
    /// assert(e.replace("abc", "c") == ?("a", 0);
    /// ```
    /// Runtime: O(key_size) acesses to stable memory.
    public func replace(key : Blob, value : Blob) : ?(Blob, Nat) {
      let { leaves; nodes } = base.regions();
      let leaves_region = leaves.region;
      let nodes_region = nodes.region;

      let ?(added, leaf) = base.put_(nodes, leaves, nodes_region, leaves_region, key) else return null;
      let ret_value = if (added) {
        base.setValue(leaves_region, leaf, value);
        value;
      } else {
        let old_value = base.getValue(leaves_region, leaf);
        base.setValue(leaves_region, leaf, value);
        old_value;
      };
      ?(ret_value, Nat64.toNat(leaf));
    };

    /// Add `key` and `value` to enumeration.
    /// Returns null if pointer size limit exceeded.
    /// Lookup value if key is already present. First return value `size` is if the key in new to the enumeration
    /// or index of key in enumeration otherwise. Second return is old value if new wasn't added or a new one otherwise.
    ///
    /// Example:
    /// ```motoko
    /// let e = StableTrie.Enumeration({
    ///   pointer_size = 2;
    ///   aridity = 2;
    ///   root_aridity = null;
    ///   key_size = 2;
    ///   value_size = 1;
    /// });
    /// assert(e.lookupOrPut("abc", "a") == ?("a", 0);
    /// assert(e.lookupOrPut("aaa", "b") == ?("b", 1));
    /// assert(e.lookupOrPut("abc", "c") == ?("a", 0);
    /// ```
    /// Runtime: O(key_size) acesses to stable memory.
    public func lookupOrPut(key : Blob, value : Blob) : ?(Blob, Nat) {
      let { leaves; nodes } = base.regions();
      let leaves_region = leaves.region;
      let nodes_region = nodes.region;

      let ?(added, leaf) = base.put_(nodes, leaves, nodes_region, leaves_region, key) else return null;
      let ret_value = if (added) {
        base.setValue(leaves_region, leaf, value);
        value;
      } else {
        base.getValue(leaves_region, leaf);
      };
      ?(ret_value, Nat64.toNat(leaf));
    };

    /// Returns `?(index, value)` where `index` is the index of `key` in order it was added to enumeration and `value` is corresponding value to the `key`,
    /// or `null` it `key` wasn't added.
    ///
    /// Example:
    /// ```motoko
    /// let e = StableTrie.Enumeration({
    ///   pointer_size = 2;
    ///   aridity = 2;
    ///   root_aridity = null;
    ///   key_size = 2;
    ///   value_size = 1;
    /// });
    /// assert(e.put("abc", "a") == ?0);
    /// assert(e.put("aaa", "b") == ?1);
    /// assert(e.lookup("abc") == ?("a", 0);
    /// assert(e.lookup("aaa") == ?("b", 1));
    /// assert(e.lookup("bbb") == null);
    /// ```
    /// Runtime: O(key_size) acesses to stable memory.
    public func lookup(key : Blob) : ?(Blob, Nat) = base.lookup(key);

    /// Returns `key` and `value` with index `index` or null if index is out of bounds.
    ///
    /// Example:
    /// ```motoko
    /// let e = StableTrie.Enumeration({
    ///   pointer_size = 2;
    ///   aridity = 2;
    ///   root_aridity = null;
    ///   key_size = 2;
    ///   value_size = 1;
    /// });
    /// assert(e.put("abc", "a") == ?0);
    /// assert(e.put("aaa", "b") == ?1);
    /// assert(e.get(0) == ("abc", "a"));
    /// assert(e.get(1) == ("aaa", "b"));
    /// ```
    /// Runtime: O(1) accesses to stable memory.
    public func get(index : Nat) : ?(Blob, Blob) {
      let { leaves } = base.regions();
      let leaves_region = leaves.region;

      let index_ = Nat64.fromNat(index);
      if (index_ >= base.leaf_count) return null;
      ?(base.getKey(leaves_region, index_), base.getValue(leaves_region, index_));
    };

    /// Returns slice `key` and `value` with indices from `left` to `right` or traps if `left` or `right` are out of bounds.
    ///
    /// Example:
    /// ```motoko
    /// let e = StableTrie.Enumeration({
    ///   pointer_size = 2;
    ///   aridity = 2;
    ///   root_aridity = null;
    ///   key_size = 2;
    ///   value_size = 1;
    /// });
    /// assert(e.put("abc", "a") == ?0);
    /// assert(e.put("aaa", "b") == ?1);
    /// assert(e.slice(0, 2) == [("abc", "a"), ("aaa", "b")]);
    /// ```
    /// Runtime: O(right - left) accesses to stable memory.
    public func slice(left : Nat, right : Nat) : [(Blob, Blob)] {
      let { leaves } = base.regions();
      let leaves_region = leaves.region;

      let l = Nat64.fromNat(left);
      let r = Nat64.fromNat(right);
      assert l <= r and r <= base.leaf_count;
      Array.tabulate<(Blob, Blob)>(
        right - left,
        func(i) {
          let index = Nat64.fromNat(i);
          (base.getKey(leaves_region, index), base.getValue(leaves_region, index));
        },
      );
    };

    public func entries() : Iter.Iter<(Blob, Blob)> = base.entries();

    public func entriesRev() : Iter.Iter<(Blob, Blob)> = base.entriesRev();

    public func vals() : Iter.Iter<Blob> = base.vals();

    public func valsRev() : Iter.Iter<Blob> = base.valsRev();

    public func keys() : Iter.Iter<Blob> = base.keys();

    public func keysRev() : Iter.Iter<Blob> = base.keysRev();

    public func size() : Nat = base.size();

    public func leafCount() : Nat = base.leafCount();

    public func nodeCount() : Nat = base.nodeCount();

    public func share() : StableData = base.share();

    public func unshare(data : StableData) = base.unshare(data);
  };
};
