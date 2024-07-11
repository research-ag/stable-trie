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
  /// Type of stable data of `StableTrie.Map`
  public type StableData = Base.StableData and {
    empty_nodes : (Nat, Nat64);
    empty_leaves : (Nat, Nat64);
  };

  /// Memory stats.
  public type MemoryStats = {
    /// Size of used stable memory in bytes.
    bytes_size : Nat;
    /// Number of leaves without deleted ones.
    used_leaf_count : Nat;
    /// Number of nodes without deleted ones.
    used_node_count : Nat;
    /// Number of allocated leaves.
    total_leaf_count : Nat;
    /// Number of allocated nodes.
    total_node_count : Nat;
  };

  class LinkedList(base : Base.StableTrieBase, getOffset : (Nat64) -> Nat64) {
    var last_empty_item : Nat64 = base.loadMask;
    public var count = 0;

    /// Add deleted item to linked list.
    public func push(region : Region.Region, item : Nat64) {
      base.storePointer(region, getOffset(item), last_empty_item);
      last_empty_item := item;
      count += 1;
    };

    /// Pop last deleted item to linked list.
    public func pop(region : Region.Region) : ?Nat64 {
      if (last_empty_item == base.loadMask) return null;

      let ret = last_empty_item;
      last_empty_item := base.loadPointer(region, getOffset(last_empty_item));
      base.storePointer(region, getOffset(ret), 0);
      count -= 1;
      ?ret;
    };

    public func share() : (Nat, Nat64) = (count, last_empty_item);

    public func unshare((c, last) : (Nat, Nat64)) {
      count := c;
      last_empty_item := last;
    };
  };

  /// A map from constant-length Blob keys to constant-length Blob values, implemented as a trie in Regions.
  ///
  /// Arguments:
  /// + `pointer_size` is the number of bytes used for internal pointers. Allowed values are 2, 4, 5, 6, 8.
  ///    There can be at most `N/2` inner nodes in the trie and at most `N/2` leaves where `N = 256 ** pointer_size`.
  /// + `aridity` is the number of children of any inner node that is not the root node. Allowed values are 2, 4, 16, 256. The recommended value is 4.
  /// + `root_aridity` is the number of children of the root node. If `null`, then `aridity` is used.
  /// + `key_size` is the byte length of all keys.
  /// + `value_size` is the byte length of all values. If `0` then the map becomes a set.
  ///
  /// There is a requirement that `key_size + value_size >= pointer_size`.
  ///
  /// Example:
  /// ```motoko
  /// let m = StableTrie.Map({
  ///   pointer_size = 2;
  ///   aridity = 4;
  ///   root_aridity = null;
  ///   key_size = 2;
  ///   value_size = 0;
  /// });
  /// ```
  public class Map(args : Base.Args) {
    let base : Base.StableTrieBase = Base.StableTrieBase(args);

    assert args.key_size + args.value_size >= args.pointer_size;

    /// Deleted nodes are stored in a linked list in stable memory so that their space can be reused. This is the head of the list.
    /// The same for leaves.

    let empty_leaves : LinkedList = LinkedList(base, base.getLeafOffset);
    let empty_nodes : LinkedList = LinkedList(base, func(node : Nat64) : Nat64 = base.getNodeOffset(node, 0));

    // callbacks are used in `newInternalNode` and `newLeaf`
    base.setCallbacks(empty_nodes.pop, empty_leaves.pop);

    /// Add the `key` and `value` pair to the map. Existing values are silently overwritten.
    /// Returns `#LimitExceeded` if the pointer size limit is exceeded.
    ///
    /// Example:
    /// ```motoko
    /// let m = StableTrie.Map({
    ///   pointer_size = 2;
    ///   aridity = 4;
    ///   root_aridity = null;
    ///   key_size = 2;
    ///   value_size = 1;
    /// });
    /// assert(m.putChecked("abc", "a") == #ok);
    /// assert(m.putChecked("aaa", "b") == #ok);
    /// assert(m.putChecked("abc", "c") == #ok);
    /// ```
    /// Runtime: O(key_size) accesses to stable memory.
    public func putChecked(key : Blob, value : Blob) : Result.Result<(), { #LimitExceeded }> {
      let { leaves; nodes } = base.regions();
      let leaves_region = leaves.region;
      let nodes_region = nodes.region;

      let ?(_, leaf) = base.put_(nodes, leaves, nodes_region, leaves_region, key) else return #err(#LimitExceeded);
      base.setValue(leaves_region, leaf, value);
      #ok();
    };

    /// Add the `key` and `value` pair to the map. If `key` already exists then the old value is silently overwritten.
    /// Traps if the pointer size limit is exceeded.
    ///
    /// Example:
    /// ```motoko
    /// let m = StableTrie.Map({
    ///   pointer_size = 2;
    ///   aridity = 4;
    ///   root_aridity = null;
    ///   key_size = 2;
    ///   value_size = 1;
    /// });
    /// m.put("abc", "a");
    /// m.put("aaa", "b");
    /// m.put("abc", "c");
    /// ```
    /// Runtime: O(key_size) acesses to stable memory.
    public func put(key : Blob, value : Blob) = base.unwrap(putChecked(key, value));

    /// Add the `key` and `value` pair to the map. If `key` already exists then the old value is overwritten and returned. If `key` is new then `null` is returned.
    /// Returns `#LimitExceeded` if the pointer size limit is exceeded.
    ///
    /// Example:
    /// ```motoko
    /// let m = StableTrie.Map({
    ///   pointer_size = 2;
    ///   aridity = 4;
    ///   root_aridity = null;
    ///   key_size = 2;
    ///   value_size = 1;
    /// });
    /// assert(m.replaceChecked("abc", "a") == #ok (null));
    /// assert(m.replaceChecked("aaa", "b") == #ok (null));
    /// assert(m.replaceChecked("abc", "c") == #ok (?"a"));
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

    /// Add the `key` and `value` pair to the map. If `key` already exists then the old value is overwritten and returned. If `key` is new then `null` is returned.
    /// Traps if pointer size limit exceeded.
    ///
    /// Example:
    /// ```motoko
    /// let m = StableTrie.Map({
    ///   pointer_size = 2;
    ///   aridity = 4;
    ///   root_aridity = null;
    ///   key_size = 2;
    ///   value_size = 1;
    /// });
    /// assert(m.replace("abc", "a") == null);
    /// assert(m.replace("aaa", "b") == null);
    /// assert(m.replace("abc", "c") == ?"a");
    /// ```
    /// Runtime: O(key_size) acesses to stable memory.
    public func replace(key : Blob, value : Blob) : ?Blob = base.unwrap(replaceChecked(key, value));

    /// Add the `key` and `value` pair to the map. If `key` already exists then the value is not written and the old value is returned (`get` behaviour). If `key` is new then the value is written and `null` is returned (`put` behaviour).
    /// Returns `#LimitExceeded` if the pointer size limit is exceeded.
    ///
    /// Example:
    /// ```motoko
    /// let m = StableTrie.Map({
    ///   pointer_size = 2;
    ///   aridity = 4;
    ///   root_aridity = null;
    ///   key_size = 2;
    ///   value_size = 1;
    /// });
    /// assert(m.getOrPutChecked("abc", "a") == #ok (null));
    /// assert(m.getOrPutChecked("aaa", "b") == #ok (null));
    /// assert(m.getOrPutChecked("abc", "c") == #ok (?"a"));
    /// assert(m.get("abc") == ?"a");
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

    /// Add the `key` and `value` pair to the map. If `key` already exists then the value is not written and the old value is returned (`get` behaviour). If `key` is new then the value is written and `null` is returned (`put` behaviour).
    /// Traps if pointer size limit exceeded.
    ///
    /// Example:
    /// ```motoko
    /// let m = StableTrie.Map({
    ///   pointer_size = 2;
    ///   aridity = 4;
    ///   root_aridity = null;
    ///   key_size = 2;
    ///   value_size = 1;
    /// });
    /// assert(m.getOrPut("abc", "a") == null);
    /// assert(m.getOrPut("aaa", "b") == null);
    /// assert(m.getOrPut("abc", "c") == ?"a");
    /// assert(m.get("abc") == ?"a");
    /// ```
    /// Runtime: O(key_size) acesses to stable memory.
    public func getOrPut(key : Blob, value : Blob) : ?Blob = base.unwrap(getOrPutChecked(key, value));

    /// Returns the `value` corresponding to `key` or null if `key` is not in the map.
    ///
    /// Example:
    /// ```motoko
    /// let m = StableTrie.Map({
    ///   pointer_size = 2;
    ///   aridity = 2;
    ///   root_aridity = null;
    ///   key_size = 2;
    ///   value_size = 1;
    /// });
    /// m.put("abc", "a");
    /// m.put("aaa", "b");
    /// assert(m.get("abc") == ?"a");
    /// assert(m.get("aaa") == ?"b");
    /// assert(m.get("bbb") == null);
    /// ```
    /// Runtime: O(key_size) acesses to stable memory.
    public func get(key : Blob) : ?Blob = Option.map<(Blob, Nat), Blob>(base.lookup(key), func(a) = a.0);

    /// Delete the `key` and its corresponding `value` from the map. Returns the deleted `value` or `null` if the key was not present in the map.
    ///
    /// Example:
    /// ```motoko
    /// let m = StableTrie.Map({
    ///   pointer_size = 2;
    ///   aridity = 4;
    ///   root_aridity = null;
    ///   key_size = 2;
    ///   value_size = 1;
    /// });
    /// m.put("abc", "a");
    /// m.put("aaa", "b");
    /// assert(m.remove("abc") == ?"a");
    /// assert(m.remove("aaa") == ?"b");
    /// assert(m.remove("bbb") == null);
    /// ```
    /// Runtime: O(key_size) acesses to stable memory.
    public func remove(key : Blob) : ?Blob = removeInternal(key, true);

    /// Delete the `key` and its corresponding `value` from the map. Nothing happens if the key is not present in the map.
    ///
    /// Example:
    /// ```motoko
    /// let m = StableTrie.Map({
    ///   pointer_size = 2;
    ///   aridity = 4;
    ///   root_aridity = null;
    ///   key_size = 2;
    ///   value_size = 1;
    /// });
    /// m.put("abc", "a");
    /// m.put("aaa", "b");
    /// m.delete("abc");
    /// m.delete("aaa");
    /// m.delete("bbb");
    /// ```
    /// Runtime: O(key_size) acesses to stable memory.
    public func delete(key : Blob) = ignore removeInternal(key, false);

    /// Remove key. `ret` is flag meaning whether to read deleted value or not.
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
          empty_leaves.push(leaves, leaf);
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
        empty_nodes.push(nodes, node);
      };
      (value, ret_branch_root);
    };

    /// Returns all the key-value pairs in the map ordered by `Blob.compare` of keys.
    ///
    /// Example:
    /// ```motoko
    /// let m = StableTrie.Map({
    ///   pointer_size = 2;
    ///   aridity = 4;
    ///   root_aridity = null;
    ///   key_size = 2;
    ///   value_size = 1;
    /// });
    /// m.put("abc", "a");
    /// m.put("aaa", "b");
    /// assert(Iter.toArray(m.entries()) == [("aaa", "b"), ("abc", "a")]);
    /// ```
    public func entries() : Iter.Iter<(Blob, Blob)> = base.entries();

    /// Returns all the key-value pairs in the map reverse ordered by `Blob.compare` of keys.
    ///
    /// Example:
    /// ```motoko
    /// let m = StableTrie.Map({
    ///   pointer_size = 2;
    ///   aridity = 4;
    ///   root_aridity = null;
    ///   key_size = 2;
    ///   value_size = 1;
    /// });
    /// m.put("abc", "a");
    /// m.put("aaa", "b");
    /// assert(Iter.toArray(m.entries()) == [("abc", "a"), ("aaa", "b")]);
    /// ```
    public func entriesRev() : Iter.Iter<(Blob, Blob)> = base.entriesRev();

    /// Returns all the values in the map ordered by `Blob.compare` of keys.
    ///
    /// Example:
    /// ```motoko
    /// let m = StableTrie.Map({
    ///   pointer_size = 2;
    ///   aridity = 4;
    ///   root_aridity = null;
    ///   key_size = 2;
    ///   value_size = 1;
    /// });
    /// m.put("abc", "a");
    /// m.put("aaa", "b");
    /// assert(Iter.toArray(m.entries()) == ["b", "a"]);
    /// ```
    public func vals() : Iter.Iter<Blob> = base.vals();

    /// Returns all the values in the map reverse ordered by `Blob.compare` of keys.
    ///
    /// Example:
    /// ```motoko
    /// let m = StableTrie.Map({
    ///   pointer_size = 2;
    ///   aridity = 4;
    ///   root_aridity = null;
    ///   key_size = 2;
    ///   value_size = 1;
    /// });
    /// m.put("abc", "a");
    /// m.put("aaa", "b");
    /// assert(Iter.toArray(m.entries()) == ["a", "b"]);
    /// ```
    public func valsRev() : Iter.Iter<Blob> = base.valsRev();

    /// Returns all the keys in the map ordered by `Blob.compare` of keys.
    ///
    /// Example:
    /// ```motoko
    /// let m = StableTrie.Map({
    ///   pointer_size = 2;
    ///   aridity = 4;
    ///   root_aridity = null;
    ///   key_size = 2;
    ///   value_size = 1;
    /// });
    /// m.put("abc", "a");
    /// m.put("aaa", "b");
    /// assert(Iter.toArray(m.entries()) == ["aaa", "abc"]);
    /// ```
    public func keys() : Iter.Iter<Blob> = base.keys();

    /// Returns all the keys in the map reverse ordered by `Blob.compare` of keys.
    ///
    /// Example:
    /// ```motoko
    /// let m = StableTrie.Map({
    ///   pointer_size = 2;
    ///   aridity = 4;
    ///   root_aridity = null;
    ///   key_size = 2;
    ///   value_size = 1;
    /// });
    /// m.put("abc", "a");
    /// m.put("aaa", "b");
    /// assert(Iter.toArray(m.entries()) == ["abc", "aaa"]);
    /// ```
    public func keysRev() : Iter.Iter<Blob> = base.keysRev();

    /// Number of key-value pairs in the map.
    public func size() : Nat = Nat64.toNat(base.leaf_count) - empty_leaves.count;

    /// Memory stats.
    public func memoryStats() : MemoryStats {
      let { bytes_size; leaf_count; node_count } = base.memoryStats();
      {
        bytes_size;
        total_leaf_count = leaf_count;
        total_node_count = node_count;
        used_leaf_count = leaf_count - empty_leaves.count;
        used_node_count = node_count - empty_nodes.count;
      };
    };

    /// Convert to stable data.
    public func share() : StableData = {
      base.share() with empty_nodes = empty_nodes.share();
      empty_leaves = empty_leaves.share();
    };

    /// Create from stable data. Must be the first call after constructor.
    public func unshare(data : StableData) {
      empty_nodes.unshare(data.empty_nodes);
      empty_leaves.unshare(data.empty_leaves);
      base.unshare(data);
    };
  };
};
