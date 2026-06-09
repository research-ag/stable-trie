/// Free list of deleted items in stable memory.
///
/// Holds raw (non-shifted) item *indices* — node indices for the node list,
/// leaf indices for the leaf list. The two lists never overlap (a given list
/// only ever holds one kind), so the caller always knows which kind it is
/// reading back; no leaf/node tag bit is needed in the stored values.
///
/// The chain lives inside the freed items themselves: each freed item's slot
/// (its first `pointer_size` bytes, at byte offset `offset_base + i*item_size`)
/// holds the index of the next freed item below it on the stack. The bottom
/// item carries no chain link — its slot stays all-zero. The signal for
/// "list is empty" is `count == 0`, not a stored sentinel; no
/// pointer-size-dependent value is ever written into the region by this
/// module, which makes the structure trivially survive a `pointer_size`
/// migration of the surrounding trie.
///
/// Items pushed onto the list MUST be all-zero before the push (apart from
/// the chain-link slot, which `push` overwrites). The caller is responsible
/// for clearing the item: `Map.removeRec` does this via
/// `Layout.setChild(node, slot, 0)` before `pushEmptyNode`, and via
/// `storeBlob(..., zero_leaf)` before `pushEmptyLeaf`.
///
/// Implemented as a plain mutable record plus module-level functions that take
/// the record as their first argument `self`, so callers use dot-notation:
/// `list.push(region, i)`, `list.pop(region)`, etc.

import Region "mo:core/Region";
import Prim "mo:prim";

module {
  let nat64to32 = Prim.nat64ToNat32;
  let nat32to16 = Prim.nat32ToNat16;
  let nat64toNat = Prim.nat64ToNat;
  let natWrap8 = Prim.intToNat8Wrap;

  /// A free list.
  ///
  /// - `offset_base`, `item_size`, `pointer_size` are fixed at construction.
  /// - `loadMask` is precomputed from `pointer_size` (mask of `pointer_size*8`
  ///   bits). Used by `pop` to mask the loaded `Nat64` down to the actual
  ///   chain-link width. NOT used as an empty-list sentinel — that role is
  ///   played by `count == 0`.
  /// - `count` is the list length; `last_empty_item` is the head index when
  ///   `count > 0`. When `count == 0`, `last_empty_item` is just a
  ///   placeholder (set to `0` by `empty` and by `pop` when the list drains).
  public type LinkedList = {
    offset_base : Nat64;
    item_size : Nat64;
    pointer_size : Nat;
    loadMask : Nat64;
    var count : Nat;
    var last_empty_item : Nat64;
  };

  /// Create an empty free list.
  ///
  /// Does NOT require `item_size >= pointer_size` — that precondition is
  /// checked by `push`. Constructing an empty list with a smaller item size
  /// is allowed (Enumeration carries an empty leaf list whose item size can
  /// be less than `pointer_size`); it just may not be pushed to.
  public func empty(offset_base : Nat64, item_size : Nat64, pointer_size : Nat64) : LinkedList {
    let loadMask : Nat64 = if (pointer_size == 8) 0xffff_ffff_ffff_ffff else (1 << (pointer_size << 3)) - 1;
    {
      offset_base;
      item_size;
      pointer_size = nat64toNat(pointer_size);
      loadMask;
      var count = 0;
      var last_empty_item = 0; // placeholder while count == 0
    };
  };

  /// Byte offset of item `i`'s chain-link slot.
  func slotOffset(self : LinkedList, i : Nat64) : Nat64 = self.offset_base +% i *% self.item_size;

  /// Load a `pointer_size`-byte link from `offset`.
  func loadPointer(region : Region.Region, offset : Nat64, mask : Nat64) : Nat64 {
    region.loadNat64(offset) & mask;
  };

  /// Store a `pointer_size`-byte link at `offset`. Dispatches via if-else
  /// on `ps`, ordered 2,4,5,6,8,1 — `pointer_size = 2` is by far the most
  /// common case, so its branch is first; `ps = 1` is a test-only
  /// configuration at the bottom of the cascade.
  func storePointer(region : Region.Region, ps : Nat, offset : Nat64, link : Nat64) {
    if (ps == 2) {
      region.storeNat16(offset, nat32to16(nat64to32(link)));
    } else if (ps == 4) {
      region.storeNat32(offset, nat64to32(link));
    } else if (ps == 5) {
      region.storeNat32(offset, nat64to32(link & 0xffff_ffff));
      region.storeNat8(offset +% 4, natWrap8(nat64toNat(link >> 32)));
    } else if (ps == 6) {
      region.storeNat32(offset, nat64to32(link & 0xffff_ffff));
      region.storeNat16(offset +% 4, nat32to16(nat64to32(link >> 32)));
    } else if (ps == 8) {
      region.storeNat64(offset, link);
    } else {
      // ps == 1, tests only.
      region.storeNat8(offset, natWrap8(nat64toNat(link)));
    };
  };

  /// Add a deleted item (by index) to the list. Caller MUST hand in an
  /// all-zero item slot; this function writes only the chain link (and only
  /// when the list was already non-empty — the bottom item has no chain
  /// link, its slot stays all-zero).
  ///
  /// Requires `item_size >= pointer_size`; otherwise the link would spill
  /// into the next item's slot.
  public func push(self : LinkedList, region : Region.Region, item : Nat64) {
    if (self.count > 0) {
      // Non-empty list: link the new top down to what used to be on top.
      storePointer(region, self.pointer_size, slotOffset(self, item), self.last_empty_item);
    };
    // Empty list: skip the write — the item is already all-zero by
    // precondition, and the all-zero state is the bottom-of-list marker.
    self.last_empty_item := item;
    self.count += 1;
  };

  /// Pop the most-recently-freed item (by index), or `null` if empty.
  /// The popped item's chain-link slot is cleared on the way out so that
  /// the item is fully reusable as an all-zero block.
  public func pop(self : LinkedList, region : Region.Region) : ?Nat64 {
    if (self.count == 0) return null;

    let ret = self.last_empty_item;
    self.count -= 1;
    if (self.count > 0) {
      // Read the chain link to find the next-to-pop.
      self.last_empty_item := loadPointer(region, slotOffset(self, ret), self.loadMask);
    } else {
      // Just popped the bottom; restore the placeholder.
      self.last_empty_item := 0;
    };
    // Clear the popped item's chain-link slot (idempotent zero-write when
    // ret was the bottom — its slot is already 0).
    storePointer(region, self.pointer_size, slotOffset(self, ret), 0);
    ?ret;
  };
};
