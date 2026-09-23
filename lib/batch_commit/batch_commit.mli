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

val propose :
  Riptide_vsr.Replica.t -> idempotency_key:string -> ?materialize:materialize_sink -> write list -> unit
(** [propose t ~idempotency_key ?materialize writes] proposes [writes] as one atomic batch through
    {!Riptide_vsr.Replica.propose} -- matching that function's own fire-and-forget convention: no
    return value, no client acknowledgment. Telling a caller whether/when their batch committed is
    explicitly out of scope here (task-master Task 9's job).

    Like the underlying {!Riptide_vsr.Replica.propose} itself, this is a silent no-op (not an
    error) unless [t] is currently the primary in [Normal] status -- see that function's own doc
    comment for the exact guard.

    Checks first whether [idempotency_key] already appears among [t]'s own currently-committed
    batches (reusing the same batch decode {!committed_envelopes} uses) and is a no-op if so --
    purely to avoid unboundedly bloating the replicated log with duplicate no-op entries from a
    client that retries many times. This check is NOT what makes a duplicate safe to retry: that
    guarantee comes entirely from {!committed_envelopes}'s own first-wins-per-key dedup on the
    READ side, and holds regardless of how many times [propose] is called with the same key --
    this check is an optimization on top of an already-safe operation, not a precondition for
    safety.

    {b Materialization} (task-master subtask 3.7's own closing mechanism -- see {!write}'s own
    [merge_key] doc comment): when [?materialize] is given, this function re-runs the SAME
    [idempotency_key] commit-membership check {!committed_envelopes}'s own decode already
    performs (i.e., is this batch now among [t]'s committed batches, whether committed by THIS
    call or an earlier one?) -- reusing that existing commit-confirmation mechanism rather than
    adding a new, separate one. If and only if the batch is committed, every one of [writes]
    carrying [merge_key = Some k] has its [payload] handed to [materialize.write ~merge_key:k] --
    synchronously, before this call returns.

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
    [propose]-time threading was chosen over a broader hook. *)
