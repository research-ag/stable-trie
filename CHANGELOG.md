# Stable-trie changelog

## Next

- Add `nodes_region_pages` and `leaves_region_pages` fields to `MemoryStats`
- Expose those plus `pointer_size` / `key_size` / `value_size` as Prometheus metrics in `toValue`

## 0.1.2

- In-place ability to change the pointer-size (see README)
- **Breaking**: Internal representation is not compatible with 0.1.1

## 0.1.1

- Add promtracker integration with `toValue` function
- Unify `memoryStats()` output across Enumeration and Map
- Add `example/` directory

## 0.1.0

- Rewrite of `Map` and `Enumeration` as static records, not classes, that can be declared stable.
- Re-design `Map` API to align with conventions from core/Map
- Re-design `Enumeration` API to align with conventions from core/List
- New functions `removeLast(), truncate()` to delete highest-index elements in `Enumeration`
- Bugfix in `Enumeration.slice` (left boundary was ignored)

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
