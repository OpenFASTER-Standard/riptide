(** The ledger module's own domain schema: the two write shapes this module ever produces, their
    hand-written {!Riptide.Value.value} codecs, and the merge-key/idempotency-key conventions that
    route them. See docs/superpowers/specs/2026-10-01-layer2-ledger-module-design.md, Decision 2.

    Hand-written [to_value]/[of_value] over {!Riptide.Value.value}, following the exact pattern
    every other domain type in this codebase already uses ({!Riptide.Envelope.to_value},
    [Batch_commit.write_to_value]) -- deliberately NOT task-master Task 2.1's
    schema-morphism machinery, which does not exist as code yet (see the design spec's own "A real
    gap found and resolved during this brainstorm" section).

    {b Every integer field here is a SIGNED [int64]}, and that is load-bearing rather than
    incidental -- see {!Wire}'s own doc comment for what it means on the host/guest byte wire, and
    {!Authorize.authorize} for which of these fields are constrained to a narrower range than
    [int64] itself allows. *)

type role =
  | Debit
  | Credit
(** Which side of a transfer one {!transfer_leg} is. A leg's own signed balance delta is DERIVED
    from this, never stored: [-amount] for [Debit], [+amount] for [Credit] (see
    {!Accumulator.balance_delta}, the single place that derivation lives). *)

type transfer_request = {
  request_id : int64;
  from_account : int64;
  to_account : int64;
  amount : int64;
}
(** What a client asks for, proposed at {!requests_merge_key}. Not itself balance-affecting: it
    records the ask, and the WASM guest subscribed to that key is what later decides whether it
    happens (see {!Wire.encode_decision} for how that decision comes back).

    [request_id] is the client's own identifier for this transfer, and becomes the
    {!transfer_leg.transfer_id} of both legs it produces. It is also what
    {!transfer_idempotency_key} derives the legs batch's own idempotency key from, and what the
    first-decision-wins table in {!Accumulator} is keyed on -- so two genuinely different transfers
    must not share one.

    [from_account]/[to_account] are {b constrained to be non-negative} by
    {!Authorize.authorize} (final whole-branch review, finding I2) -- see that function for why
    the constraint lives there rather than in this type. [amount] is a positive magnitude; a
    non-positive one is caught per-leg, at the same checkpoint. *)

type transfer_leg = {
  transfer_id : int64;
  role : role;
  actor : Riptide.Envelope.actor_id;
  this_account : int64;
  other_account : int64;
  amount : int64;
}
(** One side of a transfer: the balance-affecting write shape, proposed at
    [account_merge_key this_account]. {b Self-certifying}: every field
    {!Authorize.authorize} needs in order to judge THIS leg alone is present in THIS leg's own
    payload, with no need to see its sibling -- which is exactly what makes the per-write
    authorization checkpoint able to carry a real policy at all (design spec Decision 1).

    [amount] is always a positive magnitude; [role] supplies the sign.

    [actor] is {b the same actor as the {!Riptide_batch_commit.Batch_commit.write} carrying this
    payload}, and {!Authorize.authorize} DENIES any leg whose payload disagrees with its own
    write's [actor] -- so for any leg that ever reaches the committed log, this field is a
    structurally-guaranteed record of who authored it.

    {b Why it is here, stated accurately rather than as it was originally justified} (Task 7, the
    Layer 0/Layer 2 boundary revision). The original reason (final whole-branch review, finding I4)
    was that a {!Riptide_batch_commit.Batch_commit.materialize_sink}'s [write] callback received only
    [~merge_key] and the payload -- never the committing write's [actor] -- so the accumulator
    downstream of it could not tell a module-authored leg apart from one authored by any other path
    (a test harness's own seeding convention, say), and legs from the two could collide in its dedup
    table. {b Both halves of that reason are now gone}: [write] receives the committing write's real
    [actor] (spec Decision 2), and the accumulator has no dedup table at all any more (spec Decision
    1 -- a durable watermark replaced it). The field is kept anyway, and this is a deliberate choice
    rather than inertia: a MATERIALIZED balance is derived from these payloads and has no envelope,
    so a leg's own payload is the only place a committed leg's provenance survives at rest, and
    {!Authorize.authorize}'s agreement check is what makes that record trustworthy. What it is NOT
    any more is load-bearing for deduplication -- nothing in this module keys anything on it. *)

val requests_merge_key : string
(** ["ledger.requests"] -- the one key clients propose {!transfer_request}s at, and the one key
    this module's WASM guest is subscribed to. *)

val account_merge_key : int64 -> string
(** [account_merge_key id] is ["ledger.account." ^ decimal id] -- the merge_key an account's
    balance is materialized at, and the merge_key every {!transfer_leg} about that account is
    proposed under.

    Rendered with [%Ld], i.e. SIGNED decimal, so a negative [id] would render with a leading
    ['-']. The guest's own hand-rolled decimal routine in [test/fixtures/ledger.wat] is
    UNSIGNED and therefore cannot produce such a key at all -- the two agree for every
    non-negative [id] and only for those, which is precisely why {!Authorize.authorize} constrains
    account ids to be non-negative (final whole-branch review, finding I2). *)

val is_account_key : string -> bool
(** [is_account_key mk] is whether [mk] is shaped like an {!account_merge_key} -- i.e. carries the
    ["ledger.account."] prefix. Says nothing about whether the suffix parses as an account id; use
    {!account_of_merge_key} for that. *)

val account_of_merge_key : string -> int64 option
(** [account_of_merge_key mk] is the inverse of {!account_merge_key}: [Some id] when [mk] is
    exactly [account_merge_key id] for some [id], [None] otherwise (wrong prefix, or a suffix that
    is not a canonically-rendered [int64] -- including a suffix that parses but re-renders
    differently, e.g. a leading ['+'] or redundant zeros, so [account_merge_key] and this function
    are genuine inverses rather than merely compatible). *)

val transfer_idempotency_key : int64 -> string
(** [transfer_idempotency_key request_id] is the {!Riptide_batch_commit.Batch_commit.propose}
    idempotency key the two legs of that request's transfer are always proposed under --
    ["ledger-transfer-" ^ decimal request_id]. Deterministic from [request_id] alone, with no
    timestamp or nonce in it, which is what makes a retried or recovery-driven re-proposal of the
    same transfer land on the same key and therefore be absorbed rather than duplicated. *)

val transfer_request_to_value : transfer_request -> Riptide.Value.value
(** Encodes as a {!Riptide.Value.Record} with one [Scalar (Int _)] field per record field, named
    exactly as the record's own fields are. *)

val transfer_request_of_value : Riptide.Value.value -> transfer_request option
(** [None] -- never an exception -- for anything that is not a well-formed encoding of a
    {!transfer_request}: a non-[Record] shape, a missing field, a field of the wrong scalar type.
    An UNRECOGNIZED EXTRA field is tolerated, matching this codebase's own established
    [of_value] convention. *)

val transfer_leg_to_value : transfer_leg -> Riptide.Value.value
(** Encodes as a {!Riptide.Value.Record}; [role] is a {!Riptide.Value.Sum} tagged ["Debit"] or
    ["Credit"], [actor] a [Scalar (String _)], every other field a [Scalar (Int _)]. *)

val transfer_leg_of_value : Riptide.Value.value -> transfer_leg option
(** [None] -- never an exception -- for anything that is not a well-formed encoding of a
    {!transfer_leg}, on the same terms as {!transfer_request_of_value}, plus an unrecognized
    [role] tag. *)
