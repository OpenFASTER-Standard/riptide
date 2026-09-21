# Atomic multi-envelope commit

Design spec for task-master subtask 3.3. Builds on Task 3's now-merged VSR replication
(subtask 3.2: transport carrier, wire/log format, normal-case replica, view-change — all merged
to `main`) and Task 2's single-node `Value`/`Envelope`/`Log`. This document is the argument; the
implementation plan and running code that follow it are the authority, per this project's own "no
spec without running code" rule in `CLAUDE.md` — nothing here is binding until a task ships
working, tested code against it.

## Context

Subtask 3.3 is titled "Implement atomic multi-entity commit," and its description references a
confirmed defect in the old (v1) Riptide. Two things needed resolving before this spec could be
written at all, both worked out in brainstorming rather than assumed:

**What "entity" actually means here.** Traced back through git history (pre-wipe, at commit
`682c507~1`): v1 sharded storage by resource — every LDP resource got its own independent Ra
(Raft) consensus cluster (`lib/riptide/stream/ra_machine.ex`, one `:ra_machine` per stream).
Creating a child resource required writing to two separate Raft-replicated streams: the child's
own, and the parent container's (to add the `ldp:contains` link). These are independent consensus
groups with no cross-shard coordination. When the second write failed, v1's fallback was a
best-effort compensating delete of the orphaned child — and if *that* also failed, it logged
`"manual cleanup needed"` and gave up, leaving the system permanently inconsistent with no
recovery path (`lib/riptide_web/ldp/resource_controller.ex:225-250` in the pre-wipe history). In
v1's vocabulary, "entity" meant one sharded resource, each with its own Raft log.

This doesn't map onto v2's architecture. `2026-09-16-distributed-consensus-design.md`'s Decision 3
already committed Layer 0 to one global, unsharded, VSR-replicated log specifically to sidestep
the cross-shard coordination problem v1 never solved — there is nothing sharded by entity to
coordinate across. And no concrete domain has been chosen yet: task-master Task 6 ("build one
real Layer 2 module") is explicitly not started, and picking the first real use case is its whole
point. `CLAUDE.md` is explicit that Layer 0 must not encode domain-specific meaning ("every
domain-specific schema is expressed as a functor/instance over this universe, never as a
privileged format of its own") — an "entity" (an Account, a DividendPayment, whatever) is exactly
that kind of domain-specific thing. **Decision: "entity" is not a Layer 0 concept.** It's loose,
motivating language echoing v1's postmortem, not a spec this subtask needs to satisfy literally.
Restated in Layer 0's own vocabulary, with nothing domain-specific in it: this subtask builds
**atomic multi-envelope commit** — N related writes land in the replicated log together or not at
all, where what those N writes are "about" is entirely up to the caller.

**Envelope/VSR were never wired together.** Task 2 built a single-node, hash-chained `Log` of
`Envelope`s (`actor`/`causation`/`correlation`/`predecessor_hash`/`sequence`/`payload`), with no
replication. Task 3.1/3.2 built VSR replication, but `Replica.propose : t -> Value.value -> unit`
replicates one opaque `Value.value` per call, with no awareness of `Envelope` at all — nothing
today makes a committed VSR log entry become a real, hash-chained `Envelope`. **Decision: this
subtask closes that gap too**, rather than treating it as a separate prerequisite — atomic
multi-envelope commit doesn't mean anything until envelopes are the thing actually being
committed through VSR.

## Decision 1: Batch shape — N separate Envelopes, one atomic commit

A batch produces N separate, individually hash-chained `Envelope`s, not one `Envelope` wrapping N
sub-writes. Each write keeps its own `actor`/`causation`/`correlation` — faithful to the existing
`Envelope` type, and each write remains independently addressable/hash-chained afterward, the same
as any other envelope in the log. "Atomic" is purely a Layer 0 durability guarantee (all N land in
the log together or none do); it does not become a new, privileged envelope shape.

Rejected: one `Envelope` wrapping all N writes. Simpler (exactly one hash-chain link per commit),
but sub-writes would lose individual `actor`/`causation`/`correlation` semantics unless that
metadata were duplicated inside a wrapper, and an observer who only cares about one write in a
batch would have no clean way to consume it independently.

## Decision 2: Where this lives — a new module on top of unchanged VSR

**`lib/batch_commit.ml`/`.mli`, sitting entirely on top of the unchanged `Replica`, `Envelope`,
and `Log`. No changes to `lib/vsr/` (`replica.ml`/`.mli`, `replica_log.ml`/`.mli`, `message.ml`/
`.mli`) at all.**

This follows a design choice `Replica_log.mli` already documents and argues for: VSR's own log is
"deliberately simpler than `Riptide.Log`'s own log type: no hash-chaining, no `Riptide.Envelope`
wrapping... one layer below where `Riptide.Log`'s envelope metadata belongs." Pushing
`Envelope`-awareness into VSR itself would contradict that, and would reopen code that just went
through four per-task review cycles, a full whole-branch review, and two re-review rounds, all
clean. A thin translation layer above VSR — encoding a batch as one opaque `Value.value` for
`propose`, decoding committed entries back into `Envelope`s on the read side — needs none of that
risk.

## Decision 3: Wire shape

A batch is one `Value.value`:

```
Record [
  ("idempotency_key", Scalar (String key));
  ("writes", Sequence [
     Record [("actor", ...); ("causation", ...); ("correlation", ...); ("payload", ...)];
     ...
  ])
]
```

No new wire-format module is needed — unlike VSR's `Message` type (a distinct protocol layer with
its own encode/decode), a batch is just a `Value.value`, so `Value.canonical_encode`/
`canonical_decode` handle it directly, the same as any other proposed value.

**Idempotency key**: a client-supplied string, independent of content-addressing (per the existing
design spec's Decision 3: "content-hashing a request is not always a safe dedup key... a
client-supplied idempotency key, checked against a dedup log, independent of `Envelope.event_id`/
`content_hash`"). Lives once per batch, not duplicated per write — since a batch's N writes always
apply or don't apply together, one key per batch is the natural granularity.

## Decision 4: Read side — lazy, pure decode, not eager materialization

**`committed_envelopes : Replica.t -> Envelope.envelope list`, a pure function recomputed in full
on every call. No persistent extra state, no background loop watching `commit_number`.**

Slices `entries t` down to the committed prefix only (the first `commit_number t` entries) —
`entries` itself returns the whole log including any uncommitted tail, so this boundary is load-
bearing, not incidental. Walks that prefix in order, threading a running `(sequence, predecessor_
hash)` pair through the fold (starting at `(0, Envelope.genesis_marker)`, the same starting state
`Log.t` itself uses): for each entry, decodes it as a batch and, unless its `idempotency_key` was
already seen in an earlier (lower op-number) batch in the same walk, deterministically constructs
that batch's N envelopes using `Log.append`'s own formula — increment `sequence` by one and set
`predecessor_hash` to the previous envelope's `content_hash` (or `genesis_marker` for the very
first) — one envelope at a time, threading the updated pair forward to the next. This is a fresh
fold over the running state on every call, not a call into `Log.append`/`Log.t` itself, which
tracks its own separate, locally-appended state. A duplicate key's writes are skipped entirely —
this first-wins-per-key dedup across the full committed prefix, not any check on the write side,
is what actually makes retries safe. The result should satisfy `Log.verify_chain_list` — reusing
Task 2's existing check directly, for free.

Rejected: eager, reactively-materialized `Log.t`, incrementally updated as `commit_number` grows.
Real, non-trivial incremental-materialization machinery — and task-master Task 4 ("Lattice
merge-law contract and incremental materialized state," not started) exists specifically to build
that mechanism generally ("the incremental-projection mechanism so reads never replay the full log
from sequence zero"). Building a bespoke version of it here would duplicate Task 4's own scope a
task early. This subtask deliberately accepts full-recompute-on-every-call, the same O(n) cost
this project already discloses and accepts elsewhere (`propose`'s own O(n) dedup scan,
`is_committed`'s O(n²) walk) — the real fix belongs to Task 4.

## Decision 5: Malformed/foreign committed entries decode to zero envelopes, never raise

Every replica sees byte-identical committed entries — that's VSR's own safety guarantee
(`NoLogDivergence`). A committed entry that isn't shaped like a batch (wrong `Value.value` shape,
missing fields, wrong-typed `idempotency_key`) is therefore deterministic garbage, not an
integrity threat this layer needs to defend against by raising: every replica computes the exact
same (empty) contribution from it. Reachable in practice if something calls `Replica.propose`
directly (bypassing this module) with an unrelated value — the decode function must not crash on
that, matching this codebase's established "guard failure ⇒ total no-op" convention rather than
introducing a new failure mode.

## Decision 6: Write side is a duplicate-bloat optimization, not the correctness mechanism

**`propose : Replica.t -> idempotency_key:string -> write list -> unit`, where `write = { actor :
Envelope.actor_id; causation : Envelope.event_id; correlation : Envelope.event_id; payload :
Value.value }`.**

Encodes the batch and calls the unchanged `Replica.propose` — but first checks, via
`committed_envelopes`'s own decode, whether that `idempotency_key` is already present among
committed batches, skipping the call entirely if so. This exists only to avoid unboundedly
bloating the replicated log with duplicate no-op entries from a client that retries many times
(e.g. after a perceived timeout) — it is not what makes duplicates safe. Decision 4's decode-side
dedup is the actual correctness guarantee, and holds regardless of whether `propose` is called
once or fifty times with the same key.

Matches the existing fire-and-forget convention `Replica.propose` already established: no return
value, no client acknowledgment. Telling a caller whether/when their batch committed is explicitly
task-master Task 9's job ("client-facing API layer," a later, separate task) — out of scope here.

## Testing

**Unit-level** (`test/test_batch_commit.ml`, against a bare `Replica.t`, no network):
- Encode/decode round-trip for a multi-write batch.
- Hash-chain correctness: a decoded batch's envelopes satisfy `Log.verify_chain_list`.
- Dedup: proposing the same `idempotency_key` twice with different writes — only the first
  batch's envelopes ever appear in `committed_envelopes`.
- A directly-`Replica.propose`d foreign value (not shaped like a batch) decodes to zero envelopes
  without raising.
- The committed-prefix boundary: an uncommitted tail entry (replicated but not yet committed) does
  not appear in `committed_envelopes`'s output.

**Cluster-level** (one new test, reusing `test_vsr_replica_view_change.ml`'s own `with_cluster`
harness and `stop` mechanism — no new DST infrastructure needed): propose a batch, kill the
primary before it reaches quorum, force a view change via the existing mechanism, and assert that
every surviving replica's `committed_envelopes` result has either all N of that batch's envelopes
or none of them — never a partial set. This needs no new protocol-level atomicity mechanism to
prove: VSR's own log-entry commit is already indivisible (already exhaustively tested by the
view-change branch that just merged), so proving it here is a matter of reusing that machinery
against this module's own encode/decode, not inventing new fault injection.

## Non-goals, explicitly out of scope

- **Client request/response, telling a caller their batch committed or was a duplicate** —
  task-master Task 9's job.
- **Incremental materialization / avoiding full-log-recompute on every `committed_envelopes`
  call** — task-master Task 4's job.
- **A bound on batch size (N)** — no artificial cap; matches this project's established
  PoC-scale tolerance for unbounded-but-simple primitives elsewhere. Revisit if a real workload
  in a later task needs one.
- **Entity-level semantics of any kind** (materialized current state, conflict resolution between
  concurrent writes to "the same" thing) — there is no entity concept at this layer at all; see
  Context above.
