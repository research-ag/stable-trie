# Stable-trie changelog

## 0.1.0

### Breaking changes

- `Map` and `Enumeration` are now plain records, not classes. Construct
  with `Map.empty(args)` / `Enumeration.empty(args)` instead of
  `Map(args)` / `Enumeration(args)`. Calls on the resulting value
  (`m.put(k, v)`, `e.add(k, v)`, etc.) continue to work via Motoko's
  dot-notation resolution to module-level functions.
- `Map` and `Enumeration` are type aliases for the underlying
  `StableTrie` record. The record's fields are all stable types, so a
  `Map` or `Enumeration` value can be declared as a `stable var`
  directly in a persistent actor.
- Removed `type StableData`, `share()`, `unshare()` from `Map`,
  `Enumeration`, and the underlying trie module. They're no longer
  needed — declare the value as `stable var` instead. **The stable-data
  shape from 0.0.8 cannot be loaded by 0.1.0**; existing canisters
  cannot upgrade to 0.1.0 without a migration of their persisted
  state.
- Added `Enumeration.removeLast()` that pops the most-recently-added
  entry and returns `?(key, value)` (or `null` if empty). Internal
  trie nodes that become empty are reclaimed and reused on the next
  `add`. The leaves region is also reused LIFO so the bench/runtime
  footprint doesn't grow under add/undo workloads.
- Added `Map.remove(key)` (returning the removed `?value`) and
  `Map.delete(key)` (discarding it). The trie collapses internal nodes
  with a single leaf child, returning freed node slots to a free list
  for reuse by the next `put`.

### Internals

- Restructured the internal layer: `internal/trie.mo` (algorithm),
  `internal/layout.mo` (record shape + read/write helpers),
  `internal/iter.mo` (iterator), `internal/linked-list.mo` (free
  list). The `Base` import alias was renamed to `Trie`.
- Eager-allocation: regions are created in `empty()` rather than on
  first write. Removes the lazy-init Option wrapper from the record.
- Dropped the per-region wrapper record (`{ region; var freeSpace }`)
  in favor of four flat fields on the trie record. Skips one
  indirection on every read/write.
- setChild now dispatches via an if-else cascade on `pointer_size`
  (ordered 2 → 4 → 5 → 6 → 8), replacing the previous array-indexed
  function-pointer table. `storeFuncIndex` field removed.
- Inlined the small layout helpers (`getNodeOffset`, `getLeafOffset`,
  `getNodeBase`) into their callers; `moc` doesn't auto-inline them.

### Dependencies

- Bumped `core` from `2.0.0` to `2.5.0`.
- Bumped dev-dependency `prng` from `0.0.9` to `0.2.0` (static API
  variant — affects bench/test code only).

## 0.0.8

- Bump core dependency to 2.5.0
- Fix README errors

## 0.0.7

- Use bench-helper package
- Bump core dependency

## 0.0.6

- Bump core dependency
- Simplify bench code (needs mops >= 2.1.0)

## 0.0.5

- Fix potential underflow trap in memoryStats
- Improve benchmark accuracy
- Add documentation
- Update dependencies
- Organize code into internal/ directory

## 0.0.4

- Optimise instructions and heap usage

## 0.0.3

- Switch from base to core 2.0.0

## 0.0.2

- Improve performance
- Leverage Blob random index from moc 0.14.8

## 0.0.1

- Initial version
