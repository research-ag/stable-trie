/// Memory layout for the stable-trie record.
///
/// Owns the `StableTrie` record type and the low-level read/write helpers
/// (`getChild`/`setChild`/`getKey`/`getValue`/`setValue`/`getRawNode`)
/// plus the address arithmetic. Everything here is "where in memory
/// things live, and how to encode/decode them" — the algorithm itself
/// (find/put/remove/lookup/iter) lives in `trie.mo`. `setChild`
/// dispatches via an if-else cascade on `pointer_size` ordered
/// `2 → 4 → 5 → 6 → 8` (most common first).
///
/// The type definition lives here (rather than in `trie.mo`) to break the
/// otherwise-circular dependency: `trie.mo`'s algorithm calls layout
/// helpers, and the helpers need the record type. `trie.mo` re-exports
/// `StableTrie` so its public name stays the same.

import Region "mo:core/Region";
import Prim "mo:prim";

import LinkedList "./linked-list";

module {
  let nat64to32 = Prim.nat64ToNat32;
  let nat32to16 = Prim.nat32ToNat16;
  let nat64toNat = Prim.nat64ToNat;
  let natWrap8 = Prim.intToNat8Wrap;

  /// Stable trie record underlying `Map` and `Enumeration`.
  /// SHOULD NOT BE USED DIRECTLY FROM USER CODE.
  ///
  /// Holds:
  /// - the three `Nat`-typed user inputs actually read at runtime
  ///   (`pointer_size`, `key_size`, `value_size`) and a host of `Nat64`/`Nat`
  ///   values precomputed from `args` so per-call hot paths don't recompute
  ///   conversions and masks;
  /// - `empty_nodes_list` and `empty_leaves_list`, free lists of freed
  ///   internal nodes and leaf slots;
  /// - the mutable state vars: counts and the two regions.
  public type StableTrie = {
    pointer_size : Nat;
    key_size : Nat;
    value_size : Nat;
    aridity_ : Nat64;
    key_size_ : Nat64;
    pointer_size_ : Nat64;
    root_aridity_ : Nat64;
    loadMask : Nat64;
    bitlength : Nat16;
    bitshift : Nat8;
    max_address : Nat64;
    /// Static upper bound on the number of internal nodes `put_`'s split
    /// loop can allocate in one call. Equal to the maximum chain length
    /// from below-root to the bottom of the trie:
    /// `(key_size * 8 - root_bitlength) / bitlength`.
    max_chain_depth : Nat64;
    /// `max_address - max_chain_depth`, saturated at 0. Used by `put_`'s
    /// tier-1 capacity check: if `node_count < safe_node_bound`, the
    /// split loop's worst-case allocation fits without consulting the
    /// `empty_nodes_list`. Conservative — false alarms fall through to
    /// the tier-2 check that does account for the free list.
    safe_node_bound : Nat64;
    root_bitlength_ : Nat64;
    root_bitlength : Nat16;
    node_size : Nat64;
    node_size_ : Nat;
    leaf_size : Nat64;
    root_size : Nat64;
    offset_base : Nat64;
    padding : Nat64;
    empty_values : Bool;
    empty_nodes_list : LinkedList.LinkedList;
    empty_leaves_list : LinkedList.LinkedList;
    var leaf_count : Nat64;
    var node_count : Nat64;
    var nodes_region : Region.Region;
    var nodes_freeSpace : Nat64;
    var leaves_region : Region.Region;
    var leaves_freeSpace : Nat64;
  };

  // Base address of node (the offset of its first child pointer).
  // Unused.
  func _getNodeBase(self : StableTrie, node : Nat64) : Nat64 {
    if (node == 0) return 0; // root node
    (self.offset_base +% (node >> 1) *% self.node_size);
  };

  /// Load the whole node `node` as a `Blob` of `node_size_` bytes. Used by
  /// `scanChildren` to parse all child pointers in one region read.
  /// `getNodeBase` is inlined here.
  public func getRawNode(self : StableTrie, node : Nat64) : Blob {
    let base = if (node == 0) 0 : Nat64 else self.offset_base +% (node >> 1) *% self.node_size;
    self.nodes_region.loadBlob(base, self.node_size_);
  };

  // Address of pointer of node's `node` child number `index`.
  // Unused.
  func _getNodeOffset(self : StableTrie, node : Nat64, index : Nat64) : Nat64 {
    let delta = index *% self.pointer_size_;
    if (node == 0) return delta; // root node
    (self.offset_base +% (node >> 1) *% self.node_size) +% delta;
  };

  /// Load node's `node` child number `index`. getNodeOffset is inlined here
  /// — moc doesn't auto-inline it, and getChild is called per level inside
  /// the `find` loop on every put/lookup/remove.
  public func getChild(self : StableTrie, node : Nat64, index : Nat64) : Nat64 {
    let delta = index *% self.pointer_size_;
    let offset = if (node == 0) delta else (self.offset_base +% (node >> 1) *% self.node_size) +% delta;
    Prim.regionLoadNat64(self.nodes_region, offset) & self.loadMask;
  };

  /// Set node's `node` child number `index`.
  /// General version: nested if-else on `pointer_size`, checking sizes in
  /// order 2, 4, 5, 6, 8, 1 (most common first; `ps = 1` is a test-only
  /// configuration and lives at the bottom of the cascade). Use this from
  /// sites where setChild is called only once. From hot sites that call it
  /// repeatedly (e.g. `put_`), hoist the dispatch by picking the matching
  /// `setChildN` once and reusing it. getNodeOffset is inlined here too —
  /// moc doesn't auto-inline it.
  public func setChild(self : StableTrie, node : Nat64, index : Nat64, child : Nat64) {
    let delta = index *% self.pointer_size_;
    let offset = if (node == 0) delta else (self.offset_base +% (node >> 1) *% self.node_size) +% delta;
    let region = self.nodes_region;
    let ps = self.pointer_size;
    if (ps == 2) {
      region.storeNat16(offset, nat32to16(nat64to32(child)));
    } else if (ps == 4) {
      region.storeNat32(offset, nat64to32(child));
    } else if (ps == 5) {
      region.storeNat32(offset, nat64to32(child & 0xffff_ffff));
      region.storeNat8(offset +% 4, natWrap8(nat64toNat(child >> 32)));
    } else if (ps == 6) {
      region.storeNat32(offset, nat64to32(child & 0xffff_ffff));
      region.storeNat16(offset +% 4, nat32to16(nat64to32(child >> 32)));
    } else if (ps == 8) {
      region.storeNat64(offset, child);
    } else {
      // ps == 1, tests only.
      region.storeNat8(offset, natWrap8(nat64toNat(child)));
    };
  };

  /// Offset of leaf number `index`. Kept public for external callers (e.g.
  /// `trie.newLeaf`); the in-module users below inline its body directly.
  public func getLeafOffset(self : StableTrie, index : Nat64) : Nat64 = index *% self.leaf_size;

  /// Load key of leaf number `index`. getLeafOffset inlined.
  public func getKey(self : StableTrie, index : Nat64) : Blob {
    self.leaves_region.loadBlob(index *% self.leaf_size, self.key_size);
  };

  /// Load value of leaf number `index`. getLeafOffset inlined.
  public func getValue(self : StableTrie, index : Nat64) : Blob {
    if (self.empty_values) return "";
    self.leaves_region.loadBlob(index *% self.leaf_size +% self.key_size_, self.value_size);
  };

  /// Set value of leaf number `index`. getLeafOffset inlined.
  public func setValue(self : StableTrie, index : Nat64, value : Blob) {
    assert value.size() == self.value_size;
    if (self.empty_values) return;
    self.leaves_region.storeBlob(index *% self.leaf_size +% self.key_size_, value);
  };
};
