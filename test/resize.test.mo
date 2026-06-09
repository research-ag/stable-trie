// @testmode wasi
//
// Incremental pointer-size resize: shrink 4 → 2, grow back 2 → 4. Verify
// all entries readable after each migration.

import Blob "mo:core/Blob";
import Iter "mo:core/Iter";
import Nat8 "mo:core/Nat8";
import Nat_ "mo:core/Nat";

import Map "../src/Map";

func keyOf(i : Nat) : Blob = Blob.fromArray([
  Nat8.fromNat(i % 256),
  Nat8.fromNat((i / 256) % 256),
  Nat8.fromNat((i / 65536) % 256),
  Nat8.fromNat((i / 16777216) % 256),
]);

func valueOf(i : Nat) : Blob = Blob.fromArray([
  Nat8.fromNat(i % 256),
  Nat8.fromNat((i / 256) % 256),
  Nat8.fromNat((i / 65536) % 256),
  Nat8.fromNat((i / 16777216) % 256),
]);

// Drive an incremental resize to completion with a given batch size, so we
// exercise stepResize being called multiple times.
func resize(m : Map.Map, new_ps : Nat, batch : Nat) : Map.Map {
  let state = switch (m.beginResize(new_ps)) {
    case (?s) s;
    case null { assert false; loop {} };
  };
  var done = false;
  while (not done) {
    done := Map.stepResize(state, batch);
  };
  Map.completeResize(state);
};

// ─── Round-trip: pointer_size = 4 → 2 → 4 ────────────────────────────────

var m : Map.Map = Map.empty({
  pointer_size = 4;
  aridity = 4;
  root_aridity = null;
  key_size = 4;
  value_size = 4;
});

let N = 200;
for (i in Nat_.range(0, N)) {
  m.add(keyOf(i), valueOf(i));
};
assert m.size() == N;

// Shrink to pointer_size = 2 in batches of 7 (forces multiple stepResize calls).
m := resize(m, 2, 7);

assert m.size() == N;
for (i in Nat_.range(0, N)) {
  assert m.get(keyOf(i)) == ?valueOf(i);
};

// New writes after shrink.
m.add(keyOf(N), valueOf(N));
assert m.size() == N + 1;
assert m.get(keyOf(N)) == ?valueOf(N);

// Deletes work after shrink (exercises empty_nodes_list + new layout).
assert m.delete(keyOf(0));
assert m.get(keyOf(0)) == null;
m.add(keyOf(0), valueOf(0));

// Grow back to pointer_size = 4 in batches of 11.
m := resize(m, 4, 11);

assert m.size() == N + 1;
for (i in Nat_.range(0, N + 1)) {
  assert m.get(keyOf(i)) == ?valueOf(i);
};

m.add(keyOf(N + 1), valueOf(N + 1));
assert m.size() == N + 2;
assert m.get(keyOf(N + 1)) == ?valueOf(N + 1);

// Iteration still yields N+2 entries.
do {
  let entries = Iter.toArray(m.entries());
  assert entries.size() == N + 2;
};

// ─── Refusal cases ─────────────────────────────────────────────────────────

// Helper — `?Map.ResizeState` isn't `==`-comparable (record has a `var`).
func refused(s : ?Map.ResizeState) : Bool = switch s {
  case null true;
  case _ false;
};

assert refused(m.beginResize(4)); // no-op (same pointer_size)
assert refused(m.beginResize(3)); // invalid
assert refused(m.beginResize(7)); // invalid
assert refused(m.beginResize(0)); // invalid
