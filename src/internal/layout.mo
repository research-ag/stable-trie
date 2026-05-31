/// Memory layout for the stable-trie record.
///
/// Owns the `StableTrie` record type and the low-level read/write helpers
/// (`getChild`/`setChild`/`getKey`/`getValue`/`setValue`) plus the address
/// arithmetic (`getNodeBase`/`getLeafOffset`) and the pointer-size store
/// dispatch table. Everything in here is "this is where in memory things
/// live, and how to encode/decode them" — the algorithm itself (find/put/
/// remove/lookup/iter) lives in `trie.mo`.
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

  /// Base address of node (the offset of its first child pointer).
  public func getNodeBase(self : StableTrie, node : Nat64) : Nat64 {
    if (node == 0) return 0; // root node
    (self.offset_base +% (node >> 1) *% self.node_size);
  };

  /// Address of pointer of node's `node` child number `index`.
  func getNodeOffset(self : StableTrie, node : Nat64, index : Nat64) : Nat64 {
    let delta = index *% self.pointer_size_;
    if (node == 0) return delta; // root node
    (self.offset_base +% (node >> 1) *% self.node_size) +% delta;
  };

  /// Load node's `node` child number `index`.
  public func getChild(self : StableTrie, node : Nat64, index : Nat64) : Nat64 {
    Prim.regionLoadNat64(self.nodes_region, getNodeOffset(self, node, index)) & self.loadMask;
  };

  /// Set node's `node` child number `index`.
  /// General version: nested if-else on `pointer_size`, checking sizes in
  /// order 2, 4, 5, 6, 8. Use this from sites where setChild is called only
  /// once. From hot sites that call it repeatedly (e.g. `put_`), hoist the
  /// dispatch by picking the matching `setChildN` once and reusing it.
  public func setChild(self : StableTrie, node : Nat64, index : Nat64, child : Nat64) {
    let offset = getNodeOffset(self, node, index);
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
    } else {
      region.storeNat64(offset, child);
    };
  };

  /// Specialized setChild for pointer_size = 2. getNodeOffset inlined;
  /// `delta = index *% 2` becomes `index << 1`.
  public func setChild2(self : StableTrie, node : Nat64, index : Nat64, child : Nat64) {
    let delta = index << 1;
    let offset = if (node == 0) delta else (self.offset_base +% (node >> 1) *% self.node_size) +% delta;
    self.nodes_region.storeNat16(offset, nat32to16(nat64to32(child)));
  };

  /// Specialized setChild for pointer_size = 4. getNodeOffset inlined;
  /// `delta = index *% 4` becomes `index << 2`.
  public func setChild4(self : StableTrie, node : Nat64, index : Nat64, child : Nat64) {
    let delta = index << 2;
    let offset = if (node == 0) delta else (self.offset_base +% (node >> 1) *% self.node_size) +% delta;
    self.nodes_region.storeNat32(offset, nat64to32(child));
  };

  /// Specialized setChild for pointer_size = 5. getNodeOffset inlined;
  /// delta = index *% 5 (no shift available, but constant multiplier).
  public func setChild5(self : StableTrie, node : Nat64, index : Nat64, child : Nat64) {
    let delta = index *% 5;
    let offset = if (node == 0) delta else (self.offset_base +% (node >> 1) *% self.node_size) +% delta;
    let region = self.nodes_region;
    region.storeNat32(offset, nat64to32(child & 0xffff_ffff));
    region.storeNat8(offset +% 4, natWrap8(nat64toNat(child >> 32)));
  };

  /// Specialized setChild for pointer_size = 6. getNodeOffset inlined;
  /// delta = index *% 6 (no shift available, but constant multiplier).
  public func setChild6(self : StableTrie, node : Nat64, index : Nat64, child : Nat64) {
    let delta = index *% 6;
    let offset = if (node == 0) delta else (self.offset_base +% (node >> 1) *% self.node_size) +% delta;
    let region = self.nodes_region;
    region.storeNat32(offset, nat64to32(child & 0xffff_ffff));
    region.storeNat16(offset +% 4, nat32to16(nat64to32(child >> 32)));
  };

  /// Specialized setChild for pointer_size = 8. getNodeOffset inlined;
  /// `delta = index *% 8` becomes `index << 3`.
  public func setChild8(self : StableTrie, node : Nat64, index : Nat64, child : Nat64) {
    let delta = index << 3;
    let offset = if (node == 0) delta else (self.offset_base +% (node >> 1) *% self.node_size) +% delta;
    self.nodes_region.storeNat64(offset, child);
  };

  /// Offset of leaf number `index`.
  public func getLeafOffset(self : StableTrie, index : Nat64) : Nat64 = index *% self.leaf_size;

  /// Load key of leaf number `index`.
  public func getKey(self : StableTrie, index : Nat64) : Blob {
    self.leaves_region.loadBlob(getLeafOffset(self, index), self.key_size);
  };

  /// Load value of leaf number `index`.
  public func getValue(self : StableTrie, index : Nat64) : Blob {
    if (self.empty_values) return "";
    self.leaves_region.loadBlob(getLeafOffset(self, index) +% self.key_size_, self.value_size);
  };

  /// Set value of leaf number `index`.
  public func setValue(self : StableTrie, index : Nat64, value : Blob) {
    assert value.size() == self.value_size;
    if (self.empty_values) return;
    self.leaves_region.storeBlob(getLeafOffset(self, index) +% self.key_size_, value);
  };
};
