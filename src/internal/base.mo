/// Base for stable trie.
///
/// Copyright: 2023 - 2025 MR Research AG
///
/// Main author: Andrii Stepanov (AStepanov25)
///
/// Contributors: Timo Hanke (timohanke)
///
/// Implemented as a plain mutable record (`StableTrieBase`) plus module-level
/// functions whose first argument is `self`. Callers can use dot-notation
/// (`base.put_(...)`, `base.lookup(...)`, etc.) which Motoko resolves to the
/// corresponding module-level function.

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

import LinkedList "./linked-list";

module {
  /// Unwrap a pointer-size result or trap on overflow.
  public func unwrap<T>(r : Result.Result<T, { #LimitExceeded }>) : T {
    let #ok x = r else Runtime.trap("Pointer size overflow");
    x;
  };

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

  /// Arguments of constructor of `Enumeration` and `Map`.
  /// pointer_size: size of pointer in bytes (2, 4, 5, 6, 8)
  /// aridity: number of children per internal node (2, 4, 16, 256)
  /// root_aridity: number of children for root node (must be power), null means same as aridity
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
    #onlyLeaf : (Nat64, Nat64);
    #onlyInternal : Nat64;
    #multiple;
  };

  /// Stable data of `StableTrieBase`.
  public type StableData = {
    nodes : Region;
    leaves : Region;
    node_count : Nat64;
    leaf_count : Nat64;
    empty_nodes : ?(Nat, Nat64);
  };

  /// Pair of nodes and leaves regions.
  public type State = {
    nodes : Region;
    leaves : Region;
  };

  type Dir = { #forward; #reverse };

  /// Per-pointer-size store dispatch table, indexed by `storeFuncIndex`
  /// (see `empty`).
  let storePointerFuncs = [
    Region.storeNat64,
    func storePointer(region : Region.Region, offset : Nat64, child : Nat64) {
      region.storeNat32(offset, nat64to32(child & 0xffff_ffff));
      region.storeNat16(offset +% 4, nat32to16(nat64to32(child >> 32)));
    },
    func storePointer(region : Region.Region, offset : Nat64, child : Nat64) {
      region.storeNat32(offset, nat64to32(child & 0xffff_ffff));
      region.storeNat8(offset +% 4, natWrap8(nat64toNat(child >> 32)));
    },
    func storePointer(region : Region.Region, offset : Nat64, child : Nat64) {
      region.storeNat32(offset, nat64to32(child));
    },
    func storePointer(region : Region.Region, offset : Nat64, child : Nat64) {
      region.storeNat16(offset, nat32to16(nat64to32(child)));
    },
  ];

  /// Allocate one page if required.  `allocate` can only be used for n <= 65536
  func allocate(region : Region, n : Nat64) {
    if (region.freeSpace < n) {
      assert region.region.grow(1) != 0xffff_ffff_ffff_ffff;
      region.freeSpace +%= 65536;
    };
    region.freeSpace -%= n;
  };

  /// Base record for stable trie map and enumeration.
  /// SHOULD NOT BE USED FROM THE USER'S CODE.
  ///
  /// Holds:
  /// - the three `Nat`-typed user inputs actually read at runtime
  ///   (`pointer_size`, `key_size`, `value_size`) and a host of `Nat64`/`Nat`
  ///   values precomputed from `args` so per-call hot paths don't recompute
  ///   conversions and masks;
  /// - `empty_nodes_list`, the internal free list of freed internal nodes;
  /// - the mutable state vars (counts, regions handle, leaf-pop callback).
  public type StableTrieBase = {
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
    storeFuncIndex : Nat;
    empty_nodes_list : LinkedList.LinkedList;
    var leaf_count : Nat64;
    var node_count : Nat64;
    var regions_ : ?State;
    var popLeaf : (Region.Region) -> ?Nat64;
  };

  /// Construct an empty stable trie base.
  public func empty(args : Args) : StableTrieBase {
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

    // Lets kept here are referenced more than once (in asserts below and/or
    // by several record-literal expressions, where fields can't refer to each
    // other). One-shot values are inlined into the record literal directly.
    let aridity_ = args.aridity.toNat64();
    let key_size_ = args.key_size.toNat64();
    let pointer_size_ = args.pointer_size.toNat64();
    let root_aridity_ = args.root_aridity.get(args.aridity).toNat64();
    let bitlength = Nat16.bitcountTrailingZero(args.aridity.toNat16());

    assert Nat64.bitcountNonZero(root_aridity_) == 1; // 2-power
    let root_bitlength_ = Nat64.bitcountTrailingZero(root_aridity_);
    assert root_bitlength_ > 0 and root_bitlength_ % bitlength.toNat64() == 0;
    assert root_bitlength_ <= key_size_ * 8;

    let node_size : Nat64 = aridity_ * pointer_size_;
    let root_size : Nat64 = root_aridity_ * pointer_size_;
    let offset_base : Nat64 = root_size - node_size;

    {
      pointer_size = args.pointer_size;
      key_size = args.key_size;
      value_size = args.value_size;
      aridity_;
      key_size_;
      pointer_size_;
      root_aridity_;
      loadMask = if (args.pointer_size == 8) 0xffff_ffff_ffff_ffff : Nat64 else (1 << (pointer_size_ << 3)) - 1;
      bitlength;
      bitshift = (8 - bitlength).toNat8();
      max_address = 2 ** (pointer_size_ * 8 - 1);
      root_bitlength_;
      root_bitlength = root_bitlength_.toNat16();
      node_size;
      node_size_ = nat64toNat(node_size);
      leaf_size = args.leaf_size.toNat64();
      root_size;
      offset_base;
      padding = 8 - pointer_size_;
      empty_values = args.value_size == 0;
      storeFuncIndex = switch (args.pointer_size) {
        case (8) 0;
        case (6) 1;
        case (5) 2;
        case (4) 3;
        case (2) 4;
        case (_) Runtime.trap("invalid pointer_size");
      };
      empty_nodes_list = LinkedList.empty(offset_base, node_size, pointer_size_);
      var leaf_count = 0 : Nat64;
      var node_count = 0 : Nat64;
      var regions_ : ?State = null;
      var popLeaf = func(_ : Region.Region) : ?Nat64 = null;
    };
  };

  /// Get or create and initialize regions.
  public func regions(self : StableTrieBase) : State {
    switch (self.regions_) {
      case (?r) r;
      case (null) {
        let nodes_region = Region.new();
        let nodes : Region = {
          region = nodes_region;
          var freeSpace = 0;
        };
        let pages = (self.root_size + self.padding + 65536 - 1) / 65536;
        assert nodes.region.grow(pages) != 0xffff_ffff_ffff_ffff;
        nodes.freeSpace := pages * 65536 - self.root_size - self.padding;
        self.node_count := 1;

        let leaves : Region = {
          region = Region.new();
          var freeSpace = 0;
        };

        let ret = { nodes; leaves };
        self.regions_ := ?ret;

        ret;
      };
    };
  };

  /// Set the `popLeaf` callback. Map calls this with `empty_leaves.pop`;
  /// Enumeration leaves it at the default (always-null), since it reclaims
  /// leaf slots implicitly by decrementing `leaf_count`.
  public func setLeafPopCallback(self : StableTrieBase, leaf : (Region.Region) -> ?Nat64) {
    self.popLeaf := leaf;
  };


  /// Create internal node.
  func newInternalNode(self : StableTrieBase, region : Region) : ?Nat64 {
    let node = switch (self.empty_nodes_list.pop(region.region)) {
      case (?index) index << 1; // re-encode reused node index → pointer
      case (null) {
        if (self.node_count != self.max_address) {
          allocate(region, self.node_size);
          let nc = self.node_count;
          self.node_count +%= 1;
          nc << 1;
        } else return null;
      };
    };
    ?node;
  };

  func newLeaf(self : StableTrieBase, region : Region, key : Blob) : ?Nat64 {
    let leaf = switch (self.popLeaf(region.region)) {
      case (?leaf) leaf;
      case (null) {
        if (self.leaf_count != self.max_address) {
          allocate(region, self.leaf_size);
          let lc = self.leaf_count;
          self.leaf_count +%= 1;
          lc;
        } else return null;
      };
    };

    region.region.storeBlob(getLeafOffset(self, leaf), key);
    ?((leaf << 1) | 1);
  };

  // Get base address of node (the offset of its first child pointer).
  func getNodeBase(self : StableTrieBase, node : Nat64) : Nat64 {
    if (node == 0) return 0; // root node
    (self.offset_base +% (node >> 1) *% self.node_size);
  };

  /// Get address of pointer of node's `node` child number `index`.
  func getNodeOffset(self : StableTrieBase, node : Nat64, index : Nat64) : Nat64 {
    let delta = index *% self.pointer_size_;
    if (node == 0) return delta; // root node
    (self.offset_base +% (node >> 1) *% self.node_size) +% delta;
  };

  /// Load node's `node` child number `index`.
  public func getChild(self : StableTrieBase, region : Region.Region, node : Nat64, index : Nat64) : Nat64 {
    Prim.regionLoadNat64(region, getNodeOffset(self, node, index)) & self.loadMask;
  };

  /// Set node's `node` child number `index`.
  public func setChild(self : StableTrieBase, region : Region.Region, node : Nat64, index : Nat64, child : Nat64) {
    let offset = getNodeOffset(self, node, index);
    storePointerFuncs[self.storeFuncIndex](region, offset, child);
  };

  /// Inspect the children of an internal `node` and classify which case
  /// applies (see `ChildScan`). Reads the node as a single blob and parses
  /// each pointer in-memory, which is meaningfully cheaper than `aridity`
  /// separate region loads when aridity is large (e.g. 256).
  ///
  /// `assert`s that the node has at least one non-zero child. The
  /// "zero children" case is unreachable under the deletion invariants
  /// maintained by Map and Enumeration.
  public func scanChildren(self : StableTrieBase, region : Region.Region, node : Nat64) : ChildScan {
    let blob = region.loadBlob(getNodeBase(self, node), self.node_size_);
    let ps = self.pointer_size;
    var lone : Nat64 = 0;
    var lone_slot : Nat64 = 0;
    var i : Nat64 = 0;
    var slot_start = 0;
    while (i < self.aridity_) {
      var x : Nat64 = 0;
      let slot_end = slot_start + ps;
      var j = slot_end;
      while (j > slot_start) {
        j -= 1;
        x := x * 256 + nat32to64(nat16to32(nat8to16(blob[j])));
      };
      if (x > 0) {
        if (lone != 0) return #multiple;
        lone := x;
        lone_slot := i;
      };
      i +%= 1;
      slot_start := slot_end;
    };
    assert lone != 0; // invariant: deletion never leaves a node with 0 children
    if (lone & 1 == 1) #onlyLeaf(lone, lone_slot) else #onlyInternal(lone);
  };

  /// Push a freed internal node onto the empty-nodes list so the next
  /// `put_` reuses its slot. `node` is the encoded pointer; the list stores
  /// the bare index. The caller is responsible for clearing all child
  /// pointers of `node` before pushing.
  public func pushEmptyNode(self : StableTrieBase, region : Region.Region, node : Nat64) {
    self.empty_nodes_list.push(region, node >> 1);
  };

  /// Get offset of leaf number `index`.
  func getLeafOffset(self : StableTrieBase, index : Nat64) : Nat64 = index *% self.leaf_size;

  /// Load key of leaf number `index`.
  public func getKey(self : StableTrieBase, region : Region.Region, index : Nat64) : Blob {
    region.loadBlob(getLeafOffset(self, index), self.key_size);
  };

  /// Load value of leaf number `index`.
  public func getValue(self : StableTrieBase, region : Region.Region, index : Nat64) : Blob {
    if (self.empty_values) return "";
    region.loadBlob(getLeafOffset(self, index) +% self.key_size_, self.value_size);
  };

  /// Set value of leaf number `index`.
  public func setValue(self : StableTrieBase, region : Region.Region, index : Nat64, value : Blob) {
    assert value.size() == self.value_size;
    if (self.empty_values) return;
    region.storeBlob(getLeafOffset(self, index) +% self.key_size_, value);
  };

  /// Get index in root node.
  public func keyToRootIndex(self : StableTrieBase, key : Blob) : Nat64 {
    var result : Nat64 = 0;
    var i = 0;
    let iters = nat64toNat(self.root_bitlength_ >> 3);
    while (i < iters) {
      result := (result << 8) | nat32to64(nat16to32(nat8to16(key[i])));
      i += 1;
    };
    let skip = self.root_bitlength_ & 7;
    if (skip != 0) {
      result := (result << skip) | (nat32to64(nat16to32(nat8to16(key[i]))) >> (8 -% skip));
    };
    return result;
  };

  /// Get index in internal, not root node.
  public func keyToIndex(self : StableTrieBase, key : Blob, pos : Nat16) : Nat64 {
    return nat32to64(nat16to32(nat8to16((key[nat16toNat(pos >> 3)] << nat16to8(pos & 7)) >> self.bitshift)));
  };

  func find(self : StableTrieBase, nodes : Region.Region, key : Blob) : (Nat64, Nat64, Nat64, Nat16) {
    var idx = keyToRootIndex(self, key);
    var pos = self.root_bitlength;
    var node : Nat64 = 0;
    loop {
      let child = getChild(self, nodes, node, idx);
      if (child == 0 or child & 1 == 1) {
        return (node, idx, child, pos);
      };
      node := child;
      idx := keyToIndex(self, key, pos);
      pos +%= self.bitlength;
    };
    Runtime.trap("Unreacheable");
  };

  /// Put only `key` into trie. Returns pair (whether new leaf created, index of leaf) or null in case of pointer size overflow.
  public func put_(
    self : StableTrieBase,
    nodes : Region,
    leaves : Region,
    nodes_region : Region.Region,
    leaves_region : Region.Region,
    key : Blob,
  ) : ?(Bool, Nat64) {
    assert key.size() == self.key_size;

    let (node_, last_, old_leaf, pos_) = find(self, nodes_region, key);

    var last = last_;
    var node = node_;

    if (old_leaf == 0) {
      let ?leaf = newLeaf(self, leaves, key) else return null;

      setChild(self, nodes_region, node, last, leaf);
      return ?(true, (leaf >> 1));
    };

    let index = old_leaf >> 1;
    let old_key = getKey(self, leaves_region, index);
    if (key == old_key) {
      return ?(false, index);
    };

    var pos = pos_;
    label l loop {
      let ?add = self.newInternalNode(nodes) else {
        setChild(self, nodes_region, node, last, old_leaf);
        return null;
      };
      setChild(self, nodes_region, node, last, add);
      node := add;

      let (a, b) = (keyToIndex(self, key, pos), keyToIndex(self, old_key, pos));
      pos +%= self.bitlength;
      if (a == b) {
        last := a;
      } else {
        setChild(self, nodes_region, node, b, old_leaf);
        let ?leaf = newLeaf(self, leaves, key) else return null;
        setChild(self, nodes_region, node, a, leaf);
        return ?(true, (leaf >> 1));
      };
    };
    Runtime.trap("Unreacheable");
  };

  /// Recursive walk for `removeLast`.
  func removeLastRec(
    self : StableTrieBase,
    nodes_region : Region.Region,
    key : Blob,
    node : Nat64,
    pos : Nat16,
  ) : Nat64 {
    let idx = keyToIndex(self, key, pos);
    let child = getChild(self, nodes_region, node, idx);
    let new_child = if (child & 1 == 1) {
      0 : Nat64;
    } else {
      removeLastRec(self, nodes_region, key, child, pos +% self.bitlength);
    };

    if (new_child == child) return node;

    setChild(self, nodes_region, node, idx, new_child);
    switch (scanChildren(self, nodes_region, node)) {
      case (#onlyLeaf(leaf, slot)) {
        setChild(self, nodes_region, node, slot, 0);
        self.empty_nodes_list.push(nodes_region, node >> 1);
        leaf;
      };
      case (#onlyInternal _) node;
      case (#multiple) node;
    };
  };

  /// Remove the most-recently-added leaf (at index `leaf_count - 1`).
  public func removeLast(self : StableTrieBase) : ?(Blob, Blob) {
    if (self.leaf_count == 0) return null;
    let { leaves; nodes } = regions(self);
    let leaves_region = leaves.region;
    let nodes_region = nodes.region;

    let last_index = self.leaf_count -% 1;
    let key = getKey(self, leaves_region, last_index);
    let value = getValue(self, leaves_region, last_index);

    let root_idx = keyToRootIndex(self, key);
    let root_child = getChild(self, nodes_region, 0, root_idx);
    let new_root_child = if (root_child & 1 == 1) {
      0 : Nat64;
    } else {
      removeLastRec(self, nodes_region, key, root_child, self.root_bitlength);
    };
    if (new_root_child != root_child) {
      setChild(self, nodes_region, 0, root_idx, new_root_child);
    };

    self.leaf_count -%= 1;
    leaves.freeSpace +%= self.leaf_size;

    ?(key, value);
  };

  /// Lookup `key` in trie. Returns `value` and index of that leaf or null if not found.
  public func lookup(self : StableTrieBase, key : Blob) : ?(Blob, Nat) {
    assert key.size() == self.key_size;
    let { leaves; nodes } = regions(self);

    let (_, _, old_leaf, _) = find(self, nodes.region, key);
    if (old_leaf == 0) return null;
    let index = old_leaf >> 1;

    let leaves_region = leaves.region;
    return if (getKey(self, leaves_region, index) == key) {
      ?(getValue(self, leaves_region, index), nat64toNat(index));
    } else {
      null;
    };
  };

  /// Closure-based iterator factory returning an `Iter<Nat64>` directly.
  /// The returned iterator owns the traversal stack via closure capture.
  func makeIter(self : StableTrieBase, nodes : Region.Region, dir : Dir) : Types.Iter<Nat64> {
    let forward = dir == #forward;
    let stack = VarArray.repeat<(Nat64, Nat64)>((0, 0), self.key_size * 8 / nat16toNat(self.bitlength));
    var depth = 1;
    stack[0] := if (forward) (0, 0) else (0, self.root_aridity_ - 1);

    func next_step(i : Nat64) : Nat64 {
      if (forward) {
        i + 1;
      } else {
        if (i != 0) i - 1 else self.root_aridity_;
      };
    };

    {
      next = func() : ?Nat64 {
        let leaf = label l : ?Nat64 loop {
          let (node, i) = stack[depth - 1];
          let max = if (depth > 1) self.aridity_ else self.root_aridity_;
          if (i < max) {
            let child = getChild(self, nodes, node, i);
            if (child == 0) {
              stack[depth - 1] := (node, next_step(i));
              continue l;
            };
            if (child & 1 == 1) {
              stack[depth - 1] := (node, next_step(i));
              break l(?(child >> 1));
            };
            stack[depth] := (child, if (forward) 0 else self.aridity_ - 1);
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
  };

  func entries_base<T>(self : StableTrieBase, dir : Dir, f : (Nat64, Region.Region) -> T) : Types.Iter<T> {
    let state = regions(self);
    let { nodes; leaves } = state;
    let leaves_region = leaves.region;
    let nodes_region = nodes.region;
    makeIter(self, nodes_region, dir).map<Nat64, T>(func(leaf) = f(leaf, leaves_region));
  };

  func entries_(self : StableTrieBase, dir : Dir) : Types.Iter<(Blob, Blob)> = entries_base<(Blob, Blob)>(
    self,
    dir,
    func(leaf, leaves) = (getKey(self, leaves, leaf), getValue(self, leaves, leaf)),
  );

  func vals_(self : StableTrieBase, dir : Dir) : Types.Iter<Blob> = entries_base<Blob>(
    self,
    dir,
    func(leaf, leaves) = getValue(self, leaves, leaf),
  );

  func keys_(self : StableTrieBase, dir : Dir) : Types.Iter<Blob> = entries_base<Blob>(
    self,
    dir,
    func(leaf, leaves) = getKey(self, leaves, leaf),
  );

  /// Iterate entries in forward order.
  public func entries(self : StableTrieBase) : Types.Iter<(Blob, Blob)> = entries_(self, #forward);

  /// Iterate entries in reverse order.
  public func entriesRev(self : StableTrieBase) : Types.Iter<(Blob, Blob)> = entries_(self, #reverse);

  /// Iterate values in forward order.
  public func vals(self : StableTrieBase) : Types.Iter<Blob> = vals_(self, #forward);

  /// Iterate values in reverse order.
  public func valsRev(self : StableTrieBase) : Types.Iter<Blob> = vals_(self, #reverse);

  /// Iterate keys in forward order.
  public func keys(self : StableTrieBase) : Types.Iter<Blob> = keys_(self, #forward);

  /// Iterate keys in reverse order.
  public func keysRev(self : StableTrieBase) : Types.Iter<Blob> = keys_(self, #reverse);

  /// Return current memory stats. `node_count` reports nodes currently in
  /// use (`total_node_count - empty_nodes_list.count`); `byte_size` is
  /// computed from the high water and so never shrinks.
  public func memoryStats(self : StableTrieBase) : MemoryStats {
    let total_n = nat64toNat(self.node_count);
    {
      byte_size = if (self.node_count == 0) {
        0 // no regions allocated yet
      } else {
        nat64toNat(self.root_size + (self.node_count - 1) * self.node_size + self.leaf_count * self.leaf_size);
      };
      leaf_count = nat64toNat(self.leaf_count);
      node_count = total_n - self.empty_nodes_list.count;
      total_node_count = total_n;
    };
  };

  /// Convert to stable data.
  public func share(self : StableTrieBase) : StableData = {
    regions(self) with
    node_count = self.node_count;
    leaf_count = self.leaf_count;
    empty_nodes = ?self.empty_nodes_list.share();
  };

  /// Create from stable data. Must be the first call after `empty()`.
  /// `data.empty_nodes` is optional to allow loading legacy data that
  /// predates this field; missing or `null` is treated as an empty list.
  public func unshare(self : StableTrieBase, data : StableData) {
    switch (self.regions_) {
      case (null) {
        self.regions_ := ?data;
        self.node_count := data.node_count;
        self.leaf_count := data.leaf_count;
        self.empty_nodes_list.unshare(
          switch (data.empty_nodes) {
            case (?en) en;
            case (null) (0, self.loadMask); // legacy: empty list
          }
        );
      };
      case (_) Runtime.trap("Region is already initialized");
    };
  };
};
