# Example: `Enumeration` of user Principals + Promtracker metrics

A minimal canister that signs users up by `caller` Principal and exposes the underlying trie's memory stats as Prometheus metrics.

## What this shows

- Using `Enumeration` as a **set** of `Principal`s (`value_size = 0`) — `add` is idempotent and returns the entry's insertion-order index.
- Encoding variable-length `Principal` blobs into a fixed-width 30-byte trie key (`[length_byte] [principal_bytes…] [zero_pad]`).
- Wrapping `Enumeration.memoryStats()` as a single bundled [`promtracker`](https://github.com/research-ag/promtracker) pull `Value` so one scrape calls `memoryStats()` once and emits four consistent metrics.

## Exposed metrics

Served as Prometheus exposition on `GET /metrics`:

| metric                         | source                           |
| ------------------------------ | -------------------------------- |
| `stable_trie_used_node_count`  | `memoryStats().used_node_count`  |
| `stable_trie_used_leaf_count`  | `memoryStats().used_leaf_count`  |
| `stable_trie_byte_size`        | `memoryStats().byte_size`        |
| `stable_trie_total_node_count` | `memoryStats().total_node_count` |
| `stable_trie_total_leaf_count` | `memoryStats().total_leaf_count` |

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

## Why a bundled `Value` and not four `newValue` registrations

The four metrics come from a single record returned by `memoryStats()`. If we registered them as four separate `newValue` pull metrics, each scrape would call `memoryStats()` four times (and the four numbers could in principle drift if the trie mutates between calls — not a concern under IC's single-threaded execution, but it's a smell). Bundling them into one `Value` whose `read()` issues one `memoryStats()` call keeps the snapshot atomic and saves three calls per scrape.
