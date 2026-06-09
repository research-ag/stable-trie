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
import _Nat64 "mo:core/Nat64"; // enables `Nat64.toNat()` dot notation
import _Region "mo:core/Region"; // enables `region.storeBlob(...)` dot notation
import Result "mo:core/Result";
import Types "mo:core/Types";

import Trie "internal/trie";
import Layout "internal/layout";
import Iter "internal/iter";

module {
  /// Arguments to `empty()`. See `empty` for field meanings.
  public type Args = Trie.BaseArgs;

  /// Memory-usage statistics. See `Trie.MemoryStats` for field meanings.
  public type MemoryStats = Trie.MemoryStats;

  /// A map from constant-length Blob keys to constant-length Blob values,
  /// implemented as a trie in Regions. Same underlying type as
  /// `Enumeration` — `Map` and `Enumeration` are just two interfaces.
  public type Map = Trie.StableTrie;

  /// Construct an empty `Map`.
  ///
  /// Arguments:
  /// - `pointer_size : Nat` — bytes used for each internal pointer. One of
  ///   `2, 4, 5, 6, 8`. Bounds the trie's capacity: at most `N/2` leaves
  ///   and `N/2` internal nodes where `N = 256 ** pointer_size`.
  /// - `aridity : Nat` — number of children per non-root internal node.
  ///   One of `2, 4, 16, 256`. `4` is recommended for uniformly distributed
  ///   keys.
  /// - `root_aridity : ?Nat` — children of the root node. `null` defaults
  ///   to `aridity`; a higher value collapses several upper levels into
  ///   the root, saving memory when those levels are dense.
  /// - `key_size : Nat` — byte length of every key (constant for the life
  ///   of the map).
  /// - `value_size : Nat` — byte length of every value. `0` makes the map
  ///   a set.
  ///
  /// If `key_size + value_size < pointer_size`, leaf slots are padded up
  /// to `pointer_size` bytes so they can carry a chain link in the
  /// empty-leaves free list. The padding is transparent to the caller.
  public func empty(args : Args) : Map = Trie.empty({
    args with leaf_size = Nat.max(args.key_size + args.value_size, args.pointer_size);
  });

  // ─── Writing ──────────────────────────────────────────────────────────────

  /// Insert or overwrite `(key, value)`. Returns `#err(#LimitExceeded)` if
  /// the pointer-size limit is reached, else `#ok()`.
  ///
  /// Runtime: O(key_size) accesses to stable memory.
  public func addChecked(self : Map, key : Blob, value : Blob) : Result.Result<(), { #LimitExceeded }> {
    let ?(_, leaf) = Trie.put_(self, key) else return #err(#LimitExceeded);
    Layout.setValue(self, leaf, value);
    #ok();
  };

  /// Insert or overwrite `(key, value)`. Traps if the pointer-size limit is
  /// reached. Skips `put_`'s upfront capacity check — an overflow trap
  /// inside `putOrTrap` is rolled back by the surrounding IC message.
  public func add(self : Map, key : Blob, value : Blob) {
    let (_, leaf) = Trie.putOrTrap(self, key);
    Layout.setValue(self, leaf, value);
  };

  /// Insert or overwrite `(key, value)`. Returns `#err(#LimitExceeded)` on
  /// overflow; on success returns `true` if the key was new and `false` if
  /// the call overwrote an existing entry.
  ///
  /// Runtime: O(key_size) accesses to stable memory.
  public func insertChecked(self : Map, key : Blob, value : Blob) : Result.Result<Bool, { #LimitExceeded }> {
    let ?(added, leaf) = Trie.put_(self, key) else return #err(#LimitExceeded);
    Layout.setValue(self, leaf, value);
    #ok(added);
  };

  /// Insert or overwrite `(key, value)`. Returns `true` if the key was new.
  /// Traps if the pointer-size limit is reached.
  public func insert(self : Map, key : Blob, value : Blob) : Bool {
    let (added, leaf) = Trie.putOrTrap(self, key);
    Layout.setValue(self, leaf, value);
    added;
  };

  /// Insert or overwrite `(key, value)`. Returns `#err(#LimitExceeded)` on
  /// overflow; on success returns the previous value associated with `key`,
  /// or `null` if the key was new.
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

  /// Insert or overwrite `(key, value)`. Returns the previous value
  /// associated with `key`, or `null` if the key was new. Traps if the
  /// pointer-size limit is reached.
  public func swap(self : Map, key : Blob, value : Blob) : ?Blob {
    let (added, leaf) = Trie.putOrTrap(self, key);
    if (added) {
      Layout.setValue(self, leaf, value);
      null;
    } else {
      let old_value = Layout.getValue(self, leaf);
      Layout.setValue(self, leaf, value);
      ?old_value;
    };
  };

  /// Overwrite the value at `key` ONLY IF the key is already present.
  /// Returns the previous value, or `null` if the key was absent (in which
  /// case the map is unchanged). Cannot overflow — never allocates a new
  /// leaf — and therefore has no `*Checked` variant.
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

  /// Insert `(key, value)` ONLY IF `key` is absent. Returns
  /// `#err(#LimitExceeded)` on overflow; on success returns `null` (the
  /// key was new and the value was stored) or the existing value (the key
  /// was already present and was left untouched).
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

  /// Insert `(key, value)` ONLY IF `key` is absent. Returns `null` (newly
  /// inserted) or the existing value (left untouched). Traps if the
  /// pointer-size limit is reached.
  public func getOrAdd(self : Map, key : Blob, value : Blob) : ?Blob {
    let (added, leaf) = Trie.putOrTrap(self, key);
    if (added) {
      Layout.setValue(self, leaf, value);
      null;
    } else {
      ?Layout.getValue(self, leaf);
    };
  };

  // ─── Reading ──────────────────────────────────────────────────────────────

  /// Get the value for `key`, or `null` if not present.
  ///
  /// Runtime: O(key_size) accesses to stable memory.
  public func get(self : Map, key : Blob) : ?Blob = do ? {
    Trie.lookup(self, key)!.0;
  };

  /// `containsKey(self : Map, key : Blob) : Bool`
  ///
  /// Check whether `key` is present.
  ///
  /// Runtime: O(key_size) accesses to stable memory.
  public let containsKey : (self : Map, key : Blob) -> Bool = Trie.contains;

  // ─── Removal ──────────────────────────────────────────────────────────────

  /// Remove `key` from the map and return the previous value, or `null`
  /// if the key was absent. The only removal path that reads the leaf's
  /// value — choose `delete` or `remove` if you don't need it back.
  ///
  /// Runtime: O(key_size) accesses to stable memory.
  public func take(self : Map, key : Blob) : ?Blob {
    let (value, _) = removeInternal(self, key, true);
    value;
  };

  /// Remove `key` from the map. Returns `true` if the key was present,
  /// `false` if it was absent (in which case the map is unchanged).
  ///
  /// Runtime: O(key_size) accesses to stable memory.
  public func delete(self : Map, key : Blob) : Bool {
    let (_, removed) = removeInternal(self, key, false);
    removed;
  };

  /// Remove `key` from the map. No-op if absent. Returns nothing.
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
        // Zero the leaf so that the only non-zero bytes after the push are
        // the chain link (or none, when the list was empty — see
        // LinkedList.push). Symmetric with the per-slot `setChild(..., 0)`
        // for collapsed internal nodes in the `#onlyLeaf` branch below.
        self.leaves_region.storeBlob(Layout.getLeafOffset(self, leaf), self.zero_leaf);
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
  //
  // All iteration is in key-sorted (Blob.compare) order.

  /// `entries(self : Map) : Iter<(Blob, Blob)>`
  ///
  /// Iterate `(key, value)` pairs in ascending key order.
  public let entries : (self : Map) -> Types.Iter<(Blob, Blob)> = Iter.entries;

  /// `reverseEntries(self : Map) : Iter<(Blob, Blob)>`
  ///
  /// Iterate `(key, value)` pairs in descending key order.
  public let reverseEntries : (self : Map) -> Types.Iter<(Blob, Blob)> = Iter.reverseEntries;

  /// `values(self : Map) : Iter<Blob>`
  ///
  /// Iterate values in ascending key order.
  public let values : (self : Map) -> Types.Iter<Blob> = Iter.values;

  /// `reverseValues(self : Map) : Iter<Blob>`
  ///
  /// Iterate values in descending key order.
  public let reverseValues : (self : Map) -> Types.Iter<Blob> = Iter.reverseValues;

  /// `keys(self : Map) : Iter<Blob>`
  ///
  /// Iterate keys in ascending order.
  public let keys : (self : Map) -> Types.Iter<Blob> = Iter.keys;

  /// `reverseKeys(self : Map) : Iter<Blob>`
  ///
  /// Iterate keys in descending order.
  public let reverseKeys : (self : Map) -> Types.Iter<Blob> = Iter.reverseKeys;

  /// Number of key-value pairs in the map.
  public func size(self : Map) : Nat = self.leaf_count.toNat() - self.empty_leaves_list.count;

  /// `true` iff the map has no entries.
  public func isEmpty(self : Map) : Bool = size(self) == 0;

  /// `memoryStats(self : Map) : MemoryStats`
  ///
  /// Returns memory-usage statistics. See `MemoryStats` for field meanings.
  public let memoryStats : (self : Map) -> MemoryStats = Trie.memoryStats;

  /// `toValue(self : Map) : Trie.Value`
  ///
  /// Returns a Promtracker `Value` for direct integration with a
  /// `Promtracker.Renderer`. Compatible with **promtracker >= 1.0.1**
  /// (the `Value` / `Metric` shapes the result targets are the ones
  /// introduced in 1.0.x; 0.5.x is not supported).
  public let toValue : (self : Map) -> Trie.Value = Trie.toValue;

  // ─── Pointer-size resize (incremental) ────────────────────────────────────
  //
  // Migrate an existing Map to a different pointer_size. The work spans
  // multiple messages: `beginResize` validates and prepares; `stepResize`
  // does a batch and is called repeatedly until it returns `true`;
  // `completeResize` returns the new Map. During the migration the caller
  // must NOT read or write through the original Map reference — both the
  // old and new layouts share the same region bytes, which are partially
  // re-encoded between calls.

  /// State carried across calls of an incremental pointer-size resize.
  /// See `Trie.ResizeState`.
  public type ResizeState = Trie.ResizeState;

  /// `beginResize(self : Map, new_pointer_size : Nat) : ?ResizeState`
  ///
  /// Start an incremental pointer-size migration. Returns `null` if the
  /// resize cannot proceed (invalid pointer size; current node/leaf count
  /// wouldn't fit; the change would alter `leaf_size`; or growing while
  /// the empty-leaves free list is non-empty). On success, no nodes have
  /// been migrated yet — call `stepResize` to do the work.
  public let beginResize : (self : Map, new_pointer_size : Nat) -> ?ResizeState = Trie.beginResize;

  /// `stepResize(state : ResizeState, batch_size : Nat) : Bool`
  ///
  /// Migrate up to `batch_size` nodes. Returns `true` when every node has
  /// been migrated; further calls then become no-ops that still return
  /// `true`. Once `true` has been returned, call `completeResize` to
  /// obtain the new Map.
  public let stepResize : (state : ResizeState, batch_size : Nat) -> Bool = Trie.stepResize;

  /// `completeResize(state : ResizeState) : Map`
  ///
  /// Assemble the new Map from a completed resize. Traps if `stepResize`
  /// has not yet returned `true`. The returned Map shares the now-rewritten
  /// regions with the original; the caller must stop using the original
  /// reference (typically by holding the Map in a `var` and reassigning).
  public let completeResize : (state : ResizeState) -> Map = Trie.completeResize;
};
