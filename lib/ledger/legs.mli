(** Leg construction: the one piece of trusted code that ever turns a single
    {!Schema.transfer_request} into the two {!Riptide_batch_commit.Batch_commit.write}s of its
    debit and credit legs. See docs/superpowers/specs/2026-10-01-layer2-ledger-module-design.md,
    Decision 1: {!Authorize.authorize} can only check what a single write can self-certify, in
    isolation -- so both legs of a transfer are always derived here, together, from the same single
    decoded request, and there is no other way to produce a {!Schema.transfer_leg} write anywhere in
    this module's own trusted code.

    {b That construction-time derivation is no longer the ONLY thing standing behind the pairing}
    (Task 7, the Layer 0/Layer 2 boundary revision). It used to be, and that was a genuinely weaker
    kind of guarantee than it looked: construction-correctness verified by fuzzing the constructor,
    rather than a checkpoint no write could bypass -- a well-formed single leg proposed directly, by a
    caller that never came through here, was necessarily allowed.
    {!Riptide_batch_commit.Batch_commit.create}'s own [?authorize_batch] closed that, and
    {!Authorize.authorize_batch} is this module's implementation of it. This module now gets BOTH:
    the pairing is built correctly here, and it is independently verified at the one checkpoint every
    committed write passes through. *)

val event_id_of_request : Schema.transfer_request -> Riptide.Envelope.event_id
(** [event_id_of_request r] is the {!Riptide.Envelope.event_id} every leg of [r]'s own batch uses
    as BOTH its [causation] and its [correlation] -- the content hash of
    {!Schema.transfer_idempotency_key} of [r]'s [request_id], and nothing else. Deterministic from
    the request alone, deliberately: a re-proposal of an already-accepted transfer (see
    {!Accumulator.handle_guest_decision}) is then byte-identical to the original batch rather than
    merely equivalent to it.

    Public because it is the one place that derivation lives, and because {!decision_of_bytes}
    applies it ITSELF rather than taking [~causation]/[~correlation] from its caller -- a caller
    holding only the guest's raw bytes has not yet seen the [request_id] the derivation needs. *)

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

val decision_write :
  actor:Riptide.Envelope.actor_id ->
  accepted:bool ->
  Schema.transfer_request ->
  Riptide_batch_commit.Batch_commit.write
(** [decision_write ~actor ~accepted r] is the ONE durable record that [r] has been decided, and how
    (Task 7, the Layer 0/Layer 2 boundary revision): [payload = ]{!Wire.decision_to_value}
    [~accepted r], [merge_key = None], and [causation = correlation = ]{!event_id_of_request}[ r],
    the same identity its legs carry.

    [merge_key = None] is deliberate and load-bearing in two directions. A decision is a log fact,
    not materialized state: {!Accumulator.handle_guest_decision} reads it back with
    {!Riptide_batch_commit.Batch_commit.committed_writes_for}, i.e. out of the committed log, never
    out of a materializer -- so handing it a [merge_key] would opt it into a materialization no sink
    in this module has any use for. It also keeps it invisible to {!Accumulator.materialize_sink},
    which is what makes an accepted transfer's batch materialize to exactly its two balance updates
    and nothing else.

    {b The one consequence this carries, disclosed rather than hidden}: a write with no [merge_key]
    is, by {!Riptide_batch_commit.Batch_commit.write}'s own doc comment, as vulnerable to
    {!Riptide_storage.File_storage}'s bounded ring WAL evicting it as any other. For an ACCEPTED
    transfer that costs nothing -- the decision shares its batch with two legs that DO carry
    [merge_key]s, so {!Riptide_batch_commit.Batch_commit.write_at_op_number_has_merge_key} reports
    that entry as materialization-protected. A DECLINED transfer's batch carries this write alone, so
    it is reported as freely evictable, and a deployment that evicts it loses the decline record and
    becomes able to re-decide that request. That is strictly better than the in-memory table this
    replaced (which lost EVERY decision, accepted and declined alike, on every restart), it is
    governed by eviction-gating machinery that is a different task's own scope, and it is a bounded
    ring's inherent trade rather than something this module can decide for its deployment. *)

val batch_of_decision :
  actor:Riptide.Envelope.actor_id ->
  accepted:bool ->
  Schema.transfer_request ->
  Riptide_batch_commit.Batch_commit.write list
(** [batch_of_decision ~actor ~accepted r] is the WHOLE batch a decision about [r] commits as one
    atomic unit, under {!Schema.transfer_idempotency_key} of [r]'s own [request_id]:
    - declined: exactly [[decision_write ~actor ~accepted:false r]] -- one write, no legs.
    - accepted: [decision_write ~actor ~accepted:true r] followed by the two
      {!legs_of_request} legs, in that order.

    Atomicity is the point, not an incidental convenience: the record that a transfer was accepted
    and the legs that move its money either both commit or neither does, so no log state exists in
    which a transfer is on record as accepted while its legs are absent.
    {!Authorize.authorize_batch} enforces exactly that direction at the commit checkpoint, for
    every batch, including ones this function did not build.

    {b Not "or the reverse"} (final whole-branch review, IMP-2 -- this sentence used to claim both
    directions). A committed batch carrying a well-formed leg PAIR and no decision record at all is
    [Allow]ed by {!Authorize.authorize_batch}, by design. That direction -- every leg traceable to a
    committed decision record -- is guaranteed only by construction, i.e. by the fact that this
    function is the only thing {!Accumulator.handle_guest_decision} ever proposes and it always emits
    the record alongside the legs. It is not a property the checkpoint makes unviolatable. See
    {!Authorize.authorize_batch}'s own doc comment for the precise three-property statement. *)

val decision_of_bytes :
  actor:Riptide.Envelope.actor_id ->
  bytes ->
  (bool * Schema.transfer_request * Riptide_batch_commit.Batch_commit.write list, string) result
(** [decision_of_bytes ~actor b] is {!Wire.decode_decision} applied to [b], then
    {!legs_of_request} applied to the decoded request -- [Error] (with a
    human-readable reason) if [b] is not a well-formed {!Wire.decision_bytes}-byte decision
    payload, and [Ok (accepted, request, legs)] otherwise, where [legs] is always exactly the two
    well-paired legs {!legs_of_request} would have produced for [request], REGARDLESS of
    [accepted], with [causation = correlation = ]{!event_id_of_request} of that request.

    Building the legs even for a declined decision is deliberate: it keeps this function a pure,
    total decode-and-construct step with one behaviour to fuzz, and leaves the decision about
    whether those legs are ever proposed where it belongs -- in
    {!Accumulator.handle_guest_decision}, this function's only production caller, which proposes
    them only for a first-time accept.

    {b This is the guest-facing trust boundary}: the host's [propose_write] closure calls this
    (via {!Accumulator.handle_guest_decision}) on the raw bytes a WASM guest supplies, so it is
    this function -- not anything inside the guest -- that is what actually guarantees "both legs
    of a transfer are a genuine, matched pair". It decodes those bytes exactly ONCE and hands the
    decoded request back to its caller alongside the legs, so no caller needs to decode them a
    second time (final whole-branch review, finding M9).

    That sentence used to be false, and the fix was to make it true rather than to soften it
    (fix-wave round 2, re-review finding I3): fix round 1 renamed this function from
    [legs_of_bytes] and documented it as the trust boundary, but left
    {!Accumulator.handle_guest_decision} calling {!Wire.decode_decision} and {!legs_of_request}
    inline instead of rewiring it here -- so the one function the fuzz test in
    [test/test_ledger_authorize_fuzz.ml] hammers with adversarial bytes was not on the path any
    production write actually took. It is now the only decode of those bytes anywhere in this
    module's host half. *)
