(** The join-semilattice law contract (design spec Decision 1). Any type
    claiming to be mergeable at Layer 0 must satisfy: [join] is
    commutative, associative, and idempotent, and [bottom] is [join]'s
    identity element. This module type states the contract's shape; the
    laws themselves are checked by {!Lattice_conformance.tests} against a
    real generator for a concrete instance's [t] — they cannot be checked
    by the type system alone. *)
module type S = sig
  type t

  val bottom : t
  (** The identity element: [join bottom x = x] for all [x]. *)

  val join : t -> t -> t
  (** Must be commutative, associative, and idempotent. *)
end
