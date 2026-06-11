// @testmode wasi
//
// Coverage for `memoryStats()` (region-pages fields, page growth/
// monotonicity) and `toValue()` (full metric-tuple snapshot, including
// labels). Pins down semantics that were previously only implied by
// equality checks on memoryStats elsewhere in the suite.

import Blob "mo:core/Blob";
import Nat8 "mo:core/Nat8";
import Nat_ "mo:core/Nat";

import Map "../src/Map";

func k4(i : Nat) : Blob = Blob.fromArray([
  Nat8.fromNat(i % 256),
  Nat8.fromNat((i / 256) % 256),
  0,
  0,
]);

// ─── memoryStats: region pages on a fresh trie ────────────────────────────
//
// Layout: pointer_size = 4, aridity = 4, root_aridity = null (= 4),
// key_size = 4, value_size = 4.
//   root_size  = root_aridity * pointer_size = 16 bytes
//   node_size  = aridity * pointer_size      = 16 bytes
//   padding    = 8 - pointer_size            = 4 bytes
//   leaf_size  = max(key + value, ps)        = 8 bytes
// The nodes region is grown eagerly in `Trie.empty` to fit root_size +
// padding (20 bytes → 1 page). The leaves region is lazily grown on
// first add.

do {
  let m = Map.empty({
    pointer_size = 4;
    aridity = 4;
    root_aridity = null;
    key_size = 4;
    value_size = 4;
  });

  let s0 = m.memoryStats();
  assert s0.nodes_region_pages == 1; // root + padding fit in one 64KB page
  assert s0.leaves_region_pages == 0; // lazy
  assert s0.used_leaf_count == 0;
  assert s0.used_node_count == 1; // just the root
  assert s0.total_leaf_count == 0;
  assert s0.total_node_count == 1;

  // First add — leaves region grows to one page.
  m.add(k4(0), k4(0));
  let s1 = m.memoryStats();
  assert s1.leaves_region_pages == 1;
  assert s1.nodes_region_pages == 1;
  assert s1.used_leaf_count == 1;

  // 100 more adds — pointer_size=4 with key+value=8 means 8192 leaves
  // per page (and ~4096 nodes per page). Well below both → page counts
  // stay at 1.
  for (i in Nat_.range(1, 101)) {
    m.add(k4(i), k4(i));
  };
  let s2 = m.memoryStats();
  assert s2.nodes_region_pages == 1;
  assert s2.leaves_region_pages == 1;

  // ─── Regions never shrink ────────────────────────────────────────────────

  // Delete half the entries. used_* drops; total_* and the region pages
  // stay put.
  for (i in Nat_.range(0, 50)) {
    ignore m.delete(k4(i));
  };
  let s3 = m.memoryStats();
  assert s3.used_leaf_count == s2.used_leaf_count - 50;
  assert s3.total_leaf_count == s2.total_leaf_count; // high-water unchanged
  assert s3.nodes_region_pages == s2.nodes_region_pages;
  assert s3.leaves_region_pages == s2.leaves_region_pages;

  // ─── Regions grow monotonically across multiple page boundaries ──────────

  // Add enough entries to force a second leaves page. leaf_size = 8, so
  // > 8192 entries fills more than one page.
  for (i in Nat_.range(101, 10_000)) {
    m.add(k4(i), k4(i));
  };
  let s4 = m.memoryStats();
  assert s4.leaves_region_pages > 1; // crossed the 8192-leaf boundary
  assert s4.leaves_region_pages >= s2.leaves_region_pages;
  assert s4.nodes_region_pages >= s2.nodes_region_pages;
};

// ─── memoryStats: byte_size derived from counters, not region pages ──────
//
// byte_size = root_size + (node_count - 1) * node_size + leaf_count * leaf_size.
// Page allocation is independent of (in general, larger than) byte_size:
// regions are grown in 64KB chunks regardless of how many bytes the
// trie actually addresses inside the chunk.

do {
  let m = Map.empty({
    pointer_size = 4;
    aridity = 4;
    root_aridity = null;
    key_size = 4;
    value_size = 4;
  });
  m.add(k4(0), k4(0));
  let s = m.memoryStats();
  // 16 (root) + 0 (no non-root nodes for a single-entry trie) + 8 (one leaf) = 24.
  assert s.byte_size == 24;
  // But the leaves region is one full 64KB page (lazy first allocation).
  assert s.leaves_region_pages == 1;
};

// ─── toValue: full metric snapshot ────────────────────────────────────────
//
// Confirms every (name, labels, value) tuple emitted by toValue, in order.
// Pins the schema so a future change to the metrics array — or a
// copy-paste bug in one of the value expressions — fails the test loudly.

do {
  let m = Map.empty({
    pointer_size = 4;
    aridity = 4;
    root_aridity = null;
    key_size = 4;
    value_size = 4;
  });
  m.add(k4(0), k4(0));
  m.add(k4(1), k4(1));
  m.add(k4(2), k4(2));
  // Delete one to make used_* differ from total_* visibly.
  ignore m.delete(k4(1));

  let stats = m.memoryStats();
  let metrics = m.toValue().read();

  // 12 metrics: 5 config + 4 counts + byte_size + 2 region pages.
  assert metrics.size() == 12;

  let expected : [(Text, Text, Nat)] = [
    ("stable_trie_constant", "constant=\"pointer_size\"", 4),
    ("stable_trie_constant", "constant=\"value_size\"", 4),
    ("stable_trie_constant", "constant=\"key_size\"", 4), // catches the pointer_size copy-paste bug
    ("stable_trie_constant", "constant=\"aridity\"", 4),
    ("stable_trie_constant", "constant=\"root_aridity\"", 4), // null in empty() → defaults to aridity
    ("stable_trie_node_count", "kind=\"total\"", stats.total_node_count),
    ("stable_trie_leaf_count", "kind=\"total\"", stats.total_leaf_count),
    ("stable_trie_node_count", "kind=\"used\"", stats.used_node_count),
    ("stable_trie_leaf_count", "kind=\"used\"", stats.used_leaf_count),
    ("stable_trie_byte_size", "", stats.byte_size),
    ("stable_trie_region_pages", "type=\"nodes\"", stats.nodes_region_pages),
    ("stable_trie_region_pages", "type=\"leaves\"", stats.leaves_region_pages),
  ];

  var i = 0;
  while (i < 12) {
    assert metrics[i] == expected[i];
    i += 1;
  };

  // Sanity: distinct used and total leaf counts (delete created a divergence).
  assert stats.used_leaf_count == 2;
  assert stats.total_leaf_count == 3;
};

// ─── toValue: different config — confirms values track the trie ──────────

do {
  let m = Map.empty({
    pointer_size = 2;
    aridity = 16;
    root_aridity = ?256;
    key_size = 8;
    value_size = 0;
  });
  m.add("\01\00\00\00\00\00\00\00", "");

  let metrics = m.toValue().read();
  // First five metrics carry the config values; verify they match the
  // empty() args we passed (root_aridity explicit here, not defaulted).
  assert metrics[0] == ("stable_trie_constant", "constant=\"pointer_size\"", 2);
  assert metrics[1] == ("stable_trie_constant", "constant=\"value_size\"", 0);
  assert metrics[2] == ("stable_trie_constant", "constant=\"key_size\"", 8);
  assert metrics[3] == ("stable_trie_constant", "constant=\"aridity\"", 16);
  assert metrics[4] == ("stable_trie_constant", "constant=\"root_aridity\"", 256);
};

// ─── pointer_size = 3: layout sanity + metric tracking ────────────────────
//
// ps=3 uses a 2-byte + 1-byte split internally. Exercise that the trie is
// constructible, that adds/lookups/deletes work, and that the toValue
// pointer_size metric reflects the chosen width.

do {
  let m = Map.empty({
    pointer_size = 3;
    aridity = 4;
    root_aridity = null;
    key_size = 4;
    value_size = 4;
  });

  for (i in Nat_.range(0, 200)) {
    m.add(k4(i), k4(i));
  };
  assert m.size() == 200;
  for (i in Nat_.range(0, 200)) {
    assert m.get(k4(i)) == ?k4(i);
  };
  // Delete + re-add to exercise the leaves free list under ps=3
  // (leaf_size = max(8, 3) = 8 → 3-byte chain links fit).
  assert m.delete(k4(50));
  assert m.get(k4(50)) == null;
  m.add(k4(50), k4(50));
  assert m.get(k4(50)) == ?k4(50);

  let metrics = m.toValue().read();
  assert metrics[0] == ("stable_trie_constant", "constant=\"pointer_size\"", 3);
  assert metrics[1] == ("stable_trie_constant", "constant=\"value_size\"", 4);
  assert metrics[2] == ("stable_trie_constant", "constant=\"key_size\"", 4);
};
