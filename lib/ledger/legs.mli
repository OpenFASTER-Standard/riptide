(** Leg construction: the one piece of trusted code that ever turns a single
    {!Schema.transfer_request} into the two {!Riptide_batch_commit.Batch_commit.write}s of its
    debit and credit legs. See docs/superpowers/specs/2026-10-01-layer2-ledger-module-design.md,
    Decision 1: {!Authorize.authorize} can only check what a single write can self-certify, in
    isolation -- the guarantee that both legs of a transfer are truly a matched, balancing pair
    comes entirely from BOTH legs always being derived here, together, from the same single
    decoded request. There is no other way to produce a {!Schema.transfer_leg} write anywhere in
    this module's own trusted code. *)

val legs_of_request :
  actor:Riptide.Envelope.actor_id ->
  causation:Riptide.Envelope.event_id ->
  correlation:Riptide.Envelope.event_id ->
  Schema.transfer_request ->
  Riptide_batch_commit.Batch_commit.write list
(** [legs_of_request ~actor ~causation ~correlation r] always returns exactly
    [[debit_leg; credit_leg]], built from [r]'s own fields:
    - debit: [{ transfer_id = r.request_id; role = Debit; this_account = r.from_account;
      other_account = r.to_account; amount = r.amount }]
    - credit: [{ transfer_id = r.request_id; role = Credit; this_account = r.to_account;
      other_account = r.from_account; amount = r.amount }]

    Each is wrapped as a {!Riptide_batch_commit.Batch_commit.write} with [payload =
    Schema.transfer_leg_to_value leg] and [merge_key = Some (Schema.account_merge_key
    leg.this_account)] -- i.e. each leg's own write is always tagged with the account it is
    about. [actor]/[causation]/[correlation] are passed through unchanged to both legs, making
    them two members of the same causal batch; [actor] is additionally recorded INSIDE each leg's
    own payload (see {!Schema.transfer_leg}'s [actor] field for why that is load-bearing rather
    than redundant), always the same value as the write's own, which is exactly the agreement
    {!Authorize.authorize} enforces.

    This function never fails and never rejects [r] -- even a self-transfer
    ([r.from_account = r.to_account]), a non-positive [r.amount], or a negative account id
    produces two well-paired (same [transfer_id], mirrored accounts, matching [amount]) legs; it
    is {!Authorize.authorize}'s job, not this function's, to reject a malformed leg once proposed
    (see Decision 1). *)

val decision_of_bytes :
  actor:Riptide.Envelope.actor_id ->
  causation:Riptide.Envelope.event_id ->
  correlation:Riptide.Envelope.event_id ->
  bytes ->
  (bool * Schema.transfer_request * Riptide_batch_commit.Batch_commit.write list, string) result
(** [decision_of_bytes ~actor ~causation ~correlation b] is {!Wire.decode_decision} applied to
    [b], then {!legs_of_request} applied to the decoded request -- [Error] (with a
    human-readable reason) if [b] is not a well-formed {!Wire.decision_bytes}-byte decision
    payload, and [Ok (accepted, request, legs)] otherwise, where [legs] is always exactly the two
    well-paired legs {!legs_of_request} would have produced for [request], REGARDLESS of
    [accepted].

    Building the legs even for a declined decision is deliberate: it keeps this function a pure,
    total decode-and-construct step with one behaviour to fuzz, and leaves the decision about
    whether those legs are ever proposed where it belongs -- in
    {!Accumulator.handle_guest_decision}, the only caller, which proposes them only for a
    first-time accept.

    {b This is the guest-facing trust boundary}: the host's [propose_write] closure calls this
    (via {!Accumulator.handle_guest_decision}) on the raw bytes a WASM guest supplies, so it is
    this function -- not anything inside the guest -- that is what actually guarantees "both legs
    of a transfer are a genuine, matched pair". It decodes those bytes exactly ONCE and hands the
    decoded request back to its caller alongside the legs, so no caller needs to decode them a
    second time (final whole-branch review, finding M9). *)
