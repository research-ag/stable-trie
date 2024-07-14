# Stable trie for Motoko

## Overview

`StableTrie` is a data structure that has its main data living permanently in stable memory (via Regions).

The trie constitutes a key-value map where both keys and values are constant length Blobs.
Various parameters of the trie can be configured in the constructor such as key length, value length and the number of children per node (see the Configuration section below for details).

The trie can be used as map (`StableTrieMap`) or an enumeration (`StableTrieEnumeration`)
which are different interfaces to the same underlying data structure.

`StableTrieMap` offers deletion.
Freed space from deletions is tracked and efficiently reused by subsequent additions.
However, it should be noted that deletion does not allow the Regions to shrink and their size will remain at the data size's high watermark, even after canister upgrades.

In `StableTrieEnumeration` each key, besides its value, also has an index associated with it
which reflects the order of its insertion into the map.
This index is inherent in the data structure and therefore has no additional memory footprint over `StableTrieMap`.
Values can be looked up by index or by value
and index can be looked up by key. 
`StableTrieEnumeration` does not allow deletion.

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

* the 4 GB heap size limit
* the instruction limit available for serialization/deserialization during preupgrade/postupgrade

A data structure of the second kind we call _stable-memory_ datastructure.
All of its dynamically sized data must live in the canister's stable memory.
Heap memory usage must be limited to size O(1).
For example, when Regions are used, then the Region references live on the heap.
This is allowed for a constant number of Regions.
It is also allowed to store O(1) metadata on the heap such as a fixed number of pointers to positions in the Regions. 
Stable-memory data structures are not subject to the two limitations mentioned above.

Some published Motoko data structures are hybrid.
For example they have a linear buffer in a Region and an index tree on the heap.

The motivation of this package is to provide a stable-memory trie implementation
that is as simple as possible
and that can compete in performance with a heap implementation.

## Configuration and optimization

The trie constructor has two main configuration parameters
that every user must provide:

* The byte size of the keys.
* The byte size of the values. Values of size 0 are allowed and turn the data structure into a set.

Key size plus value size can be at most 65536. 

The other parameters are considered optimization parameters.

* Aridity of the trie, i.e. the number of children per node. Allowed values are 2, 4, 16, 256. The recommended value is 4,
which is optimal for uniformly distributed keys.

* Root aridity. Multiple levels from the top of the trie can be merged into the root node by specifying a higher aridity for the root node.
This will save memory if the top levels of the trie are "full",
i.e. all nodes on those level have all or most of its children used.
But it will waste memory if they are not full.

* Pointer size. This is the byte size of the internal pointers stored in each node.  
It can be set lower to save memory but that sets a limit on how large the trie can grow.
Allowed values are 2,4,5,6,8.

In a `StableTrieMap` key size plus value size must be greater equal pointer size.

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
the trie can have at most N/2 leaves where N = 256**n
and at most N/2 inner nodes.

One cannot predict in general which limit will be reached first,
but under most circumstances it will be the leaf limit.
When the pointer space is exceeded the implementation will block the operation and return an error.

The implementation only writes or deletes objects,
it never moves objects.
In particular, it does not perform de-fragmentation. 
The space of deleted objects is re-used in place for new objects.

## Comparison

### Links

The package is published on [MOPS](https://mops.one/stable-trie) and [GitHub](https://github.com/research-ag/stable-trie).

The API documentation can be found [here](https://mops.one/stable-trie/docs).

For updates, help, questions, feedback and other requests related to this package join us on:

* [OpenChat group](https://oc.app/2zyqk-iqaaa-aaaar-anmra-cai)
* [Twitter](https://twitter.com/mr_research_ag)
* [Dfinity forum](https://forum.dfinity.org/)

### Interface

## Usage

### Install with mops

You need `mops` installed. In your project directory run:
```
mops add stable-trie
```

In the Motoko source file import the package as:
```
import StableTrieEnumeration "mo:stable-trie/Enumeration";
import StableTrieMap "mo:stable-trie/Map";
```

### Example

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

assert Iter.toArray(e.entries()) == [("aaa", "a"), ("abc", "c")];

e.delete("abc");
e.delete("aaa");
```

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

assert e.slice(0, 2) == [("abc", "a"), ("aaa", "b")];
```

### Build & test

We need up-to-date versions of `node`, `moc` and `mops` installed.

Then run:
```
git clone git@github.com:research-ag/stable-trie.git
mops install
mops test
```

### Benchmark

Run
```
mops bench --replica pocket-ic
```

Benchmark of stable trie map. Values are average numbers of intructions.
See [canister-profiling](https://github.com/research-ag/canister-profiling) for more details.

|method|rb tree|zhus map|stable trie map|motoko stable btree|
|---|---|---|---|---|
|put|3_749|3_720|4_404|259_442|
|random blobs inside average|5_027|2_152|10_463|445_008|
|random blobs outside average|4_148|1_085|2_364|406_721|

## Design

[Trie](https://en.wikipedia.org/wiki/Trie)

## Implementation notes

Additional optimization is performed: the invariant holds that every internal node 
except from root can have not less than two leaf children (indirect children inclusive).
So branches containing single leaf are compressed.

## Copyright

MR Research AG, 2023-2024
## Authors

Main author: Andrii Stepanov (AStepanov25)
Contributors: Timo Hanke (timohanke)
## License 

Apache-2.0
