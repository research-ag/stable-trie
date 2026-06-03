# Stable-trie changelog

## 0.1.1

- Integrate promtracker
- Unify `memoryStats` across Enumeration and Map

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
