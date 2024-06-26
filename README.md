# Stable trie for Motoko

## Overview

`StableTrieEnumeration` implements an add-only set of key-value `(Blob, Blob)` pairs where the
elements are numbered in the order in which they are added to the set.
The elements are called *keys* and a key's number in the order is called *index*.
Lookups are possible in both ways, from key to index and from index to key.

See also:
* [Enumeration](https://github.com/research-ag/enumeration)
* [StableEnumeration](https://github.com/research-ag/stable_enumeration)

`StableTrieMap` is a map implemented as trie in stable memory.

### Links

The package is published on [MOPS](https://mops.one/stable-trie) and [GitHub](https://github.com/research-ag/stable-trie).

The API documentation can be found [here](https://mops.one/stable-trie/docs).

For updates, help, questions, feedback and other requests related to this package join us on:

* [OpenChat group](https://oc.app/2zyqk-iqaaa-aaaar-anmra-cai)
* [Twitter](https://twitter.com/mr_research_ag)
* [Dfinity forum](https://forum.dfinity.org/)

### Motivation

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
