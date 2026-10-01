(** The ledger module's own policy for {!Riptide_batch_commit.Batch_commit.create}'s two
    authorization parameters -- the first real policy that universal checkpoint has ever carried
    (see docs/superpowers/specs/2026-10-01-layer2-ledger-module-design.md, Decision 1, and
    docs/superpowers/specs/2026-10-01-layer2-boundary-revision-design.md, Decision 4).

    Two functions, because there are two genuinely different kinds of question:

    - {!authorize} -- the mandatory [~authorize]. Evaluated once per write, in isolation, with no
      visibility into any sibling write in the same batch, so it checks exactly what a SINGLE write
      can self-certify: pure well-formedness.
    - {!authorize_batch} -- the optional [?authorize_batch]. Evaluated once per batch, against the
      whole write list, so it checks what only a batch can certify: that a transfer's two legs are
      both present, balance each other, and correspond to the decision record committed with them.

    Both are evaluated under the same guard, at the same moment, and either one returning [Deny]
    refuses the whole batch -- see {!Riptide_batch_commit.Batch_commit.propose}'s own
    "Authorization" section. A deployment of this module should wire BOTH; wiring only
    {!authorize} is valid (that is [?authorize_batch]'s own behaviour-preserving default) and leaves
    the cross-write invariant unenforced at the checkpoint, resting on construction-time correctness
    in {!Legs} alone. *)

val authorize :
  Riptide_batch_commit.Batch_commit.write -> Riptide_batch_commit.Batch_commit.decision
(** [authorize w] branches on [w.merge_key]:
    - [Some "ledger.requests"] (a {!Schema.transfer_request}): decodes [w.payload] via
      {!Schema.transfer_request_of_value}. [Deny] if that decode fails, or if either of its
      [from_account]/[to_account] is NEGATIVE. [Allow] otherwise. Notably this does {b not} judge
      the business question -- whether the sender can afford it -- which is the WASM guest's job,
      nor reject a self-transfer request, whose two legs are instead denied individually by the
      account-key case below.
    - [Some mk] where [mk] {!Schema.is_account_key} (a {!Schema.transfer_leg}): decodes [w.payload]
      via {!Schema.transfer_leg_of_value}. [Deny] if that decode fails, or if the decoded leg's
      [amount <= 0L], or if its [this_account = other_account], or if either of those accounts is
      NEGATIVE, or if [mk] does not equal {!Schema.account_merge_key} of its own [this_account] (a
      merge_key/account mismatch), or if the leg's own [actor] field disagrees with [w.actor].
      [Allow] otherwise -- i.e. the leg is individually well-formed.
    - Anything else ([None], or a [merge_key] this module has no opinion on): [Allow] -- this
      module only ever has a verdict about its own two write shapes; every other write passes
      through untouched.

    {b Why account ids are constrained to be non-negative} (final whole-branch review, finding
    I2): {!Schema.account_merge_key} renders an account id as SIGNED decimal, while the WASM
    guest's own hand-rolled decimal routine renders it UNSIGNED -- so host and guest agree on the
    key for a non-negative id and disagree for a negative one, which made a negatively-identified
    account structurally unaddressable by the guest (it would read balance 0 at a key nothing is
    ever written to, and therefore decline everything). Of the two available fixes -- teach the
    guest two's-complement signed-decimal rendering, or shrink the valid id domain to the range
    both sides already agree on -- this is the second, enforced here at the one checkpoint no
    write can bypass. The ids simply have no business being negative; rendering them in WASM by
    hand does.

    {b Why a leg's payload-declared [actor] is checked against its write's own} (final
    whole-branch review, finding I4): see {!Schema.transfer_leg}'s [actor] field, which also records
    why the original justification for that field -- that a
    {!Riptide_batch_commit.Batch_commit.materialize_sink} never receives the committing write's
    [actor], so the field was the only way to tell legs from different authors apart in a dedup table
    -- stopped being true in Task 7 (a sink now receives the real [actor], and the dedup table is
    gone). The field is still kept, and this check is still what makes it true: it is the only place a
    committed leg's provenance survives at rest, since a materialized balance derived from these
    payloads has no envelope of its own.

    {b What this function cannot check, by construction, and where that is now checked instead}
    (Task 7, the Layer 0/Layer 2 boundary revision -- this paragraph used to disclose an open gap and
    now points at its closure): its argument is one write, so it can never verify that a transfer's
    two legs are both present in the same batch, balance each other, or indeed that a leg has a
    sibling at all. {!Riptide_batch_commit.Batch_commit.create} now takes a second, batch-level hook
    for exactly this, and {!authorize_batch} below is this module's implementation of it -- a
    checkpoint no committed write bypasses, not a construction-time convention. A WELL-FORMED single
    leg proposed directly, by a client that never went through this module's guest or {!Legs} at all,
    was previously ALLOWED (nothing in one write reveals its provenance); through a handle wired with
    [?authorize_batch:]{!authorize_batch} it is now DENIED. What is still structurally refused by this
    function alone, on every axis listed above, is a MALFORMED leg, direct or not. *)

val authorize_batch :
  Riptide_batch_commit.Batch_commit.write list -> Riptide_batch_commit.Batch_commit.decision
(** [authorize_batch writes] is the CROSS-WRITE half of this module's policy -- wire it as
    {!Riptide_batch_commit.Batch_commit.create}'s [?authorize_batch] (Task 7, the Layer 0/Layer 2
    boundary revision, design spec Decision 4, closing Task 6's own boundary friction item 2 and
    final whole-branch review finding I9). It decides on two derived views of [writes], and nothing
    else:

    - its {b legs}: every write whose [merge_key] {!Schema.is_account_key}, decoded via
      {!Schema.transfer_leg_of_value} (a write that fails to decode counts as a leg, and denies --
      {!authorize} denies it too, but this hook reaches its own verdict rather than relying on that).
    - its {b decision records}: every write with [merge_key = None] whose payload decodes via
      {!Wire.decision_of_value}, i.e. every {!Legs.decision_write}.

    {b On the legs alone:}
    - no legs: [Allow]. A client's {!Schema.transfer_request}, this module's own decision-only
      decline batch, and any write shape this module has no opinion on all land here -- there is
      nothing cross-write to check.
    - exactly two legs: they must be a matched, balancing PAIR -- same [transfer_id], same [actor],
      OPPOSITE roles (one {!Schema.Debit}, one {!Schema.Credit}), equal [amount], and each one's
      [this_account] equal to the other's [other_account]. Any single one of those failing is
      [Deny], each with its own named reason.
    - any other number of legs (one, three, …): [Deny]. {b This is the clause that closes the
      disclosed gap above}: a lone well-formed leg, and an over-stuffed batch of them, are both
      refused now.

    {b And, when the batch also carries this module's own decision record, on the correspondence
    between the two:} exactly one decision record is permitted (two or more is [Deny]), and
    - a DECLINED decision's batch must carry NO legs, and
    - an ACCEPTED decision's batch must carry exactly the pair its own request authorises: the legs'
      shared [transfer_id] must be the request's [request_id], their [amount] the request's
      [amount], the debit leg's [this_account] the request's [from_account], and the credit leg's
      [this_account] its [to_account].

    That correspondence is what makes the log's decision record and the money it moves inseparable:
    no committed state can exist in which a transfer is on record as accepted while its legs are
    absent, nor in which legs exist that no committed decision authorised, nor in which a decline
    somehow carries legs. {!Legs.batch_of_decision} constructs exactly such batches, and this
    function is what makes that true of every committed batch rather than only of the ones that
    function built.

    {b What this function deliberately does NOT check}: anything a single write can self-certify
    (that is {!authorize}'s job, and duplicating it here would create two places to keep in
    agreement), and anything about the business question -- whether the sender can afford the
    transfer -- which is the WASM guest's job and which no checkpoint here can see a balance for. A
    self-transfer's two legs are a perfectly matched pair by every criterion above and are [Allow]ed
    here; they are denied individually by {!authorize}'s [this_account = other_account] clause, which
    is the correct division of labour rather than a gap. *)
