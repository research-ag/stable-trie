/// Stable trie underlying `Map` and `Enumeration`.
///
/// Copyright: 2023 - 2026 MR Research AG
///
/// Main authors: Andrii Stepanov (AStepanov25), Timo Hanke (timohanke)
///
/// Contributors: Andy Gura (AndyGura)
///
/// Implemented as a plain mutable record (`StableTrie`) plus module-level
/// functions whose first argument is `self`. Callers can use dot-notation
/// (`trie.put_(...)`, `trie.lookup(...)`, etc.) which Motoko resolves to the
/// corresponding module-level function.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Nat_ "mo:core/Nat";
import Nat16 "mo:core/Nat16"; // bitcountTrailingZero
import Nat64 "mo:core/Nat64"; // bitcountTrailingZero
import Option "mo:core/Option";
import Region "mo:core/Region";
import Runtime "mo:core/Runtime";
import Prim "mo:prim";

import Layout "./layout";
import LinkedList "./linked-list";

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

  /// Constructor arguments shared by `Enumeration` and `Map`. The public
  /// `empty()` in those modules documents the fields in user-facing terms.
  ///
  /// - `pointer_size : Nat` — pointer byte width; one of `2, 3, 4, 5, 6, 8`.
  /// - `aridity : Nat` — children per non-root internal node; one of
  ///   `2, 4, 16, 256`.
  /// - `root_aridity : ?Nat` — children of the root node (must be a power
  ///   of 2 ≥ `aridity`); `null` defaults to `aridity`.
  /// - `key_size : Nat` — fixed key byte length, `≥ 1`.
  /// - `value_size : Nat` — fixed value byte length, `≥ 0`.
  public type BaseArgs = {
    pointer_size : Nat;
    aridity : Nat;
    root_aridity : ?Nat;
    key_size : Nat;
    value_size : Nat;
  };

  /// `BaseArgs` plus `leaf_size` — the byte size of a leaf slot. The
  /// public modules compute this for the user (Map pads up to
  /// `pointer_size`; Enumeration uses `key_size + value_size` directly).
  public type Args = BaseArgs and {
    leaf_size : Nat;
  };

  /// Memory-usage statistics. Shared shape between Map and Enumeration.
  ///
  /// Fields:
  /// - `byte_size`: total bytes occupied by the trie's stable-memory regions. Computed from the allocated (high-water) counters: it grows on every allocation; for `Map` it never shrinks, and for `Enumeration` it shrinks when `removeLast` retracts a leaf (the Region itself never shrinks).
  /// - `used_leaf_count`: leaves currently in use (`total_leaf_count` minus those freed by removals and waiting in the empty-leaves free list).
  /// - `used_node_count`: internal nodes currently in use (`total_node_count` minus those freed by node-collapse and waiting in the empty-nodes free list).
  /// - `total_leaf_count`: total leaves ever allocated. High-water mark for `Map` (never shrinks); for `Enumeration` this equals `used_leaf_count` because `removeLast` decrements the counter rather than pushing to a free list.
  /// - `total_node_count`: total internal nodes ever allocated. High-water mark for both `Map` and `Enumeration`; never shrinks even when nodes are pushed onto the empty-nodes list.
  /// - `nodes_region_pages`: number of 64KB stable-memory pages currently allocated to the nodes region. Monotonic allocation counter — grows when the region is extended to fit more internal nodes (or for the initial root + padding) and never shrinks.
  /// - `leaves_region_pages`: number of 64KB stable-memory pages currently allocated to the leaves region. Monotonic allocation counter — grows when the region is extended to fit more leaves and never shrinks (the leaves region is grown lazily, so this is `0` until the first leaf is added).
  ///
  /// In general, `used_*` is the live count and `total_*` is the high-water count. They diverge when a free list is populated: for `Map`, both leaf and node free lists are populated by `delete`/`take`/`remove`; for `Enumeration`, only the node free list is — `removeLast` drops `used_leaf_count` and `total_leaf_count` in lockstep, so those two are always equal.
  public type MemoryStats = {
    byte_size : Nat;
    used_leaf_count : Nat;
    used_node_count : Nat;
    total_leaf_count : Nat;
    total_node_count : Nat;
    nodes_region_pages : Nat;
    leaves_region_pages : Nat;
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

  /// Stable trie record underlying `Map` and `Enumeration`.
  /// SHOULD NOT BE USED DIRECTLY FROM USER CODE.
  ///
  /// Re-export from `layout.mo`, where the record type lives alongside the
  /// low-level read/write helpers. Defined there to break the otherwise-
  /// circular dependency (this module's algorithm calls layout helpers, and
  /// the helpers need the record type).
  public type StableTrie = Layout.StableTrie;

  /// Construct an empty stable trie.
  public func empty(args : Args) : StableTrie {
    assert switch (args.pointer_size) {
      // 1 is intended for tests: it shrinks max_address to 2**7 = 128,
      // making it cheap to construct scenarios that hit the node/leaf
      // pointer cap. It is not meant to be used in production tries.
      case (2 or 3 or 4 or 5 or 6 or 8 or 1) true;
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

    let max_address : Nat64 = 2 ** (pointer_size_ * 8 - 1);
    let max_chain_depth : Nat64 = (key_size_ * 8 - root_bitlength_) / bitlength.toNat64();
    let safe_node_bound : Nat64 = if (max_chain_depth >= max_address) 0 else max_address -% max_chain_depth;

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
      max_address;
      max_chain_depth;
      safe_node_bound;
      root_bitlength_;
      root_bitlength = root_bitlength_.toNat16();
      node_size;
      node_size_ = nat64toNat(node_size);
      leaf_size;
      root_size;
      offset_base;
      padding;
      empty_values = args.value_size == 0;
      zero_leaf = Blob.fromArray(Array.tabulate<Nat8>(args.leaf_size, func(_) = 0));
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

    self.leaves_region.storeBlob(Layout.getLeafOffset(self, leaf), key);
    ?((leaf << 1) | 1);
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
    let blob = Layout.getRawNode(self, node);
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

  /// Get index in root node.
  public func keyToRootIndex(self : StableTrie, key : Blob) : Nat64 {
    var result : Nat64 = 0;
    let iters = self.root_bitlength_ >> 3;
    var i : Nat64 = 0;
    while (i < iters) {
      result := (result << 8) | nat32to64(nat16to32(nat8to16(key[nat64toNat(i)])));
      i +%= 1;
    };
    let skip = self.root_bitlength_ & 7;
    if (skip != 0) {
      result := (result << skip) | (nat32to64(nat16to32(nat8to16(key[nat64toNat(i)]))) >> (8 -% skip));
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
      let child = Layout.getChild(self, node, idx);
      if (child == 0 or child & 1 == 1) {
        return (node, idx, child, pos);
      };
      node := child;
      idx := keyToIndex(self, key, pos);
      pos +%= self.bitlength;
    };
    Runtime.trap("Unreacheable");
  };

  /// Put only `key` into trie. Returns pair (whether new leaf created,
  /// index of leaf) or `null` if the pointer-size limit would be hit.
  ///
  /// On `null`, the trie is left unchanged — `put_` is atomic. This is
  /// achieved with a three-tier capacity check:
  ///
  ///   - Tier 1: two `Nat64` compares against static bounds. Does not
  ///     touch the empty-list counters at all, so the hot path never
  ///     pays for a `Nat → Nat64` conversion.
  ///   - Tier 2 (only on near-capacity): include free-list slots in the
  ///     check; still O(1).
  ///   - Tier 3 (only if tier 2 also fails): precise per-call pre-walk
  ///     to determine actual chain length.
  public func put_(self : StableTrie, key : Blob) : ?(Bool, Nat64) {
    assert key.size() == self.key_size;

    // Tier 1: conservative bounds. `node_count < safe_node_bound`
    // guarantees room for the worst-case chain; `leaf_count <
    // max_address` guarantees room for one fresh leaf.
    if (self.node_count < self.safe_node_bound and self.leaf_count < self.max_address) {
      return ?putOrTrap(self, key);
    };

    // Tier 2: account for free-list reuse before giving up the fast path.
    let avail_internals = self.max_address -% self.node_count +% self.empty_nodes_list.count.toNat64();
    let avail_leaves = self.max_address -% self.leaf_count +% self.empty_leaves_list.count.toNat64();
    if (avail_leaves >= 1 and avail_internals >= self.max_chain_depth) {
      return ?putOrTrap(self, key);
    };

    // Tier 3: precise pre-walk.
    putPreciseCheck(self, key, avail_internals, avail_leaves);
  };

  /// Slow-path capacity check: walk the trie + key bits to determine the
  /// exact allocation need, then either commit via `putOrTrap` or
  /// return `null` with the trie untouched.
  func putPreciseCheck(
    self : StableTrie,
    key : Blob,
    avail_internals : Nat64,
    avail_leaves : Nat64,
  ) : ?(Bool, Nat64) {
    let (_, _, old_leaf, pos_) = find(self, key);

    if (old_leaf == 0) {
      // Empty slot — only a new leaf is needed.
      if (avail_leaves < 1) return null;
      return ?putOrTrap(self, key);
    };

    let old_key = Layout.getKey(self, old_leaf >> 1);
    if (key == old_key) {
      // Pure overwrite — no allocation needed at all.
      return ?putOrTrap(self, key);
    };

    // Split needed: count exact chain length by walking shared-bit prefix.
    var pos = pos_;
    var k : Nat64 = 1;
    loop {
      let (a, b) = (keyToIndex(self, key, pos), keyToIndex(self, old_key, pos));
      pos +%= self.bitlength;
      if (a != b) {
        return if (avail_internals >= k and avail_leaves >= 1) ?putOrTrap(self, key) else null;
      };
      k +%= 1;
    };
  };

  /// Put a key into the trie and either return `(was-new, leaf-index)`
  /// or trap on pointer-size overflow.
  ///
  /// Called from two contexts:
  ///   - From `put_`'s fast path, after the upfront capacity check has
  ///     promised that no allocation will fail. The traps below are then
  ///     a defensive precondition assertion — unreachable unless the
  ///     capacity gate has a bug.
  ///   - Directly from trapping public APIs (`Map.add`/`insert`/`swap`/
  ///     `getOrAdd`, `Enumeration.add`/`insert`/`lookupOrAdd`). The trap
  ///     here IS the intended failure mode on overflow — the surrounding
  ///     IC message will roll back any partial mutation, so the trie is
  ///     never observed in a corrupted state.
  public func putOrTrap(self : StableTrie, key : Blob) : (Bool, Nat64) {
    assert key.size() == self.key_size;
    let (node_, last_, old_leaf, pos_) = find(self, key);

    if (old_leaf == 0) {
      let ?leaf = newLeaf(self, key) else Runtime.trap("StableTrie: pointer size overflow");
      Layout.setChild(self, node_, last_, leaf);
      return (true, leaf >> 1);
    };

    let index = old_leaf >> 1;
    let old_key = Layout.getKey(self, index);
    if (key == old_key) return (false, index);

    var pos = pos_;
    var node = node_;
    var last = last_;
    label l loop {
      let ?add = newInternalNode(self) else Runtime.trap("StableTrie: pointer size overflow");
      Layout.setChild(self, node, last, add);
      node := add;

      let (a, b) = (keyToIndex(self, key, pos), keyToIndex(self, old_key, pos));
      pos +%= self.bitlength;
      if (a == b) {
        last := a;
      } else {
        Layout.setChild(self, node, b, old_leaf);
        let ?leaf = newLeaf(self, key) else Runtime.trap("StableTrie: pointer size overflow");
        Layout.setChild(self, node, a, leaf);
        return (true, leaf >> 1);
      };
    };
    Runtime.trap("Unreacheable");
  };

  /// Recursive walk for `removeLast`.
  func removeLastRec(self : StableTrie, key : Blob, node : Nat64, pos : Nat16) : Nat64 {
    let idx = keyToIndex(self, key, pos);
    let child = Layout.getChild(self, node, idx);
    let new_child = if (child & 1 == 1) {
      0 : Nat64;
    } else {
      removeLastRec(self, key, child, pos +% self.bitlength);
    };

    if (new_child == child) return node;

    Layout.setChild(self, node, idx, new_child);
    switch (scanChildren(self, node)) {
      case (#onlyLeaf(leaf, slot)) {
        Layout.setChild(self, node, slot, 0);
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
    let key = Layout.getKey(self, last_index);
    let value = Layout.getValue(self, last_index);

    let root_idx = keyToRootIndex(self, key);
    let root_child = Layout.getChild(self, 0, root_idx);
    let new_root_child = if (root_child & 1 == 1) {
      0 : Nat64;
    } else {
      removeLastRec(self, key, root_child, self.root_bitlength);
    };
    if (new_root_child != root_child) {
      Layout.setChild(self, 0, root_idx, new_root_child);
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

    return if (Layout.getKey(self, index) == key) {
      ?(Layout.getValue(self, index), nat64toNat(index));
    } else {
      null;
    };
  };

  /// Check whether `key` is present in the trie. Cheaper than `lookup`
  /// because it skips the value blob allocation.
  public func contains(self : StableTrie, key : Blob) : Bool {
    assert key.size() == self.key_size;

    let (_, _, old_leaf, _) = find(self, key);
    if (old_leaf == 0) return false;
    Layout.getKey(self, old_leaf >> 1) == key;
  };

  /// Return current memory stats. See `MemoryStats` for field meanings.
  public func memoryStats(self : StableTrie) : MemoryStats {
    let total_l = nat64toNat(self.leaf_count);
    let total_n = nat64toNat(self.node_count);
    {
      byte_size = nat64toNat(self.root_size + (self.node_count - 1) * self.node_size + self.leaf_count * self.leaf_size);
      used_leaf_count = total_l - self.empty_leaves_list.count;
      used_node_count = total_n - self.empty_nodes_list.count;
      total_leaf_count = total_l;
      total_node_count = total_n;
      nodes_region_pages = nat64toNat(self.nodes_region.size());
      leaves_region_pages = nat64toNat(self.leaves_region.size());
    };
  };

  // Promtracker type Metric
  type Metric = (Text, Text, Nat);

  // Promtracker type Value
  public type Value = {
    read : () -> [Metric];
  };

  /// Convert memory stats to a Promtracker `Value` with appropriate labels,
  /// suitable for `renderer.addValue(...)`.
  ///
  /// The shape of the returned `Value` (the `read : () -> [Metric]` record
  /// and the `Metric = (Text, Text, Nat)` tuple shape) targets the
  /// `mo:promtracker` API as of **promtracker >= 1.0.1**. Earlier 0.5.x
  /// releases used a different `Value` shape and will not type-check
  /// against this function.
  public func toValue(self : StableTrie) : Value {
    return {
      read = func() : [Metric] = memoryStats(self) |> [
        ("stable_trie_pointer_size", "", self.pointer_size),
        ("stable_trie_value_size", "", self.value_size),
        ("stable_trie_key_size", "", self.key_size),
        ("stable_trie_node_count", "kind=\"total\"", _.total_node_count),
        ("stable_trie_leaf_count", "kind=\"total\"", _.total_leaf_count),
        ("stable_trie_node_count", "kind=\"used\"", _.used_node_count),
        ("stable_trie_leaf_count", "kind=\"used\"", _.used_leaf_count),
        ("stable_trie_byte_size", "", _.byte_size),
        ("stable_trie_region_pages", "type=\"nodes\"", _.nodes_region_pages),
        ("stable_trie_region_pages", "type=\"leaves\"", _.leaves_region_pages),
      ];
    };
  };

  // ─── Incremental pointer-size resize ───────────────────────────────────────
  //
  // The pointer width of a trie can be migrated to a different value (e.g.
  // 4 → 2 to shrink the address space once it's known the trie won't grow
  // further, or 2 → 4 to make room for more entries). Pointer values
  // encode node/leaf *indices*, not byte offsets, so the numeric value of
  // every pointer is preserved across the resize — only the byte width
  // changes.
  //
  // The rewrite happens in place on the existing nodes region:
  //
  // - Shrinking (new_ps < old_ps): each node is read at its old position
  //   with the old width and written at its new (leftward) position with
  //   the new width. Nodes are processed left-to-right.
  //
  // - Growing (new_ps > old_ps): the region is grown first if needed,
  //   then nodes are processed right-to-left, each read at its old
  //   position and written at its new (rightward) position.
  //
  // The work is incremental: `beginResize` produces a stable `ResizeState`,
  // `stepResize` does up to `batch_size` nodes per call and returns `true`
  // when the last node has been processed, and `completeResize` returns
  // the new `StableTrie` sharing the now-rewritten regions. The caller
  // is responsible for:
  //
  // - storing the original trie reference in a `var`, so it can be
  //   reassigned to the new trie after `completeResize`;
  // - keeping the `ResizeState` reachable across messages (typically a
  //   `var resizing : ?ResizeState`);
  // - NOT performing any read or write through the original trie
  //   reference between `beginResize` and `completeResize` — both the
  //   old and new layouts use the same region bytes, and the bytes are
  //   neither old-shape nor new-shape during the migration.

  /// State carried across calls of an incremental pointer-size resize.
  ///
  /// All fields are stable types so the state survives canister upgrades.
  public type ResizeState = {
    nodes_region : Region.Region;
    leaves_region : Region.Region;
    node_count : Nat64;
    leaf_count : Nat64;
    // Old layout snapshot — used to decode the still-untouched part of
    // the nodes region.
    old_pointer_size : Nat;
    old_pointer_size_ : Nat64;
    old_node_size : Nat64;
    old_offset_base : Nat64;
    old_loadMask : Nat64;
    // New layout snapshot — used to write the migrated part, and to
    // construct the new StableTrie in `completeResize`.
    new_pointer_size : Nat;
    new_pointer_size_ : Nat64;
    new_node_size : Nat64;
    new_root_size : Nat64;
    new_offset_base : Nat64;
    new_loadMask : Nat64;
    new_max_address : Nat64;
    new_safe_node_bound : Nat64;
    new_padding : Nat64;
    new_nodes_freeSpace : Nat64;
    // Unchanged layout values (carried verbatim into the new StableTrie).
    key_size : Nat;
    value_size : Nat;
    aridity_ : Nat64;
    key_size_ : Nat64;
    root_aridity_ : Nat64;
    bitlength : Nat16;
    bitshift : Nat8;
    max_chain_depth : Nat64;
    root_bitlength_ : Nat64;
    root_bitlength : Nat16;
    leaf_size : Nat64;
    empty_values : Bool;
    zero_leaf : Blob;
    // Free-list state, captured verbatim. For the nodes list, the per-node
    // rewrite re-encodes the chain links (they live at the start of each
    // freed node, which the sweep visits). For the leaves list, no
    // re-encoding is needed: the LinkedList never writes a pointer-size-
    // dependent sentinel into the region (count==0 is the empty signal),
    // so the in-region bytes are agnostic to the new pointer width as
    // long as the head index itself fits in it (which we checked above).
    empty_nodes_count : Nat;
    empty_nodes_last : Nat64;
    empty_leaves_count : Nat;
    empty_leaves_last : Nat64;
    leaves_freeSpace : Nat64;
    // Direction of the migration.
    shrinking : Bool;
    // Number of nodes already migrated (0 .. node_count). When equal to
    // node_count, the resize is done and `completeResize` may be called.
    var processed : Nat64;
  };

  /// Begin an incremental pointer-size migration. Returns `null` if the
  /// resize cannot proceed:
  ///
  /// - `new_pointer_size` is not one of `1, 2, 3, 4, 5, 6, 8`;
  /// - `new_pointer_size == self.pointer_size` (no work to do);
  /// - the new pointer space is too small to address the current
  ///   `node_count` or `leaf_count`;
  /// - the new pointer size would change `leaf_size` (Map padding case,
  ///   i.e. `new_pointer_size > leaf_size`).
  ///
  /// On success, the region is grown if needed (for the growing case)
  /// and a `ResizeState` is returned. No nodes have been migrated yet.
  ///
  /// The leaves region is NOT touched by the resize. Freed leaves in
  /// `empty_leaves_list` survive the migration unchanged because (a)
  /// they are all-zero except for their chain-link slot (the caller
  /// zeros them before push), and (b) `LinkedList` does not depend on
  /// any pointer-size-encoded sentinel inside the region — `count` is
  /// the empty signal, and the chain link of the bottom item is just
  /// zero. So a free-list entry encoded under the old layout decodes
  /// correctly under the new layout as long as the index value itself
  /// fits in the new pointer width.
  public func beginResize(self : StableTrie, new_pointer_size : Nat) : ?ResizeState {
    let valid = switch (new_pointer_size) {
      case (1 or 2 or 3 or 4 or 5 or 6 or 8) true;
      case _ false;
    };
    if (not valid) return null;
    if (new_pointer_size == self.pointer_size) return null;

    let new_pointer_size_ = Prim.intToNat64Wrap(new_pointer_size);
    let new_max_address : Nat64 = 2 ** (new_pointer_size_ * 8 - 1);

    if (self.node_count > new_max_address) return null;
    if (self.leaf_count > new_max_address) return null;

    // Refuse if leaf_size would change (Map padding case).
    if (new_pointer_size_ > self.leaf_size) return null;

    let shrinking = new_pointer_size < self.pointer_size;

    let new_node_size = self.aridity_ *% new_pointer_size_;
    let new_root_size = self.root_aridity_ *% new_pointer_size_;
    let new_offset_base = new_root_size -% new_node_size;
    let new_padding = 8 -% new_pointer_size_;
    let new_loadMask : Nat64 = if (new_pointer_size == 8) 0xffff_ffff_ffff_ffff else (1 << (new_pointer_size_ << 3)) -% 1;
    let new_safe_node_bound : Nat64 = if (self.max_chain_depth >= new_max_address) 0 else new_max_address -% self.max_chain_depth;

    let region = self.nodes_region;

    // Grow region if needed (only relevant for the growing direction).
    let new_used = new_root_size +% (self.node_count -% 1) *% new_node_size +% new_padding;
    let region_bytes = region.size() *% 65536;
    if (region_bytes < new_used) {
      let extra_needed = new_used -% region_bytes;
      let extra_pages = (extra_needed +% 65535) / 65536;
      assert region.grow(extra_pages) != 0xffff_ffff_ffff_ffff;
    };
    let final_region_bytes = region.size() *% 65536;
    let new_nodes_freeSpace = final_region_bytes -% new_used;

    ?{
      nodes_region = self.nodes_region;
      leaves_region = self.leaves_region;
      node_count = self.node_count;
      leaf_count = self.leaf_count;
      old_pointer_size = self.pointer_size;
      old_pointer_size_ = self.pointer_size_;
      old_node_size = self.node_size;
      old_offset_base = self.offset_base;
      old_loadMask = self.loadMask;
      new_pointer_size;
      new_pointer_size_;
      new_node_size;
      new_root_size;
      new_offset_base;
      new_loadMask;
      new_max_address;
      new_safe_node_bound;
      new_padding;
      new_nodes_freeSpace;
      key_size = self.key_size;
      value_size = self.value_size;
      aridity_ = self.aridity_;
      key_size_ = self.key_size_;
      root_aridity_ = self.root_aridity_;
      bitlength = self.bitlength;
      bitshift = self.bitshift;
      max_chain_depth = self.max_chain_depth;
      root_bitlength_ = self.root_bitlength_;
      root_bitlength = self.root_bitlength;
      leaf_size = self.leaf_size;
      empty_values = self.empty_values;
      zero_leaf = self.zero_leaf;
      empty_nodes_count = self.empty_nodes_list.count;
      // No sentinel translation needed: `last_empty_item` is either a real
      // index (preserved verbatim) when count > 0, or the placeholder 0
      // when count == 0 — neither depends on pointer_size.
      empty_nodes_last = self.empty_nodes_list.last_empty_item;
      empty_leaves_count = self.empty_leaves_list.count;
      empty_leaves_last = self.empty_leaves_list.last_empty_item;
      leaves_freeSpace = self.leaves_freeSpace;
      shrinking;
      var processed = 0 : Nat64;
    };
  };

  /// Migrate up to `batch_size` nodes. Returns `true` when every node has
  /// been migrated (after which `completeResize` should be called).
  /// Calling again after returning `true` is a no-op that still returns
  /// `true`.
  public func stepResize(state : ResizeState, batch_size : Nat) : Bool {
    let region = state.nodes_region;
    let aridity_ = state.aridity_;
    let root_aridity_ = state.root_aridity_;
    let node_count = state.node_count;
    let batch64 = Prim.intToNat64Wrap(batch_size);

    var processed = state.processed;
    let remaining = node_count -% processed;
    var to_process = if (remaining < batch64) remaining else batch64;

    if (state.shrinking) {
      while (to_process > 0) {
        let node_idx = processed;
        let n_slots = if (node_idx == 0) root_aridity_ else aridity_;
        let old_pos = if (node_idx == 0) 0 : Nat64 else state.old_offset_base +% node_idx *% state.old_node_size;
        let new_pos = if (node_idx == 0) 0 : Nat64 else state.new_offset_base +% node_idx *% state.new_node_size;

        var slot : Nat64 = 0;
        while (slot < n_slots) {
          let old_slot_offset = old_pos +% slot *% state.old_pointer_size_;
          let value = Prim.regionLoadNat64(region, old_slot_offset) & state.old_loadMask;
          let new_slot_offset = new_pos +% slot *% state.new_pointer_size_;
          writePointerN(region, state.new_pointer_size, new_slot_offset, value);
          slot +%= 1;
        };

        processed +%= 1;
        to_process -%= 1;
      };
    } else {
      while (to_process > 0) {
        let node_idx = node_count -% 1 -% processed;
        let n_slots = if (node_idx == 0) root_aridity_ else aridity_;
        let old_pos = if (node_idx == 0) 0 : Nat64 else state.old_offset_base +% node_idx *% state.old_node_size;
        let new_pos = if (node_idx == 0) 0 : Nat64 else state.new_offset_base +% node_idx *% state.new_node_size;

        // Slots walked right-to-left so that writes at higher slots
        // don't clobber the actual byte range of lower slots before we
        // read them.
        var slot : Nat64 = n_slots;
        while (slot > 0) {
          slot -%= 1;
          let old_slot_offset = old_pos +% slot *% state.old_pointer_size_;
          let value = Prim.regionLoadNat64(region, old_slot_offset) & state.old_loadMask;
          let new_slot_offset = new_pos +% slot *% state.new_pointer_size_;
          writePointerN(region, state.new_pointer_size, new_slot_offset, value);
        };

        processed +%= 1;
        to_process -%= 1;
      };
    };

    state.processed := processed;
    processed == node_count;
  };

  /// Assemble the new `StableTrie` from a completed resize. Traps if
  /// `stepResize` has not yet returned `true`. The returned trie shares
  /// the (now-rewritten) regions with the original; the caller must
  /// stop using the original reference.
  public func completeResize(state : ResizeState) : StableTrie {
    assert state.processed == state.node_count;

    {
      pointer_size = state.new_pointer_size;
      key_size = state.key_size;
      value_size = state.value_size;
      aridity_ = state.aridity_;
      key_size_ = state.key_size_;
      pointer_size_ = state.new_pointer_size_;
      root_aridity_ = state.root_aridity_;
      loadMask = state.new_loadMask;
      bitlength = state.bitlength;
      bitshift = state.bitshift;
      max_address = state.new_max_address;
      max_chain_depth = state.max_chain_depth;
      safe_node_bound = state.new_safe_node_bound;
      root_bitlength_ = state.root_bitlength_;
      root_bitlength = state.root_bitlength;
      node_size = state.new_node_size;
      node_size_ = nat64toNat(state.new_node_size);
      leaf_size = state.leaf_size;
      root_size = state.new_root_size;
      offset_base = state.new_offset_base;
      padding = state.new_padding;
      empty_values = state.empty_values;
      zero_leaf = state.zero_leaf;
      empty_nodes_list = {
        offset_base = state.new_offset_base;
        item_size = state.new_node_size;
        pointer_size = state.new_pointer_size;
        loadMask = state.new_loadMask;
        var count = state.empty_nodes_count;
        var last_empty_item = state.empty_nodes_last;
      };
      empty_leaves_list = {
        offset_base = 0 : Nat64;
        item_size = state.leaf_size;
        pointer_size = state.new_pointer_size;
        loadMask = state.new_loadMask;
        var count = state.empty_leaves_count;
        var last_empty_item = state.empty_leaves_last;
      };
      var leaf_count = state.leaf_count;
      var node_count = state.node_count;
      var nodes_region = state.nodes_region;
      var nodes_freeSpace = state.new_nodes_freeSpace;
      var leaves_region = state.leaves_region;
      var leaves_freeSpace = state.leaves_freeSpace;
    };
  };

  /// Write `value` at `offset` using exactly `ps` bytes (low-endian).
  /// Mirrors `Layout.setChild`'s dispatch table but parameterised by an
  /// arbitrary pointer width, so it can write the *new* width into a
  /// region still otherwise indexed by the old width.
  func writePointerN(region : Region.Region, ps : Nat, offset : Nat64, value : Nat64) {
    if (ps == 2) {
      region.storeNat16(offset, nat32to16(nat64to32(value)));
    } else if (ps == 4) {
      region.storeNat32(offset, nat64to32(value));
    } else if (ps == 3) {
      region.storeNat16(offset, nat32to16(nat64to32(value & 0xffff)));
      region.storeNat8(offset +% 2, natWrap8(nat64toNat(value >> 16)));
    } else if (ps == 5) {
      region.storeNat32(offset, nat64to32(value & 0xffff_ffff));
      region.storeNat8(offset +% 4, natWrap8(nat64toNat(value >> 32)));
    } else if (ps == 6) {
      region.storeNat32(offset, nat64to32(value & 0xffff_ffff));
      region.storeNat16(offset +% 4, nat32to16(nat64to32(value >> 32)));
    } else if (ps == 8) {
      region.storeNat64(offset, value);
    } else {
      // ps == 1
      region.storeNat8(offset, natWrap8(nat64toNat(value)));
    };
  };
};
