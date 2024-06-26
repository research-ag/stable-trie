# Enumeration
Stable trie enumeration.

Copyright: 2023-2024 MR Research AG

Main author: Andrii Stepanov (AStepanov25)

Contributors: Timo Hanke (timohanke)

## Type `StableData`
``` motoko no-repl
type StableData = Base.StableData
```

Type of stable data of `StableTrieEnumeration`.

## Class `Enumeration`

``` motoko no-repl
class Enumeration(args : Base.Args)
```

Bidirectional enumeration of any keys in the order they are added.
For a map from keys to index `Nat` it is implemented as trie in stable memory.
for a map from index `Nat` to keys the implementation is a consecutive interval of stable memory.

Arguments:
+ `pointer_size` is size of pointer of address space, first bit is reserved for internal use,
  so max amount of nodes in stable trie is `2 ** (pointer_size * 8 - 1)`. Should be one of 2, 4, 5, 6, 8.
+ `aridity` is amount of children of any non leaf node except in trie. Should be one of 2, 4, 16, 256.
+ `root_aridity` is amount of children of root node.
+ `key_size` and `value_size` are sizes of key and value which should be constant per one instance of `Enumeration`

Example:
```motoko
let e = StableTrie.Enumeration({
  pointer_size = 2;
  aridity = 2;
  root_aridity = null;
  key_size = 2;
  value_size = 0;
});
```

### Function `addChecked`
``` motoko no-repl
func addChecked(key : Blob, value : Blob) : Result.Result<Nat, {#LimitExceeded}>
```

Add `key` and `value` to the enumeration. 
Returns `#LimitExceeded` if pointer size limit exceeded.
Returns `size` if the key in new to the enumeration
or rewrites value and returns index of key in enumeration otherwise.

Example:
```motoko
let e = StableTrie.Enumeration({
  pointer_size = 2;
  aridity = 2;
  root_aridity = null;
  key_size = 2;
  value_size = 1;
});
assert(e.addChecked("abc", "a") == #ok 0);
assert(e.addChecked("aaa", "b") == #ok 1);
assert(e.addChecked("abc", "c") == #ok 0);
```
Runtime: O(key_size) acesses to stable memory.


### Function `add`
``` motoko no-repl
func add(key : Blob, value : Blob) : Nat
```

Add `key` and `value` to enumeration. 
Traps if pointer size limit exceeded. Returns `size` if the key in new to the enumeration
or rewrites value and returns index of key in enumeration otherwise.

Example:
```motoko
let e = StableTrie.Enumeration({
  pointer_size = 2;
  aridity = 2;
  root_aridity = null;
  key_size = 2;
  value_size = 1;
});
assert(e.add("abc", "a") == 0);
assert(e.add("aaa", "b") == 1);
assert(e.add("abc", "c") == 0);
```
Runtime: O(key_size) acesses to stable memory.


### Function `replaceChecked`
``` motoko no-repl
func replaceChecked(key : Blob, value : Blob) : Result.Result<(?Blob, Nat), {#LimitExceeded}>
```

Add `key` and `value` to enumeration.
Returns `#LimitExceeded` if pointer size limit exceeded.
Rewrites value if key is already present. First return is old value if new wasn't added or `null` otherwise. 
Second return value is `size` if the key in new to the enumeration
or index of key in enumeration otherwise.

Example:
```motoko
let e = StableTrie.Enumeration({
  pointer_size = 2;
  aridity = 2;
  root_aridity = null;
  key_size = 2;
  value_size = 1;
});
assert(e.replaceChecked("abc", "a") == #ok (null, 0));
assert(e.replaceChecked("aaa", "b") == #ok (null, 1));
assert(e.replaceChecked("abc", "c") == #ok ("a", 0));
```
Runtime: O(key_size) acesses to stable memory.


### Function `replace`
``` motoko no-repl
func replace(key : Blob, value : Blob) : (?Blob, Nat)
```

Add `key` and `value` to enumeration.
Traps if pointer size limit exceeded.
Rewrites value if key is already present. First return is old value if new wasn't added or `null` otherwise.
Second return value is `size` if the key in new to the enumeration
or index of key in enumeration otherwise.

Example:
```motoko
let e = StableTrie.Enumeration({
  pointer_size = 2;
  aridity = 2;
  root_aridity = null;
  key_size = 2;
  value_size = 1;
});
assert(e.replace("abc", "a") == (null, 0));
assert(e.replace("aaa", "b") == (null, 1));
assert(e.replace("abc", "c") == (?"a", 0));
```
Runtime: O(key_size) acesses to stable memory.


### Function `lookupOrPutChecked`
``` motoko no-repl
func lookupOrPutChecked(key : Blob, value : Blob) : Result.Result<(?Blob, Nat), {#LimitExceeded}>
```

Add `key` and `value` to enumeration.
Returns `#LimitExceeded` if pointer size limit exceeded.
Lookup value if key is already present. First return value `size` is if the key in new to the enumeration
or index of key in enumeration otherwise. Second return is old value if new wasn't added or null otherwise.

Example:
```motoko
let e = StableTrie.Enumeration({
  pointer_size = 2;
  aridity = 2;
  root_aridity = null;
  key_size = 2;
  value_size = 1;
});
assert(e.lookupOrPut("abc", "a") == #ok (null, 0));
assert(e.lookupOrPut("aaa", "b") == #ok (null, 1));
assert(e.lookupOrPut("abc", "c") == #ok (?"a", 0));
```
Runtime: O(key_size) acesses to stable memory.


### Function `lookupOrPut`
``` motoko no-repl
func lookupOrPut(key : Blob, value : Blob) : (?Blob, Nat)
```

Add `key` and `value` to enumeration.
Traps if pointer size limit exceeded.
Lookup value if key is already present. First return value `size` is if the key in new to the enumeration
or index of key in enumeration otherwise. Second return is old value if new wasn't added or a new one otherwise.

Example:
```motoko
let e = StableTrie.Enumeration({
  pointer_size = 2;
  aridity = 2;
  root_aridity = null;
  key_size = 2;
  value_size = 1;
});
assert(e.lookupOrPut("abc", "a") == (null, 0);
assert(e.lookupOrPut("aaa", "b") == (null, 1));
assert(e.lookupOrPut("abc", "c") == (?"a", 0);
```
Runtime: O(key_size) acesses to stable memory.


### Function `lookup`
``` motoko no-repl
func lookup(key : Blob) : ?(Blob, Nat)
```

Returns `?(value, index)` where `index` is the index of `key` in order it was added to enumeration and `value` is corresponding value to the `key`,
or `null` it `key` wasn't added.

Example:
```motoko
let e = StableTrie.Enumeration({
  pointer_size = 2;
  aridity = 2;
  root_aridity = null;
  key_size = 2;
  value_size = 1;
});
assert(e.add("abc", "a") == 0);
assert(e.add("aaa", "b") == 1);
assert(e.lookup("abc") == ?("a", 0);
assert(e.lookup("aaa") == ?("b", 1));
assert(e.lookup("bbb") == null);
```
Runtime: O(key_size) acesses to stable memory.


### Function `get`
``` motoko no-repl
func get(index : Nat) : ?(Blob, Blob)
```

Returns `key` and `value` with index `index` or null if index is out of bounds.

Example:
```motoko
let e = StableTrie.Enumeration({
  pointer_size = 2;
  aridity = 2;
  root_aridity = null;
  key_size = 2;
  value_size = 1;
});
assert(e.add("abc", "a") == 0);
assert(e.add("aaa", "b") == 1);
assert(e.get(0) == ?("abc", "a"));
assert(e.get(1) == ?("aaa", "b"));
```
Runtime: O(1) accesses to stable memory.


### Function `slice`
``` motoko no-repl
func slice(left : Nat, right : Nat) : [(Blob, Blob)]
```

Returns slice `key` and `value` with indices from `left` to `right` or traps if `left` or `right` are out of bounds.

Example:
```motoko
let e = StableTrie.Enumeration({
  pointer_size = 2;
  aridity = 2;
  root_aridity = null;
  key_size = 2;
  value_size = 1;
});
assert(e.add("abc", "a") == 0);
assert(e.add("aaa", "b") == 1);
assert(e.slice(0, 2) == [("abc", "a"), ("aaa", "b")]);
```
Runtime: O(right - left) accesses to stable memory.


### Function `entries`
``` motoko no-repl
func entries() : Iter.Iter<(Blob, Blob)>
```

Returns all the keys and values in enumeration ordered by `Blob.compare` of keys.

Example:
```motoko
let e = StableTrie.Enumeration({
  pointer_size = 2;
  aridity = 2;
  root_aridity = null;
  key_size = 2;
  value_size = 1;
});
assert(e.add("abc", "a") == 0);
assert(e.add("aaa", "b") == 1);
assert(Iter.toArray(e.entries()) == [("aaa", "b"), ("abc", "a")]);
```


### Function `entriesRev`
``` motoko no-repl
func entriesRev() : Iter.Iter<(Blob, Blob)>
```

Returns all the keys and values in the enumeration reverse ordered by `Blob.compare` of keys.

Example:
```motoko
let e = StableTrie.Enumeration({
  pointer_size = 2;
  aridity = 2;
  root_aridity = null;
  key_size = 2;
  value_size = 1;
});
assert(e.add("abc", "a") == 0);
assert(e.add("aaa", "b") == 1);
assert(Iter.toArray(e.entries()) == [("abc", "a"), ("aaa", "b")]);
```


### Function `vals`
``` motoko no-repl
func vals() : Iter.Iter<Blob>
```

Returns all the values in the enumeration ordered by `Blob.compare` of keys.

Example:
```motoko
let e = StableTrie.Enumeration({
  pointer_size = 2;
  aridity = 2;
  root_aridity = null;
  key_size = 2;
  value_size = 1;
});
assert(e.add("abc", "a") == 0);
assert(e.add("aaa", "b") == 1);
assert(Iter.toArray(e.entries()) == ["b", "a"]);
```


### Function `valsRev`
``` motoko no-repl
func valsRev() : Iter.Iter<Blob>
```

Returns all the values in the enumeration reverse ordered by `Blob.compare` of keys.

Example:
```motoko
let e = StableTrie.Enumeration({
  pointer_size = 2;
  aridity = 2;
  root_aridity = null;
  key_size = 2;
  value_size = 1;
});
assert(e.add("abc", "a") == 0);
assert(e.add("aaa", "b") == 1);
assert(Iter.toArray(e.entries()) == ["a", "b"]);
```


### Function `keys`
``` motoko no-repl
func keys() : Iter.Iter<Blob>
```

Returns all the keys in the enumeration ordered by `Blob.compare` of keys.

Example:
```motoko
let e = StableTrie.Enumeration({
  pointer_size = 2;
  aridity = 2;
  root_aridity = null;
  key_size = 2;
  value_size = 1;
});
assert(e.add("abc", "a") == 0);
assert(e.add("aaa", "b") == 1);
assert(Iter.toArray(e.entries()) == ["aaa", "abc"]);
```


### Function `keysRev`
``` motoko no-repl
func keysRev() : Iter.Iter<Blob>
```

Returns all the keys in the enumeration reverse ordered by `Blob.compare` of keys.

Example:
```motoko
let e = StableTrie.Enumeration({
  pointer_size = 2;
  aridity = 2;
  root_aridity = null;
  key_size = 2;
  value_size = 1;
});
assert(e.add("abc", "a") == 0);
assert(e.add("aaa", "b") == 1);
assert(Iter.toArray(e.entries()) == ["abc", "aaa"]);
```


### Function `size`
``` motoko no-repl
func size() : Nat
```

Size of used stable memory in bytes.


### Function `leafCount`
``` motoko no-repl
func leafCount() : Nat
```

Size of used stable memory in bytes.

Example:
```motoko
let e = StableTrie.Enumeration({
  pointer_size = 2;
  aridity = 2;
  root_aridity = null;
  key_size = 2;
  value_size = 1;
});
assert(e.add("abc", "a") == 0);
assert(e.add("aaa", "b") == 1);
assert(e.leafCount() == 2);
```


### Function `nodeCount`
``` motoko no-repl
func nodeCount() : Nat
```

Number of internal nodes excluding leaves.


### Function `share`
``` motoko no-repl
func share() : StableData
```

Convert to stable data.


### Function `unshare`
``` motoko no-repl
func unshare(data : StableData)
```

Create from stable data. Must be the first call after constructor.
