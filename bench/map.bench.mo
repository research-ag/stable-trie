import Prng "mo:prng";
import Array "mo:core/Array";
import Blob "mo:core/Blob";
import _Nat "mo:core/Nat";
import Nat32 "mo:core/Nat32";
import Nat64 "mo:core/Nat64";
import Bench "mo:bench-helper";

import StableTrie "../src/Map";

module {
  public func init() : Bench.V1 {
    let n = 9;
    let key_size = 8;

    let schema : Bench.Schema = {
      name = "StableTrie Map Benchmark";
      description = "Insert/delete random 8-byte keys into StableTrie Map. With each row in the table more keys are added, deleted and then added again. Row header `r` means this row brings total keys to `2^r`. Column header equals aridity of the trie.";
      rows = Array.tabulate<Text>(n, func i = i.toText());
      cols = ["2", "4", "16", "256"];
    };
    let (nRows, nCols) = (schema.rows.size(), schema.cols.size());

    let tries = Array.tabulate<StableTrie.Map>(
      nCols,
      func(i) {
        StableTrie.Map({
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
          func() = trie.put(keys[0], "");
        } else {
          let start = Nat32.fromIntWrap(2 ** (row - 1));
          let end = Nat32.fromIntWrap(2 ** row);
          func() {
            var j = start;
            while (j < end) {
              trie.put(keys[j.toNat()], "");
              j +%= 1;
            };
            j := start;
            while (j < end) {
              trie.delete(keys[j.toNat()]);
              j +%= 1;
            };
            j := start;
            while (j < end) {
              trie.put(keys[j.toNat()], "");
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
