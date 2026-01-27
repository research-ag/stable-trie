import Prng "mo:prng";
import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64_ "mo:core/Nat64";
import Text "mo:core/Text";
import Bench "mo:bench";

import StableTrie "../src/Enumeration";

module {
  public func init() : Bench.Bench {
    let bench = Bench.Bench();

    let n = 9;
    let cols = 4;
    let key_size = 8;
    bench.cols(["2", "4", "16", "256"]);
    bench.rows(Array.tabulate<Text>(n, func(i) = Nat.toText(i)));

    var tries = Array.tabulate<StableTrie.Enumeration>(
      cols,
      func(i) {
        StableTrie.Enumeration({
          pointer_size = 2;
          aridity = 2 ** (2 ** i);
          root_aridity = null;
          key_size;
          value_size = 0;
        });
      },
    );

    let rng = Prng.Seiran128();
    rng.init(0);
    let keys = Array.tabulate<Blob>(
      2 ** n,
      func(i) {
        Blob.fromArray(
          Array.tabulate<Nat8>(
            key_size,
            func(j) {
              Nat8.fromIntWrap(rng.next().toNat());
            },
          )
        );
      },
    );

    var aridity = 0;
    bench.runner(
      func(row, col) {
        let ?r = Nat.fromText(row) else return;

        let trie = tries[aridity];

        if (r == 0) {
          ignore trie.add(keys[0], "");
        } else {
          for (j in Nat.range(2 ** (r - 1), 2 ** r)) {
            ignore trie.add(keys[j], "");
          };
        };

        aridity += 1;
        if (aridity == cols) {
          aridity := 0;
        };
      }
    );

    bench;
  };
};
