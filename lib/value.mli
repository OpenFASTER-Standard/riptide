(** The content-addressed algebraic value universe — Layer 0's base data
    model. Every domain-specific schema (Task 6 onward) is expressed as a
    functor/instance over this universe, never as a privileged format of
    its own (this is the direct fix for the old Riptide's RDF-only
    limitation). *)

(** Raw 32-byte SHA-256 digest. Not hex-encoded — use {!hash_to_hex} for
    display. *)
type hash = string

type scalar =
  | Bool of bool
  | Int of int64
  | Float of float
  | String of string
  | Bytes of bytes

(** [Record] fields and [Map] entries need not be pre-sorted by the
    caller — {!canonical_encode} sorts them, so two values built with
    fields/entries in different order but the same logical content encode
    identically. *)
type value =
  | Scalar of scalar
  | Record of (string * value) list
  | Sum of string * value
  | Sequence of value list
  | Map of (value * value) list

(** Deterministic byte encoding: the same logical value always produces
    the same bytes, and structurally different values are never
    ambiguous (length-prefixed at every variable-length point, so no
    concatenation of two values can collide with a differently-shaped
    one). *)
val canonical_encode : value -> string

(** SHA-256 of {!canonical_encode}. *)
val content_hash : value -> hash

val hash_to_hex : hash -> string
