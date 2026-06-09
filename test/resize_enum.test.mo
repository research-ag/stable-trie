// @testmode wasi
//
// Incremental pointer-size resize for Enumeration.
//
// Enumeration differs from Map for the resize in two ways worth covering:
//
// - leaf_size = key_size + value_size (no Map-style padding).
// - removal goes through `removeLast` → leaf_count decrements directly
//   AND any collapsed internal nodes are pushed onto `empty_nodes_list`.
//   The leaves free list is never populated.

import Blob "mo:core/Blob";
import Nat8 "mo:core/Nat8";
import Nat_ "mo:core/Nat";

import Enumeration "../src/Enumeration";

let e = Enumeration.empty({
  pointer_size = 1;
  aridity = 4;
  root_aridity = null;
  key_size = 1;
  value_size = 1;
});

// Add 20 entries (well within ps=1's 128-leaf cap).
for (i in Nat_.range(0, 20)) {
  ignore e.add(Blob.fromArray([Nat8.fromNat(i)]), Blob.fromArray([Nat8.fromNat(i)]));
};

// removeLast a few times to populate empty_nodes_list (Enumeration's only
// free list — leaves are retracted via leaf_count, not pushed).
ignore e.removeLast();
ignore e.removeLast();
ignore e.removeLast();
assert e.size() == 17;
let stats_before = e.memoryStats();

// Grow 1 → 2.
var e_now : Enumeration.Enumeration = e;
do {
  let state = switch (e_now.beginResize(2)) {
    case (?s) s;
    case null { assert false; loop {} };
  };
  while (not Enumeration.stepResize(state, 4)) {};
  e_now := Enumeration.completeResize(state);
};
assert e_now.size() == 17;
for (i in Nat_.range(0, 17)) {
  assert e_now.lookup(Blob.fromArray([Nat8.fromNat(i)])) == ?(Blob.fromArray([Nat8.fromNat(i)]), i);
};
// Node free list survived the migration.
assert e_now.memoryStats().used_node_count == stats_before.used_node_count;

// Shrink 2 → 1.
do {
  let state = switch (e_now.beginResize(1)) {
    case (?s) s;
    case null { assert false; loop {} };
  };
  while (not Enumeration.stepResize(state, 4)) {};
  e_now := Enumeration.completeResize(state);
};
assert e_now.size() == 17;
for (i in Nat_.range(0, 17)) {
  assert e_now.lookup(Blob.fromArray([Nat8.fromNat(i)])) == ?(Blob.fromArray([Nat8.fromNat(i)]), i);
};

// New adds after the round-trip work, and the previously-freed internal
// nodes can be re-used.
ignore e_now.add(Blob.fromArray([Nat8.fromNat(50)]), Blob.fromArray([0]));
ignore e_now.add(Blob.fromArray([Nat8.fromNat(51)]), Blob.fromArray([0]));
assert e_now.size() == 19;

// ─── Refusal cases ─────────────────────────────────────────────────────────

func refused(s : ?Enumeration.ResizeState) : Bool = switch s {
  case null true;
  case _ false;
};

// Same-pointer-size: no-op refusal.
assert refused(e_now.beginResize(1));
// Invalid widths.
assert refused(e_now.beginResize(3));
assert refused(e_now.beginResize(0));
