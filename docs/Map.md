# Map
Stable trie map.

Copyright: 2023-2024 MR Research AG

Main author: Andrii Stepanov (AStepanov25)

Contributors: Timo Hanke (timohanke)

## Type `StableData`
``` motoko no-repl
type StableData = Base.StableData and { last_empty_node : Nat64; last_empty_leaf : Nat64 }
```

Type of stable data of `StableTrie.Map`

## Class `Map`

``` motoko no-repl
class Map(args : Base.Args)
```

A map from constant-length Blob keys to constant-length Blob values, implemented as a trie in Regions.

Arguments:
+ `pointer_size` is the number of bytes used for internal pointers. Allowed values are 2, 4, 5, 6, 8.
   There can be at most `N/2` inner nodes in the trie and at most `N/2` leaves where `N = 256 ** pointer_size`.
+ `aridity` is the number of children of any inner node that is not the root node. Allowed values are 2, 4, 16, 256. The recommended value is 4.
+ `root_aridity` is the number of children of the root node. If `null`, then `aridity` is used.
+ `key_size` is the byte length of all keys.
+ `value_size` is the byte length of all values. If `0` then the map becomes a set.

There is a requirement that `key_size + value_size >= pointer_size`.

Example:
```motoko
let m = StableTrie.Map({
  pointer_size = 2;
  aridity = 4;
  root_aridity = null;
  key_size = 2;
  value_size = 0;
});
```

### Function `putChecked`
``` motoko no-repl
func putChecked(key : Blob, value : Blob) : Result.Result<(), {#LimitExceeded}>
```

Add the `key` and `value` pair to the map. Existing values are silently overwritten.
Returns `#LimitExceeded` if the pointer size limit is exceeded.

Example:
```motoko
let m = StableTrie.Map({
  pointer_size = 2;
  aridity = 4;
  root_aridity = null;
  key_size = 2;
  value_size = 1;
});
assert(m.putChecked("abc", "a") == #ok);
assert(m.putChecked("aaa", "b") == #ok);
assert(m.putChecked("abc", "c") == #ok);
```
Runtime: O(key_size) accesses to stable memory.


### Function `put`
``` motoko no-repl
func put(key : Blob, value : Blob)
```

Add the `key` and `value` pair to the map. If `key` already exists then the old value is silently overwritten.
Traps if the pointer size limit is exceeded.

Example:
```motoko
let m = StableTrie.Map({
  pointer_size = 2;
  aridity = 4;
  root_aridity = null;
  key_size = 2;
  value_size = 1;
});
m.put("abc", "a");
m.put("aaa", "b");
m.put("abc", "c");
```
Runtime: O(key_size) acesses to stable memory.


### Function `replaceChecked`
``` motoko no-repl
func replaceChecked(key : Blob, value : Blob) : Result.Result<?Blob, {#LimitExceeded}>
```

Add the `key` and `value` pair to the map. If `key` already exists then the old value is overwritten and returned. If `key` is new then `null` is returned.
Returns `#LimitExceeded` if the pointer size limit is exceeded.

Example:
```motoko
let m = StableTrie.Map({
  pointer_size = 2;
  aridity = 4;
  root_aridity = null;
  key_size = 2;
  value_size = 1;
});
assert(m.replaceChecked("abc", "a") == #ok (null));
assert(m.replaceChecked("aaa", "b") == #ok (null));
assert(m.replaceChecked("abc", "c") == #ok (?"a"));
```
Runtime: O(key_size) acesses to stable memory.


### Function `replace`
``` motoko no-repl
func replace(key : Blob, value : Blob) : ?Blob
```

Add the `key` and `value` pair to the map. If `key` already exists then the old value is overwritten and returned. If `key` is new then `null` is returned.
Traps if pointer size limit exceeded.

Example:
```motoko
let m = StableTrie.Map({
  pointer_size = 2;
  aridity = 4;
  root_aridity = null;
  key_size = 2;
  value_size = 1;
});
assert(m.replace("abc", "a") == null);
assert(m.replace("aaa", "b") == null);
assert(m.replace("abc", "c") == ?"a");
```
Runtime: O(key_size) acesses to stable memory.


### Function `getOrPutChecked`
``` motoko no-repl
func getOrPutChecked(key : Blob, value : Blob) : Result.Result<?Blob, {#LimitExceeded}>
```

Add the `key` and `value` pair to the map. If `key` already exists then the value is not written and the old value is returned (`get` behaviour). If `key` is new then the value is written and `null` is returned (`put` behaviour).
Returns `#LimitExceeded` if the pointer size limit is exceeded.

Example:
```motoko
let m = StableTrie.Map({
  pointer_size = 2;
  aridity = 4;
  root_aridity = null;
  key_size = 2;
  value_size = 1;
});
assert(m.getOrPutChecked("abc", "a") == #ok (null));
assert(m.getOrPutChecked("aaa", "b") == #ok (null));
assert(m.getOrPutChecked("abc", "c") == #ok (?"a"));
assert(m.get("abc") == ?"a");
```
Runtime: O(key_size) acesses to stable memory.


### Function `getOrPut`
``` motoko no-repl
func getOrPut(key : Blob, value : Blob) : ?Blob
```

Add the `key` and `value` pair to the map. If `key` already exists then the value is not written and the old value is returned (`get` behaviour). If `key` is new then the value is written and `null` is returned (`put` behaviour).
Traps if pointer size limit exceeded.

Example:
```motoko
let m = StableTrie.Map({
  pointer_size = 2;
  aridity = 4;
  root_aridity = null;
  key_size = 2;
  value_size = 1;
});
assert(m.getOrPut("abc", "a") == null);
assert(m.getOrPut("aaa", "b") == null);
assert(m.getOrPut("abc", "c") == ?"a");
assert(m.get("abc") == ?"a");
```
Runtime: O(key_size) acesses to stable memory.


### Function `get`
``` motoko no-repl
func get(key : Blob) : ?Blob
```

Returns the `value` corresponding to `key` or null if `key` is not in the map.

Example:
```motoko
let m = StableTrie.Map({
  pointer_size = 2;
  aridity = 2;
  root_aridity = null;
  key_size = 2;
  value_size = 1;
});
m.put("abc", "a");
m.put("aaa", "b");
assert(m.get("abc") == ?"a");
assert(m.get("aaa") == ?"b");
assert(m.get("bbb") == null);
```
Runtime: O(key_size) acesses to stable memory.


### Function `remove`
``` motoko no-repl
func remove(key : Blob) : ?Blob
```

Delete the `key` and its corresponding `value` from the map. Returns the deleted `value` or `null` if the key was not present in the map.

Example:
```motoko
let m = StableTrie.Map({
  pointer_size = 2;
  aridity = 4;
  root_aridity = null;
  key_size = 2;
  value_size = 1;
});
m.put("abc", "a");
m.put("aaa", "b");
assert(m.remove("abc") == ?"a");
assert(m.remove("aaa") == ?"b");
assert(m.remove("bbb") == null);
```
Runtime: O(key_size) acesses to stable memory.


### Function `delete`
``` motoko no-repl
func delete(key : Blob)
```

Delete the `key` and its corresponding `value` from the map. Nothing happens if the key is not present in the map.

Example:
```motoko
let m = StableTrie.Map({
  pointer_size = 2;
  aridity = 4;
  root_aridity = null;
  key_size = 2;
  value_size = 1;
});
m.put("abc", "a");
m.put("aaa", "b");
m.delete("abc");
m.delete("aaa");
m.delete("bbb");
```
Runtime: O(key_size) acesses to stable memory.


### Function `entries`
``` motoko no-repl
func entries() : Iter.Iter<(Blob, Blob)>
```

Returns all the key-value pairs in the map ordered by `Blob.compare` of keys.

Example:
```motoko
let m = StableTrie.Map({
  pointer_size = 2;
  aridity = 4;
  root_aridity = null;
  key_size = 2;
  value_size = 1;
});
m.put("abc", "a");
m.put("aaa", "b");
assert(Iter.toArray(m.entries()) == [("aaa", "b"), ("abc", "a")]);
```


### Function `entriesRev`
``` motoko no-repl
func entriesRev() : Iter.Iter<(Blob, Blob)>
```

Returns all the key-value pairs in the map reverse ordered by `Blob.compare` of keys.

Example:
```motoko
let m = StableTrie.Map({
  pointer_size = 2;
  aridity = 4;
  root_aridity = null;
  key_size = 2;
  value_size = 1;
});
m.put("abc", "a");
m.put("aaa", "b");
assert(Iter.toArray(m.entries()) == [("abc", "a"), ("aaa", "b")]);
```


### Function `vals`
``` motoko no-repl
func vals() : Iter.Iter<Blob>
```

Returns all the values in the map ordered by `Blob.compare` of keys.

Example:
```motoko
let m = StableTrie.Map({
  pointer_size = 2;
  aridity = 4;
  root_aridity = null;
  key_size = 2;
  value_size = 1;
});
m.put("abc", "a");
m.put("aaa", "b");
assert(Iter.toArray(m.entries()) == ["b", "a"]);
```


### Function `valsRev`
``` motoko no-repl
func valsRev() : Iter.Iter<Blob>
```

Returns all the values in the map reverse ordered by `Blob.compare` of keys.

Example:
```motoko
let m = StableTrie.Map({
  pointer_size = 2;
  aridity = 4;
  root_aridity = null;
  key_size = 2;
  value_size = 1;
});
m.put("abc", "a");
m.put("aaa", "b");
assert(Iter.toArray(m.entries()) == ["a", "b"]);
```


### Function `keys`
``` motoko no-repl
func keys() : Iter.Iter<Blob>
```

Returns all the keys in the map ordered by `Blob.compare` of keys.

Example:
```motoko
let m = StableTrie.Map({
  pointer_size = 2;
  aridity = 4;
  root_aridity = null;
  key_size = 2;
  value_size = 1;
});
m.put("abc", "a");
m.put("aaa", "b");
assert(Iter.toArray(m.entries()) == ["aaa", "abc"]);
```


### Function `keysRev`
``` motoko no-repl
func keysRev() : Iter.Iter<Blob>
```

Returns all the keys in the map reverse ordered by `Blob.compare` of keys.

Example:
```motoko
let m = StableTrie.Map({
  pointer_size = 2;
  aridity = 4;
  root_aridity = null;
  key_size = 2;
  value_size = 1;
});
m.put("abc", "a");
m.put("aaa", "b");
assert(Iter.toArray(m.entries()) == ["abc", "aaa"]);
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
let m = StableTrie.Map({
  pointer_size = 2;
  aridity = 2;
  root_aridity = null;
  key_size = 2;
  value_size = 1;
});
m.put("abc", "a");
m.put("aaa", "b");
assert(m.leafCount() == 2);
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
