/// Stable trie map.
///
/// Copyright: 2023 - 2026 MR Research AG
///
/// Main authors: Andrii Stepanov (AStepanov25), Timo Hanke (timohanke)
///
/// Contributors: Andy Gura (AndyGura)
///
/// `Map` is a plain type alias for `Trie.StableTrie`: this module and
/// `Enumeration` are simply two different *interfaces* layered over the same
/// underlying trie record. Functions live at module level with `self` as the
/// first parameter, so callers use dot-notation (`m.add(k, v)`, `m.get(k)`,
/// etc.) which Motoko resolves to the matching module-level function.
///
/// The naming follows `mo:core/Map` conventions:
///
/// Writing (all by key):
/// - `add(k, v)`         — always writes; returns `()`
/// - `insert(k, v)`      — always writes; returns `Bool` (true if new)
/// - `swap(k, v)`        — always writes; returns previous value `?V`
/// - `replace(k, v)`     — writes ONLY if key already present; returns `?V`
/// - `getOrAdd(k, v)`    — writes ONLY if key absent; returns previous value `?V`
///
/// Reading:
/// - `get(k)`            — returns `?V`
/// - `containsKey(k)`    — returns `Bool`
///
/// Removal:
/// - `remove(k)`         — silent; returns `()`
/// - `delete(k)`         — returns `Bool` (true if key was present)
/// - `take(k)`           — returns previous value `?V`
///
/// Each write op that can hit pointer-size overflow has a `*Checked` variant
/// returning `Result.Result<_, { #LimitExceeded }>`. `replace` cannot
/// overflow (it never creates a new leaf), so there is no `replaceChecked`.
///
/// A `Map` value can live directly inside a `persistent actor` — there is
/// no `share`/`unshare` round-trip. A plain `let` binding is enough; the
/// record's own internal `var` fields handle the mutation, and `stable` is
/// implicit in a persistent actor. All fields (`Region.Region`, `Nat64`,
/// `LinkedList`) are themselves stable types.

import Nat "mo:core/Nat";
import Nat64_ "mo:core/Nat64"; // enables `Nat64.toNat()` dot notation
import Option "mo:core/Option";
import Result "mo:core/Result";
import Types "mo:core/Types";

import Trie "internal/trie";
import Layout "internal/layout";
import Iter "internal/iter";

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
  public func empty(args : Args) : Map = Trie.empty({
    args with leaf_size = Nat.max(args.key_size + args.value_size, args.pointer_size);
  });

  // ─── Writing ──────────────────────────────────────────────────────────────

  /// Add `(key, value)` to the map. Always writes (overwrites any existing
  /// value). Returns `#LimitExceeded` if pointer size limit is exceeded.
  ///
  /// Runtime: O(key_size) accesses to stable memory.
  public func addChecked(self : Map, key : Blob, value : Blob) : Result.Result<(), { #LimitExceeded }> {
    let ?(_, leaf) = Trie.put_(self, key) else return #err(#LimitExceeded);
    Layout.setValue(self, leaf, value);
    #ok();
  };

  /// Add `(key, value)` to the map. Always writes. Traps on pointer-size overflow.
  public func add(self : Map, key : Blob, value : Blob) = Trie.unwrap(addChecked(self, key, value));

  /// Add `(key, value)` to the map. Always writes. Returns `#LimitExceeded`
  /// on pointer-size overflow; on success returns `true` if the key was new
  /// to the map, `false` if it overwrote an existing entry.
  ///
  /// Runtime: O(key_size) accesses to stable memory.
  public func insertChecked(self : Map, key : Blob, value : Blob) : Result.Result<Bool, { #LimitExceeded }> {
    let ?(added, leaf) = Trie.put_(self, key) else return #err(#LimitExceeded);
    Layout.setValue(self, leaf, value);
    #ok(added);
  };

  /// Add `(key, value)` to the map. Always writes. Returns `true` if the
  /// key was new. Traps on pointer-size overflow.
  public func insert(self : Map, key : Blob, value : Blob) : Bool = Trie.unwrap(insertChecked(self, key, value));

  /// Add `(key, value)` to the map. Always writes. Returns `#LimitExceeded`
  /// on pointer-size overflow; on success returns the previous value (or
  /// `null` if the key is new).
  ///
  /// Runtime: O(key_size) accesses to stable memory.
  public func swapChecked(self : Map, key : Blob, value : Blob) : Result.Result<?Blob, { #LimitExceeded }> {
    let ?(added, leaf) = Trie.put_(self, key) else return #err(#LimitExceeded);
    #ok(
      if (added) {
        Layout.setValue(self, leaf, value);
        null;
      } else {
        let old_value = Layout.getValue(self, leaf);
        Layout.setValue(self, leaf, value);
        ?old_value;
      }
    );
  };

  /// Add `(key, value)` to the map. Always writes. Returns the previous
  /// value (or `null` if the key is new). Traps on pointer-size overflow.
  public func swap(self : Map, key : Blob, value : Blob) : ?Blob = Trie.unwrap(swapChecked(self, key, value));

  /// Replace the value for an existing `key`. Writes ONLY IF the key is
  /// already present. Returns the previous value, or `null` if the key was
  /// absent (in which case the map is unchanged). Cannot overflow.
  ///
  /// Runtime: O(key_size) accesses to stable memory.
  public func replace(self : Map, key : Blob, value : Blob) : ?Blob {
    switch (Trie.lookup(self, key)) {
      case null null;
      case (?(old_value, idx)) {
        Layout.setValue(self, idx.toNat64(), value);
        ?old_value;
      };
    };
  };

  /// Add `(key, value)` if `key` is absent. Writes ONLY IF the key is new.
  /// Returns `#LimitExceeded` on pointer-size overflow; on success returns
  /// the previous value (if the key was present and untouched) or `null`
  /// (if the key was new and got inserted).
  ///
  /// Runtime: O(key_size) accesses to stable memory.
  public func getOrAddChecked(self : Map, key : Blob, value : Blob) : Result.Result<?Blob, { #LimitExceeded }> {
    let ?(added, leaf) = Trie.put_(self, key) else return #err(#LimitExceeded);
    #ok(
      if (added) {
        Layout.setValue(self, leaf, value);
        null;
      } else {
        ?Layout.getValue(self, leaf);
      }
    );
  };

  /// Add `(key, value)` if `key` is absent. Returns the previous value if
  /// the key was already present, `null` if the key was new and got
  /// inserted. Traps on pointer-size overflow.
  public func getOrAdd(self : Map, key : Blob, value : Blob) : ?Blob = Trie.unwrap(getOrAddChecked(self, key, value));

  // ─── Reading ──────────────────────────────────────────────────────────────

  /// Get the value for `key`, or `null` if not present.
  ///
  /// Runtime: O(key_size) accesses to stable memory.
  public func get(self : Map, key : Blob) : ?Blob = Option.map<(Blob, Nat), Blob>(Trie.lookup(self, key), func(a) = a.0);

  /// Check whether `key` is present.
  ///
  /// Runtime: O(key_size) accesses to stable memory.
  public func containsKey(self : Map, key : Blob) : Bool = Trie.contains(self, key);

  // ─── Removal ──────────────────────────────────────────────────────────────

  /// Remove `key` from the map. Returns the previous value, or `null` if
  /// the key was absent. Reads the value via `loadBlob` (allocates a Blob
  /// on the heap with the bytes copied from stable memory).
  ///
  /// Runtime: O(key_size) accesses to stable memory.
  public func take(self : Map, key : Blob) : ?Blob {
    let (value, _) = removeInternal(self, key, true);
    value;
  };

  /// Remove `key` from the map. Returns `true` if the key was present.
  /// Skips the `loadBlob`/heap allocation that `take` would do — only the
  /// boolean is propagated up the recursion.
  ///
  /// Runtime: O(key_size) accesses to stable memory.
  public func delete(self : Map, key : Blob) : Bool {
    let (_, removed) = removeInternal(self, key, false);
    removed;
  };

  /// Remove `key` from the map. Silent; returns nothing. No-op if absent.
  /// Wraps `delete`; the boolean is discarded. Shares `delete`'s cheaper
  /// no-loadBlob path.
  ///
  /// Runtime: O(key_size) accesses to stable memory.
  public func remove(self : Map, key : Blob) = ignore delete(self, key);

  /// Internal removal driver. `ret` controls whether the leaf's value is
  /// read (`true` for `take`, `false` for `delete`/`remove`). Always
  /// returns the "was-removed" boolean in the second slot, independently
  /// of `ret`, so `delete` can answer correctly without reading the value.
  func removeInternal(self : Map, key : Blob, ret : Bool) : (?Blob, Bool) {
    let idx = Trie.keyToRootIndex(self, key);
    let child = Layout.getChild(self, 0, idx);
    let (value, removed, branch_root) = removeRec(self, key, child, self.root_bitlength, ret);
    if (branch_root != child) {
      Layout.setChild(self, 0, idx, branch_root);
    };
    (value, removed);
  };

  /// Remove recursively starting from child of root node. Returns
  /// `(value, was_removed, new_branch_root)`. `was_removed` is true iff a
  /// leaf with the given key was found and unlinked; `value` is the
  /// previous value when `ret=true` AND it was removed, else `null`.
  func removeRec(self : Map, key : Blob, node : Nat64, pos : Nat16, ret : Bool) : (?Blob, Bool, Nat64) {
    if (node == 0) return (null, false, node);
    if (node & 1 == 1) {
      let leaf = node >> 1;
      if (Layout.getKey(self, leaf) == key) {
        let v = if (ret) ?Layout.getValue(self, leaf) else null;
        Trie.pushEmptyLeaf(self, leaf);
        return (v, true, 0 : Nat64);
      } else {
        return (null, false, node);
      };
    };

    let idx = Trie.keyToIndex(self, key, pos);
    let child = Layout.getChild(self, node, idx);
    let (value, removed, branch_root) = removeRec(self, key, child, pos +% self.bitlength, ret);

    // If the recursive call didn't change anything, neither did we.
    if (branch_root == child) return (value, removed, node);

    Layout.setChild(self, node, idx, branch_root);
    switch (Trie.scanChildren(self, node)) {
      case (#onlyLeaf(leaf, slot)) {
        // Collapse: clear the surviving slot (so the pushed node is
        // all-zero when popped later — otherwise the leftover pointer
        // aliases the leaf through a phantom trie path) and bubble the
        // leaf up to the parent.
        Layout.setChild(self, node, slot, 0);
        Trie.pushEmptyNode(self, node);
        (value, removed, leaf);
      };
      case _ (value, removed, node); // chain-link state or ≥2 children — keep `node`
    };
  };

  // ─── Iteration & misc ─────────────────────────────────────────────────────

  /// Returns all the key-value pairs in the map ordered by `Blob.compare` of keys.
  public func entries(self : Map) : Types.Iter<(Blob, Blob)> = Iter.entries(self);

  /// Returns all the key-value pairs in the map in reverse key-sorted order.
  public func reverseEntries(self : Map) : Types.Iter<(Blob, Blob)> = Iter.reverseEntries(self);

  /// Returns all the values in the map ordered by `Blob.compare` of keys.
  public func values(self : Map) : Types.Iter<Blob> = Iter.values(self);

  /// Returns all the values in the map in reverse key-sorted order.
  public func reverseValues(self : Map) : Types.Iter<Blob> = Iter.reverseValues(self);

  /// Returns all the keys in the map ordered by `Blob.compare`.
  public func keys(self : Map) : Types.Iter<Blob> = Iter.keys(self);

  /// Returns all the keys in the map in reverse key-sorted order.
  public func reverseKeys(self : Map) : Types.Iter<Blob> = Iter.reverseKeys(self);

  /// Number of key-value pairs in the map.
  public func size(self : Map) : Nat = self.leaf_count.toNat() - self.empty_leaves_list.count;

  /// `true` iff the map has no entries.
  public func isEmpty(self : Map) : Bool = size(self) == 0;

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
