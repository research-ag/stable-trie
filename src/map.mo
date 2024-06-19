import Blob "mo:base/Blob";
import Nat64 "mo:base/Nat64";
import Nat "mo:base/Nat";
import Iter "mo:base/Iter";
import Region "mo:base/Region";
import Nat8 "mo:base/Nat8";
import Nat16 "mo:base/Nat16";
import Int "mo:base/Int";
import Option "mo:base/Option";

import Base "base";

module {
  /// Type of stable data of `StableTrieMap`
  public type StableData = Base.StableData and {
    last_empty_node : Nat64;
    last_empty_leaf : Nat64;
  };
  /// Bidirectional enumeration of any keys s in the order they are added.
  /// For a map from keys to index `Nat` it is implemented as trie in stable memory.
  /// for a map from index `Nat` to keys the implementation is a consecutive interval of stable memory.
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

    var last_empty_node : Nat64 = base.loadMask;
    var last_empty_leaf : Nat64 = base.loadMask;

    func pushEmptyLeaf(leaves : Base.Region, leaf : Nat64) {
      base.storePointer(leaves.region, base.getLeafOffset(leaf), last_empty_leaf);
      last_empty_leaf := leaf;
    };

    func popEmptyLeaf(leaves : Base.Region) : ?Nat64 {
      if (last_empty_leaf == base.loadMask) return null;
      let ret = last_empty_leaf;

      last_empty_leaf := base.loadPointer(leaves, base.getLeafOffset(last_empty_leaf));
      ?ret;
    };

    func pushEmptyNode(nodes : Base.Region, node : Nat64) {
      base.setChild(nodes, node, 0, last_empty_node);
      last_empty_node := node;
    };

    func popEmptyNode(nodes : Base.Region) : ?Nat64 {
      if (last_empty_node == base.loadMask) return null;
      let ret = last_empty_node;
      last_empty_node := base.getChild(nodes, last_empty_node, 0);
      ?ret;
    };

    base.setCallbacks(popEmptyNode, popEmptyLeaf);

    /// Add `key` and `value` to enumeration. Returns null if pointer size limit exceeded. Returns `size` if the key in new to the enumeration
    /// or rewrites value and returns index of key in enumeration otherwise.
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
    /// assert(e.put("abc", "a") == ?0);
    /// assert(e.put("aaa", "b") == ?1);
    /// assert(e.put("abc", "c") == ?0);
    /// ```
    /// Runtime: O(key_size) acesses to stable memory.
    public func put(key : Blob, value : Blob) : ?Bool {
      let { leaves; nodes } = base.regions();

      let ?(added, leaf) = base.put_(nodes, leaves, key) else return null;
      base.setValue(leaves, leaf, value);
      ?added;
    };

    /// Add `key` and `value` to enumeration.
    /// Returns null if pointer size limit exceeded.
    /// Rewrites value if key is already present. First return value `size` is if the key in new to the enumeration
    /// or index of key in enumeration otherwise. Second return is old value if new wasn't added or a new one otherwise.
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
    /// assert(e.replace("abc", "a") == ?("a", 0);
    /// assert(e.replace("aaa", "b") == ?("b", 1));
    /// assert(e.replace("abc", "c") == ?("a", 0);
    /// ```
    /// Runtime: O(key_size) acesses to stable memory.
    public func replace(key : Blob, value : Blob) : ?(Blob, Nat) {
      let { leaves; nodes } = base.regions();

      let ?(added, leaf) = base.put_(nodes, leaves, key) else return null;
      let ret_value = if (added) {
        base.setValue(leaves, leaf, value);
        value;
      } else {
        let old_value = base.getValue(leaves, leaf);
        base.setValue(leaves, leaf, value);
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
    /// let e = StableTrie.Map({
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

      let ?(added, leaf) = base.put_(nodes, leaves, key) else return null;
      let ret_value = if (added) {
        base.setValue(leaves, leaf, value);
        value;
      } else {
        base.getValue(leaves, leaf);
      };
      ?(ret_value, Nat64.toNat(leaf));
    };

    /// Returns `?(index, value)` where `index` is the index of `key` in order it was added to enumeration and `value` is corresponding value to the `key`,
    /// or `null` it `key` wasn't added.
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
    /// assert(e.put("abc", "a") == ?0);
    /// assert(e.put("aaa", "b") == ?1);
    /// assert(e.lookup("abc") == ?("a", 0);
    /// assert(e.lookup("aaa") == ?("b", 1));
    /// assert(e.lookup("bbb") == null);
    /// ```
    /// Runtime: O(key_size) acesses to stable memory.
    public func lookup(key : Blob) : ?Blob {
      Option.map<(Blob, Nat), Blob>(base.lookup(key), func(a) = a.0);
    };

    public func delete(key : Blob) : ?Blob {
      let { leaves; nodes } = base.regions();
      let bytes = Blob.toArray(key);

      let idx = base.keyToRootIndex(bytes);
      let child = base.getChild(nodes, 0, idx);
      let (value, leaf) = deleteRec(nodes, leaves, key, bytes, child, base.root_bitlength);
      if (leaf != child) {
        base.setChild(nodes, 0, idx, leaf);
      };
      value;
    };

    func singleLeaf(region : Base.Region, node : Nat64) : Nat64 {
      let blob = Region.loadBlob(region.region, base.getOffset(node, 0), base.node_size_);
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

    func deleteRec(nodes : Base.Region, leaves : Base.Region, key : Blob, bytes : [Nat8], node : Nat64, pos : Nat16) : (?Blob, Nat64) {
      if (node == 0) return (null, node);
      if (node & 1 == 1) {
        let leaf = node >> 1;
        if (base.getKey(leaves, leaf) == key) {
          let ret = (?base.getValue(leaves, leaf), 0 : Nat64);
          pushEmptyLeaf(leaves, leaf);
          return ret;
        } else {
          return (null, node);
        };
      };

      let idx = base.keyToIndex(bytes, pos);
      let child = base.getChild(nodes, node, idx);
      let ret = deleteRec(nodes, leaves, key, bytes, child, pos +% base.bitlength);
      let (value, leaf) = ret;

      let ret_leaf = if (leaf != child) {
        base.setChild(nodes, node, idx, leaf);
        singleLeaf(nodes, node);
      } else node;

      if (ret_leaf & 1 == 1) {
        pushEmptyNode(nodes, node);
      };
      (value, ret_leaf);
    };

    public func entries() : Iter.Iter<(Blob, Blob)> {
      base.entries();
    };

    public func entriesRev() : Iter.Iter<(Blob, Blob)> {
      base.entriesRev();
    };

    public func vals() : Iter.Iter<Blob> {
      base.vals();
    };

    public func valsRev() : Iter.Iter<Blob> {
      base.valsRev();
    };

    public func keys() : Iter.Iter<Blob> {
      base.keys();
    };

    public func keysRev() : Iter.Iter<Blob> {
      base.keysRev();
    };

    public func size() : Nat = base.size();

    public func leafCount() : Nat = base.leafCount();

    public func nodeCount() : Nat = base.nodeCount();

    public func share() : StableData = {
      base.share() with last_empty_node;
      last_empty_leaf;
    };

    public func unshare(data : StableData) {
      last_empty_node := data.last_empty_node;
      last_empty_leaf := data.last_empty_node;
      base.unshare(data);
    };
  };
};
