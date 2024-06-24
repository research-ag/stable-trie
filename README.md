# Stable trie for Motoko

## Overview

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

## Implementation notes

## Copyright

MR Research AG, 2023-2024
## Authors

Main author: Andrii Stepanov (AStepanov25)
Contributors: Timo Hanke (timohanke)
## License 

Apache-2.0
