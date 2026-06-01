# Stable-trie changelog

## 0.2.0

API rename to align with `mo:core/Map` and `mo:core/List` conventions.

Map renames from 0.1.0: `put` → `add`, `replace` (`?V`, always-write) → `swap`, `getOrPut` → `getOrAdd`, `remove` (`?V`) → `take`, `delete` (silent) → `remove`. Iteration: `vals` → `values`, `valsRev` → `reverseValues`, `entriesRev` → `reverseEntries`, `keysRev` → `reverseKeys`.

Map new functions: `insert(k, v) : Bool` (returns "was new"), `replace(k, v) : ?V` (writes only if present), `delete(k) : Bool` (returns "was present"), `containsKey(k) : Bool`, `isEmpty() : Bool`.

Enumeration renames from 0.1.0: `slice` → `sliceToArray`, `lookupOrPut` → `lookupOrAdd`. Iteration: same renames as Map.

Enumeration new functions: `insert(k, v) : (Bool, Nat)`, `put(i, v) : ()` (O(1) by-index value overwrite, traps on OOB), `at(i) : (K, V)` (trapping by-index read), `range(l, r) : Iter<(K, V)>` (lazy index-order iter), `truncate(newSize) : ()` (bulk pop), `containsKey`, `isEmpty`.

Enumeration dropped: `replace` (compose `lookup` + `put` instead — by-index writes are O(1) so no separate primitive is needed).

Each write op that can hit pointer-size overflow has a `*Checked` Result variant; `replace` (Map) and the by-index writes can't overflow so they don't.

Bug fix: `sliceToArray` (formerly `slice`) correctly returns entries from indices `[l, r)`. In 0.0.8/0.1.0 the function returned entries from `[0, r-l)`, so any call with `l > 0` returned wrong data. The 0.0.8/0.1.0 tests only exercised `slice(0, n)` so it went unnoticed.

## 0.1.0

- Rewrite of `Map` and `Enumeration` as static records, not classes, that can be declared stable.
- New constructors called `empty()`.
- New function `Enumeration.removeLast()` that deletes the most-recently-added entry
- Bumped `core` dependency to `2.5.0`.

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
