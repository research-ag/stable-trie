/// Stable trie enumeration.
///
/// Copyright: 2023 - 2025 MR Research AG
///
/// Main author: Andrii Stepanov (AStepanov25)
///
/// Contributors: Timo Hanke (timohanke)

import Array "mo:core/Array";
import Nat_ "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Result "mo:core/Result";
import Types "mo:core/Types";

import Base "internal/base";

module {
  /// Type of stable data of `StableTrieEnumeration`. Includes the state of
  /// the empty-nodes linked list (managed by `base`). Leaves do not need a
  /// free list because `removeLast` is LIFO — the freed leaf is always at
  /// the end of the leaves region and is reused by the next `add`.
  public type StableData = Base.StableData;

  /// Memory stats.
  ///
  /// `node_count` is the count of internal trie nodes currently in use. After
  /// undoing every `add` via `removeLast`, `node_count` drops back to `1`
  /// (the root). `byte_size` reflects the actual underlying region usage,
  /// which never shrinks.
  public type MemoryStats = Base.MemoryStats;

  /// Arguments type of `Enumeration`.
  public type Args = Base.BaseArgs;

  /// Bidirectional enumeration of any keys in the order they are added.
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
  public class Enumeration(args : Args) {
    let base : Base.StableTrieBase = Base.empty({
      args with leaf_size = args.key_size + args.value_size
    });

    // No callback wiring needed: base owns the empty-nodes list, and
    // `removeLast` reclaims leaf slots by decrementing `leaf_count`.

    /// Add `key` and `value` to the enumeration.
    /// Returns `#LimitExceeded` if pointer size limit exceeded.
    /// Returns `size` if the key in new to the enumeration
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
    /// assert(e.addChecked("abc", "a") == #ok 0);
    /// assert(e.addChecked("aaa", "b") == #ok 1);
    /// assert(e.addChecked("abc", "c") == #ok 0);
    /// ```
    /// Runtime: O(key_size) acesses to stable memory.
    public func addChecked(key : Blob, value : Blob) : Result.Result<Nat, { #LimitExceeded }> {
      let { leaves; nodes } = base.regions();
      let leaves_region = leaves.region;
      let nodes_region = nodes.region;

      let ?(_, leaf) = base.put_(nodes, leaves, nodes_region, leaves_region, key) else return #err(#LimitExceeded);
      base.setValue(leaves_region, leaf, value);
      #ok(leaf.toNat());
    };

    /// Add `key` and `value` to enumeration.
    /// Traps if pointer size limit exceeded. Returns `size` if the key in new to the enumeration
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
    /// assert(e.add("abc", "a") == 0);
    /// assert(e.add("aaa", "b") == 1);
    /// assert(e.add("abc", "c") == 0);
    /// ```
    /// Runtime: O(key_size) acesses to stable memory.
    public func add(key : Blob, value : Blob) : Nat = Base.unwrap(addChecked(key, value));

    /// Add `key` and `value` to enumeration.
    /// Returns `#LimitExceeded` if pointer size limit exceeded.
    /// Rewrites value if key is already present. First return is old value if new wasn't added or `null` otherwise.
    /// Second return value is `size` if the key in new to the enumeration
    /// or index of key in enumeration otherwise.
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
    /// assert(e.replaceChecked("abc", "a") == #ok (null, 0));
    /// assert(e.replaceChecked("aaa", "b") == #ok (null, 1));
    /// assert(e.replaceChecked("abc", "c") == #ok ("a", 0));
    /// ```
    /// Runtime: O(key_size) acesses to stable memory.
    public func replaceChecked(key : Blob, value : Blob) : Result.Result<(?Blob, Nat), { #LimitExceeded }> {
      let { leaves; nodes } = base.regions();
      let leaves_region = leaves.region;
      let nodes_region = nodes.region;

      let ?(added, leaf) = base.put_(nodes, leaves, nodes_region, leaves_region, key) else return #err(#LimitExceeded);
      let ret_value = if (added) {
        base.setValue(leaves_region, leaf, value);
        null;
      } else {
        let old_value = base.getValue(leaves_region, leaf);
        base.setValue(leaves_region, leaf, value);
        ?old_value;
      };
      #ok(ret_value, leaf.toNat());
    };

    /// Add `key` and `value` to enumeration.
    /// Traps if pointer size limit exceeded.
    /// Rewrites value if key is already present. First return is old value if new wasn't added or `null` otherwise.
    /// Second return value is `size` if the key in new to the enumeration
    /// or index of key in enumeration otherwise.
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
    /// assert(e.replace("abc", "a") == (null, 0));
    /// assert(e.replace("aaa", "b") == (null, 1));
    /// assert(e.replace("abc", "c") == (?"a", 0));
    /// ```
    /// Runtime: O(key_size) acesses to stable memory.
    public func replace(key : Blob, value : Blob) : (?Blob, Nat) = Base.unwrap(replaceChecked(key, value));

    /// Add `key` and `value` to enumeration.
    /// Returns `#LimitExceeded` if pointer size limit exceeded.
    /// Lookup value if key is already present. First return value `size` is if the key in new to the enumeration
    /// or index of key in enumeration otherwise. Second return is old value if new wasn't added or null otherwise.
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
    /// assert(e.lookupOrPut("abc", "a") == #ok (null, 0));
    /// assert(e.lookupOrPut("aaa", "b") == #ok (null, 1));
    /// assert(e.lookupOrPut("abc", "c") == #ok (?"a", 0));
    /// ```
    /// Runtime: O(key_size) acesses to stable memory.
    public func lookupOrPutChecked(key : Blob, value : Blob) : Result.Result<(?Blob, Nat), { #LimitExceeded }> {
      let { leaves; nodes } = base.regions();
      let leaves_region = leaves.region;
      let nodes_region = nodes.region;

      let ?(added, leaf) = base.put_(nodes, leaves, nodes_region, leaves_region, key) else return #err(#LimitExceeded);
      let ret_value = if (added) {
        base.setValue(leaves_region, leaf, value);
        null;
      } else {
        ?base.getValue(leaves_region, leaf);
      };
      #ok(ret_value, leaf.toNat());
    };

    /// Add `key` and `value` to enumeration.
    /// Traps if pointer size limit exceeded.
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
    /// assert(e.lookupOrPut("abc", "a") == (null, 0);
    /// assert(e.lookupOrPut("aaa", "b") == (null, 1));
    /// assert(e.lookupOrPut("abc", "c") == (?"a", 0);
    /// ```
    /// Runtime: O(key_size) acesses to stable memory.
    public func lookupOrPut(key : Blob, value : Blob) : (?Blob, Nat) = Base.unwrap(lookupOrPutChecked(key, value));

    /// Remove the entry that was last added to the enumeration.
    /// Returns the removed `?(key, value)` pair or `null` if the enumeration is empty.
    ///
    /// Only the leaf for that entry is removed; internal trie nodes that become
    /// empty are left in place. The space at the end of the leaves region is
    /// reused by the next `add`.
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
    /// assert(e.add("abc", "a") == 0);
    /// assert(e.add("aaa", "b") == 1);
    /// assert(e.removeLast() == ?("aaa", "b"));
    /// assert(e.size() == 1);
    /// assert(e.removeLast() == ?("abc", "a"));
    /// assert(e.removeLast() == null);
    /// ```
    /// Runtime: O(key_size) accesses to stable memory.
    public func removeLast() : ?(Blob, Blob) = base.removeLast();

    /// Returns `?(value, index)` where `index` is the index of `key` in order it was added to enumeration and `value` is corresponding value to the `key`,
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
    /// assert(e.add("abc", "a") == 0);
    /// assert(e.add("aaa", "b") == 1);
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
    /// assert(e.add("abc", "a") == 0);
    /// assert(e.add("aaa", "b") == 1);
    /// assert(e.get(0) == ?("abc", "a"));
    /// assert(e.get(1) == ?("aaa", "b"));
    /// ```
    /// Runtime: O(1) accesses to stable memory.
    public func get(index : Nat) : ?(Blob, Blob) {
      let { leaves } = base.regions();
      let leaves_region = leaves.region;

      let index_ = index.toNat64();
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
    /// assert(e.add("abc", "a") == 0);
    /// assert(e.add("aaa", "b") == 1);
    /// assert(e.slice(0, 2) == [("abc", "a"), ("aaa", "b")]);
    /// ```
    /// Runtime: O(right - left) accesses to stable memory.
    public func slice(left : Nat, right : Nat) : [(Blob, Blob)] {
      let { leaves } = base.regions();
      let leaves_region = leaves.region;

      let l = left.toNat64();
      let r = right.toNat64();
      assert l <= r and r <= base.leaf_count;
      Array.tabulate<(Blob, Blob)>(
        right - left,
        func(i) {
          let index = Nat64.fromIntWrap(i);
          (base.getKey(leaves_region, index), base.getValue(leaves_region, index));
        },
      );
    };

    /// Returns all the keys and values in enumeration ordered by `Blob.compare` of keys.
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
    /// assert(e.add("abc", "a") == 0);
    /// assert(e.add("aaa", "b") == 1);
    /// assert(Iter.toArray(e.entries()) == [("aaa", "b"), ("abc", "a")]);
    /// ```
    public func entries() : Types.Iter<(Blob, Blob)> = base.entries();

    /// Returns all the keys and values in the enumeration reverse ordered by `Blob.compare` of keys.
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
    /// assert(e.add("abc", "a") == 0);
    /// assert(e.add("aaa", "b") == 1);
    /// assert(Iter.toArray(e.entries()) == [("abc", "a"), ("aaa", "b")]);
    /// ```
    public func entriesRev() : Types.Iter<(Blob, Blob)> = base.entriesRev();

    /// Returns all the values in the enumeration ordered by `Blob.compare` of keys.
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
    /// assert(e.add("abc", "a") == 0);
    /// assert(e.add("aaa", "b") == 1);
    /// assert(Iter.toArray(e.entries()) == ["b", "a"]);
    /// ```
    public func vals() : Types.Iter<Blob> = base.vals();

    /// Returns all the values in the enumeration reverse ordered by `Blob.compare` of keys.
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
    /// assert(e.add("abc", "a") == 0);
    /// assert(e.add("aaa", "b") == 1);
    /// assert(Iter.toArray(e.entries()) == ["a", "b"]);
    /// ```
    public func valsRev() : Types.Iter<Blob> = base.valsRev();

    /// Returns all the keys in the enumeration ordered by `Blob.compare` of keys.
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
    /// assert(e.add("abc", "a") == 0);
    /// assert(e.add("aaa", "b") == 1);
    /// assert(Iter.toArray(e.entries()) == ["aaa", "abc"]);
    /// ```
    public func keys() : Types.Iter<Blob> = base.keys();

    /// Returns all the keys in the enumeration reverse ordered by `Blob.compare` of keys.
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
    /// assert(e.add("abc", "a") == 0);
    /// assert(e.add("aaa", "b") == 1);
    /// assert(Iter.toArray(e.entries()) == ["abc", "aaa"]);
    /// ```
    public func keysRev() : Types.Iter<Blob> = base.keysRev();

    /// Number of key-value pairs in enumeration.
    public func size() : Nat = base.leaf_count.toNat();

    /// Memory stats. `node_count` is the number of internal nodes currently
    /// in use; `total_node_count` is the high water (region size).
    public func memoryStats() : MemoryStats = base.memoryStats();

    /// Convert to stable data.
    public func share() : StableData = base.share();

    /// Create from stable data. Must be the first call after constructor.
    public func unshare(data : StableData) = base.unshare(data);
  };
};
