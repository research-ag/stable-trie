# Stable-trie changelog

## 0.2.0

API rename to align with `mo:core/Map` and `mo:core/List` conventions.

`Map` (writes — all by key):

- `add(k, v) : ()` — always writes; fire-and-forget.
- `insert(k, v) : Bool` — always writes; `true` if key was new.
- `swap(k, v) : ?V` — always writes; returns previous value.
- `replace(k, v) : ?V` — writes ONLY if key already present; returns `?prev` or `null`.
- `getOrAdd(k, v) : ?V` — writes ONLY if key absent; returns `?prev` or `null`.
- Each has a `*Checked` Result variant, except `replace` (cannot overflow).

`Map` (reads, removal, queries):

- `get(k) : ?V` — unchanged.
- `containsKey(k) : Bool` — new.
- `isEmpty() : Bool` — new.
- `remove(k) : ()` — silent removal.
- `delete(k) : Bool` — new; returns whether key was present.
- `take(k) : ?V` — returns previous value (the only path that reads the leaf's value blob).

`Map` (iteration — renamed to match `mo:core/Map`):

- `vals` → `values`, `valsRev` → `reverseValues`.
- `entriesRev` → `reverseEntries`, `keysRev` → `reverseKeys`.

`Map` renames from 0.1.0:

- `put` → `add`.
- `replace` (`?V`, always-write) → `swap`.
- `getOrPut` → `getOrAdd`.
- `remove` (`?V`) → `take`.
- `delete` (silent) → `remove`. (And `delete` is a new function returning `Bool`.)

`Enumeration` (writes — all by key; index folded into the return):

- `add(k, v) : Nat`.
- `insert(k, v) : (Bool, Nat)`.
- `lookupOrAdd(k, v) : (?V, Nat)`.
- `put(i, v) : ()` — new; by-index O(1) value overwrite, traps on OOB.

`Enumeration` (reads):

- `lookup(k) : ?(V, Nat)` — by key, unchanged.
- `containsKey(k) : Bool` — new.
- `isEmpty() : Bool` — new.
- `get(i) : ?(K, V)` — by index, Option (mirrors `mo:core/List.get`).
- `at(i) : (K, V)` — by index, trapping (mirrors `mo:core/List.at`).
- `sliceToArray(l, r) : [(K, V)]` — renamed from `slice` (mirrors `mo:core/List.sliceToArray`). Also fixes a bug in the 0.0.8/0.1.0 `slice`: it returned entries from indices `[0, r-l)` instead of `[l, r)`, so any call with `l > 0` was wrong. Tests in 0.0.8/0.1.0 only exercised `slice(0, n)` so this slipped through.
- `range(l, r) : Iter<(K, V)>` — new; lazy index-order iter (mirrors `mo:core/List.range`).

`Enumeration` (iteration — renamed to match `mo:core/List`):

- `vals` → `values`, `valsRev` → `reverseValues`.
- `entriesRev` → `reverseEntries`, `keysRev` → `reverseKeys`.

`Enumeration` (removal):

- `removeLast() : ?(K, V)` — unchanged.
- `truncate(newSize : Nat) : ()` — new; bulk pop, mirrors `mo:core/List.truncate`.

`Enumeration` renames from 0.1.0:

- `lookupOrPut` → `lookupOrAdd`.
- `replace` is dropped — compose `lookup` + `put` instead (by-index writes are O(1), no separate primitive needed).

`swap` and `replace` are intentionally absent from Enumeration for the same reason.

Internals:

- `internal/trie.mo`: new `contains(self, key) : Bool` primitive that skips the value-blob allocation `lookup` would do.
- `internal/trie.mo`: `removeRec` now returns `(?Blob, Bool, Nat64)` — value, was-removed, new-branch-root — so `delete` can answer "was it there?" without the value `loadBlob` that `take` needs. Recursive logic and node-collapse behaviour otherwise identical to 0.0.8.
- `internal/linked-list.mo`: drop the `storeFuncIndex` array dispatch in favour of an if-else cascade on `pointer_size` (ordered 2 → 4 → 5 → 6 → 8), mirroring the same refactor previously done to `layout.mo`'s `setChild`.

Developer-facing:

- Examples in `README.md` are now pinned by `test/readme_map.test.mo` and `test/readme_enum.test.mo` so they stay in lock-step with the actual API.
- README header credits: main authors Andrii Stepanov + Timo Hanke; contributor Andy Gura.
- Copyright bumped to 2023 – 2026.

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
