(** A register that keeps the value with the highest timestamp, breaking
    exact-timestamp ties deterministically by the value's own content hash
    — so [join] stays commutative even when two writers pick the same
    timestamp.

    {b [bottom] is the identity element structurally, not merely numerically}
    (final-review finding, 2026-09-23). The original version relied on
    [bottom] carrying [timestamp = Int64.min_int] and trusted that "any real
    write dominates it" — which is false at exactly that boundary. Two values
    with equal timestamps fall through to the content-hash tiebreak below, so
    for any real write [x] with [timestamp = Int64.min_int] whose
    [content_hash] sorts at-or-below [content_hash (Sequence [])],
    [join bottom x] returned [bottom] instead of [x]: a provable violation of
    [join bottom x = x], one of the four laws [Lattice_intf.S] exists to
    guarantee. It was not a rare corner either — of 200 sampled
    [Scalar (String _)] payloads, about half hash below
    [content_hash (Sequence [])]. The reachable consequence was real write
    loss: [Riptide_materialize.Materializer] folds each committed write into
    its [merge_key]'s accumulator starting from [bottom], so such a write was
    swallowed and the accumulator stayed at [bottom] forever with nothing
    surfacing the loss.

    The fix is [is_bottom] below: [join] tests each argument for being [bottom]
    {e structurally} and returns the other one unconditionally, before any
    timestamp or hash comparison happens. [bottom] is therefore the identity
    for every representable value, with no reliance on how timestamps or
    hashes happen to order.

    {b Why this shape and not a redesigned [t]}: the alternative was to make
    "never written" unrepresentable as a real write (an [option] or a variant
    around the record). That is arguably cleaner in the abstract, but this
    module's [t] is deliberately a concrete, exposed record in
    [last_write_wins.mli], and callers construct and destructure it as one
    (record literals in [Riptide_materialize] codecs, and
    [Last_write_wins.bottom.timestamp] as a "nothing materialized yet" probe
    in the batch-commit materialization tests). Changing the type shape would
    ripple through every one of those for no gain in the actual guarantee:
    the structural check below makes the law hold unconditionally either way.

    Note that a real write whose value {e is} [Sequence []] at
    [timestamp = Int64.min_int] is indistinguishable from [bottom] here, and
    that is sound rather than a residual hole — it {e equals} [bottom], so
    returning either side satisfies every law, and no information is lost by
    treating them as the same element. The lattice's elements are its values,
    not the history of how they were produced. *)
type t = { value : Riptide.Value.value; timestamp : int64 }

let bottom = { value = Riptide.Value.Sequence []; timestamp = Int64.min_int }

(* Structural equality with [bottom], not a timestamp test. A timestamp-only test
   ([x.timestamp = Int64.min_int]) would itself break commutativity: for two DIFFERENT real
   values both sitting at [Int64.min_int], "if a is bottom-ish return b" gives [join a b = b]
   while [join b a = a]. Comparing against [bottom] as a whole value is what keeps the
   short-circuit confined to the one element it is allowed to apply to.

   Polymorphic [=] is safe and cheap here specifically because the right-hand side is
   [Sequence []]: OCaml's structural comparison discriminates on the constructor tag first and,
   for a [Sequence], immediately on [[]] (an immediate) versus [_ :: _] (a block), so it neither
   walks a large value nor ever reaches a [Float] payload where [nan <> nan] could matter. *)
let is_bottom (x : t) = Int64.equal x.timestamp bottom.timestamp && x.value = bottom.value

let join a b =
  if is_bottom a then b
  else if is_bottom b then a
  else if a.timestamp <> b.timestamp then (if a.timestamp > b.timestamp then a else b)
  else if Riptide.Value.content_hash a.value >= Riptide.Value.content_hash b.value then a
  else b
