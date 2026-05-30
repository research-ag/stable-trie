/// Stable trie map.
///
/// Copyright: 2023 - 2025 MR Research AG
///
/// Main author: Andrii Stepanov (AStepanov25)
///
/// Contributors: Timo Hanke (timohanke)
///
/// `Map` is a plain type alias for `Trie.StableTrie`: this module and
/// `Enumeration` are simply two different *interfaces* layered over the same
/// underlying trie record. Functions live at module level with `self` as the
/// first parameter, so callers use dot-notation (`m.put(k, v)`, `m.get(k)`,
/// etc.) which Motoko resolves to the matching module-level function.
///
/// Because `Map = Trie.StableTrie`, any wrapper function here whose
/// name also appears in `base` (e.g. `entries`, `memoryStats`) is ambiguous
/// with the base version when both modules are in scope. We avoid the
/// ambiguity by calling `Trie.foo(self, ...)` explicitly in the wrapper
/// bodies. User code importing only `Map` is fine — only this module's
/// functions are in scope, so `m.foo()` resolves unambiguously.
///
/// A `Map` value can be declared as a `stable var` directly — there is no
/// `share`/`unshare` round-trip. All fields (`Region.Region`, `Nat64`,
/// `LinkedList`) are themselves stable types.

import Nat "mo:core/Nat";
import Nat64_ "mo:core/Nat64"; // enables `Nat64.toNat()` dot notation below
import Option "mo:core/Option";
import Result "mo:core/Result";
import Types "mo:core/Types";

import Trie "internal/trie";

module {
  /// Arguments type of `Map`.
  public type Args = Trie.BaseArgs;

  /// Memory stats.
  public type MemoryStats = {
    /// Size of used stable memory in bytes.
    byte_size : Nat;
    /// Number of leaves without deleted ones.
    used_leaf_count : Nat;
    /// Number of nodes without deleted ones.
    used_node_count : Nat;
    /// Number of allocated leaves.
    total_leaf_count : Nat;
    /// Number of allocated nodes.
    total_node_count : Nat;
  };

  /// A map from constant-length Blob keys to constant-length Blob values,
  /// implemented as a trie in Regions. Same underlying type as
  /// `Enumeration` — `Map` and `Enumeration` are just two interfaces.
  public type Map = Trie.StableTrie;

  /// Construct an empty `Map`.
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
  /// let m = StableTrie.empty({
  ///   pointer_size = 2;
  ///   aridity = 4;
  ///   root_aridity = null;
  ///   key_size = 2;
  ///   value_size = 0;
  /// });
  /// ```
  public func empty(args : Args) : Map = Trie.empty({
    args with leaf_size = Nat.max(args.key_size + args.value_size, args.pointer_size);
  });

  /// Add the `key` and `value` pair to the map. Existing values are silently overwritten.
  /// Returns `#LimitExceeded` if the pointer size limit is exceeded.
  ///
  /// Runtime: O(key_size) accesses to stable memory.
  public func putChecked(self : Map, key : Blob, value : Blob) : Result.Result<(), { #LimitExceeded }> {
    let ?(_, leaf) = Trie.put_(self, key) else return #err(#LimitExceeded);
    Trie.setValue(self, leaf, value);
    #ok();
  };

  /// Add the `key` and `value` pair to the map. If `key` already exists then the old value is silently overwritten.
  /// Traps if the pointer size limit is exceeded.
  ///
  /// Runtime: O(key_size) acesses to stable memory.
  public func put(self : Map, key : Blob, value : Blob) = Trie.unwrap(putChecked(self, key, value));

  /// Add the `key` and `value` pair to the map. If `key` already exists then the old value is overwritten and returned. If `key` is new then `null` is returned.
  /// Returns `#LimitExceeded` if the pointer size limit is exceeded.
  ///
  /// Runtime: O(key_size) acesses to stable memory.
  public func replaceChecked(self : Map, key : Blob, value : Blob) : Result.Result<?Blob, { #LimitExceeded }> {
    let ?(added, leaf) = Trie.put_(self, key) else return #err(#LimitExceeded);
    #ok(
      if (added) {
        Trie.setValue(self, leaf, value);
        null;
      } else {
        let old_value = Trie.getValue(self, leaf);
        Trie.setValue(self, leaf, value);
        ?old_value;
      }
    );
  };

  /// Add the `key` and `value` pair to the map. If `key` already exists then the old value is overwritten and returned. If `key` is new then `null` is returned.
  /// Traps if pointer size limit exceeded.
  ///
  /// Runtime: O(key_size) acesses to stable memory.
  public func replace(self : Map, key : Blob, value : Blob) : ?Blob = Trie.unwrap(replaceChecked(self, key, value));

  /// Add the `key` and `value` pair to the map. If `key` already exists then the value is not written and the old value is returned (`get` behaviour). If `key` is new then the value is written and `null` is returned (`put` behaviour).
  /// Returns `#LimitExceeded` if the pointer size limit is exceeded.
  ///
  /// Runtime: O(key_size) acesses to stable memory.
  public func getOrPutChecked(self : Map, key : Blob, value : Blob) : Result.Result<?Blob, { #LimitExceeded }> {
    let ?(added, leaf) = Trie.put_(self, key) else return #err(#LimitExceeded);
    #ok(
      if (added) {
        Trie.setValue(self, leaf, value);
        null;
      } else {
        ?Trie.getValue(self, leaf);
      }
    );
  };

  /// Add the `key` and `value` pair to the map. If `key` already exists then the value is not written and the old value is returned (`get` behaviour). If `key` is new then the value is written and `null` is returned (`put` behaviour).
  /// Traps if pointer size limit exceeded.
  ///
  /// Runtime: O(key_size) acesses to stable memory.
  public func getOrPut(self : Map, key : Blob, value : Blob) : ?Blob = Trie.unwrap(getOrPutChecked(self, key, value));

  /// Returns the `value` corresponding to `key` or null if `key` is not in the map.
  ///
  /// Runtime: O(key_size) acesses to stable memory.
  public func get(self : Map, key : Blob) : ?Blob = Option.map<(Blob, Nat), Blob>(Trie.lookup(self, key), func(a) = a.0);

  /// Delete the `key` and its corresponding `value` from the map. Returns the deleted `value` or `null` if the key was not present in the map.
  ///
  /// Runtime: O(key_size) acesses to stable memory.
  public func remove(self : Map, key : Blob) : ?Blob = removeInternal(self, key, true);

  /// Delete the `key` and its corresponding `value` from the map. Nothing happens if the key is not present in the map.
  ///
  /// Runtime: O(key_size) acesses to stable memory.
  public func delete(self : Map, key : Blob) = ignore removeInternal(self, key, false);

  /// Remove key. `ret` is flag meaning whether to read deleted value or not.
  func removeInternal(self : Map, key : Blob, ret : Bool) : ?Blob {
    let idx = Trie.keyToRootIndex(self, key);
    let child = Trie.getChild(self, 0, idx);
    let (value, branch_root) = removeRec(self, key, child, self.root_bitlength, ret);
    if (branch_root != child) {
      Trie.setChild(self, 0, idx, branch_root);
    };
    value;
  };

  /// Remove recursively starting from child of root node.
  func removeRec(self : Map, key : Blob, node : Nat64, pos : Nat16, ret : Bool) : (?Blob, Nat64) {
    if (node == 0) return (null, node);
    if (node & 1 == 1) {
      let leaf = node >> 1;
      if (Trie.getKey(self, leaf) == key) {
        let r = (if (ret) ?Trie.getValue(self, leaf) else null, 0 : Nat64);
        Trie.pushEmptyLeaf(self, leaf);
        return r;
      } else {
        return (null, node);
      };
    };

    let idx = Trie.keyToIndex(self, key, pos);
    let child = Trie.getChild(self, node, idx);
    let (value, branch_root) = removeRec(self, key, child, pos +% self.bitlength, ret);

    // If the recursive call didn't change anything, neither did we.
    if (branch_root == child) return (value, node);

    Trie.setChild(self, node, idx, branch_root);
    switch (Trie.scanChildren(self, node)) {
      case (#onlyLeaf(leaf, slot)) {
        // Collapse: clear the surviving slot (so the pushed node is
        // all-zero when popped later — otherwise the leftover pointer
        // aliases the leaf through a phantom trie path) and bubble the
        // leaf up to the parent.
        Trie.setChild(self, node, slot, 0);
        Trie.pushEmptyNode(self, node);
        (value, leaf);
      };
      case _ (value, node); // chain-link state or ≥2 children — keep `node`
    };
  };

  /// Returns all the key-value pairs in the map ordered by `Blob.compare` of keys.
  public func entries(self : Map) : Types.Iter<(Blob, Blob)> = Trie.entries(self);

  /// Returns all the key-value pairs in the map reverse ordered by `Blob.compare` of keys.
  public func entriesRev(self : Map) : Types.Iter<(Blob, Blob)> = Trie.entriesRev(self);

  /// Returns all the values in the map ordered by `Blob.compare` of keys.
  public func vals(self : Map) : Types.Iter<Blob> = Trie.vals(self);

  /// Returns all the values in the map reverse ordered by `Blob.compare` of keys.
  public func valsRev(self : Map) : Types.Iter<Blob> = Trie.valsRev(self);

  /// Returns all the keys in the map ordered by `Blob.compare` of keys.
  public func keys(self : Map) : Types.Iter<Blob> = Trie.keys(self);

  /// Returns all the keys in the map reverse ordered by `Blob.compare` of keys.
  public func keysRev(self : Map) : Types.Iter<Blob> = Trie.keysRev(self);

  /// Number of key-value pairs in the map.
  public func size(self : Map) : Nat = self.leaf_count.toNat() - self.empty_leaves_list.count;

  /// Memory stats.
  public func memoryStats(self : Map) : MemoryStats {
    let { byte_size; leaf_count; node_count; total_node_count } = Trie.memoryStats(self);
    {
      byte_size;
      total_leaf_count = leaf_count;
      total_node_count;
      used_leaf_count = leaf_count - self.empty_leaves_list.count;
      used_node_count = node_count;
    };
  };

};
