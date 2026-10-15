// @testmode wasi
//
// Migration from stable-trie 0.1.1 → 0.1.2.
//
// Two things change between 0.1.1 and 0.1.2 from a persisted-state
// perspective:
//
// 1. `StableTrie` grew a new field `zero_leaf : Blob`. A 0.1.1 record has
//    no value for it, so a plain upgrade would fail.
// 2. The LinkedList invariant changed: items currently in
//    `empty_leaves_list` are now expected to be all-zero past their chain
//    link. 0.1.1 only wrote the chain link, leaving the deleted leaf's
//    key/value bytes as stale tail data.
//
// `Map.migrate_0_1_1` handles both — attaches `zero_leaf` and, if the
// list is non-empty, walks it once to zero out the stale tail bytes.

import Blob "mo:core/Blob";
import Nat8 "mo:core/Nat8";
import Nat_ "mo:core/Nat";
import _Region "mo:core/Region"; // enables `region.storeBlob(...)` dot notation

import Map "../src/Map";

// Helper — view a real 0.1.2 Map as a 0.1.1-shaped record. Used in tests
// to feed the migration a value that has all the 0.1.1 fields but lacks
// `zero_leaf`. Regions and LinkedList instances are SHARED with the
// original Map (no copy); the var fields are snapshotted (independent).
func downgrade(m : Map.Map) : Map.Map_0_1_1 = {
  pointer_size = m.pointer_size;
  key_size = m.key_size;
  value_size = m.value_size;
  aridity_ = m.aridity_;
  key_size_ = m.key_size_;
  pointer_size_ = m.pointer_size_;
  root_aridity_ = m.root_aridity_;
  loadMask = m.loadMask;
  bitlength = m.bitlength;
  bitshift = m.bitshift;
  max_address = m.max_address;
  max_chain_depth = m.max_chain_depth;
  safe_node_bound = m.safe_node_bound;
  root_bitlength_ = m.root_bitlength_;
  root_bitlength = m.root_bitlength;
  node_size = m.node_size;
  node_size_ = m.node_size_;
  leaf_size = m.leaf_size;
  root_size = m.root_size;
  offset_base = m.offset_base;
  padding = m.padding;
  empty_values = m.empty_values;
  empty_nodes_list = m.empty_nodes_list;
  empty_leaves_list = m.empty_leaves_list;
  var leaf_count = m.leaf_count;
  var node_count = m.node_count;
  var nodes_region = m.nodes_region;
  var nodes_freeSpace = m.nodes_freeSpace;
  var leaves_region = m.leaves_region;
  var leaves_freeSpace = m.leaves_freeSpace;
};

func key4(i : Nat) : Blob = Blob.fromArray([Nat8.fromNat(i), 0, 0, 0]);

// ─── Basic migration: empty free lists ────────────────────────────────────

do {
  let m = Map.empty({
    pointer_size = 4;
    aridity = 4;
    root_aridity = null;
    key_size = 4;
    value_size = 4;
  });
  for (i in Nat_.range(0, 20)) {
    m.add(key4(i), key4(i));
  };

  let migrated = Map.migrate_0_1_1(downgrade(m));

  // All 20 entries readable.
  assert migrated.size() == 20;
  for (i in Nat_.range(0, 20)) {
    assert migrated.get(key4(i)) == ?key4(i);
  };
  // Add / delete still work.
  migrated.add(key4(99), key4(99));
  assert migrated.get(key4(99)) == ?key4(99);
  assert migrated.delete(key4(0));
  assert migrated.get(key4(0)) == null;
};

// ─── Migration with a non-empty empty_leaves_list ─────────────────────────

do {
  let m = Map.empty({
    pointer_size = 4;
    aridity = 4;
    root_aridity = null;
    key_size = 4;
    value_size = 4;
  });
  // leaf_size = max(4 + 4, 4) = 8; pointer_size = 4 → tail bytes = [4, 8).
  for (i in Nat_.range(0, 20)) {
    m.add(key4(i), key4(i));
  };
  assert m.delete(key4(5));
  assert m.delete(key4(7));
  assert m.delete(key4(9));
  let live = m.size();
  assert live == 17;
  assert m.empty_leaves_list.count == 3;

  // Manually overwrite the head freed leaf's tail bytes to simulate the
  // stale state that 0.1.1's push left behind. (0.1.2's `Map.removeRec`
  // zeros the leaf before push, so the head currently has zeros there.)
  let head_index = m.empty_leaves_list.last_empty_item;
  let slot_offset : Nat64 = head_index * m.leaf_size;
  let stale_tail = Blob.fromArray([
    Nat8.fromNat(0xff),
    Nat8.fromNat(0xee),
    Nat8.fromNat(0xdd),
    Nat8.fromNat(0xcc),
  ]);
  m.leaves_region.storeBlob(slot_offset + 4, stale_tail); // [4, 8)

  // Snapshot the chain link before migration so we can prove it's preserved.
  let chain_link_before = m.leaves_region.loadNat64(slot_offset) & m.loadMask;

  let migrated = Map.migrate_0_1_1(downgrade(m));

  // Chain link preserved.
  let chain_link_after = migrated.leaves_region.loadNat64(slot_offset) & migrated.loadMask;
  assert chain_link_before == chain_link_after;
  // Tail bytes zeroed by the migration walk.
  let tail = migrated.leaves_region.loadBlob(slot_offset + 4, 4);
  assert tail == Blob.fromArray([0, 0, 0, 0] : [Nat8]);

  // Functional checks: all 17 surviving entries still readable, deleted
  // keys still gone.
  assert migrated.size() == 17;
  for (i in Nat_.range(0, 20)) {
    if (i == 5 or i == 7 or i == 9) {
      assert migrated.get(key4(i)) == null;
    } else {
      assert migrated.get(key4(i)) == ?key4(i);
    };
  };

  // Adding three new keys reuses the freed slots from the migrated free
  // list — leaf_count high-water unchanged.
  let high_water = migrated.leaf_count;
  migrated.add(key4(30), key4(30));
  migrated.add(key4(31), key4(31));
  migrated.add(key4(32), key4(32));
  assert migrated.leaf_count == high_water;
  assert migrated.size() == 20;
};
