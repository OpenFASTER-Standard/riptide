(** Atomic multi-envelope commit: N related writes propose and commit as one indivisible unit
    through VSR, and land as N separate, individually hash-chained {!Riptide.Envelope.envelope}
    values -- not as one Envelope wrapping all N. See
    docs/superpowers/specs/2026-09-21-atomic-multi-envelope-commit-design.md for the full argument
    (why "entity" is not a Layer 0 concept, why this lives as a new module on top of unchanged
    VSR rather than inside it, why decode is lazy/pure rather than eagerly materialized).

    Deliberately does NOT touch {!Riptide_vsr.Replica}, {!Riptide.Envelope}, or {!Riptide.Log} --
    a batch is just a {!Riptide.Value.value}, encoded/decoded entirely inside this module, so
    {!Riptide_vsr.Replica.propose} and {!Riptide_vsr.Replica.entries} need no changes at all. *)

type write = {
  actor : Riptide.Envelope.actor_id;
  causation : Riptide.Envelope.event_id;
  correlation : Riptide.Envelope.event_id;
  payload : Riptide.Value.value;
  merge_key : string option;
}
(** One write within a batch -- everything {!Riptide.Envelope.envelope} needs except
    [predecessor_hash]/[sequence], which {!committed_envelopes} computes deterministically from
    each write's position once its batch commits, the same way {!Riptide.Log.append} computes
    them for a locally-appended entry.

    [merge_key] (task-master subtask 3.7's own closing mechanism, for writes that opt in): when
    [Some k] and this write's batch is committed, [payload] is durably folded into a
    {!Riptide_materialize.Materializer}'s accumulator at key [k], SYNCHRONOUSLY within a
    {!propose} call supplying [~materialize] -- not necessarily the exact call whose own
    {!Riptide_vsr.Replica.propose} performed the commit; any later {!propose} call for the same
    [idempotency_key] that supplies [~materialize] re-checks commit status and materializes too,
    idempotently -- see {!materialize_sink} and {!propose}'s own doc comment for the exact
    mechanism and its scope. [None] (the only
    option before this field existed) leaves a write exactly as vulnerable to
    {!Riptide_storage.File_storage}'s bounded ring WAL evicting it as before -- a disclosed,
    intentional scope boundary, not a bug. On the wire ([write_of_value], not exposed by this
    [.mli] but documented here since it governs what a REMOTE replica sees), a missing
    [merge_key] field decodes as [None] -- backward-compatible with every batch committed before
    this field existed -- while a field present but not shaped like this module's own encoding
    voids the whole write, exactly like a malformed [actor]/[causation]/[correlation]/[payload]. *)

type decision =
  | Allow
  | Deny of string
(** The result of evaluating one {!write} against whatever authorization policy governs the {!t}
    handle it is proposed through -- see {!create}'s own [~authorize] parameter and {!propose}'s
    own "Authorization" section for exactly when and how this is consulted. [Deny]'s [string] is a
    human-readable reason for logs/debugging only; nothing in this module parses, compares, or
    persists it -- a denied batch is refused in full (see {!propose}), so no [Deny] reason itself
    ever reaches the replicated log. *)

val allow_all : write -> decision
(** The explicit, visible "no real policy yet" choice. {!create}'s own [~authorize] is a REQUIRED
    argument specifically so every call site has to say so out loud rather than silently
    inheriting a default -- this is the honest default every existing call site in this codebase
    passes until a real Layer 2 authorization policy exists (task-master Task 6, the reactor
    wiring that supplies a real one). Returns [Allow] for every {!write}, unconditionally. *)

val authorization_denials : unit -> int
(** [authorization_denials ()] is how many times {!propose}'s own universal authorization
    checkpoint has refused a WHOLE batch -- because {!create}'s own [~authorize] returned
    [Deny _] for at least one of its writes -- over this process's lifetime. Shaped exactly like
    {!materialize_write_failures}: a monotonic, process-lifetime count, never reset. The useful
    reading is a delta between two samples, not an absolute value in isolation. *)

type t
(** A handle pairing one {!Riptide_vsr.Replica.t} with deployment-level policy: a mandatory
    [authorize] function (task-master Task 5, subtask 5 -- the universal authorization checkpoint
    every write through this module passes through, real client writes today and, from a later
    task in this same plan, sandboxed-WASM-module writes too) and an optional
    [require_encryption] policy (task-master subtask 5.3, audit-remediation design spec Decision
    5.3, closing the finding that {!propose}'s own [require_encryption] check and the [~encryption]
    gap it exists to catch previously lived at the EXACT SAME call site -- a call site careless
    enough to forget [~encryption] was, by construction, equally likely to forget
    [~require_encryption:true] too). Only {!propose} needs this handle: every other function in
    this module ({!committed_envelopes}, {!materialize_up_to},
    {!write_at_op_number_has_merge_key}, etc.) has nothing to do with authorization or encryption
    policy and keeps taking a bare {!Riptide_vsr.Replica.t} directly, unchanged.

    Abstract, matching this codebase's own established convention for every other handle type
    ({!Riptide_materialize.Materializer.Make.t}, {!Riptide_crypto.Redaction_store.t},
    {!Riptide_storage.File_kv_store.t} are all abstract with explicit accessor functions, never an
    exposed record) -- not because this record needs to hide anything (it is exactly three plain
    fields), but so a future field can be added to it without breaking every existing caller's
    pattern match. *)

val create :
  replica:Riptide_vsr.Replica.t ->
  authorize:(write -> decision) ->
  ?authorize_batch:(write list -> decision) ->
  ?require_encryption:bool ->
  ?materialize_watermark_store:Riptide_storage.File_kv_store.t ->
  unit ->
  t
(** [create ~replica ~authorize ?authorize_batch ?require_encryption ?materialize_watermark_store ()]
    builds a handle over [replica] with
    [authorize] as the mandatory universal authorization policy every {!propose} call through this
    handle consults for every write of every batch (see {!propose}'s "Authorization" section),
    [authorize_batch] (Task 7, the Layer 0/Layer 2 boundary revision, closing Task 6's own boundary
    friction item 2; final whole-branch review finding I9) as an OPTIONAL, additional whole-batch
    policy evaluated once per batch against the full [write list], under the exact same guard
    {!propose} evaluates [authorize] under -- see {!propose}'s own "Authorization" section for the
    precise gating, which is identical for both hooks. [fun _ -> Allow] (the default) preserves
    exactly today's behaviour: no batch-level policy, per-write enforcement only -- unlike
    [authorize], which has no default (see below), [authorize_batch] does, since "no batch-level
    policy yet" is a reasonable, common starting point that every pre-existing call site should not
    have to state out loud the way "no policy at all" must, and
    [require_encryption] (default [false], matching {!propose}'s own pre-existing default -- this
    constructor changes WHERE the policy is set, never its default value) as the encryption policy
    every {!propose} call through this handle enforces unless overridden per-call, and
    [materialize_watermark_store] (Task 7, the Layer 0/Layer 2 boundary revision -- closing Task
    6's own boundary friction item 1, final whole-branch review finding I9) as the durable,
    per-write watermark {!propose}'s own materialize step consults so a repeated materialize of
    the same committed write (e.g. the documented empty-[writes] drain idiom, or a crash-then-retry
    re-proposing the same [idempotency_key]) applies at most once, for ANY sink -- including a
    non-idempotent, accumulating one -- not merely for a pure lattice join. See
    {!materialize_sink}'s own doc comment for the accumulating-sink hazard this closes, and
    {!committed_writes_for}/{!materialize_up_to}'s own [?watermark_store] for the sibling
    mechanism covering the OTHER materialization entry point. [None] (the default) omits the
    watermark entirely, preserving exactly today's behaviour -- unconditionally safe only for an
    idempotent sink, re-applied on every replay.

    [authorize] has NO default -- unlike [require_encryption], which has always defaulted to
    [false], this parameter is REQUIRED so that "no real policy yet" is something every call site
    states out loud, via {!allow_all}, rather than something the type signature quietly assumes
    for it.

    {b [authorize] sees ONE write at a time, with no visibility into any sibling write in the same
    batch, so no cross-write invariant can be enforced through [authorize] alone} (Task 6's own
    boundary friction, item 2; final whole-branch review finding I9). The type says
    [write -> decision], and {!propose} evaluates it per write -- which is enough for any property a
    single write can self-certify, and structurally unable to express any property relating two of
    them. That is a real limit on what [authorize] alone can be trusted for, and the first real
    policy this module ever carried ran straight into it: a double-entry ledger ([lib/ledger/])
    needs "these two legs are a matched, balancing pair, both present in this batch", which is
    precisely a cross-write property, so it could not live in [authorize]. That module's original
    resolution -- guarantee the pairing BY CONSTRUCTION, in the single piece of trusted code that
    builds both legs together from one request, and let [authorize] enforce only each leg's own
    well-formedness -- worked, but was a genuinely weaker kind of guarantee: construction-correctness
    verified by fuzzing the constructor, rather than a checkpoint no write can bypass. A consequence
    worth stating because it surprises readers of this interface: a WELL-FORMED single leg proposed
    directly, by a client that never went through that module, was necessarily ALLOWED by [authorize]
    alone, since nothing in one write reveals its provenance.

    {b This gap is now CLOSEABLE, via [authorize_batch] above -- not closed by default.} [authorize_batch]
    is exactly the batch-aware extension this paragraph used to describe as "the obvious extension
    [with] a real consumer asking for it" (Task 7, the Layer 0/Layer 2 boundary revision, closing
    this item): a deployment that needs a cross-write invariant enforced now has somewhere to put it,
    evaluated once per batch against the full [write list], under the same guard [authorize] itself
    is evaluated under. [authorize_batch]'s own default ([fun _ -> Allow]) means a handle built with
    only [~authorize] gets EXACTLY the single-write-at-a-time enforcement described above, unchanged
    -- supplying [~authorize_batch] is an opt-in a deployment must make explicitly, the same way
    [require_encryption] below is opt-in, not something this constructor infers from the shape of
    [authorize] itself. A deployment that wants "every write through this path is encrypted, no
    exceptions" as an enforced invariant sets [~require_encryption:true] ONCE here, at the one place that builds
    the handle, rather than trusting every {!propose} call site scattered through its own code to
    remember [~require_encryption:true] unaided -- the same reasoning now applies to [~authorize]
    itself: a deployment's real policy lives here, once, not at each of {!propose}'s many call
    sites. *)

val replica : t -> Riptide_vsr.Replica.t
(** [replica t] is the {!Riptide_vsr.Replica.t} [t] was built from -- needed by any caller that
    also calls one of this module's OTHER functions (all of which still take a bare
    {!Riptide_vsr.Replica.t}, e.g. {!committed_envelopes}, {!materialize_up_to}) or
    {!Riptide_vsr.Replica}'s own functions (e.g. {!Riptide_vsr.Replica.commit_number},
    {!Riptide_vsr.Replica.entries}) against the same underlying replica a [t] wraps. *)

val is_primary : t -> bool
(** [is_primary t] is [true] iff [t] can currently cause a NEW {!propose} call through it to have any
    effect at all -- exactly [Riptide_vsr.Replica.is_primary (replica t) && Riptide_vsr.Replica.status
    (replica t) = Riptide_vsr.Replica.Normal], the same compound condition {!propose}'s own existing
    silent-no-op guard already checks internally (see {!Riptide_vsr.Replica.propose}'s own doc
    comment), surfaced here as the one predicate a Layer 2 caller needs rather than something it has
    to independently discover and reproduce (Task 7, the Layer 0/Layer 2 boundary revision, closing
    Task 6's own boundary friction items 4/5; design spec Decision 5). A caller whose own
    [~propose:(bytes -> (unit, string) result)]-shaped closure (e.g. {!Riptide_module.Reactor
    .subscribe}'s own) wants to report failure rather than silently swallow a proposal should check
    this IMMEDIATELY BEFORE every {!propose} call, not once, not cached -- primary/view status can
    change between any two calls -- and return an error without calling {!propose} at all when it is
    [false], instead of calling {!propose} and having it do nothing with no trace.

    {b Residual gap, disclosed rather than hidden: checking [is_primary t] and then calling
    {!propose} is NOT atomic.} [t] can stop being primary (a view change can start and complete)
    in the gap between the two calls, in which case {!propose}'s own silent-no-op guard is what
    actually protects correctness -- the proposal is simply dropped, exactly as it always was before
    this function existed -- but the caller that checked [is_primary t] moments earlier and saw
    [true] has no way to learn that from this function alone; it is not re-consulted, and {!propose}
    itself gives no acknowledgment either way (this layer's fire-and-forget contract, unchanged by
    this function). This function narrows the window in which a caller proposes blind -- it does not
    close it, and does not add any retry/acknowledgment machinery of its own (durable acknowledgment
    remains a separate, later task's job). *)

val committed_envelopes : Riptide_vsr.Replica.t -> Riptide.Envelope.envelope list
(** [committed_envelopes t] is the real, hash-chained Envelope view of everything durably
    committed on [t] so far -- a PURE function, fully recomputed from scratch on every call (no
    persistent state, no caching, no background materialization loop). Reads only
    {!Riptide_vsr.Replica.entries}/{!Riptide_vsr.Replica.commit_number}; never anything beyond the
    committed prefix (an uncommitted, replicated-but-not-yet-agreed tail entry never appears here,
    even though {!Riptide_vsr.Replica.entries} itself includes it).

    Walks the committed prefix in order. A committed entry that isn't shaped like a batch (wrong
    {!Riptide.Value.value} shape, missing or wrong-typed fields, or a causation/correlation whose
    length isn't exactly 32 bytes -- see {!Riptide.Envelope.event_id}) contributes zero envelopes
    -- every replica sees byte-identical committed entries by VSR's own safety guarantee, so this
    is deterministic, agreed-upon behavior, not a place to raise. Within a well-formed batch, if
    its own idempotency key already appeared in an EARLIER (lower op-number), WELL-FORMED batch in
    the same walk, that later batch's writes are skipped entirely (first-wins per key) -- this,
    not anything on the write side, is what makes a retried batch commit safe to apply at most
    once. A malformed batch (or one whose key collides with an earlier malformed batch) never adds
    its key to this dedup set at all, since it contributes nothing to skip in favor of: a later,
    well-formed batch under the same key still materializes normally.

    Unknown extra fields on a batch's or write's own {!Riptide.Value.value} [Record] are silently
    ignored, not rejected -- an explicit wire-format policy decision, not an oversight.

    The result satisfies {!Riptide.Log.verify_chain_list}. *)

val redaction_event_id : idempotency_key:string -> index:int -> string
(** [redaction_event_id ~idempotency_key ~index] is the keystore key this module assigns to the
    write at position [index] (0-based) of the batch committed under [idempotency_key] -- the
    [event_id] under which {!propose}'s [?encryption] sink wrapped that write's DEK, and therefore
    the key a reader must pass to {!Riptide_crypto.Redaction_store.decrypt_value} or
    {!Riptide_crypto.Redaction_store.redact} for it. Pure, total, and injective: the idempotency
    key is length-prefixed, so no two [(idempotency_key, index)] pairs can ever produce the same
    string, whatever bytes an opaque caller-supplied idempotency key contains.

    {b This is deliberately NOT the envelope's own {!Riptide.Envelope.event_id}}, and cannot be.
    An envelope's [event_id] is its {!Riptide.Envelope.content_hash}, which covers the payload
    {e and} [predecessor_hash] and [sequence] -- values that exist only once the write's position
    in the committed log is settled. Encryption has to happen strictly earlier than that (before
    the payload enters the log at all, since the same [content_hash] covers it), so the envelope's
    own identity is not yet knowable at the moment a keystore key is needed. Deriving the key from
    the batch's own idempotency key and the write's index instead keeps it available at encryption
    time and recomputable, deterministically and identically, on every replica at read time. *)

val committed_envelopes_keyed : Riptide_vsr.Replica.t -> (string * Riptide.Envelope.envelope) list
(** {!committed_envelopes}, with each envelope paired with its own {!redaction_event_id} -- the
    keystore key needed to decrypt or redact that specific record. [committed_envelopes t] is
    exactly [List.map snd (committed_envelopes_keyed t)]: same envelopes, same order, same
    semantics, same purity.

    Callers that never encrypt have no use for this; callers that do cannot decrypt without it,
    since a committed envelope carries no record of which batch or position it came from. *)

val committed_writes_for : Riptide_vsr.Replica.t -> idempotency_key:string -> write list option
(** [committed_writes_for t ~idempotency_key] is the {!write} list of the batch that actually
    COMMITTED under [idempotency_key] on [t], decoded from the committed bytes themselves -- [None]
    if no well-formed committed batch carries that key (whether because nothing was ever proposed
    under it, or because [t] has not yet learned of/committed it).

    First-wins per key, deliberately identical to {!committed_envelopes_keyed}'s own dedup rule (a
    malformed batch never claims a key, since it contributes no envelopes to skip in favour of), so
    the writes this returns are exactly the writes whose envelopes that function publishes for the
    same key. That agreement is the point of this function: it is the same lookup {!propose}'s own
    materialize step already performs internally (see that function's own "Materialization" section
    for why reading the committed bytes, rather than trusting a caller's own argument, is the root
    fix for a real, previously-reproduced data-destruction bug) -- exported here (Task 7, the Layer
    0/Layer 2 boundary revision) so a caller needing the same committed-writes-for-a-key answer
    (e.g. a Layer 2 module auditing or re-deriving what it itself committed) does not have to
    re-implement this lookup a second time outside this module. *)

type materialize_sink = {
  write : merge_key:string -> Riptide.Value.value -> unit;
}
(** An erased, pre-applied sink for one concrete {!Riptide_materialize.Materializer}, exactly the
    same "closure over an erased type" shape {!Riptide_vsr.Replica.storage_of_module}/[send]
    already use in this codebase, and for the same reason: this module never becomes a functor
    over the caller's own {!Riptide_lattice.Lattice_intf.S}/{!Riptide_storage.Kv_store_intf.S}
    choice (Layer 2's/the caller's, per this plan's own Decision 1 -- {!Batch_commit} does not
    hardcode a concrete lattice any more than {!Riptide_vsr.Replica} hardcodes a concrete
    transport).

    The caller builds one by pre-applying its own concrete
    [Riptide_materialize.Materializer.Make(L)(KV).t] and its own
    [decode : Riptide.Value.value -> L.t] (turning a write's own [payload] into the concrete
    lattice value it represents -- this module has no way to derive that decoding itself, since it
    never sees [L] at all), e.g.:
    {[
      let sink : Batch_commit.materialize_sink =
        { write = (fun ~merge_key payload -> M.write materializer ~merge_key (decode payload)) }
    ]}
    By this module's own convention, a write's [payload] carrying [merge_key = Some _] IS the
    lattice value being written -- [decode] is a pure [Value.value -> L.t] projection of it, not a
    separate wire format; {!Riptide_materialize.Materializer.create}'s own [decode]/[encode] (a
    DIFFERENT pair, [string -> L.t]/[L.t -> string], for the materializer's own KV codec) are
    orthogonal to this one and not reused by it.

    {b Known, disclosed residual gap: [write] is told the merge_key and the payload, and NOTHING
    about the write or batch it came from} (Task 6's own boundary friction, item 3; final
    whole-branch review finding I9). It does not receive the committing {!write}'s own [actor], its
    [causation]/[correlation], its [idempotency_key], or its position within its batch. For a pure
    lattice-join sink none of that matters. For an ACCUMULATING sink it matters a great deal,
    because such a sink must dedup replays itself (see {!materialize_up_to} and {!propose} for why
    replays happen and are not a caller error), and the only honest identity for "this committed
    write has already been applied" is the [(idempotency_key, position)] pair this callback is not
    given. The first real Layer 2 module built against this interface (a double-entry ledger,
    [lib/ledger/]) is therefore forced to dedup on payload CONTENT instead, which is exact for
    content that happens to be unique per write and silently wrong for content that is not -- it hit
    the wrong case for real, collapsing two genuinely different account-credit legs into one and
    destroying money while the committed log stayed perfectly correct. It also had to push an
    [actor] field into its own payload schema, and enforce agreement with the real [actor] at the
    authorization checkpoint, purely to recover information this callback already had and dropped.
    Passing the write's own identity through to [write] is a small signature change with a real
    consumer waiting for it, and belongs to the Layer 0/Layer 2 boundary revision (task-master
    Task 7). *)

type encryption_sink = {
  encrypt : event_id:string -> Riptide.Value.value -> Riptide.Value.value;
}
(** An erased, pre-applied sink for one concrete {!Riptide_crypto.Redaction_store.t} -- the same
    "closure over an erased capability" shape {!materialize_sink} above already uses, and for the
    same reason: this module must not depend on [riptide_crypto] (which depends on [riptide] and
    [riptide_storage]) to gain encryption, any more than it functors over a concrete lattice to
    gain materialization. The caller builds one by pre-applying its own store:
    {[
      let sink : Batch_commit.encryption_sink =
        { encrypt = (fun ~event_id v -> Riptide_crypto.Redaction_store.encrypt_value store ~event_id v) }
    ]}

    {b Encryption is opt-in, per {!propose} call, and this is a deliberate narrowing} of design
    spec Decision 4's "every payload gets a fresh DEK". Three facts about the real code forced it,
    all verified against the current tree rather than assumed:

    - {!Riptide.Envelope} and {!Riptide.Log} live in the [riptide] library, which nothing
      cryptographic can be added to without a dependency cycle ([riptide_crypto] needs
      {!Riptide_storage.File_kv_store} for the keystore, and [riptide_storage] already depends on
      [riptide]). Encryption genuinely cannot be "baked into envelope construction" the way an
      earlier sketch of this work supposed.
    - {!committed_envelopes} does not perform a write: it is a pure re-derivation of the envelope
      chain from bytes that are {e already} committed and replicated. Encrypting there would be
      both too late (the hash covers what is already in the log) and non-deterministic across
      replicas (each would mint its own DEK and derive a different [content_hash] for the same
      committed entry), breaking the one property the whole module exists to provide.
    - Encryption therefore has to happen before a payload enters the log -- i.e. here, in
      {!propose} -- and doing it unconditionally would silently turn every existing caller's
      payloads into ciphertext they have no key for, and break materialization on any path that
      replays from the log rather than from an in-memory write.

    An explicit parameter makes an encrypted deployment a deliberate, visible choice at the one
    entry point where writes are actually created, rather than a silent change of meaning for
    every existing call site. Making encryption unconditional is a live option for a later task,
    once a real caller exists to define what happens to plaintext-reading paths. *)

val materialize_write_failures : unit -> int
(** [materialize_write_failures ()] is how many individual writes {!propose}'s own materialize step
    and {!materialize_up_to}'s replay walk have, TOGETHER, had refused by
    {!Riptide_materialize.Materializer.write} over this process's lifetime -- i.e. how many times
    [write] raised {!Riptide_materialize.Materializer.Value_too_large} because the joined
    accumulator's encoded size exceeded the KV backend's own bound (see
    {!Riptide_materialize.Materializer.write}'s own WARNING for the full, deliberately-unfixed
    account of why that can happen; this counter does not change when or whether it happens, only
    whether a caller can OBSERVE that it did). Counts ONLY that one, narrowly-classified exception,
    never a blanket [Invalid_argument] -- see {!Riptide_materialize.Materializer.Value_too_large}'s
    own doc comment for exactly what is and is not counted here, and why the distinction matters.

    Shaped like {!Riptide_vsr.Replica.append_refusals} on purpose -- {b a monotonic,
    process-lifetime count that never resets}, so the useful reading is a delta between two samples
    taken around a call of interest, not an absolute value read in isolation. Unlike
    [append_refusals], this is a single counter rather than one per [(string * int)] reason, and it
    is scoped to neither a {!Riptide_vsr.Replica.t} nor a {!t}: a materializer write failure is a
    fact about the materialization layer, not about any specific replica's consensus/durability
    state, and the two loops that can raise it -- {!propose} (which takes a {!t}) and
    {!materialize_up_to} (which takes a bare {!Riptide_vsr.Replica.t}, and has no {!t} in scope at
    all) -- must aggregate into ONE count, as the first paragraph above promises, which a
    per-handle counter could not do. ({b Final whole-branch review, finding I3}: this paragraph used
    to justify the choice by asserting "[Batch_commit] holds no per-replica state of its own (every
    other function here is a pure projection of a [Riptide_vsr.Replica.t] argument)" -- true when
    Task 21 wrote it, falsified by Task 27's introduction of {!t}/{!create}/{!replica} six tasks
    later, and corrected here to the reason that actually still holds.) Deliberately NOT added to
    {!Riptide_vsr.Replica.append_refusals} itself, which would couple that lower, more foundational
    module to a failure mode entirely of this higher one's own making.

    Before this counter existed (task-master audit-remediation Task 21), a write's overflow
    (then a bare [Invalid_argument] -- {!Riptide_materialize.Materializer.Value_too_large} did not
    exist yet either) propagated straight out of whichever loop called it, silently aborting every
    OTHER write still queued in that same loop -- see {!propose} and {!materialize_up_to}'s own doc
    comments for the corrected account of what happens to a write like this now (counted here, and
    skipped, rather than aborting anything past it). *)

val materialize_up_to :
  Riptide_vsr.Replica.t ->
  materialize:materialize_sink ->
  through_commit_number:int ->
  ?watermark_store:Riptide_storage.File_kv_store.t ->
  unit
(** [materialize_up_to t ~materialize ~through_commit_number ?watermark_store] walks [t]'s committed log from its
    very start through [min through_commit_number (Riptide_vsr.Replica.commit_number t)] -- a
    1-based op-number/commit-count bound, INCLUSIVE, matching
    {!Riptide_vsr.Replica.commit_number}'s own counting convention (compared against each batch's
    0-based {!Riptide_vsr.Replica.entries} list position [i] as [i < bound], the same
    correspondence [committed_batch_values] already establishes: list position [i] is commit
    position/op-number [i + 1]) -- materializing every write of every well-formed batch in that
    range that carries [merge_key = Some k], via [materialize.write ~merge_key:k payload], in
    commit order, first-wins per [idempotency_key] (the same dedup rule
    {!committed_envelopes_keyed} uses: a later batch sharing a key already seen earlier in the
    walk contributes nothing, matching what [committed_writes_for] would return for that key). A
    batch that fails to decode (see {!committed_envelopes}'s own decode-failure handling)
    contributes nothing and is skipped, like everywhere else in this module.

    {b [through_commit_number] is a caller-supplied ADDITIONAL upper bound, never the sole one}:
    this function independently clamps its own walk to [Riptide_vsr.Replica.commit_number t] no
    matter what [through_commit_number] is, so it can never materialize an entry that is not
    actually committed on [t] -- including a [through_commit_number] at or past [commit_number]
    (e.g. {!Riptide_vsr.Replica.op_number}, or a restart-recovered watermark that
    {!Riptide_vsr.Replica}'s own restart guidance documents can legitimately land ahead of a
    freshly-restarted replica's [commit_number]). This matters because
    {!Riptide_vsr.Replica.entries} -- what this function reads -- includes the
    replicated-but-not-yet-committed tail; without this internal clamp a caller-supplied bound
    that reached into that tail would fold an uncommitted entry into the lattice accumulator,
    which no later view change discarding that same log entry could ever undo.

    {b That clamp keeps this WALK safe; it does not make a caller's own WATERMARK correct}
    (final-review finding I1). Passing an over-large [through_commit_number] never materializes
    something uncommitted, but a caller that then records that same number as its watermark can be
    claiming coverage of entries this walk never reached -- which is exactly what happens after a
    restart over a ring that has wrapped. See {!write_at_op_number_has_merge_key}'s own doc comment
    for the mechanism and for the honest [min (commit_number) (List.length entries)] bound a
    restart-capable caller must use instead.

    {b Safe to call repeatedly over an overlapping or fully-covered range WHEN [?watermark_store]
    IS SUPPLIED -- unconditionally so, for a sink of ANY shape, not only an idempotent one} (Task
    7, the Layer 0/Layer 2 boundary revision, closing Task 6's own boundary friction item 1; final
    whole-branch review finding I9). Every write in the walked range is checked against a durable,
    per-[(idempotency_key, position)] watermark keyed by {!redaction_event_id} before
    [materialize.write] is ever called for it, and the watermark is recorded strictly after
    [materialize.write] returns successfully -- so calling this twice with the same (or a smaller)
    [through_commit_number] against the same [watermark_store] re-hands each write to
    [materialize.write] at most once total, across both calls, never twice.

    {b Omitting [?watermark_store] preserves EXACTLY today's older, narrower guarantee, and this is
    a real condition on the caller, not a property of this function.} Calling this twice with the
    same (or a smaller) [through_commit_number] re-hands every write in that range to
    [materialize.write] again, including writes already folded in. For a sink that is a plain
    {!Riptide_materialize.Materializer.write} -- a read-join-put over a
    {!Riptide_lattice.Lattice_intf.S} -- that is harmless, because joining the same value into an
    already-converged accumulator changes nothing by the lattice laws. For an ACCUMULATING sink
    (the first real Layer 2 module built against this interface, a double-entry ledger
    ([lib/ledger/]), maintains account balances by read-current-add-delta-write-new-total, which is
    NOT idempotent) it is affirmatively unsafe: replaying one committed transfer leg applies its
    delta twice, moving money that no client asked to move. This sentence cost that module two real
    bugs before it was corrected: an initial double-application found while building it, and a
    Critical finding in its own final review where a re-dispatch triggered by exactly this
    re-materialization re-decided an already-declined transfer as accepted. A caller with an
    accumulating sink that cannot supply [?watermark_store] (e.g. for a reason specific to its own
    deployment) must still give the sink its own already-applied guard, keyed on something stable
    across replays of the same committed write -- see {!materialize_sink}'s own disclosure of what
    its [write] callback is and is not told about the write it is handed.

    {b Does NOT track its own "last materialized" position, even when [?watermark_store] is
    supplied} -- every call still walks from the very start of the log, unconditionally, and still
    decodes and re-checks the watermark for every write in range; [?watermark_store] makes each
    write's own [materialize.write] call itself happen at most once, it does not let this function
    skip re-walking or re-decoding a range it has already covered. The caller still owns any
    "where did I leave off" walk-skip optimization it wants on top of this (e.g. a caller-tracked
    lower [through_commit_number] starting point across calls); this function has no such state of
    its own and is a pure function of [t]'s current log, the range given, and
    [watermark_store]'s own current contents. Its own cost is real and disclosed, not hidden: {b
    O(through_commit_number)} work per call, since it always re-decodes and re-walks the whole
    prefix up to the bound rather than resuming from where a previous call left off. *)

val write_at_op_number_has_merge_key : Riptide_vsr.Replica.t -> op_number:int -> bool
(** [write_at_op_number_has_merge_key t ~op_number] is [true] iff the batch at the 1-based
    [op_number] in [t]'s WHOLE log -- as {!Riptide_vsr.Replica.entries} reports it, including the
    replicated-but-not-yet-committed tail, {b not} only the committed prefix -- decodes as
    well-formed and at least one of its writes carries [merge_key = Some _].

    {b Deliberately not clamped to the committed prefix}, unlike {!materialize_up_to} above:
    refusing to evict an entry that has merely been appended and may yet commit is the
    conservative, safe direction for Task 6's [?may_evict] to fail in, whereas treating an
    uncommitted [merge_key] entry as freely evictable would not be. A caller relying only on this
    function's doc comment (rather than its implementation) must not conclude an
    appended-but-not-yet-committed [merge_key] write is evictable -- it is exactly the case this
    function returns [true] for.

    {b [false] for an op_number that doesn't exist in the log (yet, or ever, e.g. 0, negative, or
    past the current log's end) or whose entry fails to decode as a well-formed batch} -- both
    treated identically to "no write here claims a merge_key", never an error or exception. This
    is deliberate and load-bearing: it lets a caller ask this question uniformly across the whole
    op-number space, including op-numbers the log hasn't reached yet, without a separate bounds
    check.

    {b AFTER A RESTART OVER A WRAPPED RING, THIS FUNCTION IS INERT, AND [false] HERE NO LONGER
    MEANS "SAFE TO EVICT"} (final-review finding I1; the behaviour itself is pinned by
    [test_dst_scenarios.ml]'s own
    [test_restart_after_the_ring_wrapped_cannot_recover_an_unmaterialized_entry]). The "past the
    current log's end" clause above is literally true but understates the hazard, because after a
    restart the log's end can be {b 0}. {!Riptide_vsr.Replica.restart} rebuilds its in-memory log
    with a strictly CONTIGUOUS scan up from op 1, stopping at the first slot that does not read
    back, while {!Riptide_storage.File_storage}'s ring always evicts the LOWEST live op-number
    first -- so once the ring has wrapped even once, that scan stops at op 1 and the rebuilt log is
    completely EMPTY, even for the higher op-numbers the ring genuinely does still hold (a prefix
    scan cannot skip a hole). This function reads that rebuilt log, so it then answers [false] for
    {e every} op-number, including ops that are genuinely still un-materialized rather than
    genuinely safe to evict -- while {!Riptide_vsr.Replica.commit_number}, recovered from the
    superblock, still reports the true, higher value.

    Two consequences a caller must build around rather than discover:

    - {b The honest post-restart watermark bound} is
      [min (Riptide_vsr.Replica.commit_number t) (List.length (Riptide_vsr.Replica.entries t))],
      {b not} [Riptide_vsr.Replica.commit_number t] alone. The latter falsely claims coverage of
      every op the rebuilt log can no longer see; the former is exactly how far
      {!materialize_up_to} can possibly have got over that log, and needs no durable state of its
      own either.
    - {b Where the rebuilt log is shorter than what was actually committed, any committed-but-
      unmaterialized entry the ring already evicted is permanently unrecoverable.} The raw bytes
      are gone and no consumer-side bookkeeping can reconstruct them. That is a real, disclosed
      limitation of this whole mechanism -- gating eviction protects an entry only for as long as
      the process that can still observe it is alive -- not a bug, and not something this function
      or {!materialize_up_to} attempts to repair.

    This is intended as {b the second half of task-master Task 6's own [?may_evict] predicate}
    for ring eviction: the first half -- "is this op-number at or below the current
    materialization watermark" -- is state Task 6 owns itself, not this module; this function
    only ever answers "did the write here opt into materialization at all". A slot this returns
    [true] for must not be evicted until it is known to be materialized (via the watermark half);
    a slot this returns [false] for was never claiming materialization's protection in the first
    place, by {!write}'s own [merge_key] doc comment ([None] leaves a write exactly as evictable
    as before this mechanism existed). *)

val propose :
  t ->
  idempotency_key:string ->
  ?require_encryption:bool ->
  ?materialize:materialize_sink ->
  ?encryption:encryption_sink ->
  write list ->
  unit
(** [propose t ~idempotency_key ?require_encryption ?materialize ?encryption writes] proposes
    [writes] as one atomic batch through
    {!Riptide_vsr.Replica.propose} (i.e. against [Batch_commit.replica t]) -- matching that
    function's own fire-and-forget convention: no return value, no client acknowledgment. Telling
    a caller whether/when their batch committed is explicitly out of scope here (task-master
    Task 9's job).

    Like the underlying {!Riptide_vsr.Replica.propose} itself, this is a silent no-op (not an
    error) unless [Batch_commit.replica t] is currently the primary in [Normal] status -- see that
    function's own doc comment for the exact guard.

    {b [require_encryption]}, when supplied, OVERRIDES [t]'s own stored policy (set at
    {!create} time) for this ONE call -- an unusual, deliberate per-call opt-out remains possible
    even under a handle whose own policy is [true]. When omitted, [t]'s own stored policy applies.
    Either way, the EFFECTIVE policy is checked first, before every other guard in this function:
    if [true] and no [?encryption] sink is supplied, this raises [Invalid_argument] rather than
    silently proposing plaintext. {!encryption_sink} above is deliberately opt-in per call --
    policy for whether a given call site encrypts lives at that call site, not inside this
    mechanism, matching {!materialize_sink}'s own framing -- but that alone would leave a real gap
    for a deployment that wants "every write through this path is encrypted, no exceptions" as an
    enforced invariant rather than a convention every call site has to remember unaided.

    {b Why this moved from a per-call flag to a construction-time handle policy} (task-master
    subtask 5.3, audit-remediation design spec Decision 5.3): a per-call [~require_encryption] on
    its own does not close that gap -- it sits at the EXACT SAME call site as [~encryption] itself,
    so a call site careless enough to forget [~encryption] was, by construction, equally likely to
    forget [~require_encryption:true] too. Storing the policy on [t] instead lets a deployment set
    it ONCE, centrally, wherever it builds its handle(s), so every {!propose} call site inherits it
    without having to remember anything itself -- the per-call override above still exists for the
    rare, deliberate exception, but the default a careless call site falls back to is now the
    deployment's own choice, not silent plaintext.

    {b Authorization} (task-master Task 5, subtask 5 -- the universal, mandatory checkpoint every
    write through this module passes through): {b evaluated ONLY for a call that could actually
    cause NEW data to enter the replicated log} -- i.e. only inside the SAME "[idempotency_key] is
    not already anywhere in this replica's log" guard the idempotency-key/commit-membership
    paragraph below describes, not before it and not unconditionally on every call (review
    finding, this task's own review round 1; an earlier version of this checkpoint evaluated
    [~authorize] unconditionally, ahead of that guard, which is the design this paragraph
    supersedes). When that guard is reached, [Batch_commit.t]'s own [~authorize] (supplied once,
    at {!create} time) is evaluated against EVERY write in [writes], and [Batch_commit.t]'s own
    [~authorize_batch] (Task 7, the Layer 0/Layer 2 boundary revision -- see {!create}'s own doc
    comment) is evaluated once, against the WHOLE [writes] list, under this exact same guard -- not
    a second, separately-gated check. If any write's [authorize w] returns [Deny reason], OR
    [authorize_batch writes] itself returns [Deny reason], this function increments
    {!authorization_denials} EXACTLY ONCE and proposes nothing for this call -- the materialize step
    below still runs, exactly as it does for a batch that was simply never proposed at all, and finds
    nothing committed under [idempotency_key] either way, so this is not a special case needing its
    own check. A batch is one atomic, indivisible unit, so a single denied write (or a single
    [authorize_batch] denial) refuses the WHOLE batch, not just itself -- there is no partial-batch
    commit path anywhere in this module, and authorization does not create one.

    {b Why a call against an ALREADY-committed [idempotency_key] is correctly exempt from this
    checkpoint entirely}, stated precisely because Task 6 (the reactor wiring a real policy) must
    not assume otherwise: this checkpoint's whole purpose is to gate NEW data entering the
    replicated log. A materialize-only call against data that is already durably committed
    introduces nothing new -- the cluster already, irrevocably agreed on it before this call was
    ever made -- so re-consulting [~authorize] over it protects nothing; it would only make a
    caller's own LOCAL materialized view inconsistently stale, depending on which of three
    operationally-identical idioms it happened to reach for catch-up materialization of an
    already-committed key:
    - [propose t ~idempotency_key ~materialize:sink []] (the documented empty-[writes] drain
      idiom below) -- never reaches this checkpoint at all, since [writes = []] fails the
      "not already in the log" guard's own [writes <> []] half regardless of log state.
    - [propose t ~idempotency_key ~materialize:sink writes], where [writes] repeats the
      already-committed batch's own original content (the only kind of retry this fire-and-forget
      layer's own contract permits a client to issue at all) -- fails the SAME guard's
      "not (already_in_log ...)" half, so this checkpoint is never reached either, for exactly
      the same reason the propose-side optimization just below it is skipped: the key is already
      in the log.
    - {!materialize_up_to} -- takes a bare {!Riptide_vsr.Replica.t}, with no {!t} (and therefore
      no [~authorize]) in scope at all to consult.

    Before this fix, only the SECOND of these three idioms was gated by [~authorize] -- purely
    because it happens to also carry a non-empty [writes] argument, not because it does anything
    the other two don't. A caller's ability to catch its own materializer up on data the cluster
    already committed depended on which of three equally-valid idioms it happened to call, which
    is the inconsistency this restructuring closes: all three are now uniformly exempt, and
    this checkpoint (both [~authorize] and [~authorize_batch]) is consulted exactly once per batch,
    at the one moment ([writes <> []] and the key is genuinely new to this replica's log) where a
    [Deny] can still prevent something from happening. This is also the more literal reading of
    "every write ... passes through the
    checkpoint": a materialize-only call against already-committed data is not proposing a
    "write" in the log-entry sense at all, so excluding it from the checkpoint is consistency
    with that reading, not a weakening of it.

    If every write is [Allow] (or the guard above is not reached at all, i.e. nothing new is being
    proposed), this function proceeds as described below, with ONE addition on the [Allow] path:
    when [writes] and [Batch_commit.replica t]'s log together mean a real proposal happens (i.e.
    inside the same "not already in the log" guard just described), one additional, synthetic
    {!write} recording the decision is appended to the writes actually encoded and passed to
    {!Riptide_vsr.Replica.propose} -- [actor = "riptide.module.authz"], [causation]/[correlation]
    copied from [writes]'s own first element (making it a real, causally-linked member of the
    same batch, not a freestanding fact), [merge_key = None], and a [payload] recording
    [idempotency_key] and the fact the batch was allowed. This write commits, chains, and decodes
    exactly like any other write in the batch -- {!committed_envelopes} yields one extra envelope
    per successfully-proposed batch as a result, which every caller comparing envelope counts
    against a proposed-write count must account for. It carries no [merge_key], so it is invisible
    to materialization, and it is never encrypted even when [?encryption] is supplied -- it is a
    fact ABOUT the batch's authorization, not user payload data, so it is deliberately excluded
    from the encrypted-payload/redaction story the rest of this comment describes.

    A denied batch's key is consequently NEVER added to the log at all (unlike an empty batch,
    which is refused earlier, before this guard is ever reached, by the guard below) -- a later
    call under the same [idempotency_key] with a permissive [~authorize] (or against a different
    handle) is a genuine first attempt, not a blocked retry.

    {b How "no write can bypass this checkpoint" is actually proven}, rather than argued in this
    comment (the design spec's own Decision 7 test strategy names both halves; neither existed until
    this plan's final fix wave, finding I6):

    - [scripts/check-authorization-checkpoint] -- the STRUCTURAL half. A grep-class audit (in the
      style of [scripts/check-citations]) over all of [lib/], with comments and string literals
      stripped first, proving: {!Riptide_vsr.Replica.propose} has exactly ONE caller in [lib/] and
      it is this function; that call is lexically inside this function; [~authorize] is evaluated
      here exactly once, before it, over EVERY element of [writes]; that call sits inside the
      [else] branch of the resulting denial guard; and [~authorize] remains a REQUIRED argument of
      {!create}, so no handle can exist with no policy. Module aliases of {!Riptide_vsr.Replica}
      are resolved, and an [open Riptide_vsr.Replica] anywhere in [lib/] (which would make a bare
      [propose] call unfindable by any lexical means) fails the audit rather than being silently
      unaudited.
    - [test/test_batch_commit_authorization_fuzz.ml] -- the BEHAVIOURAL half. QCheck properties
      over randomly generated SEQUENCES of {!propose} calls against one shared replica (random
      batch sizes including empty, random [Allow]/[Deny] mixes within one batch, random
      [merge_key] presence, random [?materialize] presence, random retries of an already-used
      idempotency key), asserting no denied write ever reaches {!committed_envelopes} or a
      {!materialize_sink}, that every batch that SHOULD have committed did (so the property cannot
      be satisfied by an implementation that commits nothing), and that
      {!authorization_denials} counts exactly once per refused BATCH rather than once per denied
      write.

    Checks first whether [idempotency_key] already appears among the batches in
    [Batch_commit.replica t]'s own log -- the WHOLE log as {!Riptide_vsr.Replica.entries} reports
    it, including the replicated-but-not-yet-committed tail, not merely the committed prefix --
    reusing the same batch decode {!committed_envelopes} uses, and is a no-op if so. For an
    unencrypted batch this is purely an optimization, avoiding unboundedly bloating the replicated
    log with duplicate no-op entries from a client that retries many times: what makes an
    unencrypted duplicate {e safe} is {!committed_envelopes}'s own first-wins-per-key dedup on the
    READ side, which holds regardless of how many times [propose] is called with the same key.

    {b For an encrypted batch ([?encryption]) the same check is load-bearing for correctness, not
    an optimization}, and that is why it spans the uncommitted tail rather than only the committed
    prefix. See the Encryption section below.

    {b Materialization} (task-master subtask 3.7's own closing mechanism -- see {!write}'s own
    [merge_key] doc comment): when [?materialize] is given, this function re-runs the SAME
    [idempotency_key] commit-membership check {!committed_envelopes}'s own decode already
    performs (i.e., is this batch now among [Batch_commit.replica t]'s committed batches, whether
    committed by THIS call or an earlier one?) -- reusing that existing commit-confirmation
    mechanism rather than adding a new, separate one. If and only if the batch is committed, every
    write of that {b committed} batch carrying [merge_key = Some k] has its [payload] handed to
    [materialize.write ~merge_key:k] -- synchronously, before this call returns.

    {b What is materialized is decoded from the committed bytes, never from the [writes] argument
    of this call}, and that distinction is load-bearing for correctness rather than cosmetic (Task
    9's end-to-end adversarial proof, 2026-09-23). The batch materialized is the FIRST well-formed
    committed batch carrying [idempotency_key] -- bit-for-bit the same batch, under the same
    first-wins-per-key rule, that {!committed_envelopes_keyed} publishes envelopes for. Before
    this was so, the two halves of this module disagreed: a client retry under an already-committed
    key carrying different writes (the only kind of retry this fire-and-forget layer lets a client
    issue, and one the read half above already defends against) had its payloads folded durably
    into the accumulator even though they appear in no committed entry on any replica -- permanent,
    unauditable divergence a lattice join can never undo -- and, worse, it let the
    [merge_key]-with-[?encryption] rejection below be split across two calls sharing one key, so a
    record committed as ciphertext could have its PLAINTEXT materialized by a second call that
    supplies no [?encryption] at all, leaving {!Riptide_crypto.Redaction_store.redact} destroying
    a ciphertext nobody can read while the plaintext stays on disk forever. Both are reproduced,
    pre-fix and post-fix, in [test/test_lattice_materialize_crypto_scenarios.ml].

    Two consequences worth stating explicitly:
    - {b The accumulator is a function of the committed log plus each key's own size-bound write
      history}, not of the committed log alone (task-master audit-remediation Task 21 narrowed this
      claim: see {!materialize_write_failures} for why). Both this function and
      {!materialize_up_to} now catch a per-write {!Riptide_materialize.Materializer.Value_too_large}
      out of {!Riptide_materialize.Materializer.write} (its own KV backend's value-size bound
      exceeded -- see that function's own WARNING), count it via {!materialize_write_failures}, and
      move on to the next write rather than aborting -- so a write can be silently and PERMANENTLY
      skipped,
      exactly like {!Riptide_materialize.Materializer.write}'s own already-documented "a later,
      smaller write to the same key still succeeds, and the gap never surfaces again" behaviour.
      This is still every real replica's accumulator, not a source of divergence: whether a given
      write is skipped this way is a deterministic function of that write's own payload and the
      backend's fixed size bound, never of timing, call order, or which replica evaluates it, so any
      two replicas that have seen the same committed writes reach the same size-cap outcome for each
      one and therefore the same accumulator -- any replica holding a committed batch can still
      materialize it, and replicas that have materialized the same committed batches (with the same
      per-write size-cap outcomes, which is guaranteed) hold the same accumulator, whatever order or
      how many times each did so (join is commutative, associative and idempotent).
    - Materializing therefore does not need the writes in hand at all: calling this function with
      an EMPTY [writes] list materializes whatever is committed under [idempotency_key] and
      proposes nothing. That is the supported way for a replica to drive its own commit stream into
      its own materializer, and it is safe in every log state -- including on a replica that has
      not yet learned of the batch at all, where it simply does nothing and can be retried later.
      See {b An empty batch is never proposed} below for why that is now guaranteed rather than
      merely typical.

    {b An empty batch is never proposed}, in any log state, and [writes = \[\]] with no
    [?materialize] raises [Invalid_argument] (review finding, 2026-09-23 -- a real silent
    data-destruction path, previously pinned as known behaviour by [test_batch_commit.ml]'s own
    [test_empty_batch_permanently_burns_its_key_via_propose] and closed here). {b WARNING, and this
    is what the guard exists to prevent}: an empty batch is perfectly well-formed, so before this
    guard, proposing one claimed [idempotency_key] permanently -- it entered
    {!committed_envelopes_keyed}'s first-wins dedup set while contributing zero envelopes, and the
    already-in-the-log check above then made every later [propose] under that key a silent no-op.
    Any real batch proposed under that key afterwards was never committed, never materialized, and
    nothing raised: silent, permanent data loss, reached by a single stray empty-list call. Since
    an empty batch contributes zero envelopes and zero materialization, there is no state in which
    writing one is useful, so suppressing the proposal costs nothing and the guard is
    unconditional. The materialize step is deliberately NOT suppressed with it -- that is the
    empty-[writes] idiom above, which must keep working on a replica that is merely behind, since
    replication lag is a normal state rather than a caller error. A call with neither writes nor a
    sink can have no effect at all, which is never what a caller meant, so it raises instead.

    Crucially, this check and materialize attempt happen on EVERY call, not only the call that
    itself performs the durable commit -- deliberately decoupled from the
    "already committed, skip re-proposing" optimization above. This means a batch proposed once
    without [?materialize] and later re-proposed (same [idempotency_key]) WITH [?materialize] is
    still materialized on that later call, even though the underlying VSR commit already
    happened during the first call. This is what makes materialization robust to a crash between
    {!Riptide_vsr.Replica.propose}'s durable commit and the materialize step: the next retried
    call for the same key reaches the materialize step again and it fires, strictly before any
    LATER call on this replica could ever evict the WAL slot(s) this batch occupies.

    {b This re-running is unconditionally safe, for a sink of ANY shape, when [Batch_commit.t] was
    built with [?materialize_watermark_store] (Task 7, the Layer 0/Layer 2 boundary revision,
    closing Task 6's own boundary friction item 1; final whole-branch review finding I9) --
    {!create}'s own store, consulted here via the same per-[(idempotency_key, position)] watermark
    {!materialize_up_to}'s own [?watermark_store] uses, keyed by {!redaction_event_id}.} Each
    committed write is materialized at most once, total, across however many [propose] calls for
    the same [idempotency_key] supply [?materialize] -- the empty-[writes] drain idiom above
    included.

    {b Omitting [?materialize_watermark_store] at {!create} time preserves EXACTLY today's older,
    narrower guarantee: safe only for a sink whose own [write] is idempotent, and this doc
    previously claimed it unconditionally.} The old wording -- "re-running [materialize.write] for
    an already-materialized write is always safe: it is a read-join-put over a lattice" --
    describes what a {!Riptide_materialize.Materializer.write} sink does, not what a
    {!materialize_sink} IS: the latter is an arbitrary caller-supplied closure. An ACCUMULATING sink
    (the first real Layer 2 module, a double-entry ledger in [lib/ledger/], maintains balances by
    read-current-add-delta-write-new-total) applies its delta a second time on every such replay
    when no watermark store is in play. A caller whose sink is not a pure lattice join and cannot
    supply [?materialize_watermark_store] must carry its own already-applied guard; see
    {!materialize_sink} and {!materialize_up_to} for the full account and for what this interface
    does not currently give such a caller to key that guard on.

    {b Scope, stated precisely because it does not cover every commit path}: this hook only fires
    synchronously inside SOME [propose] call that supplies [?materialize] and observes the batch
    as committed at the moment [already_committed] is checked -- there is no background process
    or automatic trigger that materializes a write purely because it became committed; a
    [propose] call (this one, or a later one for the same [idempotency_key]) actually has to
    happen, with [?materialize] supplied, at or after the moment the commit lands. In the
    degenerate [replica_count = 1] ([f = 0]) cluster, {!Riptide_vsr.Replica.propose} commits
    synchronously (per that function's own doc comment), so supplying [?materialize] on the very
    first [propose] call for a batch is sufficient by itself -- and, per the paragraph above, even
    a crash between that commit and materializing is recovered by any later retry call, whether or
    not it re-proposes. In a normal [replica_count >= 3] cluster, {!Riptide_vsr.Replica.propose}
    never commits synchronously -- the primary only sees its own proposal committed later,
    asynchronously, via {!Riptide_vsr.Replica.handle_message} processing a quorum of replies -- so
    materializing a write committed that way still requires SOME later [propose] call (e.g. a
    client-driven retry) to run, with [?materialize] supplied, after that async commit has
    happened; nothing in this module causes such a call to happen on its own. Closing that broader
    case (materializing without depending on a later [propose] call ever occurring) is out of
    scope for this function; see this task's own report for the full justification of why
    [propose]-time threading was chosen over a broader hook.

    {b Encryption} (design spec Decision 4 -- see {!encryption_sink} for why it is opt-in): when
    [?encryption] is given, every write's [payload] is replaced by
    [encryption.encrypt ~event_id payload] before the batch is encoded and proposed, with
    [event_id] = {!redaction_event_id}[ ~idempotency_key ~index] for that write's 0-based position.
    Because this happens strictly before the payload reaches
    {!Riptide_vsr.Replica.propose}, and {!committed_envelopes} derives each envelope's payload
    verbatim from the committed bytes, the resulting envelope's own
    {!Riptide.Envelope.content_hash} is computed over {b ciphertext} -- which is exactly what makes
    redaction work: deleting a keystore entry destroys recoverability while leaving every hash in
    the chain bit-identical, with the content-addressed envelope never touched or recomputed.

    Two behaviours of this path are load-bearing rather than incidental:

    - {b Encryption happens only on a call that actually proposes}, i.e. only when
      [idempotency_key] appears nowhere in this replica's log at all -- neither in the committed
      prefix nor in the replicated-but-not-yet-committed tail. Encrypting a batch whose key is
      already in the log would mint a fresh DEK and overwrite the keystore entry for a ciphertext
      that is already (or is about to become) immutably committed -- permanently destroying a
      record nobody asked to redact.

      {b The uncommitted tail is deliberately included in that guard, and this is the correctness-
      critical part} (review finding, 2026-09-23). In a [replica_count >= 3] cluster
      {!Riptide_vsr.Replica.propose} never commits synchronously, so every proposal spends a real
      window appended-but-uncommitted, and a client retry inside that window is the only kind of
      retry this layer's own fire-and-forget contract permits at all. Unencrypted, such a retry is
      absorbed by {!Riptide_vsr.Replica.propose}'s own byte-identical-value suppression.
      Encryption defeats that suppression -- a fresh DEK and nonce make the retry's bytes
      different, so a SECOND entry would be appended while the keystore entry for the FIRST one
      had already been overwritten; both would commit, {!committed_envelopes} would keep the first
      (first-wins per key), and its ciphertext would be unopenable by the only surviving DEK. That
      is silent, permanent data loss with no fault injected and the hash chain still verifying,
      which is why the guard spans the whole log.

      Note the residual risk that remains, disclosed rather than fixed: this check reads only
      {e this replica's own} log, so calling this function with [?encryption] against a replica
      that has not yet learned of a batch its cluster already has would still re-encrypt and
      orphan that record's DEK. Propose encrypted batches only through the primary, the same
      constraint {!Riptide_vsr.Replica.propose} already imposes for the proposal itself to have
      any effect at all.
    - {b The keystore is not replicated, while the log it protects is} -- a real, disclosed
      durability asymmetry, not an oversight (review finding, 2026-09-23). Only the replica this
      function is called on runs [encryption.encrypt], and a
      {!Riptide_crypto.Redaction_store.t}'s own keystore is an ordinary local
      {!Riptide_storage.File_kv_store.t} directory on that one machine. VSR gives every replica a
      byte-identical copy of the ciphertext; exactly one machine's unreplicated directory holds
      the only means of ever reading any of it. Losing that directory makes every encrypted record
      unrecoverable {e cluster-wide}, which is strictly weaker durability than the replicated log
      itself provides -- and a view change that moves the primary elsewhere leaves later encrypted
      writes' DEKs on the new primary while the old ones stay behind, so the DEKs for one log can
      end up split across machines. Replicating the keystore properly -- including what redaction
      means once a DEK exists in more than one place -- is out of scope here and tracked as its
      own future task.

      {b A previous version of this doc recommended closing that gap "out of band," by backing up
      or otherwise replicating the keystore directory "with the same care the KEK file itself
      gets." That recommendation is retracted (audit finding, 2026-09-29): it silently defeats
      {!Riptide_crypto.Redaction_store.redact}'s own core guarantee.} [redact] deletes the live
      keystore's only pointer to a record's wrapped DEK; it has {b no effect whatsoever} on any
      copy of that pointer made before the redaction ran -- a filesystem backup, a snapshot, a
      replica of the keystore directory itself, anything. An operator who backs up the keystore
      and later redacts a record already captured in that backup has not protected the record from
      loss; they have permanently defeated its redaction instead, since the backup plus the KEK
      recovers it exactly as well as the live keystore did before redaction ran (pinned by a
      running test, [test_a_pre_redaction_keystore_backup_defeats_redaction] in
      [test/test_redaction.ml]).

      {b The real architecture, stated precisely rather than gestured at:} durability of a wrapped
      DEK does {b not} come from this system's own replication the way the ciphertext's does, and
      the paragraph above already establishes why -- the wrapped DEK is written via a plain
      {!Riptide_storage.File_kv_store.put} straight into the keystore's own local [kv], a step VSR
      has no part in and never sees, so nothing about proposing through VSR ever puts a second copy
      of it anywhere. [redact] itself only ever touches one replica's local keystore, which is why
      it must be applied to every replica's keystore individually to be effective cluster-wide.

      {b There is consequently no backup or retention policy for keystore-derived data that is
      both safe and a complete accidental-loss mitigation at the same time, and this doc does not
      claim to have found one.} Any such policy must do one of two things: actively prune
      already-redacted entries from itself on the same schedule redaction happens (so a copy can
      never outlive the redaction it should have respected), or simply not retain data past the
      shortest tolerable redaction-latency window (so nothing is ever old enough to matter). A
      policy that does neither -- including the one this doc used to recommend -- is not a
      durability improvement; it is a standing way to make every future redaction of anything
      already captured a no-op.
    - {b A write carrying [merge_key = Some _] cannot be encrypted}: the combination raises
      [Invalid_argument] and nothing is proposed. A materializer's accumulator holds joined
      {e plaintext}, in its own KV store, structurally outside the redaction keystore -- so
      deleting a record's DEK would leave that record's contribution to the accumulator fully
      readable. Rejecting the combination loudly is the conservative call; supporting it needs a
      redaction story for materialized state that this task does not have.

      This check is per-call, and on its own that is not enough to make the property hold: what
      actually enforces it is that the check runs at the only moment encryption can happen (before
      the payload enters the log), so a committed encrypted batch's writes all carry
      [merge_key = None] {e in the log} -- and materialization reads the log, not the caller's
      argument (see the Materialization section above). The two together are what make "an
      encrypted payload's plaintext can never reach an accumulator" structural rather than a rule
      each call site has to keep. *)
