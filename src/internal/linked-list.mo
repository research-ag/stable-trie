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
/// Everything the list needs — the sentinel/`loadMask`, the pointer-sized
/// load/store, and the slot offset — is derived from just three values:
///   - `offset_base`: byte offset of item 0's slot (e.g. `0` for the leaf
///     list, the region's node base for the node list);
///   - `item_size`:   stride between consecutive items' slots (leaf size or
///     node size);
///   - `pointer_size`: number of bytes used per stored link (2/4/5/6/8).

import Region "mo:core/Region";
import Runtime "mo:core/Runtime";
import Prim "mo:prim";

module {
  let nat64to32 = Prim.nat64ToNat32;
  let nat32to16 = Prim.nat32ToNat16;
  let nat64toNat = Prim.nat64ToNat;
  let natWrap8 = Prim.intToNat8Wrap;

  public class LinkedList(
    offset_base : Nat64,
    item_size : Nat64,
    pointer_size : Nat64,
  ) {
    /// Mask of `pointer_size * 8` bits. Also serves as the empty-list
    /// sentinel: every valid index is `< 2 ** (pointer_size*8 - 1) < loadMask`,
    /// so the sentinel can never collide with a real item index.
    let loadMask : Nat64 = if (pointer_size == 8) 0xffff_ffff_ffff_ffff else (1 << (pointer_size << 3)) - 1;

    /// Byte offset of item `i`'s chain-link slot.
    func slotOffset(i : Nat64) : Nat64 = offset_base +% i *% item_size;

    /// Load a `pointer_size`-byte link from `offset`.
    func loadPointer(region : Region.Region, offset : Nat64) : Nat64 = region.loadNat64(offset) & loadMask;

    /// Store a `pointer_size`-byte link at `offset`.
    let storePointer : (region : Region.Region, offset : Nat64, link : Nat64) -> () = switch (pointer_size) {
      case (8) func(region, offset, link) = region.storeNat64(offset, link);
      case (6) func(region, offset, link) {
        region.storeNat32(offset, nat64to32(link & 0xffff_ffff));
        region.storeNat16(offset +% 4, nat32to16(nat64to32(link >> 32)));
      };
      case (5) func(region, offset, link) {
        region.storeNat32(offset, nat64to32(link & 0xffff_ffff));
        region.storeNat8(offset +% 4, natWrap8(nat64toNat(link >> 32)));
      };
      case (4) func(region, offset, link) = region.storeNat32(offset, nat64to32(link));
      case (2) func(region, offset, link) = region.storeNat16(offset, nat32to16(nat64to32(link)));
      case (_) Runtime.trap("invalid pointer_size");
    };

    var last_empty_item : Nat64 = loadMask;
    public var count = 0;

    /// Add a deleted item (by index) to the list.
    public func push(region : Region.Region, item : Nat64) {
      storePointer(region, slotOffset(item), last_empty_item);
      last_empty_item := item;
      count += 1;
    };

    /// Pop the most-recently-freed item (by index), or `null` if empty.
    public func pop(region : Region.Region) : ?Nat64 {
      if (last_empty_item == loadMask) return null;

      let ret = last_empty_item;
      last_empty_item := loadPointer(region, slotOffset(last_empty_item));
      storePointer(region, slotOffset(ret), 0);
      count -= 1;
      ?ret;
    };

    public func share() : (Nat, Nat64) = (count, last_empty_item);

    public func unshare((c, last) : (Nat, Nat64)) {
      count := c;
      last_empty_item := last;
    };
  };

};
