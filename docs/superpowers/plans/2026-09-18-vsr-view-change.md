# Implementation plan: VSR view-change

Third of several plans implementing the remainder of task-master subtask 3.2. The first two plans
(`2026-09-18-vsr-wire-and-log.md`, `2026-09-18-vsr-normal-case-replica.md`, both merged) built
prerequisite data structures and `spec/tla/VSR.tla`'s normal-case actions only, with a fixed
primary — deliberately mirroring how the TLA+ spec itself was built incrementally (its own Task 2
was normal-case-only; view-change came later, in its own Task 3-4). This plan adds view-change
(`TimerSendSVC` through `ReceiveSV`) — the highest-risk, most complex remaining slice of the
protocol: this is exactly the logic where the *original published VSR formalization effort* had a
real, documented 114-step safety counterexample (research grounding for the TLA+ spec plan,
carried forward here since this OCaml code transcribes the same logic).

Per this repo's own "no spec without running code" rule (`CLAUDE.md`): this plan does not stop at
implementing the seven actions — it ends with a real, multi-replica test proving a cluster
survives a primary failure (a real process no longer sending anything) and resumes normal
operation under a new primary, by running OCaml code, not by re-checking the already-proven TLA+
model (which already caught the historical counterexample class and has the fix — `ValidDvc` view
filtering — pre-applied, per `spec/tla/README.md`).

## Research grounding (verified directly against this repo, not assumed)

**Every view-change action, transcribed exactly from `spec/tla/VSR.tla`** (re-verify against the
actual file before implementing — quoted here for convenience, the file is the source of truth):

- **State this plan adds to `Replica.t`** (VSR.tla `VARIABLES`, lines 22-41): `rep_status`
  (`{"Normal", "ViewChange"}`), `rep_view_number` (`Nat`), `rep_last_normal_view` (`Nat` — the
  paper's `v'`, explicitly NOT derivable from `rep_view_number`, "an omission in the paper's own
  Figure 2"), `rep_recv_svc` (`SUBSET replicas`), `rep_recv_dvc` (`SUBSET [message]`),
  `rep_sent_dvc` (`BOOLEAN`, a pure modeling device — without it `SendDVC` is an unguarded
  self-loop, VSR.tla:207-215's own extensive comment on this), `aux_svc_count` (`Nat`, bounds
  `TimerSendSVC`).
- **`Primary(v) == 1 + ((v-1) % ReplicaCount)`** (VSR.tla:18): TLA+'s `%` is Euclidean (floored)
  modulo. Independently re-derived and TLC-confirmed (this session, both in the original TLA+ spec
  plan and again during this plan's own research pass): `Primary(0) = 3`, `Primary(1) = 1`,
  `Primary(2) = 2` for `ReplicaCount = 3` — periodic, `Primary(0) = Primary(ReplicaCount) =
  ReplicaCount`, NOT `1`. **The already-merged `replica.mli` has a forward note warning against
  exactly this trap** (it was already gotten wrong once, and fixed, in the normal-case plan's own
  final review) — this plan is where that forward note gets acted on.
- **`TimerSendSVC`** (VSR.tla:161-174): guard `aux_svc_count[r] < StartViewOnTimerLimit /\
  rep_status[r] = "Normal"`. Effect: `v := View(r)+1`; `rep_view_number' = v`, `rep_status' =
  "ViewChange"`, resets `rep_recv_svc' = {}`, `rep_recv_dvc' = {}`, `rep_sent_dvc' = FALSE`,
  increments `aux_svc_count`, broadcasts `StartViewChange{v, i=r}`. **Explicitly documented in the
  spec itself as "an unconditional, always-enabled action, bounded by a state-space-limiting
  counter" — i.e. not a real timeout even in the TLA+ model.** This plan's own design decision for
  how to trigger it in real OCaml is below (Architecture).
- **`ReceiveHigherSVC`** (VSR.tla:183-194): guard `m.v > View(r)` (any status). Effect: adopts
  `m.v`, `rep_status' = "ViewChange"`, `rep_recv_svc' = {m.i}` (seeded with the sender, not
  empty), resets `rep_recv_dvc' = {}`, `rep_sent_dvc' = FALSE`. `aux_svc_count` UNCHANGED (only
  `TimerSendSVC` increments it).
- **`ReceiveMatchingSVC`** (VSR.tla:196-205): guard `m.v = View(r) /\ rep_status[r] =
  "ViewChange"`. Effect: `rep_recv_svc' = @ \cup {m.i}` (set union), everything else unchanged
  (no reset — matching view, mid-episode).
- **`SendDVC`** (VSR.tla:216-228): `f = (ReplicaCount-1) \div 2`. Guard: `rep_status[r] =
  "ViewChange" /\ ~rep_sent_dvc[r] /\ Cardinality(rep_recv_svc[r]) >= f`. Effect: unicasts
  `DoViewChange{v=View(r), log=rep_log[r], last_normal_view=rep_last_normal_view[r],
  n=rep_op_number[r], k=rep_commit_number[r], i=r}` to `Primary(View(r))`; sets `rep_sent_dvc' =
  TRUE`.
- **`ValidDvc(r,m) == m.v = View(r)`** (VSR.tla:230) — the view-filtered DVC quorum-counting fix
  for the original formalization's published 114-step counterexample.
- **`ReceiveDVC`** (VSR.tla:232-240): guard `ValidDvc(r,m)`. Effect: `rep_recv_dvc' = @ \cup {m}`.
- **`WinningDVC(r)`** (VSR.tla:248-255): `CHOOSE` the valid DVC maximal by `(last_normal_view, n)`
  lexicographically — largest `last_normal_view` wins; ties broken by largest `n`.
- **`HighestCommitNumber(r)`** (VSR.tla:257-260): `CHOOSE` the max `k` over valid DVCs — **a
  separate maximum, NOT derived from the winning DVC** (VSR.tla:244-245's own explicit warning).
- **`SendSV`** (VSR.tla:264-280): guard `rep_status[r] = "ViewChange" /\ r = Primary(View(r)) /\
  Cardinality({valid DVCs}) >= f+1`. Effect: adopts `winner.log`/`winner.n` wholesale as
  `rep_log'`/`rep_op_number'`, `rep_commit_number' = HighestCommitNumber(r)` (unconditional, not
  monotonic-guarded here — the primary is starting the view fresh), `rep_status' = "Normal"`,
  `rep_last_normal_view' = View(r)`, broadcasts `StartView{v=View(r), log=winner.log, n=winner.n,
  k=new_k}`.
- **`ReceiveSV`** (VSR.tla:292-305): guard `m.v >= View(r)` (note `>=`, not `>`). Effect:
  `rep_log' = m.log`, `rep_op_number' = m.n`, `rep_commit_number' = IF m.k > @ THEN m.k ELSE @`
  (**monotonic-only** — the documented fix for a real published double-application bug, do not
  simplify to unconditional assignment), `rep_view_number' = m.v`, `rep_status' = "Normal"`,
  `rep_last_normal_view' = m.v`. **`rep_recv_dvc`/`rep_recv_svc` are left UNCHANGED here** — VSR.tla's own
  `ReceiveSV` does NOT reset them (`spec/tla/README.md`'s own "What the `ValidDvc` filter is
  actually doing here" section confirms this precisely: stale DVCs genuinely survive this
  transition in the data structure, but the ONLY reader, `SendSV`, is gated on `rep_status[r] =
  "ViewChange"`, and both actions that re-enter that status — `TimerSendSVC`, `ReceiveHigherSVC` —
  reset `rep_recv_dvc` first, so every element `SendSV` ever actually reads is already valid. This
  plan's implementation must replicate the SAME non-reset in `ReceiveSV`, not "fix" it by adding a
  reset that the TLA+ model itself was never checked against doing).

**Known, already-analyzed simplifications this plan inherits, not re-derives** (`spec/tla/README.md`):
liveness-only, not safety — no `PREPAREOK` re-send on `STARTVIEW` (a replica with an uncommitted
log tail relies on ordinary `PREPARE` re-replication once the new primary resumes); only a
higher-view `STARTVIEWCHANGE`, not a higher-view `DOVIEWCHANGE`, triggers view adoption (a
`DOVIEWCHANGE` is unicast to the primary only, so any view it could announce was already broadcast
via `STARTVIEWCHANGE` first).

**The critical blocker this plan must resolve before writing its first test, flagged by the
normal-case plan's own final review**: `lib/sim/network.ml`'s `pump_one` only advances its virtual
clock as a side effect of delivering an actual in-flight scheduled message (confirmed directly
against `network.ml`'s implementation — the empty-pending-queue branch returns `false` without
touching the clock at all; `Network.clock`'s type is deliberately a plain, non-mutable
`Eio.Time.clock_ty`, so `set_time`/`advance` aren't reachable any other way through the public
API). At `default_fault_config` (used throughout the normal-case plan's own tests, and this plan's
too, per Global Constraints), every delay is `0.0`. **A fiber sleeping on `Network.clock` via
`Eio.Time.sleep`/`sleep_until`, waiting for `TimerSendSVC`'s own real-world "timeout," would never
wake if no message happens to be in flight** — exactly the scenario a dead-primary timeout needs
to escape from (a stalled cluster sends nothing).

**Resolved design decision (Architecture, below): do not use `Network.clock`/`Eio.Time` for
`TimerSendSVC` at all.** Expose it as a plain, synchronous `Replica.check_timeout : t -> unit`
function, called externally by whatever drives the replica — a test calls it directly/
deterministically (matching this plan's own multi-replica test's need for exact, reproducible
control over when a "timeout" fires); a real deployment spawns one extra fiber per replica that
sleeps on ITS OWN real wall-clock timer (`Eio.Time.sleep` on a genuine clock, not `Network`'s) and
calls `check_timeout` periodically — **this is not a novel pattern for this codebase**:
`lib/transport/tcp.ml` already does exactly this shape of thing for its own real-clock timeouts
(`dial_timeout`, `preamble_read_timeout`, `accept_error_backoff`), fully decoupled from
`lib/sim/network.ml`. This requires **zero changes to `lib/sim/network.ml`**, matching the Global
Constraint two prior plans have already upheld, and keeps `Replica`'s core logic free of any Eio
dependency at all (exactly matching the existing `test_vsr_replica.ml` convention of driving
`Replica` via plain synchronous function calls, no fibers) — the fiber/timing concern lives
entirely in whatever DRIVES the replica, never inside `Replica` itself, consistent with the
normal-case plan's own "state separate from message handling separate from driving strategy"
architecture.

## Architecture

**Extend `Replica.t` with view-change state; replace the fixed `primary_id` field with a computed
`Primary(view_number)`; add `check_timeout` and three new `handle_message` dispatch arms; drive
`SendDVC`/`SendSV`'s own enabling-condition checks from whichever handler changes what they read**
(mirroring the normal-case plan's own established pattern of driving `PrimaryExecuteOp` from
inside `handle_prepare_ok`/`propose`, not a separate poll loop).

```ocaml
(* lib/vsr/replica.ml, sketch -- not binding, your judgment on exact field/function names, but the
   SHAPE (derive Primary(view) rather than store it; drive SendDVC from whatever changes
   Cardinality(recv_svc); drive SendSV from whatever changes Cardinality(valid recv_dvc)) is the
   binding architectural decision this plan makes. *)

type status = Normal | View_change

type t = {
  my_id : int;
  replica_count : int;
  svc_limit : int;                      (* StartViewOnTimerLimit *)
  log : Replica_log.t;
  mutable status : status;
  mutable view_number : int;
  mutable last_normal_view : int;
  mutable commit_number : int;
  mutable recv_svc : int list;          (* or a Set -- your judgment; small, bounded by replica_count *)
  mutable recv_dvc : Message.t list;    (* the raw Do_view_change messages received this episode *)
  mutable sent_dvc : bool;
  mutable svc_count : int;
  peer_op_number : (int, int) Hashtbl.t;
  send : to_:int -> string -> unit;
}
```

`primary_id` is GONE as a stored field — replaced everywhere by a pure `primary : t -> int`
function computing `1 + ((view_number - 1) mod replica_count)`, matching `Primary(v)` exactly
(get the modulo semantics right: OCaml's `mod` can return a negative result for a negative
dividend, unlike TLA+'s own Euclidean `%` — verify `(view_number - 1) mod replica_count` behaves
correctly at `view_number = 0` specifically, since that's exactly the case this plan's own
Research Grounding section flags as the historical trap; if OCaml's `mod` doesn't already give the
Euclidean result you need here, use a corrected formula, e.g.
`((view_number - 1) mod replica_count + replica_count) mod replica_count`). `is_primary t = t.my_id
= primary t`, matching the existing (already-correct) shape from the normal-case plan, just now
computed instead of stored.

**The four EXISTING normal-case actions (`propose`, `handle_prepare`, `handle_prepare_ok`) need
real changes, not just additions** — this is the expected, disclosed cost of extending them from
the normal-case plan's own fixed-`view=0`/fixed-primary scope (its own forward note said exactly
this would be needed): each must now check `t.status = Normal` (an action that was previously
always-enabled for whichever role is now correctly gated on being in the `Normal` status, matching
`IsNormalPrimary`/`IsNormalBackup`'s own compound guards in the general form of VSR.tla, not the
Task-2-only fixed-view simplification the merged code currently has), and every message they
build/accept must carry/check the REAL `t.view_number`, not the hardcoded `normal_view = 0`
constant that currently exists (delete that constant — it was a deliberate, disclosed placeholder
for exactly this plan to replace).

## Global Constraints

- **`lib/sim/network.ml`/`.mli` are NOT modified** — see Research Grounding's resolved blocker
  above. `check_timeout`'s own driving is entirely external to `Replica`.
- **No new opam dependency, and `lib/vsr/replica.ml` gains NO Eio dependency of its own** —
  `check_timeout` is a plain synchronous function, same style as every other `Replica` entry
  point. Any Eio fiber/sleep code needed to actually drive it in a real deployment belongs in a
  later plan's binary/harness code, not in `lib/vsr/`.
- **`ReceiveSV` must NOT reset `rep_recv_dvc`/`rep_recv_svc`** — replicate VSR.tla's own,
  already-analyzed non-reset exactly (see Research Grounding). Do not "fix" this into a reset;
  that would deviate from the TLA+ model this code is required to match, and the safety argument
  for why the non-reset is fine (documented at length in `spec/tla/README.md`) depends on the
  EXACT reset discipline VSR.tla actually has, not a stricter one this plan might be tempted to
  add defensively.
- **The `f+1`/`f` quorum thresholds and the `ValidDvc` filter must be transcribed exactly** — this
  is the highest-risk logic in the whole protocol (the historical 114-step counterexample class).
  Do not simplify, do not "optimize," do not combine `SendDVC`'s `>= f` threshold with `SendSV`'s
  `>= f+1` threshold into one shared constant that could accidentally drift if one is edited later
  — keep them as two textually distinct checks, each citing its own VSR.tla line number.
- **`WinningDVC`/`HighestCommitNumber` must each independently scan `recv_dvc`** — do not derive
  `HighestCommitNumber`'s result from `WinningDVC`'s own `k` field; VSR.tla's own comment
  (244-245) explicitly warns this is a separate maximum. A future reader diffing this code against
  the spec should find two clearly separate scans, not one combined with a shortcut.

## Task 1: Generalize the normal-case actions from fixed-primary/fixed-view to real `status`/`view_number`

**Files:**
- Modify: `lib/vsr/replica.ml`, `lib/vsr/replica.mli`
- Modify: `test/test_vsr_replica.ml` (existing tests constructed with the old fixed-`primary_id`
  `create` signature will need updating to the new signature — this is expected; do not weaken any
  existing assertion to make it compile, fix the construction call instead)

**Steps:**

1. Add the new state fields to `type t` per Architecture above (`status`, `view_number`,
   `last_normal_view`, `recv_svc`, `recv_dvc`, `sent_dvc`, `svc_count`), remove `primary_id`, add
   `svc_limit` to `create`'s parameters (matching `StartViewOnTimerLimit`). `create` now takes
   `my_id`/`replica_count`/`svc_limit`/`send` — NOT `primary_id` (it's derived, not configured).
   `view_number` starts at `0` (`Init`'s own value, VSR.tla `rep_view_number = [r \in replicas |->
   0]`), matching `Primary(0)`'s own already-established value for whichever replica that is.
2. Add `primary : t -> int` (the `Primary(v)` formula, get the modulo right per Architecture's own
   warning) and update `is_primary` to use it.
3. Update `propose`: add the `t.status = Normal` guard (currently missing — the merged code's own
   normal-case-only scope let this be implicit); use `t.view_number` in the `Prepare` it builds,
   not the deleted `normal_view` constant.
4. Update `handle_prepare`: add `m.view = t.view_number` (already present as a check against the
   old constant — verify it now checks the real field) AND `t.status = Normal` (currently
   missing); same real-view-number substitution in the `Prepare_ok` reply it sends.
5. Update `handle_prepare_ok`: add `t.status = Normal` (currently missing) and `m.view =
   t.view_number` (already present against the old constant — verify against the real field).
6. Update `test_vsr_replica.ml`'s existing tests to the new `create` signature (no `primary_id`
   parameter; a fixed-primary test now needs `view_number` to already put the intended replica at
   `primary`, or the test needs to directly manipulate `t.status`/`t.view_number` — since `t` is
   abstract, add whatever minimal test-only accessor/constructor is needed, documented as
   test-support surface in `replica.mli`, not exposed as part of the "real" protocol API). Do not
   delete or weaken any existing safety-guard regression test from the two prior plans' fix
   rounds — every one of those must still pass unchanged in spirit (adjusted only for the new
   `create` signature).
7. `dune build`/`dune test`, confirm clean, confirm no previously-passing test was weakened.
8. Commit.

## Task 2: `check_timeout`, `ReceiveHigherSVC`, `ReceiveMatchingSVC`, `SendDVC`

**Files:**
- Modify: `lib/vsr/replica.ml`, `lib/vsr/replica.mli`
- Modify: `test/test_vsr_replica.ml`

**Steps:**

1. Implement `check_timeout t` (`TimerSendSVC`): the guard and effect exactly per Research
   Grounding, using the new `svc_limit`/`svc_count` fields.
2. Extend `handle_message`'s dispatch: a `Start_view_change` message now drives EITHER
   `ReceiveHigherSVC` (if `m.v > t.view_number`) OR `ReceiveMatchingSVC` (if `m.v = t.view_number
   /\ t.status = View_change`) — implement both branches per their exact VSR.tla guards (a message
   matching neither is simply not enabled, i.e. dropped, same "no buffering/retry" discipline
   already established for out-of-order `Prepare`s in the normal-case plan).
3. Implement `SendDVC`'s logic and drive its own enabling check from wherever `recv_svc` actually
   changes (`ReceiveHigherSVC`'s seed-with-sender assignment, and `ReceiveMatchingSVC`'s
   set-union) — mirroring the normal-case plan's `PrimaryExecuteOp`-driven-from-`handle_prepare_ok`
   pattern exactly, not a separate poll.
4. Single-replica-in-isolation tests (matching `test_vsr_replica.ml`'s existing style — hand-
   constructed encoded messages, inspect resulting state via accessors): `check_timeout` correctly
   transitions to `View_change` and broadcasts `StartViewChange`, bounded by `svc_limit`; a
   `StartViewChange` with a higher view is adopted (seeds `recv_svc` with the sender, resets
   `recv_dvc`/`sent_dvc`); a matching-view `StartViewChange` while already in `View_change` unions
   into `recv_svc`; `SendDVC` fires exactly once `Cardinality(recv_svc) >= f` is reached and never
   fires twice for the same episode (the one-shot flag); a `StartViewChange` for a LOWER or EQUAL
   (while `Normal`) view is correctly not-enabled/dropped.
5. `dune build`/`dune test`, confirm clean.
6. Commit.

## Task 3: `ReceiveDVC`, `WinningDVC`, `HighestCommitNumber`, `SendSV`, `ReceiveSV`

**Files:**
- Modify: `lib/vsr/replica.ml`, `lib/vsr/replica.mli`
- Modify: `test/test_vsr_replica.ml`

This is the single highest-risk task in this plan — the exact logic where the original published
VSR formalization had a real 114-step counterexample. Take real care; the plan's own final review
(and the prior plans' own review history) should be expected to scrutinize this task hardest.

**Steps:**

1. Implement `ValidDvc`, `ReceiveDVC` (the view-filtered accumulation into `recv_dvc`).
2. Implement `WinningDVC`/`HighestCommitNumber` as two independent scans over `recv_dvc`, per
   Global Constraints — do not derive one from the other.
3. Implement `SendSV`'s guard and effect, driven from `ReceiveDVC` (the only action that changes
   `Cardinality(valid recv_dvc)`) — same driving pattern as Task 2's `SendDVC`.
4. Implement `ReceiveSV`'s guard (`m.v >= View(r)`, not `>`) and effect, INCLUDING the deliberate
   non-reset of `recv_dvc`/`recv_svc` (Global Constraints) and the monotonic-only commit-number
   update (reuse/match the same pattern already established for `handle_prepare`'s `k`-bound in
   the normal-case plan, including its own hardening against a corrupted/adversarial `m.k` — this
   is exactly the same class of "network delivers garbage" concern that plan's fix-round cycle
   found real bugs in, and it applies here too, since `Start_view`'s `k` field arrives over the
   same untrusted wire).
5. Tests: `SendSV` correctly selects the DVC with largest `(last_normal_view, n)`, not just
   largest `n` alone (construct a scenario where these diverge — a lower `n` but higher
   `last_normal_view` DVC must win); `HighestCommitNumber` is verified independent of which DVC
   wins (construct a scenario where the winning DVC's own `k` is NOT the highest `k` among all
   valid DVCs); `ReceiveSV` correctly leaves `recv_dvc` non-empty afterward (a direct test of the
   non-reset, not just an absence of a crash); `ReceiveSV`'s commit-number update is verified
   monotonic-only against an adversarial `m.k` (mirroring the normal-case plan's own M2 regression
   test pattern exactly); a forged/out-of-range field on any of these new message types (matching
   the normal-case plan's own M1/M2/M3 defensive-guard pattern — validate every integer field
   arriving off the wire before trusting it, do not assume `Message.decode`'s own structural
   validation is sufficient, since it only confirms SHAPE, not PROTOCOL-LEVEL legality).
6. `dune build`/`dune test`, confirm clean.
7. Commit.

## Task 4: Real multi-replica view-change proof — running code, not the TLA+ model

**Files:**
- Create: `test/test_vsr_replica_view_change.ml`
- Modify: `test/dune`, `test/test_riptide.ml`

**Steps:**

1. Using the same `Sim_transport`/`Network.default_fault_config` pattern as the normal-case
   plan's own `test_vsr_replica_cluster.ml` (3 real `Replica.t` instances, each its own receive-
   and-dispatch fiber, `settle`-style pump-driving), build a scenario proving a real view-change:
   propose and commit a value under the initial primary (per `Primary(0)`'s own real, TLC-verified
   value — do NOT assume it's replica 1), then simulate that primary going silent (simply never
   call `propose`/route further messages through it — no need to actually kill a fiber), call
   `check_timeout` on a surviving backup enough times to cross `svc_limit` and trigger a real view
   change, settle, and confirm: a new primary (matching `Primary(<the new view>)`'s own real value)
   emerges, the surviving replicas converge on the SAME log content the old primary had already
   committed (proving `WinningDVC`'s log-selection genuinely preserves committed data, not just
   "some" data), and the cluster resumes accepting new proposals under the new primary.
2. A second test: the crash-during-view-change-adjacent scenario Decision 3's own design spec
   flags as worth exercising once a DST harness exists — this plan's own scope is only "does a
   view-change complete correctly under Sim_transport's default (reliable) fault config," not
   fault-injected view-change (that's subtask 3.4's territory, same disclosed-gap pattern the
   normal-case plan already established for out-of-order `Prepare`s) — so keep this second test
   within that same honest scope: e.g. two SEQUENTIAL view changes (proving `svc_count`'s own
   bound and the reset discipline both hold up across repeated episodes, not just one), not a
   fault-injected scenario.
3. `dune build`/`dune test`, confirm clean, run multiple times for flakiness given real fiber
   interleaving.
4. Commit.

## Self-Review Notes

- **Spec coverage**: implements all 7 of `spec/tla/VSR.tla`'s view-change actions, completing the
  full protocol this plan's two predecessors began. Storage-fault-aware recovery, state-transfer,
  reconfiguration remain explicitly out of scope for this plan (and for `spec/tla/VSR.tla` itself)
  — a real, substantial, separate follow-up per the original design spec's own Decision 1.
- **Blast radius check**: `lib/sim/network.ml`/`.mli`, `lib/transport/`, `lib/log.ml`,
  `lib/value.ml`, `lib/envelope.ml` are all untouched. `lib/vsr/message.ml`/`.mli`,
  `lib/vsr/replica_log.ml`/`.mli` are untouched (already have everything this plan needs).
- **The single highest-risk judgment call in this plan**: `WinningDVC`'s lexicographic
  `(last_normal_view, n)` tie-break and `HighestCommitNumber`'s independence from it (Task 3) —
  this is precisely the logic class that had a real, published, historical counterexample.
  Whoever reviews Task 3 should treat verifying this against adversarial/edge-case DVC sets (not
  just the happy-path scenario) as the single most important thing to check, matching how this
  exact logic was treated with maximum scrutiny in this session's own earlier TLA+ spec plan.
- **Toolchain/design grounding**: the `check_timeout` mechanism (Architecture) was arrived at via
  a dedicated research pass that read `lib/sim/network.ml`'s actual `pump_one` implementation
  directly (confirming the empty-pending-queue branch never touches the clock) and evaluated two
  concrete alternative designs before choosing — not assumed or guessed. See that research pass's
  own findings, preserved in this plan's Research Grounding section above, for the full tradeoff
  analysis.
- **What the NEXT plan (subtask 3.3/3.4, or a storage-fault-aware follow-up) will need from this
  one**: this plan completes VSR's CORE safety protocol in real, running OCaml — matching what
  `spec/tla/VSR.tla` itself scopes to. Storage-fault-aware recovery (nacks, the `nack_bitset`/
  `present_bitset` on `join_view`, persisted `view`/`log_view` replacing textbook Recovery) is
  real, substantial, separate work this plan does not attempt, per the original design spec's own
  Decision 1 and this session's own `spec/tla/README.md` documentation of that scope boundary.
