/// Stable trie underlying `Map` and `Enumeration`.
///
/// Copyright: 2023 - 2025 MR Research AG
///
/// Main author: Andrii Stepanov (AStepanov25)
///
/// Contributors: Timo Hanke (timohanke)
///
/// Implemented as a plain mutable record (`StableTrie`) plus module-level
/// functions whose first argument is `self`. Callers can use dot-notation
/// (`trie.put_(...)`, `trie.lookup(...)`, etc.) which Motoko resolves to the
/// corresponding module-level function.

import Iter "mo:core/Iter";
import Nat_ "mo:core/Nat";
import Nat16 "mo:core/Nat16"; // bitcountTrailingZero
import Nat64 "mo:core/Nat64"; // bitcountTrailingZero
import Option "mo:core/Option";
import Region "mo:core/Region";
import { type Region } "mo:core/Region";
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

  /// Arguments of constructor of `StableTrie`.
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

  type Dir = { #forward; #reverse };

  /// Per-pointer-size store dispatch table, indexed by `storeFuncIndex`
  /// (see `empty`).
  let storePointerFuncs = [
    Region.storeNat64,
    func storePointer(region : Region, offset : Nat64, child : Nat64) {
      region.storeNat32(offset, nat64to32(child & 0xffff_ffff));
      region.storeNat16(offset +% 4, nat32to16(nat64to32(child >> 32)));
    },
    func storePointer(region : Region, offset : Nat64, child : Nat64) {
      region.storeNat32(offset, nat64to32(child & 0xffff_ffff));
      region.storeNat8(offset +% 4, natWrap8(nat64toNat(child >> 32)));
    },
    func storePointer(region : Region, offset : Nat64, child : Nat64) {
      region.storeNat32(offset, nat64to32(child));
    },
    func storePointer(region : Region, offset : Nat64, child : Nat64) {
      region.storeNat16(offset, nat32to16(nat64to32(child)));
    },
  ];

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
    storeFuncIndex : Nat;
    empty_nodes_list : LinkedList.LinkedList;
    empty_leaves_list : LinkedList.LinkedList;
    var leaf_count : Nat64;
    var node_count : Nat64;
    var nodes_region : Region;
    var nodes_freeSpace : Nat64;
    var leaves_region : Region;
    var leaves_freeSpace : Nat64;
  };

  /// Construct an empty stable trie.
  public func empty(args : Args) : StableTrie {
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
    let leaf_size : Nat64 = args.leaf_size.toNat64();
    let padding : Nat64 = 8 - pointer_size_;

    // Allocate the nodes and leaves regions eagerly so the region/freeSpace
    // pairs are plain `var`s (no Option wrapper). The nodes region grows
    // enough pages to hold the root and its padding; the leaves region
    // starts at 0 pages and grows on first `newLeaf`.
    let nodes_region = Region.new();
    let pages = (root_size + padding + 65536 - 1) / 65536;
    assert nodes_region.grow(pages) != 0xffff_ffff_ffff_ffff;

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
      leaf_size;
      root_size;
      offset_base;
      padding;
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
      empty_leaves_list = LinkedList.empty(0, leaf_size, pointer_size_);
      var leaf_count = 0 : Nat64;
      var node_count = 1 : Nat64;
      var nodes_region = nodes_region;
      var nodes_freeSpace = pages * 65536 - root_size - padding;
      var leaves_region = Region.new();
      var leaves_freeSpace = 0 : Nat64;
    };
  };

  /// Create internal node.
  func newInternalNode(self : StableTrie) : ?Nat64 {
    let node = switch (self.empty_nodes_list.pop(self.nodes_region)) {
      case (?index) index << 1; // re-encode reused node index → pointer
      case (null) {
        if (self.node_count != self.max_address) {
          // Inlined allocate: grow one page if there isn't room for node_size.
          if (self.nodes_freeSpace < self.node_size) {
            assert self.nodes_region.grow(1) != 0xffff_ffff_ffff_ffff;
            self.nodes_freeSpace +%= 65536;
          };
          self.nodes_freeSpace -%= self.node_size;
          let nc = self.node_count;
          self.node_count +%= 1;
          nc << 1;
        } else return null;
      };
    };
    ?node;
  };

  func newLeaf(self : StableTrie, key : Blob) : ?Nat64 {
    let leaf = switch (self.empty_leaves_list.pop(self.leaves_region)) {
      case (?leaf) leaf;
      case (null) {
        if (self.leaf_count != self.max_address) {
          // Inlined allocate: grow one page if there isn't room for leaf_size.
          if (self.leaves_freeSpace < self.leaf_size) {
            assert self.leaves_region.grow(1) != 0xffff_ffff_ffff_ffff;
            self.leaves_freeSpace +%= 65536;
          };
          self.leaves_freeSpace -%= self.leaf_size;
          let lc = self.leaf_count;
          self.leaf_count +%= 1;
          lc;
        } else return null;
      };
    };

    self.leaves_region.storeBlob(getLeafOffset(self, leaf), key);
    ?((leaf << 1) | 1);
  };

  // Get base address of node (the offset of its first child pointer).
  func getNodeBase(self : StableTrie, node : Nat64) : Nat64 {
    if (node == 0) return 0; // root node
    (self.offset_base +% (node >> 1) *% self.node_size);
  };

  /// Get address of pointer of node's `node` child number `index`.
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
  public func setChild(self : StableTrie, node : Nat64, index : Nat64, child : Nat64) {
    let offset = getNodeOffset(self, node, index);
    storePointerFuncs[self.storeFuncIndex](self.nodes_region, offset, child);
  };

  /// Inspect the children of an internal `node` and classify which case
  /// applies (see `ChildScan`). Reads the node as a single blob and parses
  /// each pointer in-memory, which is meaningfully cheaper than `aridity`
  /// separate region loads when aridity is large (e.g. 256).
  ///
  /// `assert`s that the node has at least one non-zero child. The
  /// "zero children" case is unreachable under the deletion invariants
  /// maintained by Map and Enumeration.
  public func scanChildren(self : StableTrie, node : Nat64) : ChildScan {
    let blob = self.nodes_region.loadBlob(getNodeBase(self, node), self.node_size_);
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
  public func pushEmptyNode(self : StableTrie, node : Nat64) {
    self.empty_nodes_list.push(self.nodes_region, node >> 1);
  };

  /// Push a freed leaf slot onto the empty-leaves list so the next
  /// `newLeaf` reuses it. Map's `removeRec` calls this when a key is
  /// removed; Enumeration never does, so for Enumeration the list stays
  /// empty and `newLeaf` always allocates fresh.
  public func pushEmptyLeaf(self : StableTrie, leaf : Nat64) {
    self.empty_leaves_list.push(self.leaves_region, leaf);
  };

  /// Get offset of leaf number `index`.
  func getLeafOffset(self : StableTrie, index : Nat64) : Nat64 = index *% self.leaf_size;

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

  /// Get index in root node.
  public func keyToRootIndex(self : StableTrie, key : Blob) : Nat64 {
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
  public func keyToIndex(self : StableTrie, key : Blob, pos : Nat16) : Nat64 {
    return nat32to64(nat16to32(nat8to16((key[nat16toNat(pos >> 3)] << nat16to8(pos & 7)) >> self.bitshift)));
  };

  func find(self : StableTrie, key : Blob) : (Nat64, Nat64, Nat64, Nat16) {
    var idx = keyToRootIndex(self, key);
    var pos = self.root_bitlength;
    var node : Nat64 = 0;
    loop {
      let child = getChild(self, node, idx);
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
  public func put_(self : StableTrie, key : Blob) : ?(Bool, Nat64) {
    assert key.size() == self.key_size;

    let (node_, last_, old_leaf, pos_) = find(self, key);

    var last = last_;
    var node = node_;

    if (old_leaf == 0) {
      let ?leaf = newLeaf(self, key) else return null;

      setChild(self, node, last, leaf);
      return ?(true, (leaf >> 1));
    };

    let index = old_leaf >> 1;
    let old_key = getKey(self, index);
    if (key == old_key) {
      return ?(false, index);
    };

    var pos = pos_;
    label l loop {
      let ?add = newInternalNode(self) else {
        setChild(self, node, last, old_leaf);
        return null;
      };
      setChild(self, node, last, add);
      node := add;

      let (a, b) = (keyToIndex(self, key, pos), keyToIndex(self, old_key, pos));
      pos +%= self.bitlength;
      if (a == b) {
        last := a;
      } else {
        setChild(self, node, b, old_leaf);
        let ?leaf = newLeaf(self, key) else return null;
        setChild(self, node, a, leaf);
        return ?(true, (leaf >> 1));
      };
    };
    Runtime.trap("Unreacheable");
  };

  /// Recursive walk for `removeLast`.
  func removeLastRec(self : StableTrie, key : Blob, node : Nat64, pos : Nat16) : Nat64 {
    let idx = keyToIndex(self, key, pos);
    let child = getChild(self, node, idx);
    let new_child = if (child & 1 == 1) {
      0 : Nat64;
    } else {
      removeLastRec(self, key, child, pos +% self.bitlength);
    };

    if (new_child == child) return node;

    setChild(self, node, idx, new_child);
    switch (scanChildren(self, node)) {
      case (#onlyLeaf(leaf, slot)) {
        setChild(self, node, slot, 0);
        pushEmptyNode(self, node);
        leaf;
      };
      case (#onlyInternal _) node;
      case (#multiple) node;
    };
  };

  /// Remove the most-recently-added leaf (at index `leaf_count - 1`).
  public func removeLast(self : StableTrie) : ?(Blob, Blob) {
    if (self.leaf_count == 0) return null;

    let last_index = self.leaf_count -% 1;
    let key = getKey(self, last_index);
    let value = getValue(self, last_index);

    let root_idx = keyToRootIndex(self, key);
    let root_child = getChild(self, 0, root_idx);
    let new_root_child = if (root_child & 1 == 1) {
      0 : Nat64;
    } else {
      removeLastRec(self, key, root_child, self.root_bitlength);
    };
    if (new_root_child != root_child) {
      setChild(self, 0, root_idx, new_root_child);
    };

    self.leaf_count -%= 1;
    self.leaves_freeSpace +%= self.leaf_size;

    ?(key, value);
  };

  /// Lookup `key` in trie. Returns `value` and index of that leaf or null if not found.
  public func lookup(self : StableTrie, key : Blob) : ?(Blob, Nat) {
    assert key.size() == self.key_size;

    let (_, _, old_leaf, _) = find(self, key);
    if (old_leaf == 0) return null;
    let index = old_leaf >> 1;

    return if (getKey(self, index) == key) {
      ?(getValue(self, index), nat64toNat(index));
    } else {
      null;
    };
  };

  /// Closure-based iterator factory returning an `Iter<Nat64>` directly.
  /// The returned iterator owns the traversal stack via closure capture.
  func makeIter(self : StableTrie, dir : Dir) : Types.Iter<Nat64> {
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
            let child = getChild(self, node, i);
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

  func entries_(self : StableTrie, dir : Dir) : Types.Iter<(Blob, Blob)> = makeIter(self, dir).map<Nat64, (Blob, Blob)>(
    func(leaf) = (getKey(self, leaf), getValue(self, leaf))
  );

  func vals_(self : StableTrie, dir : Dir) : Types.Iter<Blob> = makeIter(self, dir).map<Nat64, Blob>(
    func(leaf) = getValue(self, leaf)
  );

  func keys_(self : StableTrie, dir : Dir) : Types.Iter<Blob> = makeIter(self, dir).map<Nat64, Blob>(
    func(leaf) = getKey(self, leaf)
  );

  /// Iterate entries in forward order.
  public func entries(self : StableTrie) : Types.Iter<(Blob, Blob)> = entries_(self, #forward);

  /// Iterate entries in reverse order.
  public func entriesRev(self : StableTrie) : Types.Iter<(Blob, Blob)> = entries_(self, #reverse);

  /// Iterate values in forward order.
  public func vals(self : StableTrie) : Types.Iter<Blob> = vals_(self, #forward);

  /// Iterate values in reverse order.
  public func valsRev(self : StableTrie) : Types.Iter<Blob> = vals_(self, #reverse);

  /// Iterate keys in forward order.
  public func keys(self : StableTrie) : Types.Iter<Blob> = keys_(self, #forward);

  /// Iterate keys in reverse order.
  public func keysRev(self : StableTrie) : Types.Iter<Blob> = keys_(self, #reverse);

  /// Return current memory stats. `node_count` reports nodes currently in
  /// use (`total_node_count - empty_nodes_list.count`); `byte_size` is
  /// computed from the high water and so never shrinks.
  public func memoryStats(self : StableTrie) : MemoryStats {
    let total_n = nat64toNat(self.node_count);
    {
      byte_size = nat64toNat(self.root_size + (self.node_count - 1) * self.node_size + self.leaf_count * self.leaf_size);
      leaf_count = nat64toNat(self.leaf_count);
      node_count = total_n - self.empty_nodes_list.count;
      total_node_count = total_n;
    };
  };

};
