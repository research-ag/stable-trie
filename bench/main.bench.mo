import Prng "mo:prng";
import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Nat "mo:core/Nat";
import Nat32 "mo:core/Nat32";
import Nat64 "mo:core/Nat64";
import Prim "mo:prim";
import Bench "mo:bench-helper";

import StableTrie "../src/Enumeration";

module {
  let nat = Prim.nat32ToNat;

  public func init() : Bench.V1 {
    let n = 9;
    let key_size = 8;

    let schema : Bench.Schema = {
      name = "StableTrie Benchmark";
      description = "Incrementally add random 8-byte keys into StableTrie Enumeration. With each row in the table more keys get added. Row header `r` means this row brings total keys to `2^r`. Column header equals aridity of the trie.";
      rows = Array.tabulate<Text>(n, func i = i.toText());
      cols = ["2", "4", "16", "256"];
    };
    let (nRows, nCols) = (schema.rows.size(), schema.cols.size());

    let tries = Array.tabulate<StableTrie.Enumeration>(
      nCols,
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
      2 ** (n - 1),
      func(i) {
        Blob.fromArray(
          Array.tabulate<Nat8>(
            key_size,
            func _ = Nat64.explode(rng.next()).7,
          )
        );
      },
    );

    let routines : [() -> ()] = Array.tabulate<() -> ()>(
      nRows * nCols,
      func(i) {
        let row : Nat = i % nRows;
        let col : Nat = i / nRows;
        let trie = tries[col];

        if (row == 0) {
          func() = ignore trie.add(keys[0], "");
        } else {
          let start = Nat32.fromIntWrap(2 ** (row - 1));
          let end = Nat32.fromIntWrap(2 ** row);
          func() {
            var j = start;
            while (j < end) {
              ignore trie.add(keys[nat(j)], "");
              j +%= 1;
            };
          };
        };
      },
    );

    func run(ri : Nat, ci : Nat) = routines[ci * nRows + ri]();

    Bench.V1(schema, run);
  };
};
