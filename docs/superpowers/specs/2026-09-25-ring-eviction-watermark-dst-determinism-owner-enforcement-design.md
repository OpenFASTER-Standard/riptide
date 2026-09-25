# General ring-eviction watermark, deterministic DST completion, and type-level owner enforcement

Design spec for three related task-master subtasks — 3.7 (general multi-replica ring-eviction
watermark), 3.8 (the real, decisively-proven root cause behind a flaky DST test), and 4.8
(type-level owner-tag enforcement, the residual left open by the just-merged
`layer0-followup-hardening` branch). Brainstormed and specified together because all three touch
the DST/storage layer 3.7's own testing depends on, and because 3.8's fix needs to land before
3.7's new multi-replica tests can be trusted not to flake for an unrelated reason. This document
is the argument; the implementation plan and running code that follow it are the authority, per
`CLAUDE.md`'s "no spec without running code" rule.

## Context

3.7 is the harder half of task-master subtask 3.7, deliberately deferred out of the just-merged
plan as its own dedicated pass (Tasks 6-8 of that plan's own document were never started). 3.8 was
originally believed to be about `Network`'s fault-injection PRNG order-dependence; that fix landed
(closing a real, separate gap) but two independent investigations, by direct code reading,
confirmed it cannot be the mechanism behind the specific named flake — the real cause was later
decisively proven during unrelated work on subtask 4.7 (5/5 reproducible failures under artificial
CPU load on a tree with every other fix stashed out, versus 0/30 without load). 4.8 is the
residual the just-merged plan's own final whole-branch review found and the spec for that plan
corrected rather than closed: neither `Materializer.create` nor `Redaction_store.create` enforces
an owner tag at the constructor level, only by convention at every current real call site.

3.7 touches Layer 0 (the consensus/replication protocol) directly and requires the same real
governance sign-off this repo's `CLAUDE.md` requires for any Layer 0 change — the user's own
explicit approval of this design serves that role, the same pattern already used for this
session's prior Layer 0-adjacent work.

## Decision 1 (subtask 3.7): the trigger — a domain-agnostic commit-advanced hook

**Mechanism:** `Riptide_vsr.Replica.create` gains:

```ocaml
?on_commit_advanced:(old_commit:int -> new_commit:int -> unit)
```

invoked synchronously at each of the four real, confirmed `t.commit_number <-` assignment sites
(`lib/vsr/replica.ml:833` — the primary's own commit inside `primary_execute_op`; `:924` —
piggybacked commit info inside a `Prepare_ok`/similar handler; `:1374` — inside `Start_view`
handling during a view change; `:1701` — piggybacked commit info inside `handle_prepare`) via a
small internal helper (`advance_commit_number t new_commit`) that reads the old value, performs
the assignment, then invokes the hook if present. `Replica` stays domain-agnostic: the hook's type
carries only integers, never `Value.value`, materialization, or redaction — preserving the
existing, deliberate architectural boundary `batch_commit.mli` already documents ("Deliberately
does NOT touch `Riptide_vsr.Replica`'s message-handling side").

**Why not a background polling fiber instead:** rejected. It adds real, unavoidable lag (a poll
interval during which a committed-but-unmaterialized entry is still evictable, unless the gate
below covers that window on its own) and needs a real scheduling story — where does the fiber run,
under whose switch, with what lifecycle — that this repo does not yet have an answer for (no
production process/runtime model exists). A synchronous hook needs none of that.

## Decision 2 (subtask 3.7): the drain — a range-based generalization of the existing per-key one

**Mechanism:** `Batch_commit` gains:

```ocaml
val materialize_up_to :
  Riptide_vsr.Replica.t -> materialize:materialize_sink -> through_commit_number:int -> unit
```

generalizing the existing per-idempotency-key `committed_writes_for` (added by the just-merged
plan's Task 9 fix) into one that walks every committed batch since the caller's own last-observed
watermark through `through_commit_number` (inclusive), materializing every write carrying a
`merge_key`, in commit order — reusing whatever internal decode helper `committed_writes_for`
already uses rather than duplicating it.

A real deployment's own code wires `?on_commit_advanced` to call `materialize_up_to`, and — this is
the mechanism that makes restart recovery free — calls it once more, immediately after
constructing the `Replica.t` and before it starts handling any new messages, through the replica's
own current `commit_number` at that moment. Because `Materializer.write` is a lattice join,
re-materializing an already-covered range is a safe no-op; there is no new durable watermark state
to persist, and no restart-time reconciliation scan to write. The watermark itself — the highest
commit_number `materialize_up_to` has been called through — is a plain in-memory value owned by
whoever wires the hook, not tracked inside `Batch_commit` (which stays stateless, per its own
already-established design confirmed during subtask 4.5's own work).

## Decision 3 (subtask 3.7): the gate — reusing `Replica`'s existing refusal-classification machinery

**The real mechanism, found only by reading `replica.ml` before writing this decision, not
assumed:** `Replica.durable_append` (`replica.ml:631-641`) already catches `Invalid_argument` from
`wal_append`, classifies the message via `classify_append_refusal` (`replica.ml:124-151`) into one
of three existing `append_refusal` shapes, and both of its real callers — `propose`
(`replica.ml:861`, inside `if durable_append t ~op_number:n v then begin ... end`, no `else`) and
`handle_prepare` (`replica.ml:887-889`, whose own comment states "Total no-op, exactly like any
other guard failure here") — already treat a classified refusal as a pure, silent no-op, relying
on VSR's own ordinary retry semantics (an unacknowledged client request retries; a primary that
can't durably append doesn't broadcast `Prepare`) for eventual progress. A blocked eviction is a
fourth instance of exactly this existing shape, not a new failure mode requiring new machinery.

**Mechanism:** `File_storage.create` gains `?may_evict:(op_number:int -> bool)`. Inside
`wal_append` (`file_storage.ml:287-303`), before overwriting a genuinely live ring slot
(`op_number > ring_capacity`, evicting the entry at `op_number - ring_capacity`): if the predicate
returns `false`, raise `Invalid_argument` with a message matching this module's own existing
prefix convention (`"wal_append: entry of "`, `"wal_append: op_number "`) —
`"wal_append: eviction blocked for op_number <n>"`. `Batch_commit` supplies the predicate:

```ocaml
fun ~op_number -> op_number <= watermark || not (write_at_op_number_has_merge_key t ~op_number)
```

— safe to evict once the op is at or below the current watermark, or if that op's write never
opted into materialization at all (the existing, unchanged, disclosed boundary: a write with no
`merge_key` stays exactly as vulnerable to eviction as before this whole materialization effort).

**Registering the new refusal kind:** `Riptide_vsr.Replica`'s `append_refusal` type
(`replica.ml:124`) gains a fourth variant, `Eviction_blocked`, added to `append_refusal_kinds`,
`append_refusal_index`, `append_refusal_name`, and `classify_append_refusal`'s own prefix match —
mechanical, four small edits, no change to `durable_append`/`propose`/`handle_prepare` at all,
since the existing "classify and silently decline" machinery already handles any newly-recognized
shape automatically.

## Decision 4 (subtask 3.7): observability — promote the refusal counter to a real accessor

**What "loud, not a silent wedge" means here, reconciled against the earlier plan's own stronger
"raise a loud exception" framing:** a declined append is silent in exactly the sense every other
refusal kind already is — no exception escapes `Replica.propose`, deliberately consistent with
this codebase's established philosophy. What makes it not a silent wedge is that it is *counted*,
the same way the other three refusal kinds already are — but `for_test_append_refusals`
(`replica.mli:829-838`) is currently documented as "Diagnostics, not protocol... nothing in this
module reads it," meaning today this signal is test-only. Promote it to a real, non-test-prefixed
accessor (`val append_refusals : t -> (string * int) list`, or rename the existing one outright —
an implementation-plan decision) so a real deployment's own monitoring can poll it. A caller
watching `eviction_blocked`'s count grow, alongside `commit_number` failing to advance, is the real
signal that materialization has genuinely fallen behind: real data is never lost (the write stays
durably logged and gets retried), and the condition is genuinely observable, even though no
exception propagates out of a single `propose`/`handle_prepare` call.

## Decision 5 (subtask 3.8): a progress-based completion budget for `settle()`, not a raw iteration count

**Root cause, decisively confirmed** (5/5 reproducible failures under artificial CPU load on a
tree with every other recent fix stashed out, versus 0/30 without load, discovered during
unrelated work on subtask 4.7): `lib/dst/cluster.ml`'s `settle()` bounds its I/O-wait branch with
a fixed `io_waits : int` countdown (`cluster.ml:186-203`, starts at 5000, decremented once per
`wait_io()` call with no delivery that round) — a raw attempt count, not a time budget. Under real
`File_storage` I/O, `wait_io` is a genuine `Eio.Time.sleep` (`cluster.ml:324-329`, needed because a
fiber parked on an io_uring completion cannot be advanced by `Eio.Fiber.yield` alone) — legitimate
and untouched by this decision. What's wrong is that a fixed number of *attempts* doesn't
correspond to a fixed amount of *real time* once the machine is under load: each attempt takes
longer, so the same countdown exhausts in less real elapsed time than it would unloaded, at
exactly the moment the cluster most needs longer to make progress.

**Mechanism:** `with_cluster` gains `?max_wait_duration:float` (real seconds). `run_on_file_storage`
passes it, using the `Eio.Time.clock` it already has via `env` (`cluster.ml:315`,
`Eio.Stdenv.clock env`). When supplied, `settle`'s loop tracks wall-clock time since the *last
real delivery* (via `Eio.Time.now clock`, confirmed real: `Eio.Time.now : _ clock -> float`) rather
than a raw attempt count — resetting the deadline every time `!delivered` is true in the existing
loop. Only once that quiet window exceeds `max_wait_duration` does `settle` raise `Did_not_settle`.
A steadily-progressing-but-slow cluster never times out regardless of total run length; a
genuinely stuck one still does, in bounded real time.

`run`'s own mock-backend entry point (`Eio_mock.Backend.run`, no real I/O, `cluster.ml:274-301`)
is untouched: its own file's existing comment already establishes `inflight` returns to zero after
the first yield of every round under `Eio_mock.Backend` + `Memory_storage`, so the `io_waits`
branch this decision is fixing is never meaningfully exercised on that path to begin with — it
keeps its existing fixed countdown as a harmless, effectively-inert fallback, and does not need
`?max_wait_duration` threaded through it.

## Decision 6 (subtask 4.8): close `Redaction_store.create`'s half of type-level owner enforcement

**Mechanism:** `File_kv_store` gains `val owner : t -> string option`, reading back what
`create`'s own marker-file logic (`check_or_write_owner_marker`, `file_kv_store.ml:325-341`)
already knows at construction time — no new I/O, just exposing state already computed.
`Redaction_store` gains a real, exported constant, `val owner_tag : string` (`"redaction-keystore"`,
closing the earlier-deferred "no shared constant, string literal copy-pasted across 7 call sites"
finding at the same time). `Redaction_store.create` asserts `File_kv_store.owner kv =
Some owner_tag`, raising `Invalid_argument` immediately if not — a mismatched or untagged `kv`
never reaches any keystore operation.

**`Materializer.create` stays convention-only, deliberately.** It receives its `kv` already built,
through the deliberately backend-agnostic `Kv_store_intf.S` module type (`lib/storage/kv_store_intf.ml`),
which carries no ownership concept and is implemented by more than this one backend conceptually
(even though `File_kv_store` is the only one that exists today). Adding an ownership capability to
that shared interface, for the benefit of exactly one caller, would widen every future backend's
contract for a property most of them will never need. `materializer.mli` states this reasoning
plainly rather than leaving the asymmetry unexplained.

## Testing

**3.7:** a real multi-replica scenario (reusing the just-merged plan's own adversarial harness
conventions from `test_lattice_materialize_crypto_scenarios.ml`) where a genuine *follower* — not
the primary, not an operator-driven manual drain — has its ring evict a committed,
`merge_key`-carrying entry safely, proven non-vacuous by temporarily disabling `?on_commit_advanced`
and confirming the identical scenario now genuinely loses the entry. A second scenario proving a
real backlog (materialization deliberately made slow/stuck) is both harmless (no data lost; the
write stays durably logged, and materializes once the backlog clears) and observable (the promoted
`append_refusals`/`eviction_blocked` count genuinely rises during the backlog window). A third,
explicit test proving a write with no `merge_key` is never blocked by the gate regardless of
backlog state — the existing, disclosed boundary must stay completely unaffected.

**3.8:** the previously-flaky scenario run repeatedly under real, induced CPU load (matching the
load-generation technique already used to decisively prove the root cause — busy-loop processes
pinned against available cores), proving it no longer flakes where it reliably did before. A
second, deliberately-stuck-forever scenario (e.g., a storage backend that never completes I/O)
proving `Did_not_settle` still fires, in bounded real time, when the cluster genuinely cannot make
progress — the fix must not silently disable the harness's own livelock detection.

**4.8:** a real construction-time rejection test — `Redaction_store.create` given a `kv` tagged
with a different or absent owner — proving it raises before any keystore operation, mirroring the
non-vacuity discipline already established for `File_kv_store.create`'s own `?owner` guard.

## Non-goals, explicitly out of scope

- **A production replica server binary.** Still not built; all four hook/gate consumers in this
  design remain test-harness code, the shape any real future caller would follow.
- **Any change to `run`'s own mock-backend completion path** — Decision 5 scopes to
  `run_on_file_storage` specifically, per the reasoning above.
- **A `Kv_store_intf.S` interface change for `Materializer`** — Decision 6's own explicit choice;
  `Materializer.create` stays convention-only, honestly documented.
- **New durable watermark persistence** — Decision 2's restart-time re-materialization through the
  replica's own current `commit_number` makes this unnecessary.
- **Automatic materialization retry/backoff scheduling inside `Replica` or `Batch_commit`** —
  Decision 3's reuse of the existing refusal-classification machinery means VSR's own ordinary
  retry semantics already provide this; no new scheduler or clock dependency is introduced into
  either module.
