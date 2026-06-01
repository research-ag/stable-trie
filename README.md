[![mops](https://oknww-riaaa-aaaam-qaf6a-cai.raw.ic0.app/badge/mops/stable-trie)](https://mops.one/stable-trie)
[![documentation](https://oknww-riaaa-aaaam-qaf6a-cai.raw.ic0.app/badge/documentation/stable-trie)](https://mops.one/stable-trie/docs)

# Stable trie for Motoko

## Overview

`StableTrie` is a data structure that has its main data living permanently in stable memory (via Regions).

The trie constitutes a key-value map where both keys and values are constant length Blobs.
Various parameters of the trie can be configured in the constructor such as key length, value length and the number of children per node (see the Configuration section below for details).

The trie can be used as a _map_ (`StableTrieMap`) or an _enumeration_ (`StableTrieEnumeration`)
which are different interfaces to the same underlying data structure.

`StableTrieMap` offers deletion.
Freed space from deletions is tracked and efficiently reused by subsequent additions.
However, it should be noted that deletion does not allow the Regions to shrink and their size will remain at the data size's high watermark, even after canister upgrades.

In `StableTrieEnumeration` each key, besides its value, also has an index associated with it
which reflects the order of its insertion into the map.
This index is inherent in the data structure and therefore has no additional memory footprint over `StableTrieMap`.
Value and index can be looked up by key,
value and key can be looked up by index.
`StableTrieEnumeration` supports LIFO removal via `removeLast()`,
which pops the most-recently-added entry.
Internal trie nodes that become empty are reclaimed and reused by subsequent `add` calls;
the leaves region is also reused LIFO.
Arbitrary-key deletion is not supported in the Enumeration variant.

Both the map and the enumeration variant can be adapted to implement a set simply by setting the value size to 0.
The map variant gives us a set with deletions.
The enumeration variant gives us a set which preserves the order of insertions into the set (enumerated set).

## Motivation

Available data structures in Motoko for key-value maps are associative lists, red-black trees, tries, hashmaps and b-trees.
The vast majority of them are heap data structures.

The term "stable" for data structures can cause confusion.
Many data structures have been named "stable" on the grounds
that they can be declared `stable` in Motoko or, equialently,
that their type is a so-called "stable type".
This is a Motoko-specific terminology.

Another interpretation of the term "stable" is to characterize a
data structure as living in the canister's stable memory as opposed to the heap.
This is an IC-specific and language-agnostic terminology.

A data structure of the first kind we call a _stable-type_ data structure. It can be declared `stable` in Motoko but still lives on the heap and is subject to two limitations:

- the 4 GB heap size limit
- the instruction limit available for serialization/deserialization during preupgrade/postupgrade

A data structure of the second kind we call _stable-memory_ datastructure.
All of its dynamically sized data must live in the canister's stable memory.
Heap memory usage must be limited to size `O(1)`.
For example, when Regions are used, then the Region references live on the heap.
This is allowed for a constant number of Regions.
It is also allowed to store `O(1)` metadata on the heap such as a fixed number of pointers to positions in the Regions.
Stable-memory data structures are not subject to the two limitations mentioned above.

Some published Motoko data structures are hybrid.
For example they have a linear buffer in a Region and an index tree on the heap.

The motivation of this package is to provide a stable-memory trie implementation
that is as simple as possible
and that can compete in performance with a heap implementation.

## Configuration and optimization

The trie constructor has two main configuration parameters affecting keys and values:

- The byte size of the keys.
- The byte size of the values. Values of size 0 are allowed and turn the data structure into a set.

Key size plus value size can be at most 65536.

The other parameters are considered optimization parameters.

- Aridity of the trie, i.e. the number of children per node. Allowed values are 2, 4, 16, 256. The recommended value is 4,
  which is optimal for uniformly distributed keys.

- Root aridity. Multiple levels from the top of the trie can be merged into the root node by specifying a higher aridity for the root node.
  This will save memory if the top levels of the trie are "full",
  i.e. all nodes on those level have all or most of its children used.
  But it will waste memory if they are not full.

- Pointer size. This is the byte size of the internal pointers stored in each node.  
  It can be set lower to save memory but that sets a limit on how large the trie can grow.
  Allowed values are 2,4,5,6,8.

## Extensions

Instead of storing the values in the trie directly,
we can store a pointer to another stable-memory data structure
which holds the actual value.
In this case the trie provides the lookup by key
and the other stable-memory data structure only has to store the values.

That way we can get around the size limitation for values.
We can also store variable size variables
if the other stable-memory data structure is designed for them.

## Implementation

The trie uses two Regions, one for internal nodes and one for leaves.
Each Region is an array of constant size objects.

Pointers use one bit to encode the Region they point to
and the remaining bits to encode the index of the object in the region.
This means that with a pointer size of n bytes
the trie can have at most `N/2` leaves where `N = 256**n`
and at most `N/2` inner nodes.

One cannot predict in general which limit will be reached first,
but under most circumstances it will be the leaf limit.
When the pointer space is exceeded the implementation will block the operation and return an error.

The implementation only writes or deletes objects,
it never moves objects.
In particular, it does not perform de-fragmentation.
The space of deleted objects is re-used in place for new objects.

Deletion is complete in the sense that not only leaves get deleted
but also inner nodes which end up forming a linear branch get compressed back into a single node.

## Comparison

We have profiled StableTrieMap against the RBTree from base, the motoko-hashmap from ZhenyaUsenko, and the MotokoStableBTree from sardariuss.
Note that RBTree and motoko-hashmap are heap data structures.
MotokoStableBTree is a stable-memory data structure.

The results in the following table shows that stable-trie can compete with the heap data structures.
And it is 2 orders of magnitude faster than the only other stable-memory map.

| method           | rb tree | zhus map | stable trie map | motoko stable btree |
| ---------------- | ------- | -------- | --------------- | ------------------- |
| put              | 3_736   | 3_491    | 3_136           | 255_732             |
| inside get       | 2_196   | 1_835    | 2_793           | 200_453             |
| outside get      | 1_605   | 1_019    | 1_391           | 207_289             |
| inside deletion  | 5_034   | 2_080    | 8_906           | 438_861             |
| outside deletion | 4_148   | 1_016    | 1_442           | 401_505             |

"Inside" means that the key that is looked up or deleted is present in the tree.
"Outside" means that the key is not present.
The row for "inside deletion" shows the additional work done to clean up the trie and to track the freed space for re-use.

The tree size in this profiling run is 4,096 entries.
The key length is 29 bytes like a typical user principal.

See [canister-profiling](https://github.com/research-ag/canister-profiling) for more details.

## Links

The package is published on [MOPS](https://mops.one/stable-trie) and [GitHub](https://github.com/research-ag/stable-trie).

The API documentation can be found [here](https://mops.one/stable-trie/docs).

For updates, help, questions, feedback and other requests related to this package join us on:

- [OpenChat group](https://oc.app/2zyqk-iqaaa-aaaar-anmra-cai)
- [Twitter](https://twitter.com/mr_research_ag)
- [Dfinity forum](https://forum.dfinity.org/)

## Usage

### Install with mops

You need `mops` installed. In your project directory run:

```bash
mops add stable-trie
```

In the Motoko source file import the package as:

```motoko
import Map "mo:stable-trie/Map";
import Enumeration "mo:stable-trie/Enumeration";

```

`Map` and `Enumeration` are records with all-stable fields, so an
instance can live directly inside a `persistent actor` (a plain `let`
binding is enough; `stable` is implicit there). There is no
`share` / `unshare` round-trip.

### Example

```motoko
import Iter "mo:core/Iter";
import Map "mo:stable-trie/Map";

let m = Map.empty({
  pointer_size = 2;
  aridity = 2;
  root_aridity = null;
  key_size = 3;
  value_size = 1;
});
assert (m.swap("abc", "a") == null);
assert (m.swap("aaa", "b") == null);
assert (m.swap("abc", "c") == ?"a");

assert Iter.toArray(m.entries()) == [("aaa", "b"), ("abc", "c")];

m.remove("abc");
m.remove("aaa");

```

```motoko
import Enumeration "mo:stable-trie/Enumeration";

let e = Enumeration.empty({
  pointer_size = 2;
  aridity = 2;
  root_aridity = null;
  key_size = 3;
  value_size = 1;
});
assert (e.add("abc", "a") == 0);
assert (e.add("aaa", "b") == 1);
assert (e.add("abc", "c") == 0); // re-adds, overwrites the value at index 0

assert e.sliceToArray(0, 2) == [("abc", "c"), ("aaa", "b")];

assert e.removeLast() == ?("aaa", "b"); // pop most-recently-added
assert e.size() == 1;

```

### Persistent actor

Because `Map` and `Enumeration` are records with all-stable fields, an instance can live directly inside a `persistent actor` — no `share` / `unshare` round-trip is needed. A plain `let` is enough: the record's own internal `var` fields handle the mutation, and `stable` is implicit in a persistent actor.

```motoko
import Map "mo:stable-trie/Map";

persistent actor {
  let m : Map.Map = Map.empty({
    pointer_size = 4;
    aridity = 4;
    root_aridity = null;
    key_size = 8;
    value_size = 4;
  });

  public func add(k : Blob, v : Blob) : async () { m.add(k, v) };
  public query func get(k : Blob) : async ?Blob { m.get(k) };
};

```

The trie survives canister upgrades automatically; you don't need `preupgrade` / `postupgrade` hooks.

### Build & test

Run:

```
git clone git@github.com:research-ag/stable-trie.git
mops install
mops test
```

### Benchmark

Run

```bash
mops bench
```

This is the benchmark to compare different versions of stable-trie.
For comparison of stable-trie against other data structures see the section Comparisons above.

## Formatting

This project uses `prettier` with `prettier-plugin-motoko` for formatting.
To format the code, run:

```bash
npx -y prettier --plugin prettier-plugin-motoko --write '**/*.{mo,json,md}'
```

## Copyright

MR Research AG, 2023 - 2026

## Authors

Main authors: Andrii Stepanov (AStepanov25), Timo Hanke (timohanke)

Contributors: Andy Gura (AndyGura)

## License

Apache-2.0
