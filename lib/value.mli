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
      (** Content-addressed by its raw IEEE-754 bit pattern, not by any
          OCaml equality relation - [canonical_encode] emits
          [Int64.bits_of_float f] verbatim. Two consequences that follow
          directly and are both intentional, not bugs: (1) [0.0] and
          [-0.0] are *distinct* values here (different sign bit, hence
          different bytes and different {!content_hash}), even though
          OCaml's [=] and [compare] both treat them as equal - a
          replicated log where two nodes derive [-0.0] vs [0.0] from
          different arithmetic paths will therefore disagree on the
          content hash of "the same" logical zero. (2) two NaN payloads
          with different bit patterns are distinct values, while two NaNs
          with identical bits are the same value, even though OCaml's [=]
          on the [float] type follows IEEE754 (where [nan = nan] is
          [false]) rather than bit-pattern equality. Callers that need
          value-level (not bit-pattern) float equality must normalize
          before constructing a [Float] (e.g. canonicalize [-0.0] to
          [0.0] and NaN payloads to a single fixed pattern) - this module
          does not do it for you. *)
  | String of string
  | Bytes of string

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
    one). "Same logical value" here means: equal after normalizing
    [Record] field order and [Map] entry order (see above) - it does
    {b not} mean equal under OCaml's [=] or [compare]. In particular,
    [Float] is compared by raw IEEE-754 bit pattern, not by either of
    those (see {!scalar}'s [Float] case for exactly what that implies
    for [0.0]/[-0.0] and for NaN). *)
val canonical_encode : value -> string

(** SHA-256 of {!canonical_encode}. *)
val content_hash : value -> hash

(** Renders a raw {!hash} as lowercase hex for display/logging. Raises
    [Invalid_argument] if [h] is not exactly 32 bytes (the shape any real
    {!content_hash} always has). *)
val hash_to_hex : hash -> string
