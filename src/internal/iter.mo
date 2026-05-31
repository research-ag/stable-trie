/// Read-only iteration over a `StableTrie`.
///
/// Pulled out of `trie.mo` because it has a clean boundary: the iterator
/// only reads the trie shape via `getChild`/`getKey`/`getValue` and never
/// touches the mutation paths (`put_`, `removeLast`, free lists). This
/// means it can be optimized independently — e.g. switching the
/// `(Nat64, Nat64)` traversal stack to two parallel `[var Nat64]`s
/// touches nothing in `trie.mo`.

import _Iter "mo:core/Iter"; // enables `.map` dot notation below
import Types "mo:core/Types";
import VarArray "mo:core/VarArray";
import Prim "mo:prim";

import Trie "./trie";
import Layout "./layout";

module {
  let nat16toNat = Prim.nat16ToNat;

  type Dir = { #forward; #reverse };

  /// Closure-based iterator factory returning an `Iter<Nat64>` directly.
  /// The returned iterator owns the traversal stack via closure capture.
  func makeIter(self : Trie.StableTrie, dir : Dir) : Types.Iter<Nat64> {
    let forward = dir == #forward;
    let stack = VarArray.repeat<(Nat64, Nat64)>((0, 0), self.key_size * 8 / nat16toNat(self.bitlength));
    var depth = 1;
    stack[0] := if (forward) (0, 0) else (0, self.root_aridity_ - 1);

    func next_step(i : Nat64) : Nat64 {
      if (forward) {
        i + 1;
      } else {
        if (i != 0) i - 1 else self.root_aridity_;
      };
    };

    {
      next = func() : ?Nat64 {
        let leaf = label l : ?Nat64 loop {
          let (node, i) = stack[depth - 1];
          let max = if (depth > 1) self.aridity_ else self.root_aridity_;
          if (i < max) {
            let child = Layout.getChild(self, node, i);
            if (child == 0) {
              stack[depth - 1] := (node, next_step(i));
              continue l;
            };
            if (child & 1 == 1) {
              stack[depth - 1] := (node, next_step(i));
              break l(?(child >> 1));
            };
            stack[depth] := (child, if (forward) 0 else self.aridity_ - 1);
            depth += 1;
          } else {
            if (depth == 1) break l null;
            depth -= 1;
            let (prev_node, prev_i) = stack[depth - 1];
            stack[depth - 1] := (prev_node, next_step(prev_i));
          };
        };
        leaf;
      };
    };
  };

  func entries_(self : Trie.StableTrie, dir : Dir) : Types.Iter<(Blob, Blob)> = makeIter(self, dir).map<Nat64, (Blob, Blob)>(
    func(leaf) = (Layout.getKey(self, leaf), Layout.getValue(self, leaf))
  );

  func vals_(self : Trie.StableTrie, dir : Dir) : Types.Iter<Blob> = makeIter(self, dir).map<Nat64, Blob>(
    func(leaf) = Layout.getValue(self, leaf)
  );

  func keys_(self : Trie.StableTrie, dir : Dir) : Types.Iter<Blob> = makeIter(self, dir).map<Nat64, Blob>(
    func(leaf) = Layout.getKey(self, leaf)
  );

  /// Iterate entries in forward order.
  public func entries(self : Trie.StableTrie) : Types.Iter<(Blob, Blob)> = entries_(self, #forward);

  /// Iterate entries in reverse order.
  public func entriesRev(self : Trie.StableTrie) : Types.Iter<(Blob, Blob)> = entries_(self, #reverse);

  /// Iterate values in forward order.
  public func vals(self : Trie.StableTrie) : Types.Iter<Blob> = vals_(self, #forward);

  /// Iterate values in reverse order.
  public func valsRev(self : Trie.StableTrie) : Types.Iter<Blob> = vals_(self, #reverse);

  /// Iterate keys in forward order.
  public func keys(self : Trie.StableTrie) : Types.Iter<Blob> = keys_(self, #forward);

  /// Iterate keys in reverse order.
  public func keysRev(self : Trie.StableTrie) : Types.Iter<Blob> = keys_(self, #reverse);
};
