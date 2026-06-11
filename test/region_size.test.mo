// @testmode wasi
//
// Exact Region page counts at page-boundary configurations.
//
// Both regions are read with branch-free 8-byte masked loads in hot paths
// (`Layout.getChild` for node child pointers, `LinkedList.pop` for
// free-list chain links). Region loads are bounds-checked, so the region
// must always extend at least 8 bytes past the *offset* of the last slot
// that can be loaded — equivalently, `8 - item_size` bytes past the end
// of the used area (when the item is narrower than 8 bytes).
//
// For the nodes region this is the `padding = 8 - pointer_size` reserved
// by the constructor. For the leaves region the analogous slack is
// `8 - leaf_size` (only when `leaf_size < 8`), reserved at page-grow time
// in `newLeaf` — a freed leaf's chain link is loaded 8 bytes wide by
// `LinkedList.pop` no matter how narrow the leaf is.

import Blob "mo:core/Blob";
import Nat8 "mo:core/Nat8";
import Nat_ "mo:core/Nat";

import Map "../src/Map";

// 2-byte keys [i, i]: distinct in their low 13 bits and in their high 13
// bits for i < 32, so they hit distinct root slots regardless of which
// end of the key the root index is taken from — no internal nodes get
// allocated, keeping the nodes page count deterministic.
func k2(i : Nat) : Blob = Blob.fromArray([Nat8.fromNat(i), Nat8.fromNat(i)]);

func k4(i : Nat) : Blob = Blob.fromArray([
  Nat8.fromNat(i % 256),
  Nat8.fromNat((i / 256) % 256),
  0,
  0,
]);

// ─── Nodes region: root exactly one page, pointer_size = 8 ────────────────
//
// root_size = 8192 * 8 = 65536 = exactly one page, and padding =
// 8 - pointer_size = 0. The constructor must allocate exactly 1 page —
// 2 would be an off-by-one in the ceiling division.

do {
  let m = Map.empty({
    pointer_size = 8;
    aridity = 2;
    root_aridity = ?8192;
    key_size = 2;
    value_size = 0;
  });
  assert m.memoryStats().nodes_region_pages == 1;

  // The 8-byte load of the last root slot (offset 65528) ends exactly at
  // the page boundary — legal. Reads and writes work.
  for (i in Nat_.range(0, 10)) {
    m.add(k2(i), "");
  };
  for (i in Nat_.range(0, 10)) {
    assert m.get(k2(i)) == ?("" : Blob);
  };
  assert m.memoryStats().nodes_region_pages == 1;
};

// ─── Nodes region: root exactly one page, pointer_size = 4 ────────────────
//
// root_size = 4**7 * 4 = 65536 = exactly one page, BUT the page count is
// 2, not 1 — and that is correct, not an off-by-one: `getChild` reads
// every child pointer with an 8-byte masked load, so reading the *last*
// root slot (offset 65532) touches bytes 65532..65539, four bytes past
// the page end. The constructor reserves `padding = 8 - pointer_size = 4`
// bytes after the root for exactly this reason, pushing the allocation to
// 65540 bytes → 2 pages. (The ps=8 block above, where padding = 0, pins
// the off-by-one-free behavior of the ceiling division itself.)

do {
  let m = Map.empty({
    pointer_size = 4;
    aridity = 4;
    root_aridity = ?16384;
    key_size = 2;
    value_size = 0;
  });
  assert m.memoryStats().nodes_region_pages == 2;

  for (i in Nat_.range(0, 10)) {
    m.add(k2(i), "");
  };
  for (i in Nat_.range(0, 10)) {
    assert m.get(k2(i)) == ?("" : Blob);
  };
  assert m.memoryStats().nodes_region_pages == 2;
};

// ─── Leaves region: exact page fill, leaf_size = 8 ────────────────────────
//
// leaf_size = key + value = 8, so 8192 leaves fill one page exactly and
// no slack is needed: the chain-link load of the last leaf (offset 65528)
// ends exactly at the page boundary. Exactly 1 page — 2 would be an
// off-by-one in the growth check.

do {
  let m = Map.empty({
    pointer_size = 4;
    aridity = 4;
    root_aridity = null;
    key_size = 4;
    value_size = 4;
  });
  for (i in Nat_.range(0, 8192)) {
    m.add(k4(i), k4(i));
  };
  assert m.memoryStats().leaves_region_pages == 1; // exact fit

  // Free the page's last leaf (offset 65528) with another free-list entry
  // beneath it, then re-add: the pop loads the chain link at 65528..65535
  // — boundary-exact, legal, no growth.
  assert m.delete(k4(0));
  assert m.delete(k4(8191)); // top of free-list stack
  m.add(k4(20_000), k4(20_000)); // pops leaf 8191
  m.add(k4(20_001), k4(20_001)); // pops leaf 0
  assert m.memoryStats().leaves_region_pages == 1;
  assert m.get(k4(20_000)) == ?k4(20_000);
  assert m.get(k4(20_001)) == ?k4(20_001);

  // Next add has no free leaves and no free space — second page.
  m.add(k4(20_002), k4(20_002));
  assert m.memoryStats().leaves_region_pages == 2;
};

// ─── Leaves region: leaf_size = 4 < 8 — chain-link load needs slack ──────
//
// leaf_size = max(key + value, pointer_size) = 4. A freed leaf's chain
// link is read with an 8-byte load, so the leaf at offset 65532 (the
// 16384th) needs the region to extend 4 bytes past the page end —
// analogous to the nodes region's padding. `newLeaf` reserves
// 8 - leaf_size = 4 slack bytes out of every new page, so page 1 holds
// 16383 leaves and the 16384th allocation grows the region.
//
// Without the slack this block traps with "region access out of bounds"
// at the re-add below: pop of leaf 16383 loads bytes 65532..65539 from a
// one-page (65536-byte) region.

do {
  let m = Map.empty({
    pointer_size = 4;
    aridity = 4;
    root_aridity = null;
    key_size = 4;
    value_size = 0;
  });
  for (i in Nat_.range(0, 16_383)) {
    m.add(k4(i), "");
  };
  assert m.memoryStats().leaves_region_pages == 1; // 16383 * 4 = 65532 + 4 slack

  m.add(k4(16_383), ""); // leaf 16383 at offset 65532 — grows to 2 pages
  assert m.memoryStats().leaves_region_pages == 2;

  // Put the boundary leaf on the free list with an entry beneath it, then
  // re-add: pop loads the chain link at 65532..65539 — in bounds thanks
  // to the slack page.
  assert m.delete(k4(100));
  assert m.delete(k4(16_383)); // top of free-list stack
  m.add(k4(20_000), ""); // pops leaf 16383: the load that used to trap
  m.add(k4(20_001), ""); // pops leaf 100
  assert m.memoryStats().leaves_region_pages == 2;
  assert m.get(k4(20_000)) == ?("" : Blob);
  assert m.get(k4(20_001)) == ?("" : Blob);
  assert m.get(k4(100)) == null;
  assert m.size() == 16_384;
};
