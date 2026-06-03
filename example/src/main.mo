/// Example canister: stores user Principals in an `Enumeration` and
/// exposes the trie's `memoryStats` as Prometheus metrics via
/// `promtracker`.
///
/// Endpoints:
///   - update register()   — signs the caller up; no-op if already present
///   - query  isRegistered() — whether the caller has signed up
///   - query  size()       — number of registered users
///   - query  http_request — exposed by the `Http` mixin; serves `/metrics`
///
/// The 4 trie metrics are bundled into a single pull `Value` so the
/// `memoryStats()` call happens once per scrape (rather than four times
/// if we used four separate `newValue` registrations).

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Nat8 "mo:core/Nat8";
import Principal "mo:core/Principal";

import PT "mo:promtracker";
import Http "mo:promtracker/mixins/http";

import Enumeration "mo:stable-trie/Enumeration";

persistent actor Main {

  // ─── Storage ──────────────────────────────────────────────────────────
  //
  // Principal blobs are variable length (1..29 bytes for valid IC
  // principals). The trie needs a fixed-width key, so we encode each
  // principal as:
  //
  //   [length_byte]  [principal_bytes…]  [zero padding to 30 bytes]
  //
  // The leading length byte rules out collisions between principals of
  // different lengths whose prefixes match.

  let signups : Enumeration.Enumeration = Enumeration.empty({
    pointer_size = 4; // up to 2^31 entries
    aridity = 4;
    root_aridity = null;
    key_size = 30;
    value_size = 0; // a set: every registered principal carries no payload
  });

  func encodePrincipal(p : Principal) : Blob {
    let pb = Principal.toBlob(p);
    let n = pb.size();
    assert n <= 29;
    Blob.fromArray(
      Array.tabulate<Nat8>(
        30,
        func(i) {
          if (i == 0) Nat8.fromNat(n) else if (i <= n) pb[i - 1] else 0;
        },
      )
    );
  };

  // ─── Public API ───────────────────────────────────────────────────────

  /// Sign the caller up. Returns the caller's insertion-order index
  /// (the same value on subsequent calls).
  public shared ({ caller }) func register() : async Nat {
    signups.add(encodePrincipal(caller), "");
  };

  /// Whether the caller has signed up.
  public shared query ({ caller }) func isRegistered() : async Bool {
    signups.containsKey(encodePrincipal(caller));
  };

  /// Number of registered principals.
  public query func size() : async Nat {
    signups.size();
  };

  // ─── Metrics ──────────────────────────────────────────────────────────

  transient let renderer = PT.Renderer();

  // Custom Value that reads all four `memoryStats` fields in one go.
  // Same shape as `PT.allSystemMetrics`: an object with a `read()` that
  // returns `[(name, labels, value)]`. Calling memoryStats() once per
  // scrape (instead of once per metric) is a one-line micro-optimisation
  // but it also keeps the four numbers strictly consistent — they're
  // sampled from the same snapshot.
  transient let trieMetrics : {
    read : () -> [(Text, Text, Nat)];
  } = {
    read = func() {
      let s = signups.memoryStats();
      [
        ("stable_trie_used_node_count", "", s.used_node_count),
        ("stable_trie_used_leaf_count", "", s.used_leaf_count),
        ("stable_trie_byte_size", "", s.byte_size),
        ("stable_trie_total_node_count", "", s.total_node_count),
        ("stable_trie_total_leaf_count", "", s.total_leaf_count),
      ];
    };
  };

  renderer.addValue(trieMetrics);
  renderer.addValue(PT.allSystemMetrics);
  renderer.addCanisterLabel(Main);

  // Serves Prometheus exposition on GET /metrics.
  include Http(renderer.renderExposition, "/metrics");
};
