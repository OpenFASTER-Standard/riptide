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
    intentional scope boundary, not a bug. On the wire ({!write_of_value}, not exposed by this
    [.mli] but documented here since it governs what a REMOTE replica sees), a missing
    [merge_key] field decodes as [None] -- backward-compatible with every batch committed before
    this field existed -- while a field present but not shaped like this module's own encoding
    voids the whole write, exactly like a malformed [actor]/[causation]/[correlation]/[payload]. *)

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
    orthogonal to this one and not reused by it. *)

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
    [append_refusals], this is a single counter rather than one per [(string * int)] reason and not
    scoped to any one {!Riptide_vsr.Replica.t}: [Batch_commit] holds no per-replica state of its own
    (every other function here is a pure projection of a [Riptide_vsr.Replica.t] argument), and a
    materializer write failure is a fact about the materialization layer, not about any specific
    replica's consensus/durability state -- deliberately NOT added to
    {!Riptide_vsr.Replica.append_refusals} itself, which would couple that lower, more foundational
    module to a failure mode entirely of this higher one's own making.

    Before this counter existed (task-master audit-remediation Task 21), a write's overflow
    (then a bare [Invalid_argument] -- {!Riptide_materialize.Materializer.Value_too_large} did not
    exist yet either) propagated straight out of whichever loop called it, silently aborting every
    OTHER write still queued in that same loop -- see {!propose} and {!materialize_up_to}'s own doc
    comments for the corrected account of what happens to a write like this now (counted here, and
    skipped, rather than aborting anything past it). *)

val materialize_up_to :
  Riptide_vsr.Replica.t -> materialize:materialize_sink -> through_commit_number:int -> unit
(** [materialize_up_to t ~materialize ~through_commit_number] walks [t]'s committed log from its
    very start through [min through_commit_number (Riptide_vsr.Replica.commit_number t)] -- a
    1-based op-number/commit-count bound, INCLUSIVE, matching
    {!Riptide_vsr.Replica.commit_number}'s own counting convention (compared against each batch's
    0-based {!Riptide_vsr.Replica.entries} list position [i] as [i < bound], the same
    correspondence {!committed_batch_values} already establishes: list position [i] is commit
    position/op-number [i + 1]) -- materializing every write of every well-formed batch in that
    range that carries [merge_key = Some k], via [materialize.write ~merge_key:k payload], in
    commit order, first-wins per [idempotency_key] (the same dedup rule
    {!committed_envelopes_keyed} uses: a later batch sharing a key already seen earlier in the
    walk contributes nothing, matching what {!committed_writes_for} would return for that key). A
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

    {b Safe to call repeatedly over an overlapping or fully-covered range}: re-materializing a
    write already folded into the accumulator is a no-op, because {!materialize_sink}'s
    underlying join is idempotent (joining the same value into an already-converged accumulator
    changes nothing) -- so calling this function twice with the same (or a smaller)
    [through_commit_number] is always safe, including immediately after a crash and restart.

    {b Does NOT track its own "last materialized" position} -- every call walks from the very
    start of the log, unconditionally. The caller (task-master Task 6) owns any watermark it
    wants to keep, to avoid redundant re-walks across calls; this function has no persistent state
    of its own and is a pure function of [t]'s current log plus the range given. Its own cost is
    real and disclosed, not hidden: {b O(through_commit_number)} work per call, since it always
    re-decodes and re-walks the whole prefix up to the bound rather than resuming from where a
    previous call left off. *)

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
  Riptide_vsr.Replica.t ->
  idempotency_key:string ->
  ?require_encryption:bool ->
  ?materialize:materialize_sink ->
  ?encryption:encryption_sink ->
  write list ->
  unit
(** [propose t ~idempotency_key ?require_encryption ?materialize ?encryption writes] proposes
    [writes] as one atomic batch through
    {!Riptide_vsr.Replica.propose} -- matching that function's own fire-and-forget convention: no
    return value, no client acknowledgment. Telling a caller whether/when their batch committed is
    explicitly out of scope here (task-master Task 9's job).

    Like the underlying {!Riptide_vsr.Replica.propose} itself, this is a silent no-op (not an
    error) unless [t] is currently the primary in [Normal] status -- see that function's own doc
    comment for the exact guard.

    {b [require_encryption]} (default [false]) is a deployment-level policy primitive, checked
    first, before every other guard in this function: if [true] and no [?encryption] sink is
    supplied, this raises [Invalid_argument] rather than silently proposing plaintext. {!encryption_sink}
    above is deliberately opt-in per call -- policy for whether a given call site encrypts lives at
    that call site, not inside this mechanism, matching {!materialize_sink}'s own framing -- but
    that leaves a real gap for a deployment that wants "every write through this path is
    encrypted, no exceptions" as an enforced invariant rather than a convention every call site has
    to remember unaided. A real deployment choosing to run encrypted should always pass
    [~require_encryption:true] from its own calling code, not merely pass [~encryption] and hope no
    call site elsewhere in the same deployment forgets it.

    Checks first whether [idempotency_key] already appears among the batches in [t]'s own log --
    the WHOLE log as {!Riptide_vsr.Replica.entries} reports it, including the
    replicated-but-not-yet-committed tail, not merely the committed prefix -- reusing the same
    batch decode {!committed_envelopes} uses, and is a no-op if so. For an unencrypted batch this
    is purely an optimization, avoiding unboundedly bloating the replicated log with duplicate
    no-op entries from a client that retries many times: what makes an unencrypted duplicate
    {e safe} is {!committed_envelopes}'s own first-wins-per-key dedup on the READ side, which holds
    regardless of how many times [propose] is called with the same key.

    {b For an encrypted batch ([?encryption]) the same check is load-bearing for correctness, not
    an optimization}, and that is why it spans the uncommitted tail rather than only the committed
    prefix. See the Encryption section below.

    {b Materialization} (task-master subtask 3.7's own closing mechanism -- see {!write}'s own
    [merge_key] doc comment): when [?materialize] is given, this function re-runs the SAME
    [idempotency_key] commit-membership check {!committed_envelopes}'s own decode already
    performs (i.e., is this batch now among [t]'s committed batches, whether committed by THIS
    call or an earlier one?) -- reusing that existing commit-confirmation mechanism rather than
    adding a new, separate one. If and only if the batch is committed, every write of that
    {b committed} batch carrying [merge_key = Some k] has its [payload] handed to
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
    LATER call on this replica could ever evict the WAL slot(s) this batch occupies. Re-running
    [materialize.write] for an already-materialized write is always safe: it is a read-join-put
    over a lattice, and joining the same value into an already-converged accumulator is a no-op
    by the lattice laws.

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
