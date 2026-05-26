/// Base class for stable trie.
///
/// Copyright: 2023 - 2025 MR Research AG
///
/// Main author: Andrii Stepanov (AStepanov25)
///
/// Contributors: Timo Hanke (timohanke)

import Iter "mo:core/Iter";
import Nat_ "mo:core/Nat";
import Nat16 "mo:core/Nat16"; // bitcountTrailingZero
import Nat64 "mo:core/Nat64"; // bitcountTrailingZero
import Option "mo:core/Option";
import Region "mo:core/Region";
import Result "mo:core/Result";
import Runtime "mo:core/Runtime";
import Types "mo:core/Types";
import VarArray "mo:core/VarArray";
import Prim "mo:prim";

module {
  // up conversions
  let nat8to16 = Prim.nat8ToNat16;
  let nat16to32 = Prim.nat16ToNat32;
  let nat16toNat = Prim.nat16ToNat;
  let nat32to64 = Prim.nat32ToNat64;
  let nat64toNat = Prim.nat64ToNat;

  // down conversions
  let nat16to8 = Prim.nat16ToNat8;
  let nat32to16 = Prim.nat32ToNat16;
  let nat64to32 = Prim.nat64ToNat32;
  let natWrap8 = Prim.intToNat8Wrap;

  /// Stable region with `freeSpace` variable.
  public type Region = {
    region : Region.Region;
    var freeSpace : Nat64;
  };

  /// List of empty items (nodes or leaves) in stable memory.
  /// Used to implement deletion: freed items are pushed and the next allocation
  /// pops from the list before growing the region.
  ///
  /// Parameterised on the low-level region primitives so it can live anywhere
  /// — `StableTrieBase` uses one of these internally for empty nodes, and
  /// `Map` uses another for empty leaves.
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

  /// Arguments of constructor of `Enumeration` and `Map`.
  /// pointer_size: size of pointer in bytes (2, 4, 5, 6, 8)
  /// aridity: number of children per internal node (2, 4, 16, 256)
  /// root_aridity: number of children for root node (must be power), null mean same as aridity
  /// key_size: size of keys in bytes (>= 1)
  /// value_size: size of values in bytes (>= 0)
  public type BaseArgs = {
    pointer_size : Nat;
    aridity : Nat;
    root_aridity : ?Nat;
    key_size : Nat;
    value_size : Nat;
  };

  /// Arguments of constructor of `StableTrieBase`.
  public type Args = BaseArgs and {
    leaf_size : Nat;
  };

  /// Memory stats.
  public type MemoryStats = {
    /// Size of used stable memory in bytes.
    byte_size : Nat;
    /// Number of allocated leaves (high water — never shrinks).
    leaf_count : Nat;
    /// Number of internal trie nodes currently in use (`total_node_count`
    /// minus nodes returned to the empty-nodes free list).
    node_count : Nat;
    /// Number of internal trie nodes ever allocated (high water — never
    /// shrinks even when nodes are pushed onto the empty-nodes list).
    total_node_count : Nat;
  };

  /// Result of inspecting a non-root internal node's child slots after a
  /// deletion has just cleared one of them. The variant has no `#none` case
  /// because that state must never arise under our deletion invariants —
  /// `scanChildren` traps if it would have produced it.
  public type ChildScan = {
    /// Exactly one non-zero slot, holding a leaf pointer. Payload is
    /// (leaf_pointer, slot_index). Indicates that the node should collapse:
    /// the caller clears `slot_index` and bubbles the leaf up to the parent.
    #onlyLeaf : (Nat64, Nat64);
    /// Exactly one non-zero slot, holding an internal-node pointer. This is
    /// the chain-link state `put_` produces — the caller keeps the node.
    #onlyInternal : Nat64;
    /// Two or more non-zero slots. The caller keeps the node as-is.
    #multiple;
  };

  /// Stable data of `StableTrieBase`. Includes the head of the linked list of
  /// empty internal nodes so it can be restored across upgrades.
  ///
  /// `empty_nodes` is optional for backward compatibility with v0.0.8 and
  /// earlier: pre-0.0.9 `Enumeration` had no such field, and pre-0.0.9 `Map`
  /// had it as a required field directly on `Map.StableData` (rather than
  /// here on `Base.StableData`). Both old shapes widen into `?(Nat, Nat64)`
  /// under Motoko's stable-type compatibility rules. `share()` always emits
  /// the value as `?Some`; `null` only ever appears when loading legacy data.
  public type StableData = {
    nodes : Region;
    leaves : Region;
    node_count : Nat64;
    leaf_count : Nat64;
    empty_nodes : ?(Nat, Nat64);
  };

  /// Base class for stable trie map and enumeration. SHOULD NOT BE USED FROM THE USER'S CODE.
  public class StableTrieBase(args : Args) {
    assert switch (args.pointer_size) {
      case (2 or 4 or 5 or 6 or 8) true;
      case (_) false;
    };
    assert switch (args.aridity) {
      case (2 or 4 or 16 or 256) true;
      case (_) false;
    };
    // Max leaf size is 2 ** 16, one page of stable memory.
    assert args.key_size >= 1 and args.key_size + args.value_size <= 2 ** 16;

    let aridity_ = args.aridity.toNat64();
    let key_size_ = args.key_size.toNat64();
    let pointer_size_ = args.pointer_size.toNat64();
    let root_aridity_ = Option.get(args.root_aridity, args.aridity).toNat64();
    /// Mask of `pointer_size * 8` bits.
    public let loadMask = if (args.pointer_size == 8) 0xffff_ffff_ffff_ffff : Nat64 else (1 << (pointer_size_ << 3)) - 1;

    /// Bitlength of aridity - 1
    public let bitlength = Nat16.bitcountTrailingZero(args.aridity.toNat16()); // TODO: use dot notation when available
    let bitshift = (8 - bitlength).toNat8();
    let bitlength_ = bitlength.toNat64();

    let max_address = 2 ** (pointer_size_ * 8 - 1);

    assert Nat64.bitcountNonZero(root_aridity_) == 1; // 2-power
    let root_bitlength_ = Nat64.bitcountTrailingZero(root_aridity_); // TODO: use dot notation when available
    assert root_bitlength_ > 0 and root_bitlength_ % bitlength_ == 0; // => root_bitlength_ >= bitlength_
    assert root_bitlength_ <= key_size_ * 8;

    /// Bitlength of root_aridity - 1
    public let root_bitlength = root_bitlength_.toNat16();

    let node_size : Nat64 = aridity_ * pointer_size_;
    /// Node size in bytes, equals aridity * pointer_size.
    public let node_size_ : Nat = nat64toNat(node_size);
    let leaf_size : Nat64 = args.leaf_size.toNat64();
    let root_size : Nat64 = root_aridity_ * pointer_size_;
    let offset_base : Nat64 = root_size - node_size;
    let padding : Nat64 = 8 - pointer_size_;
    let empty_values : Bool = args.value_size == 0;

    /// Current number of leaves.
    public var leaf_count : Nat64 = 0;
    var node_count : Nat64 = 0;

    /// Store pointer to a region
    public let storePointer : (region : Region.Region, offset : Nat64, child : Nat64) -> () = switch (pointer_size_) {
      case (8) func(region, offset, child) = region.storeNat64(offset, child);
      case (6) func(region, offset, child) {
        region.storeNat32(offset, nat64to32(child & 0xffff_ffff));
        region.storeNat16(offset +% 4, nat32to16(nat64to32(child >> 32)));
      };
      case (5) func(region, offset, child) {
        region.storeNat32(offset, nat64to32(child & 0xffff_ffff));
        region.storeNat8(offset +% 4, natWrap8(nat64toNat(child >> 32)));
      };
      case (4) func(region, offset, child) = region.storeNat32(offset, nat64to32(child));
      case (2) func(region, offset, child) = region.storeNat16(offset, nat32to16(nat64to32(child)));
      case (_) Runtime.trap("Can never happen");
    };

    /// Pair of nodes and leaves regions.
    public type State = {
      nodes : Region;
      leaves : Region;
    };

    var regions_ : ?State = null;

    /// Get or create and initialize regions.
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
          assert nodes.region.grow(pages) != 0xffff_ffff_ffff_ffff;
          nodes.freeSpace := pages * 65536 - root_size - padding;
          node_count := 1;

          let leaves : Region = {
            region = Region.new();
            var freeSpace = 0;
          };

          let ret = { nodes = nodes; leaves = leaves };
          regions_ := ?ret;

          ret;
        };
      };
    };

    /// Pop empty leaf from empty leaf stack. Used to implement deletion in map.
    var popLeaf : (Region.Region) -> ?Nat64 = func(_) = null;

    /// Unwrap a pointer-size result or trap on overflow.
    public func unwrap<T>(r : Result.Result<T, { #LimitExceeded }>) : T {
      let #ok x = r else Runtime.trap("Pointer size overflow");
      x;
    };

    /// Set the `popLeaf` callback. Map calls this with `empty_leaves.pop`;
    /// Enumeration leaves it at the default (always-null), since it reclaims
    /// leaf slots implicitly by decrementing `leaf_count`.
    public func setLeafPopCallback(leaf : (Region.Region) -> ?Nat64) {
      popLeaf := leaf;
    };

    /// Allocate one page if required.  `allocate` can only be used for n <= 65536
    func allocate(region : Region, n : Nat64) {
      if (region.freeSpace < n) {
        assert region.region.grow(1) != 0xffff_ffff_ffff_ffff;
        region.freeSpace +%= 65536;
      };
      region.freeSpace -%= n;
    };

    /// Create internal node.
    func newInternalNode(region : Region) : ?Nat64 {
      let node = switch (empty_nodes_list.pop(region.region)) {
        case (?node) node;
        case (null) {
          if (node_count != max_address) {
            allocate(region, node_size);
            let nc = node_count;
            node_count +%= 1;
            nc << 1;
          } else return null;
        };
      };

      ?node;
    };

    func newLeaf(region : Region, key : Blob) : ?Nat64 {
      let leaf = switch (popLeaf(region.region)) {
        case (?leaf) leaf;
        case (null) {
          if (leaf_count != max_address) {
            allocate(region, leaf_size);
            let lc = leaf_count;
            leaf_count +%= 1;
            lc;
          } else return null;
        };
      };

      region.region.storeBlob(getLeafOffset(leaf), key);
      ?((leaf << 1) | 1);
    };

    /// Get address of pointer of node's `node` child number `index`.
    public func getNodeOffset(node : Nat64, index : Nat64) : Nat64 {
      let delta = index *% pointer_size_;
      if (node == 0) return delta; // root node
      (offset_base +% (node >> 1) *% node_size) +% delta;
    };

    /// Load pointer from a region.
    public func loadPointer(region : Region.Region, offset : Nat64) : Nat64 {
      // region.loadNat64(offset) & loadMask;
      // workaround for https://github.com/caffeinelabs/motoko/issues/5767
      Prim.regionLoadNat64(region, offset) & loadMask;
    };

    /// Load node's `node` child number `index`.
    public func getChild(region : Region.Region, node : Nat64, index : Nat64) : Nat64 {
      // inline loadPointer(region, getNodeOffset(node, index))
      Prim.regionLoadNat64(region, getNodeOffset(node, index)) & loadMask;
    };

    /// Set node's `node` child number `index`.
    public func setChild(region : Region.Region, node : Nat64, index : Nat64, child : Nat64) {
      let offset = getNodeOffset(node, index);
      storePointer(region, offset, child);
    };

    /// Inspect the children of an internal `node` and classify which case
    /// applies (see `ChildScan`). Reads the node as a single blob and parses
    /// each pointer in-memory, which is meaningfully cheaper than `aridity`
    /// separate region loads when aridity is large (e.g. 256).
    ///
    /// `assert`s that the node has at least one non-zero child. The
    /// "zero children" case is unreachable under the deletion invariants
    /// maintained by Map and Enumeration: every internal node is born with
    /// two children, and the collapse step ensures no node ever has exactly
    /// one *leaf* child sitting around for the next delete to clear. So when
    /// we run `scanChildren` after clearing one slot, the worst case is a
    /// node that drops to a single (internal-chain-link or leaf) child, never
    /// to zero. A trap here means an upstream invariant has been broken.
    public func scanChildren(region : Region.Region, node : Nat64) : ChildScan {
      let blob = region.loadBlob(getNodeOffset(node, 0), node_size_);
      var lone : Nat64 = 0;
      var lone_slot : Nat64 = 0;
      var i = 0;
      while (i < args.aridity) {
        var x : Nat64 = 0;
        var j = (i + 1) * args.pointer_size;
        while (j > i * args.pointer_size) {
          j -= 1;
          x := x * 256 + nat32to64(nat16to32(nat8to16(blob[j])));
        };
        if (x > 0) {
          if (lone != 0) return #multiple;
          lone := x;
          lone_slot := i.toNat64();
        };
        i += 1;
      };
      assert lone != 0; // invariant: deletion never leaves a node with 0 children
      if (lone & 1 == 1) #onlyLeaf(lone, lone_slot) else #onlyInternal(lone);
    };

    /// Linked list of freed internal-node slots in the nodes region. Populated
    /// by `removeLast` (here) and `pushEmptyNode` (called by Map.removeRec);
    /// consumed by `newInternalNode` before falling back to growing the region.
    //
    // Placed *after* `getNodeOffset` and `loadPointer` are defined so the
    // closures below don't trigger Motoko's definedness check (M0016).
    let empty_nodes_list : LinkedList = LinkedList(
      loadMask,
      func(region : Region.Region, offset : Nat64) : Nat64 = loadPointer(region, offset),
      storePointer,
      func(node : Nat64) : Nat64 = getNodeOffset(node, 0),
    );

    /// Push a freed internal node onto the empty-nodes list so the next
    /// `put_` reuses its slot. The caller is responsible for clearing all
    /// child pointers of `node` before pushing (otherwise stale pointers
    /// would alias live leaves through phantom trie paths).
    public func pushEmptyNode(region : Region.Region, node : Nat64) {
      empty_nodes_list.push(region, node);
    };

    /// Number of internal nodes currently held in the empty-nodes list.
    public func emptyNodesCount() : Nat = empty_nodes_list.count;

    /// Get offset of leaf number `index`.
    public func getLeafOffset(index : Nat64) : Nat64 = index *% leaf_size;

    /// Load key of leaf number `index`.
    public func getKey(region : Region.Region, index : Nat64) : Blob {
      region.loadBlob(getLeafOffset(index), args.key_size);
    };

    /// Load value of leaf number `index`.
    public func getValue(region : Region.Region, index : Nat64) : Blob {
      if (empty_values) return "";
      region.loadBlob(getLeafOffset(index) +% key_size_, args.value_size);
    };

    /// Set value of leaf number `index`.
    public func setValue(region : Region.Region, index : Nat64, value : Blob) {
      assert value.size() == args.value_size;
      if (empty_values) return;
      region.storeBlob(getLeafOffset(index) +% key_size_, value);
    };

    /// Get index in root node.
    public func keyToRootIndex(key : Blob) : Nat64 {
      var result : Nat64 = 0;
      var i = 0;
      let iters = nat64toNat(root_bitlength_ >> 3);
      while (i < iters) {
        result := (result << 8) | nat32to64(nat16to32(nat8to16(key[i])));
        i += 1;
      };
      let skip = root_bitlength_ & 7;
      if (skip != 0) {
        result := (result << skip) | (nat32to64(nat16to32(nat8to16(key[i]))) >> (8 -% skip));
      };
      return result;
    };

    /// Get index in internal, not root node.
    public func keyToIndex(key : Blob, pos : Nat16) : Nat64 {
      return nat32to64(nat16to32(nat8to16((key[nat16toNat(pos >> 3)] << nat16to8(pos & 7)) >> bitshift)));
    };

    func find(nodes : Region.Region, key : Blob) : (Nat64, Nat64, Nat64, Nat16) {
      var idx = keyToRootIndex(key);
      var pos = root_bitlength;
      var node : Nat64 = 0;
      loop {
        let child = getChild(nodes, node, idx);
        if (child == 0 or child & 1 == 1) {
          return (node, idx, child, pos);
        };
        node := child;
        idx := keyToIndex(key, pos);
        pos +%= bitlength;
      };
      Runtime.trap("Unreacheable");
    };

    /// Put only `key` into trie. Returns pair (wheter new leaf created, index of leaf) or null in case of pointer size overflow.
    public func put_(nodes : Region, leaves : Region, nodes_region : Region.Region, leaves_region : Region.Region, key : Blob) : ?(Bool, Nat64) {
      assert key.size() == args.key_size;

      let (node_, last_, old_leaf, pos_) = find(nodes_region, key);

      var last = last_;
      var node = node_;

      if (old_leaf == 0) {
        let ?leaf = newLeaf(leaves, key) else return null;

        setChild(nodes_region, node, last, leaf);
        return ?(true, (leaf >> 1));
      };

      let index = old_leaf >> 1;
      let old_key = getKey(leaves_region, index);
      if (key == old_key) {
        return ?(false, index);
      };

      var pos = pos_;
      label l loop {
        let ?add = newInternalNode(nodes) else {
          setChild(nodes_region, node, last, old_leaf);
          return null;
        };
        setChild(nodes_region, node, last, add);
        node := add;

        let (a, b) = (keyToIndex(key, pos), keyToIndex(old_key, pos));
        pos +%= bitlength;
        if (a == b) {
          last := a;
        } else {
          setChild(nodes_region, node, b, old_leaf);
          let ?leaf = newLeaf(leaves, key) else return null;
          setChild(nodes_region, node, a, leaf);
          return ?(true, (leaf >> 1));
        };
      };
      Runtime.trap("Unreacheable");
    };

    /// Recursive walk for `removeLast`. Descends `node` along the path of
    /// `key` to clear the target leaf, then on the way back up classifies
    /// each visited internal node via `scanChildren` and either keeps it or
    /// collapses it (single leaf child).
    ///
    /// Returns the new pointer value to be stored in the caller's slot for
    /// `node`: either `node` itself (keep) or a bubbled-up leaf pointer
    /// (collapse). When collapsing, the orphaned node has all child slots
    /// cleared and is pushed onto `empty_nodes_list` so the next pop hands
    /// back a clean node.
    func removeLastRec(
      nodes_region : Region.Region,
      key : Blob,
      node : Nat64,
      pos : Nat16,
    ) : Nat64 {
      let idx = keyToIndex(key, pos);
      let child = getChild(nodes_region, node, idx);
      let new_child = if (child & 1 == 1) {
        // Target leaf reached.
        0 : Nat64;
      } else {
        removeLastRec(nodes_region, key, child, pos +% bitlength);
      };

      // If the slot didn't change, nothing else in `node` did either.
      if (new_child == child) return node;

      setChild(nodes_region, node, idx, new_child);
      switch (scanChildren(nodes_region, node)) {
        case (#onlyLeaf(leaf, slot)) {
          // Collapse: clear the surviving slot (so the pushed node is
          // all-zero) and bubble the leaf up to the parent.
          setChild(nodes_region, node, slot, 0);
          empty_nodes_list.push(nodes_region, node);
          leaf;
        };
        case (#onlyInternal _) node; // chain-link state — keep `node`
        case (#multiple) node;        // ≥2 children — keep `node`
      };
    };

    /// Remove the most-recently-added leaf (the leaf at index `leaf_count - 1`).
    /// Returns the removed `(key, value)` or `null` if the trie is empty.
    ///
    /// The freed leaf slot at the end of the leaves region is made available
    /// for reuse by the next `put_` (we just decrement `leaf_count` and bump
    /// the leaves region's `freeSpace`).
    ///
    /// Internal nodes that become empty or that hold only a single leaf
    /// (which is then bubbled up) are pushed to the internal empty-nodes
    /// list, where the next `newInternalNode` reclaims them.
    public func removeLast() : ?(Blob, Blob) {
      if (leaf_count == 0) return null;
      let { leaves; nodes } = regions();
      let leaves_region = leaves.region;
      let nodes_region = nodes.region;

      let last_index = leaf_count -% 1;
      let key = getKey(leaves_region, last_index);
      let value = getValue(leaves_region, last_index);

      // The root node has its own (root_)aridity and bitlength, so handle it
      // separately. Below the root, recursion uses the regular bitlength.
      // The root itself is never pushed; we only update its child pointer.
      let root_idx = keyToRootIndex(key);
      let root_child = getChild(nodes_region, 0, root_idx);
      let new_root_child = if (root_child & 1 == 1) {
        0 : Nat64;
      } else {
        removeLastRec(nodes_region, key, root_child, root_bitlength);
      };
      if (new_root_child != root_child) {
        setChild(nodes_region, 0, root_idx, new_root_child);
      };

      leaf_count -%= 1;
      leaves.freeSpace +%= leaf_size;

      ?(key, value);
    };

    /// Lookup `key` in trie. Returns `value` and index of that leaf or null if not found.
    public func lookup(key : Blob) : ?(Blob, Nat) {
      assert key.size() == args.key_size;
      let { leaves; nodes } = regions();

      let (_, _, old_leaf, _) = find(nodes.region, key);
      if (old_leaf == 0) return null;
      let index = old_leaf >> 1;

      let leaves_region = leaves.region;
      return if (getKey(leaves_region, index) == key) {
        ?(getValue(leaves_region, index), nat64toNat(index));
      } else {
        null;
      };
    };

    type Dir = { #forward; #reverse };

    class Iterator(nodes : Region.Region, dir : Dir) {
      let forward = dir == #forward;
      let stack = VarArray.repeat<(Nat64, Nat64)>((0, 0), args.key_size * 8 / nat16toNat(bitlength));
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

    func entries_base<T>(dir : Dir, f : (Nat64, Region.Region) -> T) : Types.Iter<T> {
      let state = regions();
      let { nodes; leaves } = state;
      let leaves_region = leaves.region;
      let nodes_region = nodes.region;
      Iter.map<Nat64, T>(Iterator(nodes_region, dir), func(leaf) = f(leaf, leaves_region));
    };

    func entries_(dir : Dir) : Types.Iter<(Blob, Blob)> = entries_base<(Blob, Blob)>(
      dir,
      func(leaf, leaves) = (getKey(leaves, leaf), getValue(leaves, leaf)),
    );

    func vals_(dir : Dir) : Types.Iter<Blob> = entries_base<Blob>(
      dir,
      func(leaf, leaves) = getValue(leaves, leaf),
    );

    func keys_(dir : Dir) : Types.Iter<Blob> = entries_base<Blob>(
      dir,
      func(leaf, leaves) = getKey(leaves, leaf),
    );

    /// Iterate entries in forward order.
    public func entries() : Types.Iter<(Blob, Blob)> = entries_(#forward);

    /// Iterate entries in reverse order.
    public func entriesRev() : Types.Iter<(Blob, Blob)> = entries_(#reverse);

    /// Iterate values in forward order.
    public func vals() : Types.Iter<Blob> = vals_(#forward);

    /// Iterate values in reverse order.
    public func valsRev() : Types.Iter<Blob> = vals_(#reverse);

    /// Iterate keys in forward order.
    public func keys() : Types.Iter<Blob> = keys_(#forward);

    /// Iterate keys in reverse order.
    public func keysRev() : Types.Iter<Blob> = keys_(#reverse);

    /// Return current memory stats. `node_count` reports nodes currently in
    /// use (`total_node_count - empty_nodes_list.count`); `byte_size` is
    /// computed from the high water and so never shrinks.
    public func memoryStats() : MemoryStats {
      let total_n = nat64toNat(node_count);
      {
        byte_size = if (node_count == 0) {
          0 // no regions allocated yet
        } else {
          nat64toNat(root_size + (node_count - 1) * node_size + leaf_count * leaf_size);
        };
        leaf_count = nat64toNat(leaf_count);
        node_count = total_n - empty_nodes_list.count;
        total_node_count = total_n;
      };
    };

    /// Convert to stable data.
    public func share() : StableData = {
      regions() with
      node_count;
      leaf_count;
      empty_nodes = ?empty_nodes_list.share();
    };

    /// Create from stable data. Must be the first call after constructor.
    /// `data.empty_nodes` is optional to allow loading legacy data that
    /// predates this field; missing or `null` is treated as an empty list.
    public func unshare(data : StableData) {
      switch (regions_) {
        case (null) {
          regions_ := ?data;
          node_count := data.node_count;
          leaf_count := data.leaf_count;
          empty_nodes_list.unshare(
            switch (data.empty_nodes) {
              case (?en) en;
              case (null) (0, loadMask); // legacy: empty list
            }
          );
        };
        case (_) Runtime.trap("Region is already initialized");
      };
    };
  };
};
