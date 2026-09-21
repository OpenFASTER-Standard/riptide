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
}
(** One write within a batch -- everything {!Riptide.Envelope.envelope} needs except
    [predecessor_hash]/[sequence], which {!committed_envelopes} computes deterministically from
    each write's position once its batch commits, the same way {!Riptide.Log.append} computes
    them for a locally-appended entry. *)

val committed_envelopes : Riptide_vsr.Replica.t -> Riptide.Envelope.envelope list
(** [committed_envelopes t] is the real, hash-chained Envelope view of everything durably
    committed on [t] so far -- a PURE function, fully recomputed from scratch on every call (no
    persistent state, no caching, no background materialization loop). Reads only
    {!Riptide_vsr.Replica.entries}/{!Riptide_vsr.Replica.commit_number}; never anything beyond the
    committed prefix (an uncommitted, replicated-but-not-yet-agreed tail entry never appears here,
    even though {!Riptide_vsr.Replica.entries} itself includes it).

    Walks the committed prefix in order. A committed entry that isn't shaped like a batch (wrong
    {!Riptide.Value.value} shape, missing or wrong-typed fields) contributes zero envelopes --
    every replica sees byte-identical committed entries by VSR's own safety guarantee, so this is
    deterministic, agreed-upon behavior, not a place to raise. Within a well-formed batch, if its
    own idempotency key already appeared in an EARLIER (lower op-number) batch in the same walk,
    that later batch's writes are skipped entirely (first-wins per key) -- this, not anything on
    the write side, is what makes a retried batch commit safe to apply at most once.

    The result satisfies {!Riptide.Log.verify_chain_list}. *)

val propose : Riptide_vsr.Replica.t -> idempotency_key:string -> write list -> unit
(** [propose t ~idempotency_key writes] proposes [writes] as one atomic batch through
    {!Riptide_vsr.Replica.propose} -- matching that function's own fire-and-forget convention: no
    return value, no client acknowledgment. Telling a caller whether/when their batch committed is
    explicitly out of scope here (task-master Task 9's job).

    Checks first whether [idempotency_key] already appears among [t]'s own currently-committed
    batches ({!committed_envelopes}'s own decode, reused) and is a no-op if so -- purely to avoid
    unboundedly bloating the replicated log with duplicate no-op entries from a client that
    retries many times. This check is NOT what makes a duplicate safe to retry: that guarantee
    comes entirely from {!committed_envelopes}'s own first-wins-per-key dedup on the READ side,
    and holds regardless of how many times [propose] is called with the same key -- this check is
    an optimization on top of an already-safe operation, not a precondition for safety. *)
