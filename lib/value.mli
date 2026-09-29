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
    for [0.0]/[-0.0] and for NaN).

    Raises [Invalid_argument] if [v] contains a [Record] with two fields
    sharing the same name, or a [Map] with two entries whose keys encode
    to the same bytes - at any nesting depth, not just the top level. A
    duplicate key has no well-defined position in the canonical (sorted)
    order, so there is no single correct way to encode it; this is
    rejected outright rather than silently picked by whichever entry
    happened to sort first. This holds even for a [value] built directly
    in memory, never round-tripped through {!canonical_decode} (which
    enforces the same rule from the wire-bytes side).

    Also raises [Invalid_argument] if [v] nests [Record]/[Sum]/[Sequence]/[Map]
    more than 1000 levels deep - a real, enforced limit, not aspirational
    language: this codebase's own real payloads never come close to it (the
    deepest, an [Envelope], is a handful of levels), and it exists
    specifically to keep a [Map] with 2+ entries at every nesting level -
    still algorithmically quadratic in depth (see [encode_into]'s own doc
    comment in the implementation) - cheap regardless of how deep a [value]
    built directly in memory happens to be, not just one that arrived via
    {!canonical_decode} (which enforces the identical cap from the wire-bytes
    side, for a different reason - see there). *)
val canonical_encode : value -> string

(** The structural inverse of {!canonical_encode}: decodes a [value] from
    its canonical byte encoding.

    Round-trip relationship: for any [v] with no duplicate-keyed [Record] or
    [Map] anywhere in it (a [v] that does have one makes {!canonical_encode}
    itself raise [Invalid_argument] - see that function's own doc comment
    above - so [canonical_decode] is never even reached for such a [v]),
    [canonical_decode (canonical_encode v)] reproduces [v]'s logical
    content, but {b not necessarily its exact OCaml representation} —
    decoding re-encodes [Record] fields and [Map] entries into the same
    canonical (sorted) order {!canonical_encode} would have chosen, which is
    not necessarily the order the original value was constructed with if
    that value's fields/entries were out of sorted order to begin with. The
    property that actually holds for any such duplicate-key-free [v] is
    [canonical_encode (canonical_decode (canonical_encode v)) =
    canonical_encode v] - i.e. round-tripping through decode is a no-op once
    a value has already been through one canonical encoding.

    Raises [Invalid_argument] if: the input is empty; an unknown tag byte is
    encountered; any length or count prefix - a string/bytes length, or a
    [Record]/[Sequence]/[Map] element/entry count - would require reading
    past the end of the input; or bytes remain in the input after a
    complete value has been decoded (a well-formed prefix followed by
    trailing garbage is rejected as a whole, not accepted as "the first
    well-formed value found"). Every length/count prefix is checked against
    the bytes actually remaining in the input before being trusted, so
    malformed or adversarial input (this decoder is intended for bytes
    arriving over a network with no integrity guarantee) raises cleanly
    rather than reading out of bounds, looping unboundedly, or crashing with
    an unhandled exception.

    Two further bounds are real, enforced limits (not aspirational language) -
    both independently necessary, since they guard against two different
    resources an adversarial input can exhaust:

    - {b Nesting depth}: rejected past 1000 levels of [Record]/[Sum]/[Sequence]/[Map]
      nesting, the same cap {!canonical_encode} enforces (see its own doc
      comment) - without it, a wire payload that grows only linearly with depth
      (as little as ~9 bytes per extra nesting level via the cheapest shape, a
      single-element [Sequence]) can drive this function's own recursion
      arbitrarily deep, exhausting the call stack for single-digit-MB of wire
      bytes - orders of magnitude cheaper than the stack space it consumes.

    - {b Total decoded node count}: rejected once the number of decoded
      nodes (every [Scalar]/[Record]/[Sum]/[Sequence]/[Map] counts as one,
      at any depth) exceeds a budget scaled to the input's own byte length -
      [max 10_000 (String.length input / 64)], i.e. at most one decoded node
      per 64 bytes of input, floored at 10,000 nodes so small, legitimate
      inputs are never affected. Without this, a compact wire encoding
      (e.g. a flat [Sequence] of cheap [Bool] elements, needing only 2 wire
      bytes each) can still expand into a live in-memory tree tens of times
      larger than its own byte size, purely from OCaml's own per-node heap
      overhead (measured: ~55 bytes of live heap per [Bool] node, a ~27x
      amplification over its 2-byte wire cost) - a 64 MiB frame shaped this
      way was measured reaching ~9 GB live memory with no other protection
      in place (docs/superpowers/specs/2026-09-29-audit-remediation-design.md,
      Decision 2.3), which the existing "claimed count can't exceed
      remaining bytes" check alone does not prevent, since that check only
      rules out claiming *more nodes than the input could physically
      contain* - it says nothing about the memory cost of the nodes the
      input genuinely does contain.

    Also raises [Invalid_argument] if a [Record]'s fields, or a [Map]'s
    entries, are not encoded in strict canonical order - each field name
    (respectively, each entry's encoded key bytes) must compare strictly
    greater than the previous one, by the same comparator
    {!canonical_encode} sorts by. This rejects both a genuinely
    out-of-order encoding and an exact duplicate key (which compares
    equal to, rather than greater than, its predecessor) - see
    {!canonical_encode}'s own doc comment for why a duplicate key has no
    single valid encoding to begin with. Without this check, two
    byte-different wire encodings could decode to values considered "the
    same" but disagree on {!content_hash}, defeating the whole point of
    calling this encoding "canonical". *)
val canonical_decode : string -> value

(** SHA-256 of {!canonical_encode}. Inherits {!canonical_encode}'s own [Invalid_argument]
    (M4, task-6 review): [v] containing a duplicate-keyed [Record] or [Map] anywhere in it
    makes this raise rather than return a hash. *)
val content_hash : value -> hash

(** Renders a raw {!hash} as lowercase hex for display/logging. Raises
    [Invalid_argument] if [h] is not exactly 32 bytes (the shape any real
    {!content_hash} always has). *)
val hash_to_hex : hash -> string
