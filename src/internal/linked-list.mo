/// Free list of deleted items in stable memory.
///
/// Holds raw (non-shifted) item *indices* — node indices for the node list,
/// leaf indices for the leaf list. The two lists never overlap (a given list
/// only ever holds one kind), so the caller always knows which kind it is
/// reading back; no leaf/node tag bit is needed in the stored values.
///
/// The chain lives inside the freed items themselves: each freed item's slot
/// (its first `pointer_size` bytes, at byte offset `offset_base + i*item_size`)
/// holds the index of the next freed item, or the all-ones sentinel for the
/// tail of the chain.
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
  ///   bits). It doubles as the empty-list sentinel: every valid index is
  ///   `< 2 ** (pointer_size*8 - 1) < loadMask`, so the sentinel can never
  ///   collide with a real item index.
  /// - `count` is the list length; `last_empty_item` is the head index (or the
  ///   sentinel when the list is empty).
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
      var last_empty_item = loadMask; // empty: head == sentinel
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

  /// Add a deleted item (by index) to the list. Requires that the item slot
  /// be large enough to hold a chain link, i.e. the `item_size` chosen at
  /// construction is at least `pointer_size`; otherwise the link spills into
  /// the next item's slot.
  public func push(self : LinkedList, region : Region.Region, item : Nat64) {
    storePointer(region, self.pointer_size, slotOffset(self, item), self.last_empty_item);
    self.last_empty_item := item;
    self.count += 1;
  };

  /// Pop the most-recently-freed item (by index), or `null` if empty.
  public func pop(self : LinkedList, region : Region.Region) : ?Nat64 {
    if (self.last_empty_item == self.loadMask) return null;

    let ret = self.last_empty_item;
    self.last_empty_item := loadPointer(region, slotOffset(self, self.last_empty_item), self.loadMask);
    storePointer(region, self.pointer_size, slotOffset(self, ret), 0);
    self.count -= 1;
    ?ret;
  };
};
