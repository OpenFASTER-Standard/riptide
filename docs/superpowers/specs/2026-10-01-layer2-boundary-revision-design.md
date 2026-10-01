# Layer 0/Layer 2 boundary revision — design spec

Task-master Task 7: "Revise the Layer 0/Layer 2 boundary based on real usage." Task 5 defined the
boundary as explicitly provisional; Task 6 (a real double-entry ledger, `lib/ledger/`) pressure-tested
it and catalogued six concrete friction points, each already disclosed at the interface it concerns
(`lib/batch_commit/batch_commit.mli`, `lib/module/reactor.mli`) rather than only in a workspace note.
This spec revises the boundary to close them. Per this repo's own `CLAUDE.md`, this is the expected,
healthy second pass of a first extension mechanism — not evidence anything went wrong — and per the
same file's "no spec without running code" rule, every mechanism below ships with real, running tests
in the same change, not as prose alone.

## Context

Task-master subtask 7.1's catalog (`.taskmaster/tasks/tasks.json`) names six items, cross-referenced
against the exact mli paragraphs that disclose each:

1. `materialize_sink`'s re-materialization guarantee is false for any accumulating (non-lattice-join)
   sink — the direct cause of two real ledger bugs, including that plan's own Critical finding.
2. `Batch_commit.create`'s `~authorize` sees one write at a time, with no sibling visibility, so no
   cross-write invariant can be enforced at the checkpoint.
3. `materialize_sink.write` receives only `merge_key` and payload — never the committing write's
   `actor`, `idempotency_key`, or batch position — forcing any sink that must dedup replays onto
   content-based keys, which silently collapsed two distinct ledger legs and destroyed money.
4. A `~propose` closure holding a fixed `Batch_commit.t` silently no-ops forever once a view change
   moves the primary, and the closure's result type cannot express "no primary right now, retry."
5. A guest's proposed write can be discarded by a view change after `~propose` already returned `Ok`,
   with no re-proposal anywhere — recovery only works via re-dispatch, making "a dispatched guest must
   be idempotent under re-dispatch" a real but previously unstated obligation on module authors.
6. The host-side state a module must keep to satisfy (1) and (3) has nowhere durable to live. The
   ledger's `Accumulator.t` holds both its decision table and its already-applied-legs table purely in
   memory. Live-reproduced consequence: a restart followed by nothing more exotic than the documented
   `Batch_commit.materialize_up_to` catch-up walk re-applies every leg in the log to balances that
   already contain them, silently doubling every account balance (1500 units across two accounts
   became 3000), while the committed log itself stays perfectly correct.

**Scope decision**: this task closes exactly these six items, including item 6's full depth (a real
durable fix, not just an interface change) — not a per-module workaround, and not a broader
"harden Layer 0" effort (that is task-master Task 12's own, separate scope). Items 1, 3, and 6 share
one root cause (accumulating sinks have no reliable way to know "have I already applied this write")
and are closed by one mechanism, below. Items 2 and 4/5 are each independent and closed separately.

**Durability-mechanism choice** (item 6's central design fork): where should "this write was already
applied" durably live? Two real options were weighed:

- **Boundary-owned watermark (chosen)**: `Batch_commit` owns a small new durable KV (the same
  `File_kv_store` primitive the encryption keystore already uses), tracking already-materialized
  writes automatically, transparent to every sink author, present and future.
- **Folded into the lattice value**: no new store — a module's own lattice type carries its own
  applied-id set, persisted via the existing `Materializer`. Zero new boundary machinery, but ties
  unbounded dedup-set growth to business-state storage and risks colliding with `Materializer.write`'s
  own already-disclosed `Value_too_large` limit.

Chosen: boundary-owned watermark. It is the option that makes "not a per-module workaround" literally
true — every future accumulating module gets exactly-once materialization for free, without needing
to know a lattice-CRDT trick to stay safe, and it doesn't tie dedup growth to business-state storage
that already has its own disclosed size limit to worry about.

## Decision 1: durable materialization watermark (closes items 1, part of 6)

`Batch_commit.create` gains `?materialize_watermark_store:Riptide_storage.File_kv_store.t` (mirrors
how `encryption_sink`'s own keystore is caller-supplied; `None` preserves today's behavior exactly for
any call site that doesn't opt in). Key derivation reuses `redaction_event_id`'s own already-proven
length-prefixing scheme (`lib/batch_commit/batch_commit.mli`'s own doc comment: "the idempotency key
is length-prefixed, so no two `(idempotency_key, index)` pairs can ever produce the same string,
whatever bytes an opaque caller-supplied idempotency key contains") rather than a naive delimiter join
— a naive `idempotency_key ^ "|" ^ string_of_int position` repeats exactly the collision class the
ledger's own `leg_key` bug (fix-wave round 1, M2) already taught this codebase to avoid for a
structurally identical reason: an opaque caller string can itself contain the delimiter. Before
`materialize.write` runs for a given write, the store is checked; if the key is present, the call is
skipped; otherwise `write` runs and the key is recorded afterward. No concurrency concerns — this
codebase's existing single-threaded event-loop model already holds everywhere else this pattern is
used.

**Ordering, disclosed rather than hidden**: the watermark store and a sink's own materializer KV are
two separate durable stores, written non-atomically — some crash window between them is unavoidable.
Recording the watermark *after* calling `sink.write` (not before) means a crash in that narrow window
produces a rare double-apply on next replay — strictly better than today's "every restart+catchup
double-applies everything," and preferable to the reverse ordering's failure mode (a crash between
recording the watermark and actually calling `write` would permanently and silently skip a write that
was never applied at all). This residual gap is documented in the new doc comments the same way every
other durability edge case in this module already is — not claimed away.

With this in place, `materialize_up_to` and `propose`'s own materialize step become genuinely
exactly-once per `(idempotency_key, position)` for any sink, not only lattice joins — the "safe to
call repeatedly" doc claim becomes unconditionally true rather than conditioned on sink idempotency.

## Decision 2: write identity on the sink (closes item 3)

`materialize_sink.write` changes shape:

```ocaml
type materialize_sink = {
  write :
    merge_key:string -> idempotency_key:string -> position:int ->
    actor:Riptide.Envelope.actor_id -> causation:Riptide.Envelope.event_id ->
    correlation:Riptide.Envelope.event_id -> Riptide.Value.value -> unit;
}
```

This is independent of Decision 1 — a sink's own business logic (the ledger's actor-matching
authorization check) needs this identity regardless of who owns dedup. This is **not** purely
additive: every existing sink constructor needs updating to the new shape. Confirmed by grep before
writing the plan: the ledger's own `Accumulator` wiring, plus roughly 15 sink-literal call sites
spread across `test_module_end_to_end.ml`, `test_batch_commit_authorization_fuzz.ml`,
`test_module_reactor.ml` (6), `test_batch_commit_materialize.ml` (6), `test_batch_commit.ml`, and
`test_lattice_materialize_crypto_scenarios.ml` — real, known, enumerable volume, mechanical to update
(most just accept and ignore the new labeled arguments), not a design question, but large enough that
the plan should size it as its own task rather than an afterthought bundled into another one.

## Decision 3: committed-log query replaces in-memory decision mirrors (closes the other half of item 6)

```ocaml
val committed_writes_for : Riptide_vsr.Replica.t -> idempotency_key:string -> write list option
```

Same first-wins-per-key rule `committed_envelopes_keyed` already uses: `Some writes` for the first
well-formed committed batch under that key, `None` if not yet committed. The ledger's own
`decided_requests` table — an in-memory mirror of something the replicated log already durably knows
— is deleted outright, not persisted in parallel. "Has request 50 already been decided, and what was
the decision?" becomes a direct query against already-durable, already-replicated data (the ledger
decodes the decision tag itself from the returned write's payload), not a second, volatile source of
truth that can diverge from the log on restart. `Batch_commit` stays ledger-agnostic — it exposes a
read path, not a ledger-specific concept.

## Decision 4: optional batch-level authorize hook (closes item 2)

```ocaml
val create :
  replica:Riptide_vsr.Replica.t -> authorize:(write -> decision) ->
  ?authorize_batch:(write list -> decision) -> ?require_encryption:bool ->
  ?materialize_watermark_store:Riptide_storage.File_kv_store.t -> unit -> t
```

`?authorize_batch` defaults to always-`Allow`. Evaluated once per batch, inside the same
"not already in the log" guard the existing per-write checks use — a `Deny` here refuses the whole
batch identically to a per-write `Deny`, and folds into the existing `authorization_denials` counter
rather than a new one (a batch refused for a whole-batch reason is still just a refused batch; the
counter's meaning doesn't need splitting by which check caught it).

The ledger's `authorize.ml` is retrofitted to supply the real "both legs present, amounts sum to
zero" check here, retiring the self-certifying-per-leg-plus-construction-time-pairing workaround Task
6 had to invent in the absence of this hook. Its per-write checks shrink to pure well-formedness.

## Decision 5: primary-liveness becomes queryable before calling propose (closes items 4, 5)

**Revised during plan-writing** (file-structure mapping surfaced a blast radius the spec didn't
account for): the first draft of this decision changed `Batch_commit.propose`'s own return type from
`unit` to `(unit, [\`Not_primary]) result`. A real count against this codebase shows that would touch
110 existing `propose` call sites across six test files from several already-merged, unrelated plans
(`test_batch_commit.ml`, `test_batch_commit_materialize.ml`, `test_module_reactor.ml`,
`test_redaction.ml`, `test_lattice_materialize_crypto_scenarios.ml`, `test_dst_scenarios.ml`) —
wildly disproportionate to what items 4/5 actually need, and a direct violation of this task's own
"scoped fixes only" instruction. Corrected here rather than carried into the plan.

What items 4/5 actually need already exists: `Riptide_vsr.Replica.is_primary`,
`Riptide_vsr.Replica.status`, and `Batch_commit.replica` (handle → its underlying `Replica.t`) are
all already public. A caller can already determine primary-liveness before ever calling `propose` —
the only thing missing is that nobody does, and the pattern isn't documented anywhere as the thing a
`~propose` closure must do.

Fix: one new, small, purely additive function —

```ocaml
val is_primary : t -> bool
```

— combining `Riptide_vsr.Replica.is_primary (replica t) && Riptide_vsr.Replica.status (replica t) =
Normal` (the exact compound condition `propose`'s own existing silent-no-op guard already checks
internally) into the one predicate a Layer 2 author actually needs, so they don't have to
independently discover and reproduce that compound condition themselves. Zero existing call sites
change — this is a brand new function, not a modified one.

Authorize-denial is untouched by this decision — still silent, still counted via
`authorization_denials` — which was always a separate, already-working observability mechanism.

The reactor's own `~propose:(bytes -> (unit, string) result)` closure type needs **no change**.
What changes is the closure-construction *pattern*, now documented and demonstrated: check
`Batch_commit.is_primary handle` immediately before calling `propose`, on every call, rather than
checking once or never; return `Error "not primary, retry"` from the closure without calling
`propose` at all when it's `false`, instead of calling `propose` and having it silently do nothing.
This does not add retry/acknowledgment machinery (`Batch_commit.propose` remains fire-and-forget;
durable acknowledgment is still task-master Task 9's own job) — it only makes an existing silent gap
observable. The ledger's own test harness (`with_ledger_env`) is retrofitted to this pattern,
demonstrating the fix against the same view-change scenario that originally caught the bug live.

**Residual gap, disclosed rather than hidden**: `is_primary` and the subsequent `propose` call are
two separate operations, not atomic — a view change landing in between them (vanishingly unlikely in
practice given both are synchronous, in-process, same-event-loop calls, but not structurally
impossible) means `is_primary` can still observe stale liveness. This is strictly better than
today (where `propose` never reports non-primary at all), not a claim of perfect liveness detection.

## Data flow

**Normal dispatch**: client's transfer request commits → reactor dispatches the ledger guest → guest
decides, calls `propose_write` with the 33-byte ABI (decision tag + legs) → `Batch_commit.propose`
evaluates `authorize_batch` (real two-legs-balance check) alongside the per-write checks → on commit,
the materialize step calls `sink.write` with full write identity → the watermark store records
`(idempotency_key, position)` as applied → the ledger's accumulator applies the delta exactly once.

**Restart + catch-up**: process restarts, a fresh in-memory accumulator starts empty — no
`decided_requests` table to lose, since the ledger now asks `committed_writes_for` directly against
the already-durable log instead of keeping its own mirror. `materialize_up_to`'s catch-up walk
re-processes the whole log as it always has, but before calling `sink.write` for each entry, checks
the watermark store, which survived the restart on the same disk the keystore already trusts for
exactly this kind of durability. Every already-applied write is skipped; balances come out correct
with no doubling.

**View-change drop**: guest proposes legs mid-view-change → the `~propose` closure checks
`Batch_commit.is_primary handle` first, finds it `false`, and returns `Error "not primary, retry"`
without ever calling `propose` → the reactor relays that string back to the guest's `propose_write`
host call. Recovery is still via re-dispatch (the existing, now-explicitly-documented
idempotent-under-re-dispatch obligation) — what changes is that this failure is now observable in
logs/tests instead of indistinguishable from success.

## Error handling

See Decision 1's "Ordering, disclosed rather than hidden" for the watermark/business-state dual-write
race and the deliberate choice of which failure mode to prefer. See Decision 4 for why
`authorize_batch` denial shares `authorization_denials` rather than getting its own counter. See
Decision 5's own "Residual gap, disclosed rather than hidden" for the non-atomicity between checking
`is_primary` and calling `propose`.

**Backward compatibility**: every new parameter is optional with a behavior-preserving default — no
`?materialize_watermark_store` means re-materialization is exactly as unsafe for non-idempotent sinks
as it is today; no `?authorize_batch` means exactly today's per-write-only enforcement.
`committed_writes_for` and `is_primary` are both brand new functions, touching zero existing call
sites. Only `materialize_sink.write`'s shape actually changes, and every sink constructor in this
codebase needs updating to match — a real, known, enumerable set (confirmed by grep before writing
the plan): the ledger's own `Accumulator` wiring, and roughly 15 sink-literal call sites across
`test_module_end_to_end.ml`, `test_batch_commit_authorization_fuzz.ml`, `test_module_reactor.ml`,
`test_batch_commit_materialize.ml`, `test_batch_commit.ml`, and
`test_lattice_materialize_crypto_scenarios.ml` — mechanical (most just need to accept and ignore the
new labeled arguments), not a design question, but real volume worth sizing correctly in the plan.

**Ledger retrofit's test consequence**: `test_restart_without_durable_dedup_state_doubles_balances`
(the deliberate pin of the known-bad behavior) is replaced by a test with the same restart+catchup
setup asserting the *correct* outcome. `Accumulator.t`'s `applied_legs` and `decided_requests`
in-memory tables are deleted entirely, not kept alongside the new mechanism.

## Testing strategy

1. **Watermark exactly-once**: drive the same committed batch through `materialize_up_to` (and the
   empty-writes drain idiom) twice against a non-idempotent sink; assert `write` fires exactly once
   total. A real process-restart simulation replaces the round-2 pin test, now asserting correctness.
2. **Write identity**: unit test asserting `materialize_sink.write` receives `idempotency_key`,
   `position`, `actor`, `causation`, `correlation` matching the committed write exactly.
3. **`committed_writes_for`**: unit tests mirroring `committed_envelopes_keyed`'s own coverage
   pattern — present, absent, first-wins-per-key.
4. **`authorize_batch`**: extends `test_batch_commit_authorization_fuzz.ml`'s existing QCheck
   properties to batch-level denials at the same rigor as per-write ones; the ledger's own
   two-legs-balance test moves from "construction-time guarantee, fuzzed indirectly" to "checkpoint
   enforced, fuzzed directly."
5. **`is_primary`**: a DST scenario reproducing the exact original bug (a legs batch proposed during
   a storm-driven view change, using the same fault-injection harness that caught it live) now
   asserting the closure observes `is_primary = false` and reports it, instead of `propose` silently
   swallowing the attempt with no trace.

**Regression bar** (Task 7.2's own stated test strategy): the full existing ledger suite (end-to-end +
fuzz + DST) must still pass after retrofit, with exactly one deliberate exception — the
known-limitation pin test, replaced by its correctness-asserting counterpart.

**Task 7.3 (freeze + document)**: verified the same way every other "freeze and document" milestone
in this repo has been — a versioned boundary spec, `scripts/check-citations` passing over the
newly-frozen interface files, full suite green, all 3 repo gates clean.

## Non-goals

- **Durable, acknowledged `propose`** (full commit confirmation back to a caller) — explicitly
  task-master Task 9's own job, repeatedly disclosed as such in the existing mli text. Decision 5 only
  makes an existing silent primary-liveness gap observable; it does not add acknowledgment.
- **Queued/deferred re-dispatch beyond `max_dispatch_depth`** — a real scheduler for reaction chains
  deeper than the current bound, named in `reactor.mli` as a future task's own design, untouched here.
- **Per-host-function protocol enforcement, dispatch amortization/caching, structured trap events** —
  the other disclosed reactor gaps (items from the original Task 5 boundary review, not things Task 6
  specifically surfaced) are out of scope per this repo's own "that list *is* Task 7's scope — nothing
  more, nothing speculative added on top of what real usage actually exposed."
- **Multi-replica/cluster-wide primary routing** — Decision 5's "re-derive primary-liveness" means
  checking this one replica's own local view/status, not routing a proposal to a different machine.
  Real client-side primary discovery across a cluster is Task 9's own concern.
- **Broader hardening against adversarial conditions** — task-master Task 12's own, separate scope.
