/// Stable trie enumeration.
///
/// `Enumeration` is a "set enumeration" of elements of `Blob`s called "keys"
/// interface implemented in stable memory using trie.
///
/// A typical application is to assign permanent user numbers to princpals.
///
/// The data structure is a map `Nat -> Blob` with the following properties:
/// * keys are not repeated, i.e. the map is injective
/// * keys are consecutively numbered (no gaps), i.e. if n keys are stored
///   then `[0,n) -> Blob` is bijective
/// * keys are numbered in the order they are added to the data structure
/// * keys cannot be deleted
/// * efficient inverse lookup `Blob -> Nat`
/// * doubles as a set implementation (without deletion)
///
/// Copyright: 2023-2024 MR Research AG
/// Main author: Andrii Stepanov (AStepanov25)
/// Contributors: Timo Hanke (timohanke)

import Blob "mo:base/Blob";
import Nat64 "mo:base/Nat64";
import Nat "mo:base/Nat";
import Array "mo:base/Array";
import Iter "mo:base/Iter";
import Option "mo:base/Option";
import Region "mo:base/Region";
import Nat8 "mo:base/Nat8";
import Nat16 "mo:base/Nat16";
import Debug "mo:base/Debug";
import Nat32 "mo:base/Nat32";
import Int "mo:base/Int";

module {
  /// Stable region with `freeSpace` variable.
  public type Region = {
    region : Region.Region;
    var freeSpace : Nat64;
  };

  public type Args = {
    pointer_size : Nat;
    aridity : Nat;
    root_aridity : ?Nat;
    key_size : Nat;
    value_size : Nat;
  };

  /// Type of stable data of `StableTrieEnumeration`
  public type StableData = {
    nodes : Region;
    leaves : Region;
    node_count : Nat64;
    leaf_count : Nat64;
  };

  public class StableTrieBase(args : Args) {
    assert switch (args.pointer_size) {
      case (2 or 4 or 5 or 6 or 8) true;
      case (_) false;
    };
    assert switch (args.aridity) {
      case (2 or 4 or 16 or 256) true;
      case (_) false;
    };
    assert args.key_size >= 1 and args.key_size + args.value_size <= 2 ** 16;

    public let aridity_ = Nat64.fromNat(args.aridity);
    public let key_size_ = Nat64.fromNat(args.key_size);
    public let value_size_ = Nat64.fromNat(args.value_size);
    public let pointer_size_ = Nat64.fromNat(args.pointer_size);
    public let root_aridity_ = Nat64.fromNat(Option.get(args.root_aridity, args.aridity));

    public let loadMask = if (args.pointer_size == 8) 0xffff_ffff_ffff_ffff : Nat64 else (1 << (pointer_size_ << 3)) - 1;

    public let bitlength = Nat16.bitcountTrailingZero(Nat16.fromNat(args.aridity));
    public let bitshift = Nat16.toNat8(8 - bitlength);
    public let bitlength_ = Nat32.toNat64(Nat16.toNat32(bitlength));

    public let max_address = 2 ** (pointer_size_ * 8 - 1);

    assert Nat64.bitcountNonZero(root_aridity_) == 1; // 2-power
    public let root_bitlength_ = Nat64.bitcountTrailingZero(root_aridity_);
    assert root_bitlength_ > 0 and root_bitlength_ % bitlength_ == 0; // => root_bitlength_ >= bitlength_
    assert root_bitlength_ <= key_size_ * 8;

    let root_depth = Nat32.toNat16(Nat64.toNat32(root_bitlength_ / bitlength_));
    public let root_bitlength = Nat32.toNat16(Nat64.toNat32(root_bitlength_));

    public let node_size : Nat64 = aridity_ * pointer_size_;
    public let node_size_ : Nat = Nat64.toNat(node_size);
    public let leaf_size : Nat64 = key_size_ + value_size_;
    public let root_size : Nat64 = root_aridity_ * pointer_size_;
    public let offset_base : Nat64 = root_size - node_size;
    public let padding : Nat64 = 8 - pointer_size_;
    public let empty_values : Bool = args.value_size == 0;

    public var leaf_count : Nat64 = 0;
    public var node_count : Nat64 = 0;

    public var storePointer : (offset : Nat64, child : Nat64) -> () = func(_, _) {};

    public type State = {
      nodes : Region;
      leaves : Region;
    };

    var regions_ : ?State = null;

    public func regions() : State {
      switch (regions_) {
        case (?r) r;
        case (null) {
          let nodes_region = Region.new();
          let nodes : Region = {
            region = nodes_region;
            var freeSpace = 0;
          };
          let pages = (root_size + padding + 65536 - 1) / 65536;
          assert Region.grow(nodes.region, pages) != 0xffff_ffff_ffff_ffff;
          nodes.freeSpace := pages * 65536 - root_size - padding;
          node_count := 1;

          let leaves : Region = {
            region = Region.new();
            var freeSpace = 0;
          };

          let ret = { nodes = nodes; leaves = leaves };
          regions_ := ?ret;
          storePointer := switch (pointer_size_) {
            case (8) func(offset, child) = Region.storeNat64(nodes_region, offset, child);
            case (6) func(offset, child) {
              Region.storeNat32(nodes_region, offset, Nat32.fromNat64(child & 0xffff_ffff));
              Region.storeNat16(nodes_region, offset +% 4, Nat16.fromNat32(Nat32.fromNat64(child >> 32)));
            };
            case (5) func(offset, child) {
              Region.storeNat32(nodes_region, offset, Nat32.fromNat64(child & 0xffff_ffff));
              Region.storeNat8(nodes_region, offset +% 4, Nat8.fromNat16(Nat16.fromNat32(Nat32.fromNat64(child >> 32))));
            };
            case (4) func(offset, child) = Region.storeNat32(nodes_region, offset, Nat32.fromNat64(child));
            case (2) func(offset, child) = Region.storeNat16(nodes_region, offset, Nat16.fromNat32(Nat32.fromNat64(child)));
            case (_) Debug.trap("Can never happen");
          };

          ret;
        };
      };
    };

    // allocate can only be used for n <= 65536
    func allocate(region : Region, n : Nat64) {
      if (region.freeSpace < n) {
        assert Region.grow(region.region, 1) != 0xffff_ffff_ffff_ffff;
        region.freeSpace +%= 65536;
      };
      region.freeSpace -%= n;
    };

    func newInternalNode(region : Region) : ?Nat64 {
      if (node_count == max_address) return null;

      allocate(region, node_size);
      let nc = node_count;
      node_count +%= 1;
      ?(nc << 1);
    };

    public func newLeaf(region : Region, key : Blob) : ?Nat64 {
      if (leaf_count == max_address) return null;

      allocate(region, leaf_size);
      let lc = leaf_count;
      let pos = leaf_count *% leaf_size;
      leaf_count +%= 1;
      Region.storeBlob(region.region, pos, key);
      ?((lc << 1) | 1);
    };

    public func getOffset(node : Nat64, index : Nat64) : Nat64 {
      let delta = index *% pointer_size_;
      if (node == 0) return delta; // root node
      (offset_base +% (node >> 1) *% node_size) +% delta;
    };

    public func getChild(region : Region, node : Nat64, index : Nat64) : Nat64 {
      Region.loadNat64(region.region, getOffset(node, index)) & loadMask;
    };

    public func setChild(node : Nat64, index : Nat64, child : Nat64) {
      let offset = getOffset(node, index);
      storePointer(offset, child);
    };

    public func getLeafOffset(index : Nat64) : Nat64 = index *% leaf_size;

    public func getKey(region : Region, index : Nat64) : Blob {
      Region.loadBlob(region.region, getLeafOffset(index), args.key_size);
    };

    public func getValue(region : Region, index : Nat64) : Blob {
      if (empty_values) return "";
      Region.loadBlob(region.region, getLeafOffset(index) +% key_size_, args.value_size);
    };

    public func setValue(region : Region, index : Nat64, value : Blob) {
      assert value.size() == args.value_size;
      if (empty_values) return;
      Region.storeBlob(region.region, getLeafOffset(index) +% key_size_, value);
    };

    public func keyToRootIndex(bytes : [Nat8]) : Nat64 {
      var result : Nat64 = 0;
      var i = 0;
      let iters = Nat64.toNat(root_bitlength_ >> 3);
      while (i < iters) {
        result := (result << 8) | Nat32.toNat64(Nat16.toNat32(Nat8.toNat16(bytes[i])));
        i += 1;
      };
      let skip = root_bitlength_ & 7;
      if (skip != 0) {
        result := (result << skip) | (Nat32.toNat64(Nat16.toNat32(Nat8.toNat16(bytes[i]))) >> (8 -% skip));
      };
      return result;
    };

    public func keyToIndex(bytes : [Nat8], pos : Nat16) : Nat64 {
      let bit_pos = Nat8.fromNat16(pos & 7);
      let ret = Nat8.toNat((bytes[Nat16.toNat(pos >> 3)] << bit_pos) >> bitshift);
      return Nat64.fromIntWrap(ret);
    };

    public func find(nodes : Region, bytes : [Nat8]) : (Nat64, Nat64, Nat64, Nat16) {
      var idx = keyToRootIndex(bytes);
      var pos = root_bitlength;
      var node : Nat64 = 0;
      var old_leaf : Nat64 = 0;
      loop {
        switch (getChild(nodes, node, idx)) {
          case (0) {
            old_leaf := 0;
            return (node, idx, old_leaf, pos);
          };
          case (n) {
            if (n & 1 == 1) {
              old_leaf := n;
              return (node, idx, old_leaf, pos);
            };
            node := n;
          };
        };
        idx := keyToIndex(bytes, pos);
        pos +%= bitlength;
      };
      Debug.trap("Unreacheable");
    };

    public func put_(nodes : Region, leaves : Region, key : Blob) : ?Nat64 {
      assert key.size() == args.key_size;
      let bytes = Blob.toArray(key);

      let (node_, last_, old_leaf, pos_) = find(nodes, bytes);

      var last = last_;
      var node = node_;

      if (old_leaf == 0) {
        let ?leaf = newLeaf(leaves, key) else return null;

        setChild(node, last, leaf);
        return ?(leaf >> 1);
      };

      let index = old_leaf >> 1;
      let old_key = getKey(leaves, index);
      if (key == old_key) {
        return ?index;
      };

      let old_bytes = Blob.toArray(old_key);
      var pos = pos_;
      label l loop {
        let ?add = newInternalNode(nodes) else {
          setChild(node, last, old_leaf);
          return null;
        };
        setChild(node, last, add);
        node := add;

        let (a, b) = (keyToIndex(bytes, pos), keyToIndex(old_bytes, pos));
        pos +%= bitlength;
        if (a == b) {
          last := a;
        } else {
          setChild(node, b, old_leaf);
          let ?leaf = newLeaf(leaves, key) else return null;
          setChild(node, a, leaf);
          return ?(leaf >> 1);
        };
      };
      Debug.trap("Unreacheable");
    };

    public func lookup(key : Blob) : ?(Blob, Nat) {
      assert key.size() == args.key_size;
      let { leaves; nodes } = regions();

      let bytes = Blob.toArray(key);

      let (_, _, old_leaf, _) = find(nodes, bytes);
      if (old_leaf == 0) return null;
      let index = old_leaf >> 1;
      return if (getKey(leaves, index) == key) ?(getValue(leaves, index), Nat64.toNat(index)) else null;
    };

    class Iterator(nodes : Region, forward : Bool) {
      let stack = Array.init<(Nat64, Nat64)>(args.key_size * 8 / Nat16.toNat(bitlength), (0, 0));
      var depth = 1;
      stack[0] := if (forward) (0, 0) else (0, root_aridity_ - 1);

      func next_step(i : Nat64) : Nat64 {
        if (forward) {
          i + 1;
        } else {
          if (i != 0) i - 1 else root_aridity_;
        };
      };

      public func next() : ?Nat64 {
        let leaf = label l : ?Nat64 loop {
          let (node, i) = stack[depth - 1];
          let max = if (depth > 1) aridity_ else root_aridity_;
          if (i < max) {
            let child = getChild(nodes, node, i);
            if (child == 0) {
              stack[depth - 1] := (node, next_step(i));
              continue l;
            };
            if (child & 1 == 1) {
              stack[depth - 1] := (node, next_step(i));
              break l(?(child >> 1));
            };
            stack[depth] := (child, if (forward) 0 else aridity_ - 1);
            depth += 1;
          } else {
            if (depth == 1) break l null;
            depth -= 1;
            let (prev_node, prev_i) = stack[depth - 1];
            stack[depth - 1] := (prev_node, next_step(prev_i));
          };
        };
        leaf;
      };
    };

    func entries_(forward : Bool) : Iter.Iter<(Blob, Blob)> {
      let state = regions();
      let { nodes; leaves } = state;

      Iter.map<Nat64, (Blob, Blob)>(Iterator(nodes, forward), func(leaf) = (getKey(leaves, leaf), getValue(leaves, leaf)));
    };

    func vals_(forward : Bool) : Iter.Iter<Blob> {
      let state = regions();
      let { nodes; leaves } = state;

      Iter.map<Nat64, Blob>(Iterator(nodes, forward), func(leaf) = getValue(leaves, leaf));
    };

    func keys_(forward : Bool) : Iter.Iter<Blob> {
      let state = regions();
      let { nodes; leaves } = state;

      Iter.map<Nat64, Blob>(Iterator(nodes, forward), func(leaf) = getKey(leaves, leaf));
    };

    public func entries() : Iter.Iter<(Blob, Blob)> {
      entries_(true);
    };

    public func entriesRev() : Iter.Iter<(Blob, Blob)> {
      entries_(false);
    };

    public func vals() : Iter.Iter<Blob> {
      vals_(true);
    };

    public func valsRev() : Iter.Iter<Blob> {
      vals_(false);
    };

    public func keys() : Iter.Iter<Blob> {
      keys_(true);
    };

    public func keysRev() : Iter.Iter<Blob> {
      keys_(false);
    };

    public func size() : Nat = Nat64.toNat(root_size + (node_count - 1) * node_size + leaf_count * leaf_size);

    public func leafCount() : Nat = Nat64.toNat(leaf_count);

    public func nodeCount() : Nat = Nat64.toNat(node_count);

    public func share() : StableData = {
      regions() with
      node_count;
      leaf_count;
    };

    public func unshare(data : StableData) {
      switch (regions_) {
        case (null) {
          regions_ := ?data;
          node_count := data.node_count;
          leaf_count := data.leaf_count;
        };
        case (_) Debug.trap("Region is already initialized");
      };
    };
  };
};
