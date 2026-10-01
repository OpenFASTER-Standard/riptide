(** The ledger module's own policy for {!Riptide_batch_commit.Batch_commit.create}'s mandatory
    [~authorize] parameter -- the first real policy that universal checkpoint has ever carried
    (see docs/superpowers/specs/2026-10-01-layer2-ledger-module-design.md, Decision 1). Evaluated
    once per write, in isolation, with no visibility into any sibling write in the same batch --
    see that Decision for the full argument for why this function checks exactly what a SINGLE
    write can self-certify, and nothing about cross-write pairing (that guarantee comes from
    {!Legs} instead). *)

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
    whole-branch review, finding I4): see {!Schema.transfer_leg}'s [actor] field. The field exists
    so that a {!Riptide_batch_commit.Batch_commit.materialize_sink} -- which never receives the
    committing write's [actor] -- can still tell apart legs from different authors. That is only
    worth anything if the field is true, and this check is what makes it true for every leg that
    ever reaches the committed log.

    {b What this function still cannot check, by construction, and why that is disclosed rather
    than fixed here}: its argument is one write. It can therefore never verify that a transfer's
    two legs are both present in the same batch, balance each other, or indeed that a leg has a
    sibling at all -- {!Riptide_batch_commit.Batch_commit}'s own [~authorize] signature has no
    batch-level form (see that module's own disclosure of this at
    {!Riptide_batch_commit.Batch_commit.create}). A WELL-FORMED single leg proposed directly, by a
    client that never went through this module's guest or {!Legs} at all, is consequently ALLOWED,
    and that is by design rather than an oversight: it is exactly how both of this module's test
    harnesses seed an account's opening balance, there being no "mint"/account-opening flow in
    this focused-core scope. What is structurally refused is a MALFORMED direct leg, on every axis
    listed above. *)
