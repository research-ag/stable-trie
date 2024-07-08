/// Stable trie map.
///
/// Copyright: 2023-2024 MR Research AG
///
/// Main author: Andrii Stepanov (AStepanov25)
///
/// Contributors: Timo Hanke (timohanke)

import Blob "mo:base/Blob";
import Nat64 "mo:base/Nat64";
import Nat "mo:base/Nat";
import Iter "mo:base/Iter";
import Region "mo:base/Region";
import Nat8 "mo:base/Nat8";
import Nat16 "mo:base/Nat16";
import Int "mo:base/Int";
import Option "mo:base/Option";
import Result "mo:base/Result";

import Base "base";

module {
  /// Type of stable data of `StableTrieMap`
  public type StableData = Base.StableData and {
    last_empty_node : Nat64;
    last_empty_leaf : Nat64;
  };

  /// Map interface implemented as trie in stable memory.
  ///
  /// Arguments:
  /// + `pointer_size` is size of pointer of address space, first bit is reserved for internal use,
  ///   so max amount of nodes in stable trie is `2 ** (pointer_size * 8 - 1)`. Should be one of 2, 4, 5, 6, 8.
  /// + `aridity` is amount of children of any non leaf node except in trie. Should be one of 2, 4, 16, 256.
  /// + `root_aridity` is amount of children of root node.
  /// + `key_size` and `value_size` are sizes of key and value which should be constant per one instance of `Map`
  ///
  /// Example:
  /// ```motoko
  /// let e = StableTrie.Map({
  ///   pointer_size = 2;
  ///   aridity = 2;
  ///   root_aridity = null;
  ///   key_size = 2;
  ///   value_size = 0;
  /// });
  /// ```
  public class Map(args : Base.Args) {
    let base : Base.StableTrieBase = Base.StableTrieBase(args);

    assert args.key_size + args.value_size >= args.pointer_size;

    /// Deleted nodes form linked list in stable memory. This is a root of this list.
    var last_empty_node : Nat64 = base.loadMask;
    /// Deleted leaves form linked list in stable memory. This is a root of this list.
    var last_empty_leaf : Nat64 = base.loadMask;

    /// Add deleted leaf to linked list.
    func pushEmptyLeaf(leaves : Region.Region, leaf : Nat64) {
      base.storePointer(leaves, base.getLeafOffset(leaf), last_empty_leaf);
      last_empty_leaf := leaf;
    };

    /// Pop last deleted leaf to linked list.
    func popEmptyLeaf(leaves : Region.Region) : ?Nat64 {
      if (last_empty_leaf == base.loadMask) return null;
      let ret = last_empty_leaf;

      last_empty_leaf := base.loadPointer(leaves, base.getLeafOffset(last_empty_leaf));
      ?ret;
    };

    /// Add deleted node to linked list.
    func pushEmptyNode(nodes : Region.Region, node : Nat64) {
      base.storePointer(nodes, base.getNodeOffset(node, 0), last_empty_node);
      last_empty_node := node;
    };

    /// Pop last deleted node to linked list.
    func popEmptyNode(nodes : Region.Region) : ?Nat64 {
      if (last_empty_node == base.loadMask) return null;
      let ret = last_empty_node;
      last_empty_node := base.loadPointer(nodes, base.getNodeOffset(last_empty_node, 0));
      ?ret;
    };

    // callbacks are used in `newInternalNode` and `newLeaf`
    base.setCallbacks(popEmptyNode, popEmptyLeaf);

    /// Add `key` and `value` to the map. Rewrites value in case it's already there.
    /// Returns `#LimitExceeded` if pointer size limit exceeded.
    ///
    /// Example:
    /// ```motoko
    /// let e = StableTrie.Map({
    ///   pointer_size = 2;
    ///   aridity = 2;
    ///   root_aridity = null;
    ///   key_size = 2;
    ///   value_size = 1;
    /// });
    /// assert(e.putChecked("abc", "a") == #ok);
    /// assert(e.putChecked("aaa", "b") == #ok);
    /// assert(e.putChecked("abc", "c") == #ok);
    /// ```
    /// Runtime: O(key_size) acesses to stable memory.
    public func putChecked(key : Blob, value : Blob) : Result.Result<(), { #LimitExceeded }> {
      let { leaves; nodes } = base.regions();
      let leaves_region = leaves.region;
      let nodes_region = nodes.region;

      let ?(_, leaf) = base.put_(nodes, leaves, nodes_region, leaves_region, key) else return #err(#LimitExceeded);
      base.setValue(leaves_region, leaf, value);
      #ok();
    };

    /// Add `key` and `value` to the map. Rewrites value in case it's already there.
    /// Traps if pointer size limit exceeded.
    ///
    /// Example:
    /// ```motoko
    /// let e = StableTrie.Map({
    ///   pointer_size = 2;
    ///   aridity = 2;
    ///   root_aridity = null;
    ///   key_size = 2;
    ///   value_size = 1;
    /// });
    /// e.put("abc", "a");
    /// e.put("aaa", "b");
    /// e.put("abc", "c");
    /// ```
    /// Runtime: O(key_size) acesses to stable memory.
    public func put(key : Blob, value : Blob) = base.unwrap(putChecked(key, value));

    /// Add `key` and `value` to the map.
    /// Returns `#LimitExceeded` if pointer size limit exceeded.
    /// Rewrites value if key is already present. Returns old value if new wasn't added or `null` otherwise. 
    ///
    /// Example:
    /// ```motoko
    /// let e = StableTrie.Map({
    ///   pointer_size = 2;
    ///   aridity = 2;
    ///   root_aridity = null;
    ///   key_size = 2;
    ///   value_size = 1;
    /// });
    /// assert(e.replaceChecked("abc", "a") == #ok (null));
    /// assert(e.replaceChecked("aaa", "b") == #ok (null));
    /// assert(e.replaceChecked("abc", "c") == #ok ("a"));
    /// ```
    /// Runtime: O(key_size) acesses to stable memory.
    public func replaceChecked(key : Blob, value : Blob) : Result.Result<?Blob, { #LimitExceeded }> {
      let { leaves; nodes } = base.regions();
      let leaves_region = leaves.region;
      let nodes_region = nodes.region;

      let ?(added, leaf) = base.put_(nodes, leaves, nodes_region, leaves_region, key) else return #err(#LimitExceeded);
      #ok(
        if (added) {
          base.setValue(leaves_region, leaf, value);
          null;
        } else {
          let old_value = base.getValue(leaves_region, leaf);
          base.setValue(leaves_region, leaf, value);
          ?old_value;
        }
      );
    };

    /// Add `key` and `value` to the map.
    /// Traps if pointer size limit exceeded.
    /// Rewrites value if key is already present. Returns old value if new wasn't added or `null` otherwise. 
    ///
    /// Example:
    /// ```motoko
    /// let e = StableTrie.Map({
    ///   pointer_size = 2;
    ///   aridity = 2;
    ///   root_aridity = null;
    ///   key_size = 2;
    ///   value_size = 1;
    /// });
    /// assert(e.replace("abc", "a") == null);
    /// assert(e.replace("aaa", "b") == null);
    /// assert(e.replace("abc", "c") == "a");
    /// ```
    /// Runtime: O(key_size) acesses to stable memory.
    public func replace(key : Blob, value : Blob) : ?Blob = base.unwrap(replaceChecked(key, value));

    /// Add `key` and `value` to the map.
    /// Returns `#LimitExceeded` if pointer size limit exceeded.
    /// Lookup value if key is already present. Returns old value if new wasn't added or a null otherwise.
    ///
    /// Example:
    /// ```motoko
    /// let e = StableTrie.Map({
    ///   pointer_size = 2;
    ///   aridity = 2;
    ///   root_aridity = null;
    ///   key_size = 2;
    ///   value_size = 1;
    /// });
    /// assert(e.getOrPutChecked("abc", "a") == #ok (null));
    /// assert(e.getOrPutChecked("aaa", "b") == #ok (null));
    /// assert(e.getOrPutChecked("abc", "c") == #ok (?"a"));
    /// ```
    /// Runtime: O(key_size) acesses to stable memory.
    public func getOrPutChecked(key : Blob, value : Blob) : Result.Result<?Blob, { #LimitExceeded }> {
      let { leaves; nodes } = base.regions();
      let leaves_region = leaves.region;
      let nodes_region = nodes.region;

      let ?(added, leaf) = base.put_(nodes, leaves, nodes_region, leaves_region, key) else return #err(#LimitExceeded);
      #ok(
        if (added) {
          base.setValue(leaves_region, leaf, value);
          null;
        } else {
          ?base.getValue(leaves_region, leaf);
        }
      );
    };

    /// Add `key` and `value` to the map.
    /// Traps if pointer size limit exceeded.
    /// Lookup value if key is already present. Returns old value if new wasn't added or a null otherwise.
    ///
    /// Example:
    /// ```motoko
    /// let e = StableTrie.Map({
    ///   pointer_size = 2;
    ///   aridity = 2;
    ///   root_aridity = null;
    ///   key_size = 2;
    ///   value_size = 1;
    /// });
    /// assert(e.getOrPut("abc", "a") == null);
    /// assert(e.getOrPut("aaa", "b") == null);
    /// assert(e.getOrPut("abc", "c") == ?"a");
    /// ```
    /// Runtime: O(key_size) acesses to stable memory.
    public func getOrPut(key : Blob, value : Blob) : ?Blob = base.unwrap(getOrPutChecked(key, value));

    /// Returns `value` corresponding to the `key` or null if the `key` is not in the map.
    ///
    /// Example:
    /// ```motoko
    /// let e = StableTrie.Map({
    ///   pointer_size = 2;
    ///   aridity = 2;
    ///   root_aridity = null;
    ///   key_size = 2;
    ///   value_size = 1;
    /// });
    /// e.put("abc", "a");
    /// e.put("aaa", "b");
    /// assert(e.get("abc") == ?"a");
    /// assert(e.get("aaa") == ?"b");
    /// assert(e.get("bbb") == null);
    /// ```
    /// Runtime: O(key_size) acesses to stable memory.
    public func get(key : Blob) : ?Blob = Option.map<(Blob, Nat), Blob>(base.lookup(key), func(a) = a.0);

    /// Remove `value` corresponding to the `key` and return removed `value`.
    ///
    /// Example:
    /// ```motoko
    /// let e = StableTrie.Map({
    ///   pointer_size = 2;
    ///   aridity = 2;
    ///   root_aridity = null;
    ///   key_size = 2;
    ///   value_size = 1;
    /// });
    /// e.put("abc", "a");
    /// e.put("aaa", "b");
    /// assert(e.remove("abc") == ?"a");
    /// assert(e.remove("aaa") == ?"b");
    /// assert(e.remove("bbb") == null);
    /// ```
    /// Runtime: O(key_size) acesses to stable memory.
    public func remove(key : Blob) : ?Blob = removeInternal(key, true);

    /// Delete `value` corresponding to the `key`.
    ///
    /// Example:
    /// ```motoko
    /// let e = StableTrie.Map({
    ///   pointer_size = 2;
    ///   aridity = 2;
    ///   root_aridity = null;
    ///   key_size = 2;
    ///   value_size = 1;
    /// });
    /// e.put("abc", "a");
    /// e.put("aaa", "b");
    /// e.delete("abc");
    /// e.delete("aaa");
    /// e.delete("bbb");
    /// ```
    /// Runtime: O(key_size) acesses to stable memory.
    public func delete(key : Blob) = ignore removeInternal(key, false);

    /// Remove key. `ret` is flag meaning whether to read deleted value.
    func removeInternal(key : Blob, ret : Bool) : ?Blob {
      let { leaves; nodes } = base.regions();
      let leaves_region = leaves.region;
      let nodes_region = nodes.region;

      let bytes = Blob.toArray(key);

      let idx = base.keyToRootIndex(bytes);
      let child = base.getChild(nodes_region, 0, idx);
      let (value, branch_root) = removeRec(nodes_region, leaves_region, key, bytes, child, base.root_bitlength, ret);
      if (branch_root != child) {
        base.setChild(nodes_region, 0, idx, branch_root);
      };
      value;
    };

    /// Returns leaf if the node constains single leaf. Or node otherwise.
    func branchRoot(region : Region.Region, node : Nat64) : Nat64 {
      let blob = Region.loadBlob(region, base.getNodeOffset(node, 0), base.node_size_);
      let bytes = Blob.toArray(blob);

      var lastNode : Nat64 = 0;
      for (i in Iter.range(0, args.aridity - 1)) {
        var x : Nat64 = 0;
        for (i in Iter.revRange(i * args.pointer_size + args.pointer_size - 1, i * args.pointer_size)) {
          x := x * 256 + Nat64.fromNat(Nat8.toNat(bytes[Int.abs(i)]));
        };
        if (x > 0) {
          if (lastNode != 0) return node;
          lastNode := x;
        };
      };
      if (lastNode & 1 == 0) node else lastNode;
    };

    /// Remove recursively starting from child of root node.
    func removeRec(nodes : Region.Region, leaves : Region.Region, key : Blob, bytes : [Nat8], node : Nat64, pos : Nat16, ret : Bool) : (?Blob, Nat64) {
      if (node == 0) return (null, node);
      if (node & 1 == 1) {
        let leaf = node >> 1;
        if (base.getKey(leaves, leaf) == key) {
          let r = (if (ret) ?base.getValue(leaves, leaf) else null, 0 : Nat64);
          pushEmptyLeaf(leaves, leaf);
          return r;
        } else {
          return (null, node);
        };
      };

      let idx = base.keyToIndex(bytes, pos);
      let child = base.getChild(nodes, node, idx);
      let (value, branch_root) = removeRec(nodes, leaves, key, bytes, child, pos +% base.bitlength, ret);

      let ret_branch_root = if (branch_root != child) {
        base.setChild(nodes, node, idx, branch_root);
        branchRoot(nodes, node);
      } else node;

      if (ret_branch_root & 1 == 1) {
        pushEmptyNode(nodes, node);
      };
      (value, ret_branch_root);
    };

    /// Returns all the keys and values in the map ordered by `Blob.compare` of keys.
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
    /// e.put("abc", "a");
    /// e.put("aaa", "b");
    /// assert(Iter.toArray(e.entries()) == [("aaa", "b"), ("abc", "a")]);
    /// ```
    public func entries() : Iter.Iter<(Blob, Blob)> = base.entries();

    /// Returns all the keys and values in the map reverse ordered by `Blob.compare` of keys.
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
    /// e.put("abc", "a");
    /// e.put("aaa", "b");
    /// assert(Iter.toArray(e.entries()) == [("abc", "a"), ("aaa", "b")]);
    /// ```
    public func entriesRev() : Iter.Iter<(Blob, Blob)> = base.entriesRev();

    /// Returns all the values in the map ordered by `Blob.compare` of keys.
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
    /// e.put("abc", "a");
    /// e.put("aaa", "b");
    /// assert(Iter.toArray(e.entries()) == ["b", "a"]);
    /// ```
    public func vals() : Iter.Iter<Blob> = base.vals();

    /// Returns all the values in the map reverse ordered by `Blob.compare` of keys.
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
    /// e.put("abc", "a");
    /// e.put("aaa", "b");
    /// assert(Iter.toArray(e.entries()) == ["a", "b"]);
    /// ```
    public func valsRev() : Iter.Iter<Blob> = base.valsRev();

    /// Returns all the keys in the map ordered by `Blob.compare` of keys.
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
    /// e.put("abc", "a");
    /// e.put("aaa", "b");
    /// assert(Iter.toArray(e.entries()) == ["aaa", "abc"]);
    /// ```
    public func keys() : Iter.Iter<Blob> = base.keys();

    /// Returns all the keys in the map reverse ordered by `Blob.compare` of keys.
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
    /// e.put("abc", "a");
    /// e.put("aaa", "b");
    /// assert(Iter.toArray(e.entries()) == ["abc", "aaa"]);
    /// ```
    public func keysRev() : Iter.Iter<Blob> = base.keysRev();
    
    /// Size of used stable memory in bytes.
    public func size() : Nat = base.size();

    /// Size of used stable memory in bytes.
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
    /// e.put("abc", "a");
    /// e.put("aaa", "b");
    /// assert(e.leafCount() == 2);
    /// ```
    public func leafCount() : Nat = base.leafCount();

    /// Number of internal nodes excluding leaves.
    public func nodeCount() : Nat = base.nodeCount();
    
    /// Convert to stable data.
    public func share() : StableData = {
      base.share() with last_empty_node;
      last_empty_leaf;
    };

    /// Create from stable data. Must be the first call after constructor.
    public func unshare(data : StableData) {
      last_empty_node := data.last_empty_node;
      last_empty_leaf := data.last_empty_node;
      base.unshare(data);
    };
  };
};
