# Layer 0/Layer 2 boundary revision implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the six friction points Task 6's ledger module surfaced in the Layer 0/Layer 2
boundary (`lib/batch_commit/`, `lib/module/reactor.ml`), then freeze and document the revised
boundary as task-master Task 7.

**Architecture:** Five additive-where-possible mechanisms land in `Batch_commit` and a
signature-widening one in `materialize_sink`; the ledger (`lib/ledger/`) is retrofitted to consume
all of them, deleting its own in-memory workarounds. Last, task-master subtasks 7.1-7.3 are closed
with real evidence.

**Tech Stack:** OCaml 5.0.0, dune, Alcotest, QCheck. `Riptide_storage.File_kv_store` (existing) is
reused for the new durable watermark — no new storage backend.

**Spec:** `docs/superpowers/specs/2026-10-01-layer2-boundary-revision-design.md`

## Global Constraints

- Every new parameter is optional with a behavior-preserving default: `None` for
  `?materialize_watermark_store`/`?watermark_store`, always-`Allow` for `?authorize_batch`.
- `materialize_sink.write`'s new shape, used everywhere in this plan:
  `merge_key:string -> idempotency_key:string -> position:int -> actor:Riptide.Envelope.actor_id -> causation:Riptide.Envelope.event_id -> correlation:Riptide.Envelope.event_id -> Riptide.Value.value -> unit`
- Watermark keys are derived with the existing `redaction_event_id ~idempotency_key ~index:position`
  (do not invent a new delimiter-based key — see the spec's Decision 1 for why that class of bug is
  already known in this codebase).
- Watermark ordering is always: call `sink.write`, THEN record the watermark. Never the reverse.
- `authorize_batch` denial increments the existing `authorization_denials_count` — no new counter.
- `is_primary t` is exactly `Riptide_vsr.Replica.is_primary (replica t) && Riptide_vsr.Replica.status (replica t) = Normal`.
- The full existing test suite (631 tests as of branch tip) must pass after every task, with exactly
  one deliberate exception in Task 4 (the known-limitation pin test is replaced, not kept alongside
  its replacement).
- All 3 repo gates (`scripts/validate-tasks`, `scripts/check-authorization-checkpoint`,
  `scripts/check-citations`) must exit 0 before this plan is considered done.
- `unset CC CXX && eval $(opam env --switch=5.0.0)` before any `dune build`/`dune test` (see
  `/work/riptide-env.sh`).

## Review Focus

- A sink/caller that does NOT opt into `?materialize_watermark_store` must behave exactly as before
  (still unsafe for a non-idempotent sink under replay) — the new mechanism must not silently change
  behavior for anyone who didn't ask for it.
- `authorize_batch` must not be evaluated at all when `writes = []` (the documented empty-writes
  drain idiom) — same precondition as the existing per-write `authorize`, not a new, looser gate.
- `is_primary` on a `replica_count = 1` (solo) cluster must read `true` whenever that replica is
  `Normal` — the compound condition must not accidentally require a quorum concept that doesn't
  apply to a solo deployment.
- Two different idempotency keys sharing the same write `position` (e.g. both batches' first write)
  must not collide in the watermark store — the reused `redaction_event_id` derivation already proves
  this for the keystore; a direct test pins it for the watermark's own use too.
- A write with `merge_key = None` must never reach `sink.write` at all, before or after this plan's
  refactor of the two materialize loops to thread position/identity through — easy to regress while
  rewriting `List.iter` into `List.iteri`.

---

### Task 1: Durable materialization watermark + exposed committed-log query

**Files:**
- Modify: `lib/batch_commit/batch_commit.ml`
- Modify: `lib/batch_commit/batch_commit.mli`
- Test: `test/test_batch_commit_materialize.ml`

**Interfaces:**
- Produces:
  - `Batch_commit.create : replica:Riptide_vsr.Replica.t -> authorize:(write -> decision) -> ?require_encryption:bool -> ?materialize_watermark_store:Riptide_storage.File_kv_store.t -> unit -> t` (adds one optional parameter to the existing function)
  - `Batch_commit.materialize_up_to : Riptide_vsr.Replica.t -> materialize:materialize_sink -> through_commit_number:int -> ?watermark_store:Riptide_storage.File_kv_store.t -> unit` (adds one optional parameter)
  - `Batch_commit.committed_writes_for : Riptide_vsr.Replica.t -> idempotency_key:string -> write list option` (newly exported; implementation already exists at `batch_commit.ml:115-123`, unchanged)
- Consumes: nothing new from outside this file.

- [ ] **Step 1: Write failing tests for watermark exactly-once, in `test_batch_commit_materialize.ml`**

Add a non-idempotent test sink (a counter incremented on every `write` call — the existing file
already has several `{ write = fun ~merge_key payload -> ... }` sinks to pattern-match against,
updated to the new 7-argument shape per Global Constraints once Task 3 lands; for THIS task, write
the sink inline with the new signature even though nothing else in the codebase uses it yet, since
`materialize_sink`'s type doesn't change until Task 3 — use a `ref` counter sink built directly
against the current `materialize_sink` type with the OLD 2-argument shape for this task's own tests
only, since Task 1 must not block on Task 3). Four tests:

```ocaml
let test_watermark_makes_repeated_materialize_exactly_once () =
  (* propose with ~materialize:sink and ?materialize_watermark_store:store once;
     then call propose again under the SAME idempotency_key with empty writes and the
     same ~materialize:sink and ?materialize_watermark_store:store (the drain idiom);
     assert the sink's own counter is 1, not 2 *)

let test_materialize_up_to_with_watermark_store_is_exactly_once_across_two_calls () =
  (* call materialize_up_to twice with the same ?watermark_store and an overlapping
     through_commit_number range; assert the sink's counter equals the number of
     distinct merge_key-carrying writes, not double that *)

let test_no_watermark_store_preserves_todays_double_apply () =
  (* Review Focus item 1: the SAME scenario as the first test above, but with
     ?materialize_watermark_store omitted entirely -- assert the sink's counter IS 2,
     proving opt-out is a real no-op for this mechanism, not silently protected anyway *)

let test_watermark_does_not_collide_across_different_idempotency_keys_same_position () =
  (* Review Focus item 4: propose two DIFFERENT idempotency_key batches, each with a
     write at position 0 carrying a DIFFERENT merge_key, both ~materialize:sink and
     ?materialize_watermark_store:store; assert the sink's counter is 2 (both applied),
     not 1 (the second wrongly treated as an already-seen position) *)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `dune build 2>&1 | head -50`
Expected: FAIL to compile — `?materialize_watermark_store`/`?watermark_store` are unknown labels.

- [ ] **Step 3: Add `materialize_watermark_store` to `Batch_commit.t` and thread it through `create`**

In `batch_commit.ml`, add `materialize_watermark_store : Riptide_storage.File_kv_store.t option;`
to the `t` record and `?(materialize_watermark_store = None)` to `create`.

- [ ] **Step 4: Thread an optional watermark store through the shared `materialize_write_catching` helper**

Change its signature to accept `?watermark_store:Riptide_storage.File_kv_store.t` plus the write's
`idempotency_key`/`position`, check-then-skip via `File_kv_store.get`/`.put` (keyed by
`redaction_event_id ~idempotency_key ~index:position`, per Global Constraints) around the existing
`sink.write`/exception-catching body, recording the watermark strictly AFTER `sink.write` returns
successfully (per the ordering constraint — a `Value_too_large` exception means `write` did NOT
successfully apply, so the watermark must not be recorded in that branch either).

- [ ] **Step 5: Update both call sites — `propose`'s materialize step and `materialize_up_to`**

`propose` passes `t.materialize_watermark_store`; `materialize_up_to` gains its own
`?(watermark_store = None)` parameter and passes it through. Both already iterate writes with
`List.iter`/need `idempotency_key` in scope (already present as a function argument/closed-over
value in both).

- [ ] **Step 6: Export `committed_writes_for` in `batch_commit.mli`**

Add the `val` with a doc comment (the existing `.ml` doc comment at lines 107-114 is a good
starting point — adapt it to a public-facing one, noting it's the same function `propose`'s own
materialize step already calls internally).

- [ ] **Step 7: Write unit tests for `committed_writes_for`'s own 3 cases**

```ocaml
let test_committed_writes_for_returns_none_when_never_committed () = ...
let test_committed_writes_for_returns_the_committed_writes () = ...
let test_committed_writes_for_is_first_wins_per_key () = (* two batches, same key, assert the FIRST one's writes come back *)
```

- [ ] **Step 8: Run all tests to verify they pass**

Run: `dune test --force 2>&1 | tail -30`
Expected: PASS, including the new tests from Steps 1 and 7.

- [ ] **Step 9: Update `batch_commit.mli`'s doc comments for `propose` and `materialize_up_to`**

Remove the "safe to call repeatedly only for an idempotent sink" caveat's unconditional framing;
state instead that supplying `?materialize_watermark_store`/`?watermark_store` makes it
unconditionally safe, and that omitting it preserves exactly today's caveat (Review Focus item 1).

- [ ] **Step 10: Commit**

```bash
git add lib/batch_commit/batch_commit.ml lib/batch_commit/batch_commit.mli test/test_batch_commit_materialize.ml
git commit -m "batch_commit: durable materialization watermark + export committed_writes_for"
```

---

### Task 2: Batch-level authorize hook + primary-liveness query

**Files:**
- Modify: `lib/batch_commit/batch_commit.ml`
- Modify: `lib/batch_commit/batch_commit.mli`
- Test: `test/test_batch_commit.ml`
- Test: `test/test_batch_commit_authorization_fuzz.ml`

**Interfaces:**
- Produces:
  - `Batch_commit.create` gains `?authorize_batch:(write list -> decision)` (default: `fun _ -> Allow`)
  - `Batch_commit.is_primary : t -> bool`
- Consumes: `t`'s existing `replica`/`authorize`/`require_encryption`/`materialize_watermark_store` fields (Task 1).

- [ ] **Step 1: Write a failing test for `authorize_batch` denial refusing the whole batch**

```ocaml
let test_authorize_batch_deny_refuses_the_whole_batch () =
  (* create with ~authorize:allow_all and
     ~authorize_batch:(fun _ -> Deny "batch-level policy violation");
     propose a 2-write batch; assert committed_envelopes is empty and
     authorization_denials went up by exactly 1 *)
```

- [ ] **Step 2: Write a failing test that `authorize_batch` is NOT evaluated for an empty-writes drain call**

```ocaml
let test_authorize_batch_not_consulted_for_empty_writes_drain () =
  (* ~authorize_batch:(fun _ -> assert false); propose t ~idempotency_key ~materialize:sink [];
     must not raise *)
```

(Review Focus item 2.)

- [ ] **Step 3: Write a failing test for `is_primary`**

```ocaml
let test_is_primary_true_for_normal_solo_replica () = ...
let test_is_primary_false_after_for_test_set_view_to_view_change () = ...
```

(Review Focus item 3 — use a solo, `replica_count = 1` replica for the first case specifically.)

- [ ] **Step 4: Run tests to verify they fail**

Run: `dune build 2>&1 | head -50`
Expected: FAIL — `?authorize_batch`, `is_primary` unknown.

- [ ] **Step 5: Add `authorize_batch` to `t` and thread it through `create` and `propose`**

`?(authorize_batch = fun (_ : write list) -> Allow)` on `create`, stored on `t`. In `propose`, inside
the existing `writes <> [] && not (already_in_log ...)` guard (the same precondition the per-write
`authorize` already uses — satisfies Review Focus item 2 by construction, not a separate check),
evaluate `t.authorize_batch writes` alongside the existing `List.exists ... Deny` check; either one
denying increments `authorization_denials_count` and skips the propose, per Global Constraints.

- [ ] **Step 6: Implement `is_primary`**

```ocaml
let is_primary (t : t) : bool =
  Riptide_vsr.Replica.is_primary t.replica && Riptide_vsr.Replica.status t.replica = Normal
```

- [ ] **Step 7: Run all tests to verify they pass**

Run: `dune test --force 2>&1 | tail -30`
Expected: PASS.

- [ ] **Step 8: Document both in `batch_commit.mli`**

`?authorize_batch`'s doc comment should directly reference and correct the existing "authorize sees
one write at a time, no batch visibility" disclosure at `create`'s own doc comment (the exact
paragraph quoted in this plan's spec, Context section, item 2) — state the gap is now closeable, not
closed by default. `is_primary`'s doc comment should name the residual non-atomicity with a
subsequent `propose` call (spec Decision 5's own disclosed gap).

- [ ] **Step 9: Commit**

```bash
git add lib/batch_commit/batch_commit.ml lib/batch_commit/batch_commit.mli test/test_batch_commit.ml test/test_batch_commit_authorization_fuzz.ml
git commit -m "batch_commit: add optional authorize_batch hook and is_primary query"
```

---

### Task 3: `materialize_sink.write` gains write identity

**Files:**
- Modify: `lib/batch_commit/batch_commit.ml` (type definition + the two call sites touched in Task 1)
- Modify: `lib/module/reactor.ml` (`wrap_materialize_sink`'s own `write` closure)
- Modify (mechanical — each site adds the 5 new labeled arguments, ignoring any it doesn't need): `lib/ledger/accumulator.ml`, `test/test_module_end_to_end.ml`, `test/test_batch_commit_authorization_fuzz.ml`, `test/test_module_reactor.ml` (6 sink literals), `test/test_batch_commit_materialize.ml` (6, including Task 1's new ones), `test/test_batch_commit.ml`, `test/test_lattice_materialize_crypto_scenarios.ml`

**Interfaces:**
- Produces: `type materialize_sink = { write : merge_key:string -> idempotency_key:string -> position:int -> actor:Riptide.Envelope.actor_id -> causation:Riptide.Envelope.event_id -> correlation:Riptide.Envelope.event_id -> Riptide.Value.value -> unit }`
- Consumes: Task 1's `materialize_write_catching` (now the single place that calls `sink.write` and
  already has `idempotency_key`/`position`/the write's own `actor`/`causation`/`correlation` in scope
  from its own `~w:write` argument — passing them through is the only change to that function itself).

- [ ] **Step 1: Write a failing test that `sink.write` receives correct identity, in `test_batch_commit_materialize.ml`**

```ocaml
let test_sink_write_receives_the_committing_writes_own_identity () =
  (* propose a 2-write batch with ~actor:"author-x", distinct causation/correlation,
     and ~materialize:sink where sink.write records every argument it's called with;
     assert position 0 and position 1 each got idempotency_key = the batch's own key,
     position = 0 and 1 respectively, and actor/causation/correlation matching the
     ORIGINAL write at that position, not the synthetic authorization-decision write
     appended at the end of the batch (which carries actor = "riptide.module.authz"
     and merge_key = None, so never reaches a sink at all) *)
```

(Spec Testing Strategy item 2.) This will not compile until Step 2 below changes the type — write
it now, confirm it fails to compile in Step 2, then it becomes the first thing proven to pass once
the signature and Step 3's call-site update land.

- [ ] **Step 2: Change the `materialize_sink` type in `batch_commit.ml`**

```ocaml
type materialize_sink = {
  write :
    merge_key:string -> idempotency_key:string -> position:int ->
    actor:Envelope.actor_id -> causation:Envelope.event_id -> correlation:Envelope.event_id ->
    Value.value -> unit;
}
```

- [ ] **Step 3: Build to find every now-broken call site**

Run: `dune build 2>&1`
Expected: FAIL — a type error at every sink-literal call site (the exact list above) and at
`reactor.ml`'s `inner.write ~merge_key v` call. Use this output as your own checklist — every file in
this task's list must appear, and no file outside it should.

- [ ] **Step 4: Update `materialize_write_catching`'s call to `sink.write`**

Pass the 5 new labeled arguments through from the `write : write` value already in scope there (from
Task 1's Step 4 change) — `~idempotency_key ~position ~actor:w.actor ~causation:w.causation ~correlation:w.correlation`.
This is also what makes Step 1's identity test pass — do this before touching any other call site.

- [ ] **Step 5: Update `reactor.ml`'s `wrap_materialize_sink`**

Its own `write` closure's signature widens to match (OCaml infers this from the `materialize_sink`
type it's constructing); forward every new argument unchanged to `inner.write` at line 131 (the
`write` function dispatches to subscribed modules using `v`/`merge_key` only — nothing else in that
function's body needs the new identity, it's purely pass-through).

- [ ] **Step 6: Update every remaining call site from the Step 3 build-error list**

For each: add the 5 new labeled parameters to the `fun` literal, using `~idempotency_key:_
~position:_ ~actor:_ ~causation:_ ~correlation:_` for every sink that doesn't need them (the large
majority — most of these are deliberately minimal test sinks), and real names where a test's own
assertions need to inspect one (e.g. any test asserting dedup behavior).

While doing this, specifically confirm (Review Focus item 5) that `test_batch_commit_materialize.ml`'s
existing `k-mixed`/`k-mixed-batch` tests (a batch with some writes carrying `merge_key = Some _` and
others `None`) still pass unmodified after this signature change — a `merge_key = None` write must
still never reach `sink.write` at all, which is easy to regress while mechanically threading the 5
new arguments through every call site's own `List.iter`/`List.iteri`.

- [ ] **Step 7: Build and run the full suite**

Run: `dune build 2>&1 && dune test --force 2>&1 | tail -30`
Expected: clean build, Step 1's identity test now passes, and every pre-existing test (including the
`k-mixed`/`k-mixed-batch` ones named in Step 6) still passes unmodified — Task 3 is otherwise a pure
signature-propagation task, not a behavior change, so nothing besides Step 1's new test should newly
pass or fail.

- [ ] **Step 8: Update `batch_commit.mli`'s `materialize_sink` doc comment**

Document the 5 new fields (reference the spec's Decision 2 for the exact wording — identity is
independent of Task 1's watermark, needed for a sink's own business logic regardless).

- [ ] **Step 9: Commit**

```bash
git add lib/batch_commit/batch_commit.ml lib/batch_commit/batch_commit.mli lib/module/reactor.ml \
  lib/ledger/accumulator.ml test/test_module_end_to_end.ml test/test_batch_commit_authorization_fuzz.ml \
  test/test_module_reactor.ml test/test_batch_commit_materialize.ml test/test_batch_commit.ml \
  test/test_lattice_materialize_crypto_scenarios.ml
git commit -m "batch_commit: materialize_sink.write carries full write identity"
```

---

### Task 4: Ledger durability retrofit

**Files:**
- Modify: `lib/ledger/accumulator.ml`
- Modify: `lib/ledger/accumulator.mli`
- Modify: `lib/ledger/authorize.ml`
- Modify: `lib/ledger/authorize.mli`
- Modify: `test/test_ledger_end_to_end.ml` (harness + replace the known-limitation pin test)

**Interfaces:**
- Consumes: Task 1 (`?materialize_watermark_store`, `committed_writes_for`), Task 2
  (`?authorize_batch`, `is_primary`), Task 3 (`materialize_sink.write`'s new shape).
- Produces: `Accumulator.t` with `decided_requests`/`applied_legs` tables removed;
  `Accumulator.materialize_sink`'s own signature gains nothing new (it still returns a
  `Batch_commit.materialize_sink`, now of the new shape, matching Task 3) but its callers must now
  also pass `?materialize_watermark_store` to whatever `Batch_commit.create` they build against.

- [ ] **Step 1: Write a failing test proving correctness across restart (replacing the pin)**

In `test_ledger_end_to_end.ml`, replace `test_restart_without_durable_dedup_state_doubles_balances`
with `test_restart_with_durable_watermark_leaves_balances_correct`: same restart+catchup setup (a
fresh `Accumulator.t` over the same durable materializer and a `Batch_commit.t` built with
`?materialize_watermark_store` now supplied), asserting balances after the catch-up walk equal
balances before it, not double.

- [ ] **Step 2: Write a failing test that a declined decision still survives restart via `committed_writes_for`**

Adapt the existing `test_a_declined_decision_survives_every_rematerialization_idiom` (already
exercises all 3 catch-up routes) to also cover a FRESH `Accumulator.t` instance (simulating restart)
seeing the SAME decision via `committed_writes_for`, not via its own table (which no longer exists).

- [ ] **Step 3: Run tests to verify they fail**

Run: `dune build 2>&1 | head -50`
Expected: FAIL to compile (the test references `committed_writes_for`-based behavior that doesn't
exist in `Accumulator` yet) or FAIL at runtime against the current, still-in-memory implementation.

- [ ] **Step 4: Delete `decided_requests` from `Accumulator.t`; rewrite `handle_guest_decision` to query `committed_writes_for`**

Remove the `decided_requests : (int64, bool * Schema.transfer_request) Hashtbl.t` field entirely.
`handle_guest_decision` needs a way to query "has this request already been decided, with what
decision" — thread a `committed:(idempotency_key:string -> Batch_commit.write list option)` closure
parameter through (the caller wires it to `fun ~idempotency_key -> Batch_commit.committed_writes_for
replica ~idempotency_key`), decode any returned write's decision tag the same way
`Legs.decision_of_bytes` already does. `decision : t -> request_id:int64 -> bool option` becomes
`decision : t -> committed:(...) -> request_id:int64 -> bool option` (or similar — keep `prevented_flips`/
`repeat_dispatches` counters as-is, they're orthogonal to the storage mechanism).

- [ ] **Step 5: Delete `applied_legs` from `Accumulator.t`; wire the watermark store through instead**

Remove the `applied_legs : (string, unit) Hashtbl.t` field and the `leg_key`/`Hashtbl.mem`/`Hashtbl.add`
dance in `materialize_sink`'s own `write`. `Accumulator.materialize_sink`'s callers now pass
`?materialize_watermark_store` when building their `Batch_commit.t` — the dedup Task 1 added there
replaces this table outright, not alongside it.

- [ ] **Step 6: Retrofit `authorize.ml`/`authorize.mli` to use the real batch-level check**

Add `authorize_batch : Batch_commit.write list -> Batch_commit.decision` to `authorize.ml`: decode
every write with `merge_key` matching an account key as a `transfer_leg`, assert there are exactly 2
for a transfer-leg-carrying batch, they reference the SAME `transfer_id`, opposite roles, matching
`other_account`/`this_account` pairs, and equal `amount` — `Deny` otherwise. Wire it into the
ledger's `with_ledger_env` test harness's own `Batch_commit.create` call (`?authorize_batch:Authorize.authorize_batch`).
Per spec Decision 4, `authorize.ml`'s existing per-write checks SHRINK to pure well-formedness — the
self-certifying pairing comment/logic that referenced "construction-time pairing in Legs" can be
corrected to point at this new checkpoint-enforced check instead.

- [ ] **Step 7: Retrofit the test harness's `~propose` closure to use `is_primary`**

In `with_ledger_env` (or wherever the closure passed to `Reactor.subscribe`'s `~propose` is built),
change it from caching one `Batch_commit.t` to checking `Batch_commit.is_primary handle` immediately
before every `Batch_commit.propose` call, returning `Error "not primary, retry"` without calling
`propose` at all when `false` (spec Decision 5's data-flow section).

- [ ] **Step 8: Run tests to verify they pass**

Run: `dune test --force 2>&1 | tail -30`
Expected: PASS, including Steps 1-2's new tests. `test_restart_without_durable_dedup_state_doubles_balances`
no longer exists as a test name anywhere.

- [ ] **Step 9: Update `accumulator.mli`'s and `authorize.mli`'s doc comments**

Remove the "both tables are in-memory... every account's balance doubles" disclosure from `t`'s own
doc comment (Context section's item 6 is now closed, not merely disclosed) and the matching
"known, disclosed residual gap" paragraphs on `materialize_sink`. Update `authorize.mli`'s own "what
this function still cannot check... by construction" paragraph to state the batch-level check now
closes it, with a pointer to `authorize_batch`.

- [ ] **Step 10: Commit**

```bash
git add lib/ledger/accumulator.ml lib/ledger/accumulator.mli lib/ledger/authorize.ml lib/ledger/authorize.mli test/test_ledger_end_to_end.ml
git commit -m "ledger: retrofit onto the revised boundary -- durable watermark, batch authorize, is_primary"
```

---

### Task 5: New regression coverage for items 4/5 and the strengthened batch-authorize fuzz property

**Files:**
- Modify: `test/test_ledger_dst_load.ml`
- Modify: `test/test_ledger_authorize_fuzz.ml`

**Interfaces:**
- Consumes: Task 2's `is_primary`, Task 4's `Authorize.authorize_batch`.

- [ ] **Step 1: Write a failing DST scenario reproducing the original view-change drop, now asserting observability**

In `test_ledger_dst_load.ml`, add a scenario reusing the existing fault-injection harness (storm-driven
view change mid-dispatch — the same shape that originally caught this live): assert the retrofitted
`~propose` closure (Task 4, Step 7) observes `is_primary = false` and reports the error string, rather
than asserting only "the transfer eventually converges" (which the suite already covers elsewhere).

- [ ] **Step 2: Write a failing fuzz property for `authorize_batch` in `test_ledger_authorize_fuzz.ml`**

Extend the existing QCheck generator shapes (already covering `Negative_account`/`Forged_actor` malformed
single legs) with a generator for malformed PAIRS: mismatched `transfer_id`, same role twice, unequal
amounts, wrong account pairing. Property: every malformed pair is denied by `authorize_batch`, every
well-formed pair (via `Legs.legs_of_request`) is allowed.

- [ ] **Step 3: Run tests to verify they fail**

Run: `dune build 2>&1 && dune test --force 2>&1 | tail -30`
Expected: FAIL (the DST scenario and fuzz property don't exist yet, or fail against intentionally
broken expectations if written test-first against a stub).

- [ ] **Step 4: Confirm both pass against the already-implemented Task 2/4 code**

No new implementation code in this task — Tasks 2 and 4 already implement everything these tests
exercise. If either test fails here, that's a real regression in Task 2 or 4's own work, not
something to patch around in this task; fix it at the source.

Run: `dune test --force 2>&1 | tail -30`
Expected: PASS.

- [ ] **Step 5: Run the full suite 3x to confirm no flakiness, and check for zombie processes**

Run: `dune test --force 2>&1 | tail -10` (x3), `ps aux | grep test_riptide` after each.
Expected: clean each time, zero leftover processes.

- [ ] **Step 6: Commit**

```bash
git add test/test_ledger_dst_load.ml test/test_ledger_authorize_fuzz.ml
git commit -m "ledger: DST coverage for is_primary observability, fuzz coverage for authorize_batch pairing"
```

---

### Task 6: Freeze the boundary, document it, close out task-master Task 7

**Files:**
- Modify: `docs/superpowers/specs/2026-10-01-layer2-boundary-revision-design.md` (mark frozen)
- Modify: `.taskmaster/tasks/tasks.json` (subtasks 7.1, 7.2, 7.3 → done, with `evidence.commits`)
- Modify: `lib/batch_commit/batch_commit.mli`, `lib/module/reactor.mli` (a brief "frozen as of Task 7"
  note at the top of each, replacing "explicitly provisional" framing from Task 5)

**Interfaces:** Consumes everything from Tasks 1-5. Produces nothing further.

- [ ] **Step 1: Add a short "Boundary frozen" section to the design spec**

State plainly: as of this task, the six items in the Context section are closed (reference the
commits from Tasks 1-5 once they exist), and this interface now carries the same "changes require
re-verification" discipline as the rest of Layer 0 (per this repo's own `CLAUDE.md`).

- [ ] **Step 2: Update the top-of-file doc comments in `batch_commit.mli` and `reactor.mli`**

Both currently describe themselves relative to "task-master Task 6, subtasks 6.1 and 6.5" and the
Task 5 boundary as provisional — add one sentence noting Task 7 closed the friction catalog and the
boundary is now frozen, pointing at the design spec.

- [ ] **Step 3: Run `scripts/check-citations`**

Run: `./scripts/check-citations`
Expected: exit 0 (confirms every citation these doc updates reference resolves).

- [ ] **Step 4: Update `tasks.json`: subtasks 7.1, 7.2, 7.3 to `done` with real evidence**

Per this repo's own `CLAUDE.md` ("Task status is derived, never asserted"): use
`task-master set-status --id=7.1 --status=done` (and `.2`, `.3`) for the status field itself, then
hand-edit `evidence.commits` into each subtask with the real commit SHAs from Tasks 1-6 of this plan
(confirm each is an ancestor of HEAD via `git merge-base --is-ancestor <sha> HEAD` before citing it).
Task 7's own parent status is NEVER hand-set — confirm it derives to `done` automatically once all
three subtasks are.

- [ ] **Step 5: Run `scripts/validate-tasks`**

Run: `./scripts/validate-tasks`
Expected: exit 0.

- [ ] **Step 6: Run the full suite one final time, plus all 3 gates**

Run: `dune build @all 2>&1 && dune test --force 2>&1 | tail -10 && ./scripts/validate-tasks && ./scripts/check-authorization-checkpoint && ./scripts/check-citations`
Expected: clean build, 631+ tests (631 pre-existing minus the 1 replaced, plus Tasks 1/2/5's new
ones), all 3 gates exit 0.

- [ ] **Step 7: Commit**

```bash
git add docs/superpowers/specs/2026-10-01-layer2-boundary-revision-design.md \
  lib/batch_commit/batch_commit.mli lib/module/reactor.mli .taskmaster/tasks/tasks.json
git commit -m "Freeze the Layer 0/Layer 2 boundary revision; close task-master Task 7"
```
