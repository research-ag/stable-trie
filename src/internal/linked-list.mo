/// List of empty items (nodes or leaves) in stable memory.
/// Used to implement deletion: freed items are pushed and the next allocation
/// pops from the list before growing the region.
///
/// Parameterised on the low-level region primitives so it can live anywhere
/// — `StableTrieBase` uses one of these internally for empty nodes, and
/// `Map` uses another for empty leaves.

import Nat64 "mo:core/Nat64"; // bitcountTrailingZero
import Region "mo:core/Region";

module {

  public class LinkedList(
    sentinel : Nat64,
    loadFn : (Region.Region, Nat64) -> Nat64,
    storeFn : (Region.Region, Nat64, Nat64) -> (),
    getOffset : (Nat64) -> Nat64,
  ) {
    var last_empty_item : Nat64 = sentinel;
    public var count = 0;

    /// Add deleted item to linked list.
    public func push(region : Region.Region, item : Nat64) {
      storeFn(region, getOffset(item), last_empty_item);
      last_empty_item := item;
      count += 1;
    };

    /// Pop last deleted item from linked list.
    public func pop(region : Region.Region) : ?Nat64 {
      if (last_empty_item == sentinel) return null;

      let ret = last_empty_item;
      last_empty_item := loadFn(region, getOffset(last_empty_item));
      storeFn(region, getOffset(ret), 0);
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
