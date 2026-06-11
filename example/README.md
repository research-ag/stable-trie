# Example: `Enumeration` of user Principals + Promtracker metrics

A minimal canister that signs users up by `caller` Principal and exposes the underlying trie's memory stats as Prometheus metrics.

## What this shows

- Using `Enumeration` as a **set** of `Principal`s (`value_size = 0`) — `add` is idempotent and returns the entry's insertion-order index.
- Encoding variable-length `Principal` blobs into a fixed-width 30-byte trie key (`[length_byte] [principal_bytes…] [zero_pad]`).
- Exposing the trie's `memoryStats()` via [`promtracker`](https://github.com/research-ag/promtracker) — `Enumeration.toValue()` returns a pull `Value` that calls `memoryStats()` once per scrape and emits twelve samples in five named metric families: the configuration constants, the used/total node and leaf counts, the byte size, and the region page counts.

## Exposed metrics

Served as Prometheus exposition on `GET /metrics`:

| metric                                          | source                               |
| ----------------------------------------------- | ------------------------------------ |
| `stable_trie_constant{constant="pointer_size"}` | constructor `pointer_size`           |
| `stable_trie_constant{constant="value_size"}`   | constructor `value_size`             |
| `stable_trie_constant{constant="key_size"}`     | constructor `key_size`               |
| `stable_trie_constant{constant="aridity"}`      | constructor `aridity`                |
| `stable_trie_constant{constant="root_aridity"}` | constructor `root_aridity`, resolved |
| `stable_trie_node_count{kind="total"}`          | `memoryStats().total_node_count`     |
| `stable_trie_leaf_count{kind="total"}`          | `memoryStats().total_leaf_count`     |
| `stable_trie_node_count{kind="used"}`           | `memoryStats().used_node_count`      |
| `stable_trie_leaf_count{kind="used"}`           | `memoryStats().used_leaf_count`      |
| `stable_trie_byte_size`                         | `memoryStats().byte_size`            |
| `stable_trie_region_pages{type="nodes"}`        | `memoryStats().nodes_region_pages`   |
| `stable_trie_region_pages{type="leaves"}`       | `memoryStats().leaves_region_pages`  |

The used/total split is exposed via a `kind` label on `stable_trie_node_count` and `stable_trie_leaf_count`, so Prometheus queries can `sum by (kind)` or filter with `{kind="used"}` directly. The two region page counts share the `stable_trie_region_pages` family, split by a `type` label, and the five configuration constants share the `stable_trie_constant` family, split by a `constant` label. `{constant="root_aridity"}` reports the resolved value — equal to `{constant="aridity"}` when `null` was passed to the constructor.

Plus `PT.allSystemMetrics` (cycles balance, RTS memory, etc.).

## Public API

- `register() : async Nat` — signs the caller up; returns the caller's insertion-order index. Idempotent (subsequent calls return the same index).
- `isRegistered() : async Bool` — whether the caller has signed up.
- `size() : async Nat` — number of registered principals.
- `http_request` — exposes `/metrics` via the `Http` mixin.

## Build

```bash
mops install
mops build
```

The compiled `example.wasm` lands in `.mops/.build/`. Wire it up with `dfx` or the playground from there.
