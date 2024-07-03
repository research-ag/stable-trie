# Map
Stable trie map.

Copyright: 2023-2024 MR Research AG

Main author: Andrii Stepanov (AStepanov25)

Contributors: Timo Hanke (timohanke)

## Type `StableData`
``` motoko no-repl
type StableData = Base.StableData and { last_empty_node : Nat64; last_empty_leaf : Nat64 }
```

Type of stable data of `StableTrieMap`

## Class `Map`

``` motoko no-repl
class Map(args : Base.Args)
```

Map interface implemented as trie in stable memory.

Arguments:
+ `pointer_size` is size of pointer of address space, first bit is reserved for internal use,
  so max amount of nodes in stable trie is `2 ** (pointer_size * 8 - 1)`. Should be one of 2, 4, 5, 6, 8.
+ `aridity` is amount of children of any non leaf node except in trie. Should be one of 2, 4, 16, 256.
+ `root_aridity` is amount of children of root node.
+ `key_size` and `value_size` are sizes of key and value which should be constant per one instance of `Map`

Example:
```motoko
let e = StableTrie.Map({
  pointer_size = 2;
  aridity = 2;
  root_aridity = null;
  key_size = 2;
  value_size = 0;
});
```

### Function `putChecked`
``` motoko no-repl
func putChecked(key : Blob, value : Blob) : Result.Result<(), {#LimitExceeded}>
```

Add `key` and `value` to the map. Rewrites value in case it's already there.
Returns `#LimitExceeded` if pointer size limit exceeded.

Example:
```motoko
let e = StableTrie.Map({
  pointer_size = 2;
  aridity = 2;
  root_aridity = null;
  key_size = 2;
  value_size = 1;
});
assert(e.putChecked("abc", "a") == #ok);
assert(e.putChecked("aaa", "b") == #ok);
assert(e.putChecked("abc", "c") == #ok);
```
Runtime: O(key_size) acesses to stable memory.


### Function `put`
``` motoko no-repl
func put(key : Blob, value : Blob)
```

Add `key` and `value` to the map. Rewrites value in case it's already there.
Traps if pointer size limit exceeded.

Example:
```motoko
let e = StableTrie.Map({
  pointer_size = 2;
  aridity = 2;
  root_aridity = null;
  key_size = 2;
  value_size = 1;
});
e.put("abc", "a");
e.put("aaa", "b");
e.put("abc", "c");
```
Runtime: O(key_size) acesses to stable memory.


### Function `replaceChecked`
``` motoko no-repl
func replaceChecked(key : Blob, value : Blob) : Result.Result<?Blob, {#LimitExceeded}>
```

Add `key` and `value` to the map.
Returns `#LimitExceeded` if pointer size limit exceeded.
Rewrites value if key is already present. Returns old value if new wasn't added or `null` otherwise. 

Example:
```motoko
let e = StableTrie.Map({
  pointer_size = 2;
  aridity = 2;
  root_aridity = null;
  key_size = 2;
  value_size = 1;
});
assert(e.replaceChecked("abc", "a") == #ok (null));
assert(e.replaceChecked("aaa", "b") == #ok (null));
assert(e.replaceChecked("abc", "c") == #ok ("a"));
```
Runtime: O(key_size) acesses to stable memory.


### Function `replace`
``` motoko no-repl
func replace(key : Blob, value : Blob) : ?Blob
```

Add `key` and `value` to the map.
Traps if pointer size limit exceeded.
Rewrites value if key is already present. Returns old value if new wasn't added or `null` otherwise. 

Example:
```motoko
let e = StableTrie.Map({
  pointer_size = 2;
  aridity = 2;
  root_aridity = null;
  key_size = 2;
  value_size = 1;
});
assert(e.replace("abc", "a") == null);
assert(e.replace("aaa", "b") == null);
assert(e.replace("abc", "c") == "a");
```
Runtime: O(key_size) acesses to stable memory.


### Function `getOrPutChecked`
``` motoko no-repl
func getOrPutChecked(key : Blob, value : Blob) : Result.Result<?Blob, {#LimitExceeded}>
```

Add `key` and `value` to the map.
Returns `#LimitExceeded` if pointer size limit exceeded.
Lookup value if key is already present. Returns old value if new wasn't added or a null otherwise.

Example:
```motoko
let e = StableTrie.Map({
  pointer_size = 2;
  aridity = 2;
  root_aridity = null;
  key_size = 2;
  value_size = 1;
});
assert(e.getOrPutChecked("abc", "a") == #ok (null));
assert(e.getOrPutChecked("aaa", "b") == #ok (null));
assert(e.getOrPutChecked("abc", "c") == #ok (?"a"));
```
Runtime: O(key_size) acesses to stable memory.


### Function `getOrPut`
``` motoko no-repl
func getOrPut(key : Blob, value : Blob) : ?Blob
```

Add `key` and `value` to the map.
Traps if pointer size limit exceeded.
Lookup value if key is already present. Returns old value if new wasn't added or a null otherwise.

Example:
```motoko
let e = StableTrie.Map({
  pointer_size = 2;
  aridity = 2;
  root_aridity = null;
  key_size = 2;
  value_size = 1;
});
assert(e.getOrPut("abc", "a") == null);
assert(e.getOrPut("aaa", "b") == null);
assert(e.getOrPut("abc", "c") == ?"a");
```
Runtime: O(key_size) acesses to stable memory.


### Function `get`
``` motoko no-repl
func get(key : Blob) : ?Blob
```

Returns `value` corresponding to the `key` or null if the `key` is not in the map.

Example:
```motoko
let e = StableTrie.Map({
  pointer_size = 2;
  aridity = 2;
  root_aridity = null;
  key_size = 2;
  value_size = 1;
});
e.put("abc", "a");
e.put("aaa", "b");
assert(e.get("abc") == ?"a");
assert(e.get("aaa") == ?"b");
assert(e.get("bbb") == null);
```
Runtime: O(key_size) acesses to stable memory.


### Function `remove`
``` motoko no-repl
func remove(key : Blob) : ?Blob
```

Remove `value` corresponding to the `key` and return removed `value`.

Example:
```motoko
let e = StableTrie.Map({
  pointer_size = 2;
  aridity = 2;
  root_aridity = null;
  key_size = 2;
  value_size = 1;
});
e.put("abc", "a");
e.put("aaa", "b");
assert(e.remove("abc") == ?"a");
assert(e.remove("aaa") == ?"b");
assert(e.remove("bbb") == null);
```
Runtime: O(key_size) acesses to stable memory.


### Function `delete`
``` motoko no-repl
func delete(key : Blob)
```

Delete `value` corresponding to the `key`.

Example:
```motoko
let e = StableTrie.Map({
  pointer_size = 2;
  aridity = 2;
  root_aridity = null;
  key_size = 2;
  value_size = 1;
});
e.put("abc", "a");
e.put("aaa", "b");
e.delete("abc");
e.delete("aaa");
e.delete("bbb");
```
Runtime: O(key_size) acesses to stable memory.


### Function `entries`
``` motoko no-repl
func entries() : Iter.Iter<(Blob, Blob)>
```

Returns all the keys and values in the map ordered by `Blob.compare` of keys.

Example:
```motoko
let e = StableTrie.Enumeration({
  pointer_size = 2;
  aridity = 2;
  root_aridity = null;
  key_size = 2;
  value_size = 1;
});
e.put("abc", "a");
e.put("aaa", "b");
assert(Iter.toArray(e.entries()) == [("aaa", "b"), ("abc", "a")]);
```


### Function `entriesRev`
``` motoko no-repl
func entriesRev() : Iter.Iter<(Blob, Blob)>
```

Returns all the keys and values in the map reverse ordered by `Blob.compare` of keys.

Example:
```motoko
let e = StableTrie.Enumeration({
  pointer_size = 2;
  aridity = 2;
  root_aridity = null;
  key_size = 2;
  value_size = 1;
});
e.put("abc", "a");
e.put("aaa", "b");
assert(Iter.toArray(e.entries()) == [("abc", "a"), ("aaa", "b")]);
```


### Function `vals`
``` motoko no-repl
func vals() : Iter.Iter<Blob>
```

Returns all the values in the map ordered by `Blob.compare` of keys.

Example:
```motoko
let e = StableTrie.Enumeration({
  pointer_size = 2;
  aridity = 2;
  root_aridity = null;
  key_size = 2;
  value_size = 1;
});
e.put("abc", "a");
e.put("aaa", "b");
assert(Iter.toArray(e.entries()) == ["b", "a"]);
```


### Function `valsRev`
``` motoko no-repl
func valsRev() : Iter.Iter<Blob>
```

Returns all the values in the map reverse ordered by `Blob.compare` of keys.

Example:
```motoko
let e = StableTrie.Enumeration({
  pointer_size = 2;
  aridity = 2;
  root_aridity = null;
  key_size = 2;
  value_size = 1;
});
e.put("abc", "a");
e.put("aaa", "b");
assert(Iter.toArray(e.entries()) == ["a", "b"]);
```


### Function `keys`
``` motoko no-repl
func keys() : Iter.Iter<Blob>
```

Returns all the keys in the map ordered by `Blob.compare` of keys.

Example:
```motoko
let e = StableTrie.Enumeration({
  pointer_size = 2;
  aridity = 2;
  root_aridity = null;
  key_size = 2;
  value_size = 1;
});
e.put("abc", "a");
e.put("aaa", "b");
assert(Iter.toArray(e.entries()) == ["aaa", "abc"]);
```


### Function `keysRev`
``` motoko no-repl
func keysRev() : Iter.Iter<Blob>
```

Returns all the keys in the map reverse ordered by `Blob.compare` of keys.

Example:
```motoko
let e = StableTrie.Enumeration({
  pointer_size = 2;
  aridity = 2;
  root_aridity = null;
  key_size = 2;
  value_size = 1;
});
e.put("abc", "a");
e.put("aaa", "b");
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
e.put("abc", "a");
e.put("aaa", "b");
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
