/// Stable trie enumeration.
///
/// Copyright: 2023 - 2026 MR Research AG
///
/// Main authors: Andrii Stepanov (AStepanov25), Timo Hanke (timohanke)
///
/// Contributors: Andy Gura (AndyGura)
///
/// `Enumeration` is a plain type alias for `Trie.StableTrie`: this
/// module and `Map` are simply two different *interfaces* layered over the
/// same underlying trie record. Functions live at module level with `self`
/// as the first parameter, so callers use dot-notation (`e.add(k, v)`,
/// `e.get(i)`, etc.) which Motoko resolves to the matching module-level
/// function.
///
/// The Enumeration interface adds an *index* dimension on top of `Map`:
/// every key has an inherent `Nat` index reflecting its insertion order,
/// and entries can also be read or written by index. By-index reads
/// follow `mo:core/List` conventions (`get(i) : ?(K, V)` Option-safe,
/// `at(i) : (K, V)` trapping, `put(i, v)` write).
///
/// Writing (by key):
/// - `add(k, v) : Nat`               — always writes; returns index
/// - `insert(k, v) : (Bool, Nat)`    — always writes; (was-new, index)
/// - `lookupOrAdd(k, v) : (?V, Nat)` — writes ONLY if key absent
///
/// Writing (by index):
/// - `put(i, v) : ()`                — overwrite value at `i`; traps on OOB
///
/// Reading (by key):
/// - `lookup(k) : ?(V, Nat)`         — Option-safe
/// - `containsKey(k) : Bool`
///
/// Reading (by index):
/// - `get(i) : ?(K, V)`              — Option-safe, mo:core/List style
/// - `at(i) : (K, V)`                — traps on OOB
/// - `sliceToArray(l, r) : [(K, V)]` — bulk range read (mirrors `List.sliceToArray`)
/// - `range(l, r) : Iter<(K, V)>`    — lazy range iter in index order (mirrors `List.range`)
///
/// Removal (LIFO only — arbitrary deletion would break the index):
/// - `removeLast() : ?(K, V)`
/// - `truncate(newSize : Nat) : ()`  — drop entries from `newSize` onwards
///
/// Each by-key write op that can hit pointer-size overflow has a `*Checked`
/// variant returning `Result.Result<_, { #LimitExceeded }>`. `put` cannot
/// overflow (no new leaf is allocated).
///
/// `swap` and `replace` are intentionally absent from Enumeration. In Map
/// those primitives are useful because they fold the find and the write
/// into a single tree-descent — there's no other way to overwrite without
/// descending twice. In Enumeration, `put(i, v)` is O(1), so a `lookup(k)`
/// + `put(i, v)` composition is no slower than a fused primitive would be
/// and the user has the index in hand for further use.
///
/// An `Enumeration` value can live directly inside a `persistent actor` —
/// there is no `share`/`unshare` round-trip. A plain `let` binding is
/// enough; the record's own internal `var` fields handle the mutation, and
/// `stable` is implicit in a persistent actor. All fields (`Region.Region`,
/// `Nat64`, `LinkedList`) are themselves stable types.

import Array "mo:core/Array";
import Nat_ "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Result "mo:core/Result";
import Types "mo:core/Types";
import Prim "mo:prim";

import Trie "internal/trie";
import Layout "internal/layout";
import Iter "internal/iter";

module {
  /// Memory-usage statistics. See `Trie.MemoryStats` for field meanings.
  /// Note that for Enumeration, `used_leaf_count` always equals
  /// `total_leaf_count` — `removeLast` decrements the leaf counter
  /// directly rather than pushing freed slots onto a free list.
  /// Internal nodes still use a free list, so `used_node_count` and
  /// `total_node_count` may diverge.
  public type MemoryStats = Trie.MemoryStats;

  /// Arguments to `empty()`. See `empty` for field meanings.
  public type Args = Trie.BaseArgs;

  /// A key→value→index store: every key has both a value and an inherent
  /// `Nat` index reflecting its insertion order. Keys live in a trie
  /// (key→index lookup); values live in a flat array indexed by the index
  /// (index→key/value lookup). Same underlying record as `Map` — `Map`
  /// and `Enumeration` are just two interfaces over the same data
  /// structure.
  public type Enumeration = Trie.StableTrie;

  /// Construct an empty `Enumeration`.
  ///
  /// Arguments:
  /// + `pointer_size` — bytes for internal pointers (2, 4, 5, 6, 8).
  /// + `aridity` — children per non-root internal node (2, 4, 16, 256).
  /// + `root_aridity` — children for the root node, or `null` to default
  ///   to `aridity`.
  /// + `key_size` — byte length of every key.
  /// + `value_size` — byte length of every value (`0` makes it a set).
  public func empty(args : Args) : Enumeration = Trie.empty({
    args with leaf_size = args.key_size + args.value_size;
  });

  // ─── Writing (by key) ─────────────────────────────────────────────────────

  /// Add `(key, value)`. Always writes. Returns `#LimitExceeded` on
  /// pointer-size overflow; on success returns the entry's index.
  ///
  /// Runtime: O(key_size) accesses to stable memory.
  public func addChecked(self : Enumeration, key : Blob, value : Blob) : Result.Result<Nat, { #LimitExceeded }> {
    let ?(_, leaf) = Trie.put_(self, key) else return #err(#LimitExceeded);
    Layout.setValue(self, leaf, value);
    #ok(leaf.toNat());
  };

  /// Add `(key, value)`. Always writes. Returns the index. Traps on
  /// pointer-size overflow. Skips `put_`'s upfront capacity check — an
  /// overflow trap inside `putOrTrap` is rolled back by the surrounding
  /// IC message.
  public func add(self : Enumeration, key : Blob, value : Blob) : Nat {
    let (_, leaf) = Trie.putOrTrap(self, key);
    Layout.setValue(self, leaf, value);
    leaf.toNat();
  };

  /// Add `(key, value)`. Always writes. Returns `#LimitExceeded` on
  /// pointer-size overflow; on success returns `(was-new, index)`.
  ///
  /// Runtime: O(key_size) accesses to stable memory.
  public func insertChecked(self : Enumeration, key : Blob, value : Blob) : Result.Result<(Bool, Nat), { #LimitExceeded }> {
    let ?(added, leaf) = Trie.put_(self, key) else return #err(#LimitExceeded);
    Layout.setValue(self, leaf, value);
    #ok(added, leaf.toNat());
  };

  /// Add `(key, value)`. Always writes. Returns `(was-new, index)`.
  /// Traps on pointer-size overflow.
  public func insert(self : Enumeration, key : Blob, value : Blob) : (Bool, Nat) {
    let (added, leaf) = Trie.putOrTrap(self, key);
    Layout.setValue(self, leaf, value);
    (added, leaf.toNat());
  };

  /// Add `(key, value)` if `key` is absent. Writes ONLY if the key is new.
  /// Returns `#LimitExceeded` on overflow; on success returns
  /// `(previous-value-or-null, index)`. If the key was already present the
  /// value is left untouched and `?old_value` is returned; if it was new
  /// the value is stored and `null` is returned.
  ///
  /// Runtime: O(key_size) accesses to stable memory.
  public func lookupOrAddChecked(self : Enumeration, key : Blob, value : Blob) : Result.Result<(?Blob, Nat), { #LimitExceeded }> {
    let ?(added, leaf) = Trie.put_(self, key) else return #err(#LimitExceeded);
    let ret_value = if (added) {
      Layout.setValue(self, leaf, value);
      null;
    } else {
      ?Layout.getValue(self, leaf);
    };
    #ok(ret_value, leaf.toNat());
  };

  /// Add `(key, value)` if `key` is absent. Returns `(?prev_value, index)`.
  /// Traps on pointer-size overflow.
  public func lookupOrAdd(self : Enumeration, key : Blob, value : Blob) : (?Blob, Nat) {
    let (added, leaf) = Trie.putOrTrap(self, key);
    let ret_value = if (added) {
      Layout.setValue(self, leaf, value);
      null;
    } else {
      ?Layout.getValue(self, leaf);
    };
    (ret_value, leaf.toNat());
  };

  // ─── Writing (by index) ───────────────────────────────────────────────────

  /// Overwrite the value at index `i`. Traps if `i >= size()` or if
  /// `value.size() != value_size`. The key at index `i` is unchanged.
  ///
  /// Runtime: O(1) accesses to stable memory.
  public func put(self : Enumeration, index : Nat, value : Blob) {
    let i = index.toNat64();
    if (i >= self.leaf_count) Prim.trap("Enumeration.put: index out of bounds");
    Layout.setValue(self, i, value);
  };

  // ─── Reading (by key) ─────────────────────────────────────────────────────

  /// Look up `key`. Returns `?(value, index)`, or `null` if absent.
  ///
  /// Runtime: O(key_size) accesses to stable memory.
  public let lookup : (self : Enumeration, key : Blob) -> ?(Blob, Nat) = Trie.lookup;

  /// Check whether `key` is present.
  ///
  /// Runtime: O(key_size) accesses to stable memory.
  public let containsKey : (self : Enumeration, key : Blob) -> Bool = Trie.contains;

  // ─── Reading (by index) ───────────────────────────────────────────────────

  /// Read the entry at index `i`. Returns `?(key, value)`, or `null` if
  /// `i >= size()`. Matches `mo:core/List.get` semantics.
  ///
  /// Runtime: O(1) accesses to stable memory.
  public func get(self : Enumeration, index : Nat) : ?(Blob, Blob) {
    let i = index.toNat64();
    if (i >= self.leaf_count) return null;
    ?(Layout.getKey(self, i), Layout.getValue(self, i));
  };

  /// Read the entry at index `i`. Traps if `i >= size()`. Matches
  /// `mo:core/List.at` semantics.
  ///
  /// Runtime: O(1) accesses to stable memory.
  public func at(self : Enumeration, index : Nat) : (Blob, Blob) {
    let i = index.toNat64();
    if (i >= self.leaf_count) Prim.trap("Enumeration.at: index out of bounds");
    (Layout.getKey(self, i), Layout.getValue(self, i));
  };

  /// Return entries in index range `[left, right)` as an Array. Traps if
  /// `right > size()` or `left > right`. Mirrors `mo:core/List.sliceToArray`.
  ///
  /// Runtime: O(right - left) accesses to stable memory.
  public func sliceToArray(self : Enumeration, left : Nat, right : Nat) : [(Blob, Blob)] {
    let l = left.toNat64();
    let r = right.toNat64();
    assert l <= r and r <= self.leaf_count;
    Array.tabulate<(Blob, Blob)>(
      right - left,
      func(i) {
        let index = Nat64.fromIntWrap(i) +% l;
        (Layout.getKey(self, index), Layout.getValue(self, index));
      },
    );
  };

  /// Return entries in index range `[left, right)` as a lazy iterator.
  /// Traps if `right > size()` or `left > right`. Mirrors
  /// `mo:core/List.range`.
  ///
  /// Runtime: O(1) per `next` call, no upfront work.
  public func range(self : Enumeration, left : Nat, right : Nat) : Types.Iter<(Blob, Blob)> {
    let l = left.toNat64();
    let r = right.toNat64();
    assert l <= r and r <= self.leaf_count;
    var i = l;
    {
      next = func() : ?(Blob, Blob) {
        if (i >= r) return null;
        let entry = (Layout.getKey(self, i), Layout.getValue(self, i));
        i +%= 1;
        ?entry;
      };
    };
  };

  // ─── Removal ──────────────────────────────────────────────────────────────

  /// Remove the most-recently-added entry. Returns `?(key, value)`, or
  /// `null` if the enumeration is empty. Matches `mo:core/List.removeLast`.
  ///
  /// Internal trie nodes that become empty are reclaimed and reused by
  /// subsequent `add` calls; the leaves region is also reused LIFO.
  ///
  /// Runtime: O(key_size) accesses to stable memory.
  public let removeLast : (self : Enumeration) -> ?(Blob, Blob) = Trie.removeLast;

  /// Truncate to `newSize`. If `newSize >= size()`, no-op. Otherwise drops
  /// entries from index `newSize` onwards; surviving entries are at
  /// indices `0..newSize-1`. Matches `mo:core/List.truncate`.
  ///
  /// Composes useful idioms: `truncate(0)` clears all entries; `truncate(
  /// size() - n)` drops the last `n` entries.
  ///
  /// Runtime: O((size() - newSize) * key_size) accesses to stable memory.
  public func truncate(self : Enumeration, newSize : Nat) {
    while (size(self) > newSize) {
      ignore removeLast(self);
    };
  };

  // ─── Iteration & misc ─────────────────────────────────────────────────────

  // Iteration helpers walk the trie, so they visit entries in
  // **key-sorted** (Blob.compare) order — *not* insertion order. For
  // index-order iteration, use `range(0, size())` or `sliceToArray`.

  /// Iterate `(key, value)` pairs in ascending key order.
  public let entries : (self : Enumeration) -> Types.Iter<(Blob, Blob)> = Iter.entries;

  /// Iterate `(key, value)` pairs in descending key order.
  public let reverseEntries : (self : Enumeration) -> Types.Iter<(Blob, Blob)> = Iter.reverseEntries;

  /// Iterate values in ascending key order.
  public let values : (self : Enumeration) -> Types.Iter<Blob> = Iter.values;

  /// Iterate values in descending key order.
  public let reverseValues : (self : Enumeration) -> Types.Iter<Blob> = Iter.reverseValues;

  /// Iterate keys in ascending key order.
  public let keys : (self : Enumeration) -> Types.Iter<Blob> = Iter.keys;

  /// Iterate keys in descending key order.
  public let reverseKeys : (self : Enumeration) -> Types.Iter<Blob> = Iter.reverseKeys;

  /// Number of entries in the enumeration.
  public func size(self : Enumeration) : Nat = self.leaf_count.toNat();

  /// `true` iff the enumeration has no entries.
  public func isEmpty(self : Enumeration) : Bool = size(self) == 0;

  /// Returns memory-usage statistics. See `MemoryStats` for field meanings.
  public let memoryStats : (self : Enumeration) -> MemoryStats = Trie.memoryStats;
};
