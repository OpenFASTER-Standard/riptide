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
    past a hard depth limit, or if it contains more than a hard total-node-count
    limit - both real, enforced limits, not aspirational language, and both
    enforced identically by {!canonical_decode} (see its own doc comment for
    the full reasoning behind each and why they must be symmetric):

    - {b Nesting depth}: the outermost [v] is depth 0; each level of
      [Record]/[Sum]/[Sequence]/[Map] nesting inside it increases depth by 1.
      Raises as soon as encoding would need to process a node at depth 1001 or
      deeper - so a [v] nested exactly 1001 levels deep is still accepted, as
      long as that innermost (1001st) level is itself empty (an empty
      [Record]/[Sequence]/[Map], or a [Scalar]) and so has no child of its own
      needing to be processed at depth 1001. This codebase's own real payloads
      never come close to this limit (the deepest, an [Envelope], is a handful
      of levels), and it exists specifically to keep a [Map] with 2+ entries at
      every nesting level - still algorithmically quadratic in depth (see
      [encode_into]'s own doc comment in the implementation) - cheap regardless
      of how deep a [value] built directly in memory happens to be, not just
      one that arrived via {!canonical_decode} (which enforces the identical
      cap from the wire-bytes side, for a different reason - see there).

    - {b Total node count}: rejected once the number of nodes processed while
      encoding (every [Scalar]/[Record]/[Sum]/[Sequence]/[Map] counts as one,
      at any depth) exceeds the same fixed budget {!canonical_decode} enforces
      on the way back in - see its own doc comment for the exact figure and the
      reasoning behind it. Without this, a [value] built directly in memory
      (never round-tripped through {!canonical_decode}) could encode
      successfully past the budget {!canonical_decode} would reject the
      resulting bytes at, breaking the round-trip relationship documented
      below and, concretely, creating a silent data-loss path for any caller
      that authenticates-then-stores encoded bytes and treats "fails to
      decode" as "never stored" (see [Riptide_crypto.Redaction_store]'s own
      doc comment for a real instance of exactly that shape). *)
val canonical_encode : value -> string

(** The structural inverse of {!canonical_encode}: decodes a [value] from
    its canonical byte encoding.

    Round-trip relationship: for any [v] for which {!canonical_encode} itself
    succeeds (i.e. [v] has no duplicate-keyed [Record] or [Map] anywhere in
    it, and is within both the nesting-depth and total-node-count limits
    documented on {!canonical_encode} above - a [v] that violates any of
    those makes {!canonical_encode} itself raise [Invalid_argument], so
    [canonical_decode] is never even reached for such a [v]),
    [canonical_decode (canonical_encode v)] reproduces [v]'s logical
    content, but {b not necessarily its exact OCaml representation} —
    decoding re-encodes [Record] fields and [Map] entries into the same
    canonical (sorted) order {!canonical_encode} would have chosen, which is
    not necessarily the order the original value was constructed with if
    that value's fields/entries were out of sorted order to begin with. The
    property that actually holds for any such [v] (i.e. any [v] for which
    {!canonical_encode} itself succeeds) is [canonical_encode (canonical_decode
    (canonical_encode v)) = canonical_encode v] - i.e. round-tripping through
    decode is a no-op once a value has already been through one canonical
    encoding. This holds unconditionally for such a [v] specifically because
    {!canonical_encode} and {!canonical_decode} enforce the identical
    nesting-depth and total-node-count limits (see both functions' own doc
    comments): [canonical_encode v] succeeding already guarantees the wire
    bytes it produced describe a structure - same shape, same depth, same
    total node count - that stays within {!canonical_decode}'s own budget for
    those same bytes, so [canonical_decode (canonical_encode v)] can never
    itself raise on either bound. Before this was made symmetric,
    {!canonical_encode} had no such limits of its own, so this property could
    be false for a [v] whose encoded node count exceeded {!canonical_decode}'s
    budget: [canonical_encode v] would succeed, but [canonical_decode
    (canonical_encode v)] would then raise instead of reproducing [v], not
    merely be a partial no-op.

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

    - {b Nesting depth}: the outermost decoded value is depth 0; each level
      of [Record]/[Sum]/[Sequence]/[Map] nesting inside it increases depth by
      1. Rejected as soon as decoding would need to process a node at depth
      1001 or deeper - so input encoding a value nested exactly 1001 levels
      deep still decodes successfully, as long as that innermost (1001st)
      level is itself empty and so has no child of its own needing to be
      decoded at depth 1001. This is the same cap {!canonical_encode}
      enforces (see its own doc comment) - without it, a wire payload that
      grows only linearly with depth (as little as ~9 bytes per extra
      nesting level via the cheapest shape, a single-element [Sequence]) can
      drive this function's own recursion arbitrarily deep, exhausting the
      call stack for single-digit-MB of wire bytes - orders of magnitude
      cheaper than the stack space it consumes.

    - {b Total decoded node count}: rejected once the number of decoded
      nodes (every [Scalar]/[Record]/[Sum]/[Sequence]/[Map] counts as one,
      at any depth) exceeds a fixed budget of 1,048,576 nodes (64 MiB /
      64 bytes-per-node, derived from [lib/transport/tcp.ml]'s
      [max_message_size], the largest frame this codebase will ever hand to
      this function - see the implementation's own doc comment on
      [max_node_count] for the exact derivation). This is an ABSOLUTE
      ceiling, applied regardless of the particular input's own declared
      byte length - {b not} a budget scaled down for a smaller input. (An
      earlier version of this bound was scaled per-input -
      [max 10_000 (String.length input / 64)] - which, in practice, collapsed
      to a flat 10,000-node ceiling for every shape this codebase actually
      produces, since none of them are anywhere near 64 wire bytes/node; that
      made ordinary, legitimate traffic - e.g. a replicated log grown past
      ~1,000 entries, wrapped in a [Value.Sequence] for a view-change message
      - permanently undecodable well before any real size limit was
      approached. The fixed, absolute ceiling here closes that regression
      while keeping the identical worst-case memory bound.) Without any such
      budget, a compact wire encoding (e.g. a flat [Sequence] of cheap
      [Bool] elements, needing only 2 wire bytes each) can still expand into
      a live in-memory tree tens of times larger than its own byte size,
      purely from OCaml's own per-node heap overhead (measured: ~55 bytes of
      live heap per [Bool] node, a ~27x amplification over its 2-byte wire
      cost) - a 64 MiB frame shaped this way was measured reaching ~9 GB
      live memory with no other protection in place
      (docs/superpowers/specs/2026-09-29-audit-remediation-design.md,
      Decision 2.3), which the existing "claimed count can't exceed
      remaining bytes" check alone does not prevent, since that check only
      rules out claiming *more nodes than the input could physically
      contain* - it says nothing about the memory cost of the nodes the
      input genuinely does contain. The same fixed budget is enforced
      identically by {!canonical_encode} (see its own doc comment) - see
      the round-trip relationship documented above for why that symmetry
      matters.

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
