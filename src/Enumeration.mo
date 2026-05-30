/// Stable trie enumeration.
///
/// Copyright: 2023 - 2025 MR Research AG
///
/// Main author: Andrii Stepanov (AStepanov25)
///
/// Contributors: Timo Hanke (timohanke)
///
/// `Enumeration` is a plain type alias for `Trie.StableTrie`: this
/// module and `Map` are simply two different *interfaces* layered over the
/// same underlying trie record. Functions live at module level with `self`
/// as the first parameter, so callers use dot-notation (`e.add(k, v)`,
/// `e.get(i)`, etc.) which Motoko resolves to the matching module-level
/// function.
///
/// Because `Enumeration = Trie.StableTrie`, any wrapper function here
/// whose name also appears in `base` (e.g. `lookup`, `removeLast`,
/// `entries`, `memoryStats`) is ambiguous with the base version when both
/// modules are in scope. We avoid the ambiguity by calling
/// `Trie.foo(self, ...)` explicitly in the wrapper bodies. User code
/// importing only `Enumeration` is fine — only this module's functions are
/// in scope, so `e.foo()` resolves unambiguously.
///
/// An `Enumeration` value can be declared as a `stable var` directly — there
/// is no `share`/`unshare` round-trip. All fields (`Region.Region`, `Nat64`,
/// `LinkedList`) are themselves stable types.

import Array "mo:core/Array";
import Nat_ "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Result "mo:core/Result";
import Types "mo:core/Types";

import Trie "internal/trie";

module {
  /// Memory stats.
  ///
  /// `node_count` is the count of internal trie nodes currently in use. After
  /// undoing every `add` via `removeLast`, `node_count` drops back to `1`
  /// (the root). `byte_size` reflects the actual underlying region usage,
  /// which never shrinks.
  public type MemoryStats = Trie.MemoryStats;

  /// Arguments type of `Enumeration`.
  public type Args = Trie.BaseArgs;

  /// Bidirectional enumeration of any keys in the order they are added.
  /// For a map from keys to index `Nat` it is implemented as trie in stable
  /// memory; for a map from index `Nat` to keys the implementation is a
  /// consecutive interval of stable memory. Same underlying type as `Map` —
  /// `Map` and `Enumeration` are just two interfaces.
  public type Enumeration = Trie.StableTrie;

  /// Construct an empty `Enumeration`.
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
  /// let e = StableTrie.empty({
  ///   pointer_size = 2;
  ///   aridity = 2;
  ///   root_aridity = null;
  ///   key_size = 2;
  ///   value_size = 0;
  /// });
  /// ```
  public func empty(args : Args) : Enumeration = Trie.empty({
    args with leaf_size = args.key_size + args.value_size;
  });

  /// Add `key` and `value` to the enumeration.
  /// Returns `#LimitExceeded` if pointer size limit exceeded.
  /// Returns `size` if the key in new to the enumeration
  /// or rewrites value and returns index of key in enumeration otherwise.
  ///
  /// Runtime: O(key_size) acesses to stable memory.
  public func addChecked(self : Enumeration, key : Blob, value : Blob) : Result.Result<Nat, { #LimitExceeded }> {
    let ?(_, leaf) = Trie.put_(self, key) else return #err(#LimitExceeded);
    Trie.setValue(self, leaf, value);
    #ok(leaf.toNat());
  };

  /// Add `key` and `value` to enumeration.
  /// Traps if pointer size limit exceeded. Returns `size` if the key in new to the enumeration
  /// or rewrites value and returns index of key in enumeration otherwise.
  ///
  /// Runtime: O(key_size) acesses to stable memory.
  public func add(self : Enumeration, key : Blob, value : Blob) : Nat = Trie.unwrap(addChecked(self, key, value));

  /// Add `key` and `value` to enumeration.
  /// Returns `#LimitExceeded` if pointer size limit exceeded.
  /// Rewrites value if key is already present. First return is old value if new wasn't added or `null` otherwise.
  /// Second return value is `size` if the key in new to the enumeration
  /// or index of key in enumeration otherwise.
  ///
  /// Runtime: O(key_size) acesses to stable memory.
  public func replaceChecked(self : Enumeration, key : Blob, value : Blob) : Result.Result<(?Blob, Nat), { #LimitExceeded }> {
    let ?(added, leaf) = Trie.put_(self, key) else return #err(#LimitExceeded);
    let ret_value = if (added) {
      Trie.setValue(self, leaf, value);
      null;
    } else {
      let old_value = Trie.getValue(self, leaf);
      Trie.setValue(self, leaf, value);
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
  /// Runtime: O(key_size) acesses to stable memory.
  public func replace(self : Enumeration, key : Blob, value : Blob) : (?Blob, Nat) = Trie.unwrap(replaceChecked(self, key, value));

  /// Add `key` and `value` to enumeration.
  /// Returns `#LimitExceeded` if pointer size limit exceeded.
  /// Lookup value if key is already present. First return value `size` is if the key in new to the enumeration
  /// or index of key in enumeration otherwise. Second return is old value if new wasn't added or null otherwise.
  ///
  /// Runtime: O(key_size) acesses to stable memory.
  public func lookupOrPutChecked(self : Enumeration, key : Blob, value : Blob) : Result.Result<(?Blob, Nat), { #LimitExceeded }> {
    let ?(added, leaf) = Trie.put_(self, key) else return #err(#LimitExceeded);
    let ret_value = if (added) {
      Trie.setValue(self, leaf, value);
      null;
    } else {
      ?Trie.getValue(self, leaf);
    };
    #ok(ret_value, leaf.toNat());
  };

  /// Add `key` and `value` to enumeration.
  /// Traps if pointer size limit exceeded.
  /// Lookup value if key is already present. First return value `size` is if the key in new to the enumeration
  /// or index of key in enumeration otherwise. Second return is old value if new wasn't added or a new one otherwise.
  ///
  /// Runtime: O(key_size) acesses to stable memory.
  public func lookupOrPut(self : Enumeration, key : Blob, value : Blob) : (?Blob, Nat) = Trie.unwrap(lookupOrPutChecked(self, key, value));

  /// Remove the entry that was last added to the enumeration.
  /// Returns the removed `?(key, value)` pair or `null` if the enumeration is empty.
  ///
  /// Only the leaf for that entry is removed; internal trie nodes that become
  /// empty are left in place. The space at the end of the leaves region is
  /// reused by the next `add`.
  ///
  /// Runtime: O(key_size) accesses to stable memory.
  public func removeLast(self : Enumeration) : ?(Blob, Blob) = Trie.removeLast(self);

  /// Returns `?(value, index)` where `index` is the index of `key` in order it was added to enumeration and `value` is corresponding value to the `key`,
  /// or `null` it `key` wasn't added.
  ///
  /// Runtime: O(key_size) acesses to stable memory.
  public func lookup(self : Enumeration, key : Blob) : ?(Blob, Nat) = Trie.lookup(self, key);

  /// Returns `key` and `value` with index `index` or null if index is out of bounds.
  ///
  /// Runtime: O(1) accesses to stable memory.
  public func get(self : Enumeration, index : Nat) : ?(Blob, Blob) {
    let index_ = index.toNat64();
    if (index_ >= self.leaf_count) return null;
    ?(Trie.getKey(self, index_), Trie.getValue(self, index_));
  };

  /// Returns slice `key` and `value` with indices from `left` to `right` or traps if `left` or `right` are out of bounds.
  ///
  /// Runtime: O(right - left) accesses to stable memory.
  public func slice(self : Enumeration, left : Nat, right : Nat) : [(Blob, Blob)] {
    let l = left.toNat64();
    let r = right.toNat64();
    assert l <= r and r <= self.leaf_count;
    Array.tabulate<(Blob, Blob)>(
      right - left,
      func(i) {
        let index = Nat64.fromIntWrap(i);
        (Trie.getKey(self, index), Trie.getValue(self, index));
      },
    );
  };

  /// Returns all the keys and values in enumeration ordered by `Blob.compare` of keys.
  public func entries(self : Enumeration) : Types.Iter<(Blob, Blob)> = Trie.entries(self);

  /// Returns all the keys and values in the enumeration reverse ordered by `Blob.compare` of keys.
  public func entriesRev(self : Enumeration) : Types.Iter<(Blob, Blob)> = Trie.entriesRev(self);

  /// Returns all the values in the enumeration ordered by `Blob.compare` of keys.
  public func vals(self : Enumeration) : Types.Iter<Blob> = Trie.vals(self);

  /// Returns all the values in the enumeration reverse ordered by `Blob.compare` of keys.
  public func valsRev(self : Enumeration) : Types.Iter<Blob> = Trie.valsRev(self);

  /// Returns all the keys in the enumeration ordered by `Blob.compare` of keys.
  public func keys(self : Enumeration) : Types.Iter<Blob> = Trie.keys(self);

  /// Returns all the keys in the enumeration reverse ordered by `Blob.compare` of keys.
  public func keysRev(self : Enumeration) : Types.Iter<Blob> = Trie.keysRev(self);

  /// Number of key-value pairs in enumeration.
  public func size(self : Enumeration) : Nat = self.leaf_count.toNat();

  /// Memory stats. `node_count` is the number of internal nodes currently
  /// in use; `total_node_count` is the high water (region size).
  public func memoryStats(self : Enumeration) : MemoryStats = Trie.memoryStats(self);

};
