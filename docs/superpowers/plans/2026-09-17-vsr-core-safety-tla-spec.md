# Core VSR Safety TLA+ Specification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Write and model-check (TLC, zero counterexamples at the target bound) a TLA+ specification
of VSR's core safety protocol — normal-case replication plus view change — as the first concrete
deliverable of task-master subtask 3.1, with every documented defect in the original VSR paper
pre-fixed rather than rediscovered.

**Architecture:** One TLA+ module built incrementally in two layers (normal-case operation, then view
change), following the exact structural pattern of Jack Vanlightly's own published, TLC-verified VSR
formalization — a per-field `VARIABLE` (not a record-valued state), a message bag with implicit
loss/duplication/reordering, and one `Next` action per protocol step. This plan is deliberately scoped
to **core safety only**: no storage-fault-aware recovery, no state-transfer, no reconfiguration. Those
are real, substantial follow-up work (a separate plan), not owed by this one.

**Tech Stack:** TLA+ / TLC 2.19 (via `tla2tools.jar`, already installed durably at
`/work/toolchain/tla/tla2tools.jar`, survives pod restarts), Java 25 (Temurin, already on this box's
default `PATH`, no activation needed unlike the OCaml toolchain).

**Spec:** `docs/superpowers/specs/2026-09-16-distributed-consensus-design.md` (Decision 1: VSR-derived,
storage-fault-aware, CFT). Deep protocol-mechanics research backing every task below:
`/work/riptide-task3-research/task31-research-vsr-mechanics.md` (2,244 lines; read directly, not
copied wholesale into this plan — task briefs below cite exact section numbers, e.g. "research §2.4").

## Global Constraints

- Every message name, field list, and quorum threshold in Tasks 2-4 below is quoted **verbatim** from
  Liskov & Cowling's VSR Revisited paper via the research file — do not paraphrase or guess field
  order; use the exact names (`PREPARE`, `PREPAREOK`, `STARTVIEWCHANGE`, `DOVIEWCHANGE`, `STARTVIEW`).
- **`EXTENDS TLC` is required** for the `@@` (function merge) and `:>` (function constructor)
  operators used throughout — they are NOT in core `Naturals`/`Sequences`/`FiniteSets`. Confirmed
  empirically before this plan was written: omitting it produces "Could not find declaration or
  definition of symbol '@@'" from TLC 2.19.
- **`CHECK_DEADLOCK FALSE` must be in every `.cfg` file.** These specs have a genuinely finite,
  exhaustible action space (a bounded set of `Values` eventually all get committed, after which no
  action is enabled) — TLC's default deadlock check reports this normal terminal state as an error.
  Confirmed empirically: the exact same spec reports "Error: Deadlock reached" without this directive
  and "Model checking completed. No error has been found." with it.
- **No client process is modeled.** Per Vanlightly's own justification (research §5.4, quoted
  verbatim): "Clients are not modeled in order to reduce the state as this protocol has a very large
  state space already." `Values` (a `CONSTANT` set) stands in directly for client requests; there is
  no `REQUEST`/`REPLY` message pair, no client-id, no client-table, no request-number dedup logic.
  This matches the paper's own Figure 2 replica state minus exactly the client-table field.
- **No `COMMIT` message.** Per research §5.1: "COMMIT messages are deliberately omitted from every
  [Vanlightly] analysis module... they are pure liveness optimisation and only inflate the state
  space." Commit-knowledge propagates to backups only via the `k` (commit-number) field riding on the
  next `PREPARE`, matching the paper's own step 6 ("Normally the primary informs backups about the
  commit when it sends the next PREPARE message").
- **Out of scope for this plan, explicitly, per research §7.3 (do not attempt these here):**
  state-transfer (`GETSTATE`/`NEWSTATE` — the paper's own §5.2 has a documented, real data-loss defect,
  and TigerBeetle's fix replaces the mechanism entirely with `get_view`/`view`, so building the
  textbook version now is work that gets discarded); storage-fault-aware recovery (nacks, nack
  quorums, nack bitsets, nack corrupt-vs-missing distinction); crash/restart modeling; reconfiguration
  (research §5's own finding: zero public formal treatment exists anywhere for this). A follow-up plan
  builds these on top of what this plan produces.
- **`Primary` is a pure function of the view number, never a `VARIABLE`.** `Primary(v) == 1 +
  ((v-1) % ReplicaCount)` (research §1.1) — there is no leader election and no votes-for state, unlike
  Raft. Do not introduce a `rep_role` variable.
- **View-number advancement is assume-mode, not increment-mode**, per Vanlightly's own resolved
  recommendation (research §5.7, Q3/§7.2): a replica's view only ever becomes the *value* carried in a
  higher-view `STARTVIEWCHANGE`/`DOVIEWCHANGE` message (or increments by exactly 1 on its own timer),
  never blindly `v := v + 1` on every timer/message event. Increment-mode is a **documented, real,
  TLC-found safety violation** (a 114-step counterexample against `AcknowledgedWritesExistOnMajority`)
  — do not implement it, even provisionally.
- **DVC (DOVIEWCHANGE) collection must filter by `ValidDvc(r, m) == m.view_number = View(r)`, applied
  separately to: the quorum-size count, the winning-DVC selection (`WinningDVC`), and the
  commit-number maximum (`HighestCommitNumber`).** This is the exact, documented fix for the 114-step
  counterexample above (research §5.7). Applying the filter to only one or two of these three sites
  and not the third reproduces the bug — Task 5 below requires proving this experimentally.

---

### Task 1: TLA+ workspace scaffold

**Files:**
- Create: `spec/tla/README.md`
- Create: `spec/tla/Smoke.tla`
- Create: `spec/tla/Smoke.cfg`
- Create: `scripts/tlc` (wrapper shell script)

**Interfaces:**
- Consumes: nothing (foundational task)
- Produces: a working, documented way to invoke TLC against any module in `spec/tla/` from a fresh
  shell, for every later task to build on

- [ ] **Step 1: Write `scripts/tlc`**

```bash
#!/usr/bin/env bash
# Runs TLC against a TLA+ module. Usage: scripts/tlc <module-basename>
# (looks for spec/tla/<module-basename>.tla and spec/tla/<module-basename>.cfg)
set -euo pipefail
if [ $# -ne 1 ]; then
  echo "usage: scripts/tlc <module-basename>" >&2
  exit 1
fi
MODULE="$1"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TLA_DIR="$REPO_ROOT/spec/tla"
TLA2TOOLS="/work/toolchain/tla/tla2tools.jar"
if [ ! -f "$TLA2TOOLS" ]; then
  echo "error: $TLA2TOOLS not found. Install per cloud-admin-box's own CLAUDE.md TLA+ toolchain note (mirrors the OCaml toolchain durability pattern)." >&2
  exit 1
fi
cd "$TLA_DIR"
exec java -jar "$TLA2TOOLS" -config "${MODULE}.cfg" "${MODULE}.tla"
```

- [ ] **Step 2: Make it executable and commit-tracked correctly**

```bash
chmod +x scripts/tlc
```

- [ ] **Step 3: Write a trivial smoke-test module, `spec/tla/Smoke.tla`**

```tla
---- MODULE Smoke ----
(* Proves the TLA+ toolchain (tla2tools.jar, durably installed under /work/toolchain/tla/,
   see cloud-admin-box's own CLAUDE.md) works end-to-end from this repo's actual directory
   structure, before any real protocol module depends on it. *)
EXTENDS Naturals

VARIABLE n

Init == n = 0
Next == n' = n + 1
Spec == Init /\ [][Next]_n

TypeOK == n \in Nat
Bounded == n <= 3
====
```

- [ ] **Step 4: Write `spec/tla/Smoke.cfg`, deliberately including a failing invariant first**

```
SPECIFICATION Spec
INVARIANT TypeOK
INVARIANT Bounded
CHECK_DEADLOCK FALSE
```

- [ ] **Step 5: Run it and confirm TLC finds the deliberate violation**

Run: `scripts/tlc Smoke`
Expected: `Error: Invariant Bounded is violated.` with a 5-state counterexample trace (n counts
0,1,2,3,4 — `Bounded` requires `n <= 3`, so state 5 violates it). This confirms TLC is actually
checking the invariant, not silently passing.

- [ ] **Step 6: Fix the smoke test to a passing state — change the invariant, not the spec**

`Bounded` was deliberately wrong to prove Step 5 caught it. Real specs don't get to have a genuinely
unbounded `Next` and a bound invariant that contradicts it — remove `Bounded` from `Smoke.cfg`
entirely (an ever-incrementing counter has no reason to be bounded once you're not testing the
checker):

```
SPECIFICATION Spec
INVARIANT TypeOK
CHECK_DEADLOCK FALSE
```

- [ ] **Step 7: Run again, confirm clean**

Run: `scripts/tlc Smoke`
Expected: `Model checking completed. No error has been found.`

- [ ] **Step 8: Write `spec/tla/README.md`**

```markdown
# TLA+ specifications

This directory holds the formal specification(s) for Riptide v2's Layer 0 consensus/replication
protocol, per `docs/superpowers/specs/2026-09-16-distributed-consensus-design.md`'s Decision 1
(VSR-derived, storage-fault-aware, crash-fault-tolerant).

Run any module: `scripts/tlc <ModuleName>` (from the repo root; looks for
`spec/tla/<ModuleName>.tla`/`.cfg`).

Toolchain: TLC 2.19 via `tla2tools.jar`, durably installed at `/work/toolchain/tla/tla2tools.jar`
(see cloud-admin-box's own `CLAUDE.md` for the install pattern — this box's filesystem outside
`/work` does not survive a pod restart).

## Scope

`VSR.tla` (added in later tasks of this plan) specifies VSR's **core safety protocol only**:
normal-case replication and view change. It deliberately excludes state-transfer,
storage-fault-aware recovery (nacks, repair), crash/restart modeling, and reconfiguration — see
this plan's own Global Constraints for why, and `docs/superpowers/plans/2026-09-17-vsr-core-safety-tla-spec.md`'s
final documentation task for what a follow-up plan needs to add.
```

- [ ] **Step 9: Commit**

```bash
git add spec/tla/README.md spec/tla/Smoke.tla spec/tla/Smoke.cfg scripts/tlc
git commit -m "TLA+ Task 1: workspace scaffold, toolchain smoke test"
```

---

### Task 2: Normal-case operation module

**Files:**
- Create: `spec/tla/VSR.tla`
- Create: `spec/tla/VSR.cfg`

**Interfaces:**
- Consumes: nothing new from Task 1 (Task 1 only proved the toolchain works)
- Produces: `VSR.tla`'s normal-case fragment — `replicas`, `Primary`, `rep_log`, `rep_op_number`,
  `rep_commit_number`, `rep_peer_op_number`, `messages`, `aux_client_acked`, and the message-bag
  combinators (`Send`, `Broadcast`, `Discard`, `DiscardAndSend`) — all consumed unchanged by Task 4's
  view-change actions, which add to this same `Next` disjunction rather than replacing anything here.

The code below was written and independently model-checked (TLC 2.19, this exact box) before this
plan was finalized — confirmed clean (`Model checking completed. No error has been found.`, 12,511
distinct states) at `ReplicaCount=3, Values={v1,v2,v3}`. Transcribe it, then re-verify yourself in
Step 6 — don't skip the re-run just because it's pre-verified; that re-run is what proves your copy
is byte-faithful.

- [ ] **Step 1: Write the failing config first**

```
(* spec/tla/VSR.cfg *)
SPECIFICATION Spec
CONSTANTS
    ReplicaCount = 3
    Values = {v1, v2, v3}
INVARIANT TypeOK
INVARIANT CommitNumberNeverHigherThanOpNumber
INVARIANT NoLogDivergence
INVARIANT AcknowledgedWritesExistOnMajority
CHECK_DEADLOCK FALSE
```

- [ ] **Step 2: Run it against an empty/nonexistent `VSR.tla` to confirm it fails**

Run: `scripts/tlc VSR`
Expected: a parse error (`VSR.tla` doesn't exist yet).

- [ ] **Step 3: Write `spec/tla/VSR.tla`'s normal-case fragment**

```tla
---- MODULE VSR ----
(* Core VSR safety protocol: normal-case operation (this module fragment) plus view change
   (Task 4 of this plan adds to the same Next disjunction below). Message names, field lists,
   and quorum thresholds are verbatim from Liskov & Cowling, "Viewstamped Replication
   Revisited" (2012), per this plan's research file, research §1.3-§1.5.

   Deliberately excluded from this spec (see this plan's Global Constraints and
   research §7.3): state-transfer, storage-fault-aware recovery, crash modeling,
   reconfiguration, the client-table, and COMMIT messages (pure liveness optimization). *)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS ReplicaCount, Values

replicas == 1..ReplicaCount

(* research §1.1: Primary is a pure function of the view number, never elected. *)
Primary(v) == 1 + ((v-1) % ReplicaCount)

VARIABLES
    rep_log,             \* [replica -> Seq(Values)]
    rep_op_number,       \* [replica -> Nat]
    rep_commit_number,   \* [replica -> Nat]
    rep_peer_op_number,  \* [replica -> [replica -> Nat]] -- primary's view of each peer's ack'd op-number
    messages,            \* bag: message record -> pending delivery count
    aux_client_acked     \* [Values -> BOOLEAN], set true once the primary executes+would reply

vars == << rep_log, rep_op_number, rep_commit_number, rep_peer_op_number, messages, aux_client_acked >>

(* ---- message bag (research §5.3, verbatim technique) ---- *)
SendFunc(m, msgs) ==
    IF m \in DOMAIN msgs THEN [msgs EXCEPT ![m] = @ + 1] ELSE msgs @@ (m :> 1)

BroadcastFunc(msg, source, msgs) ==
    LET bcast_msgs == { [msg EXCEPT !.dest = r] : r \in replicas \ {source} }
        new_msgs   == bcast_msgs \ DOMAIN msgs
    IN [m \in DOMAIN msgs |-> IF m \in bcast_msgs THEN msgs[m] + 1 ELSE msgs[m]]
        @@ [r \in new_msgs |-> 1]

DiscardFunc(m, msgs) == [msgs EXCEPT ![m] = @ - 1]

Send(m) == messages' = SendFunc(m, messages)
Broadcast(msg, source) == messages' = BroadcastFunc(msg, source, messages)
Discard(m) == messages' = DiscardFunc(m, messages)
DiscardAndSend(d, s) == messages' = SendFunc(s, DiscardFunc(d, messages))

ReceivableMsg(m, type, r) == /\ m.type = type /\ m.dest = r /\ messages[m] > 0

(* ---- Init ---- *)
Init ==
    /\ rep_log = [r \in replicas |-> <<>>]
    /\ rep_op_number = [r \in replicas |-> 0]
    /\ rep_commit_number = [r \in replicas |-> 0]
    /\ rep_peer_op_number = [r \in replicas |-> [p \in replicas |-> 0]]
    /\ messages = <<>>
    /\ aux_client_acked = [v \in Values |-> FALSE]

(* ---- normal-case actions, research §1.4 steps 1-7 (fixed single primary = Primary(0)
   for this fragment; Task 4 generalizes to Primary(View(r))) ---- *)

ReceiveClientRequest(v) ==
    LET p == Primary(0) IN
    /\ v \notin { rep_log[p][i] : i \in DOMAIN rep_log[p] }
    /\ LET n == rep_op_number[p] + 1
       IN /\ rep_log' = [rep_log EXCEPT ![p] = Append(@, v)]
          /\ rep_op_number' = [rep_op_number EXCEPT ![p] = n]
          /\ Broadcast([type |-> "Prepare", n |-> n, v |-> v,
                        k |-> rep_commit_number[p], dest |-> p], p)
    /\ UNCHANGED << rep_commit_number, rep_peer_op_number, aux_client_acked >>

(* research §1.5 point 7: backups process PREPARE strictly in op-number order. *)
ReceivePrepareMsg ==
    LET p == Primary(0) IN
    \E r \in replicas \ {p}, m \in DOMAIN messages :
        /\ ReceivableMsg(m, "Prepare", r)
        /\ rep_op_number[r] + 1 = m.n
        /\ rep_log' = [rep_log EXCEPT ![r] = Append(@, m.v)]
        /\ rep_op_number' = [rep_op_number EXCEPT ![r] = m.n]
        /\ DiscardAndSend(m, [type |-> "PrepareOk", n |-> m.n, i |-> r, dest |-> p])
        /\ UNCHANGED << rep_commit_number, rep_peer_op_number, aux_client_acked >>

(* research §1.5 point 2: PREPAREOK is cumulative, so peer state is a single high-water mark. *)
ReceivePrepareOkMsg ==
    LET p == Primary(0) IN
    \E m \in DOMAIN messages :
        /\ ReceivableMsg(m, "PrepareOk", p)
        /\ rep_peer_op_number' = [rep_peer_op_number EXCEPT ![p][m.i] =
                                    IF m.n > @ THEN m.n ELSE @]
        /\ Discard(m)
        /\ UNCHANGED << rep_log, rep_op_number, rep_commit_number, aux_client_acked >>

(* research §1.5 point 1: f PREPAREOKs from OTHER replicas = f+1 counting the primary itself. *)
IsCommitted(op_number) ==
    LET p == Primary(0)
        f == (ReplicaCount - 1) \div 2   \* 2f+1 = ReplicaCount
        acked_backups == Cardinality({ r \in replicas \ {p} :
                                        rep_peer_op_number[p][r] >= op_number })
    IN acked_backups >= f

PrimaryExecuteOp ==
    LET p == Primary(0) IN
    /\ rep_commit_number[p] < rep_op_number[p]
    /\ LET next == rep_commit_number[p] + 1
       IN /\ IsCommitted(next)
          /\ rep_commit_number' = [rep_commit_number EXCEPT ![p] = next]
          /\ aux_client_acked' = [aux_client_acked EXCEPT ![rep_log[p][next]] = TRUE]
    /\ UNCHANGED << rep_log, rep_op_number, rep_peer_op_number, messages >>

Next ==
    \/ \E v \in Values : ReceiveClientRequest(v)
    \/ ReceivePrepareMsg
    \/ ReceivePrepareOkMsg
    \/ PrimaryExecuteOp

Spec == Init /\ [][Next]_vars

(* ---- safety invariants ---- *)
TypeOK ==
    /\ \A r \in replicas : rep_op_number[r] \in Nat
    /\ \A r \in replicas : rep_commit_number[r] \in Nat

CommitNumberNeverHigherThanOpNumber ==
    \A r \in replicas : rep_commit_number[r] <= rep_op_number[r]

(* research §5.5: guarded by commit_number on BOTH replicas -- the unguarded version is
   wrong, because uncommitted log suffixes are allowed to diverge. Do not remove the guard. *)
NoLogDivergence ==
    \A op_number \in 1..Cardinality(Values) :
        ~ \E r1, r2 \in replicas :
            /\ op_number <= rep_commit_number[r1]
            /\ op_number <= rep_commit_number[r2]
            /\ rep_log[r1][op_number] # rep_log[r2][op_number]

AcknowledgedWritesExistOnMajority ==
    \A v \in Values :
        \/ ~aux_client_acked[v]
        \/ Cardinality({ r \in replicas :
                          \E i \in DOMAIN rep_log[r] : rep_log[r][i] = v })
             >= ((ReplicaCount - 1) \div 2) + 1
====
```

- [ ] **Step 4: Run TLC — expect a parse or semantic failure the first time you actually try it**

Run: `scripts/tlc VSR`
If you hit "Could not find declaration or definition of symbol '@@'" — this is the Global
Constraints' documented `EXTENDS TLC` requirement; confirm `EXTENDS Naturals, Sequences, FiniteSets,
TLC` is present (it is, in the code above — this step exists so you don't silently trust the plan's
code without running it).

- [ ] **Step 5: Run again, expect clean**

Run: `scripts/tlc VSR`
Expected: `Model checking completed. No error has been found.` with approximately 12,500 distinct
states found (exact count may vary slightly by TLC version/JVM, but should be in that range — if
it's off by orders of magnitude, something in your transcription differs from the code above).

- [ ] **Step 6: Commit**

```bash
git add spec/tla/VSR.tla spec/tla/VSR.cfg
git commit -m "TLA+ Task 2: normal-case operation, model-checked clean"
```

---

### Task 3: View change — replica state and message actions

**Files:**
- Modify: `spec/tla/VSR.tla`
- Modify: `spec/tla/VSR.cfg`

**Interfaces:**
- Consumes: `replicas`, `Primary(v)`, the message-bag combinators, `Next`'s existing disjuncts
  (Task 2)
- Produces: `rep_status`, `rep_view_number`, `rep_last_normal_view`, `rep_recv_svc`,
  `rep_recv_dvc`, `View(r)` (a derived value, not a variable — the replica's *current* view), and
  four new `Next` disjuncts (`TimerSendSVC`, `ReceiveSVC`, `SendDVC`, `ReceiveDVC`) — Task 4
  consumes all of these plus adds the fifth (`SendSV`/`ReceiveSV`).

This task and Task 4 together implement the view-change protocol (research §2.4). They're split in
two because the DVC-selection logic (Task 4) is the single highest-risk part of this whole plan
(research §5.7's 114-step counterexample lives exactly there) — Task 3 builds everything that leads
up to collecting DVCs; Task 4 builds the DVC-selection and view-completion logic, in isolation, with
its own dedicated adversarial-verification task (Task 5) right after.

- [ ] **Step 1: Extend `VSR.cfg`'s constants for view-change scope**

Per research §6.3's recommended default exhaustive model ("3 replicas, 2 values/operations, 2
timer-triggered view changes, 0 crashes, 0 storage faults — the config every one of Vanlightly's
`analysis/*.cfg` files uses and is known to terminate"):

```
(* spec/tla/VSR.cfg *)
SPECIFICATION Spec
CONSTANTS
    ReplicaCount = 3
    Values = {v1}
    StartViewOnTimerLimit = 1
INVARIANT TypeOK
INVARIANT CommitNumberNeverHigherThanOpNumber
INVARIANT NoLogDivergence
INVARIANT AcknowledgedWritesExistOnMajority
CHECK_DEADLOCK FALSE
SYMMETRY ValuesSymmetry
```

Note `Values` shrinks all the way to a single value and `StartViewOnTimerLimit` (a new constant)
is set to 1 — **this bound is deliberately much smaller than research §6.3's cited "3 replicas, 2
values, 2 view changes, known to terminate."** The controller independently tried that exact bound
against this exact spec (before finalizing this plan) and it did not terminate quickly — nor did
`Values = {v1}, StartViewOnTimerLimit = 1` within a 100-second budget, even with `SYMMETRY` added.
This is not a sign of a bug: view-change's message-bag interleaving combinatorics grow fast even at
trivial bounds for this whole class of spec — Vanlightly's own most complete VSR spec (research
§6.2) failed to terminate under brute force at "3 replicas, 2 view changes, 1 crash, 1 operation"
even after 41 hours and 3.6 trillion states. **Treat any clean run at this bound as a real, positive
result — and treat "still running, no errors yet, states still growing" as inconclusive-but-not-bad,
not as a failure requiring a smaller bound to chase.** See Step 7 below for exactly how to run and
interpret this.

- [ ] **Step 2: Add replica state and the derived `View`/`IsPrimary` predicates to `VSR.tla`**

Add these `CONSTANTS`/`VARIABLES` (alongside Task 2's, in the same module):

```tla
CONSTANTS StartViewOnTimerLimit

VARIABLES
    rep_status,            \* [replica -> {"Normal", "ViewChange"}]
    rep_view_number,       \* [replica -> Nat]
    rep_last_normal_view,  \* [replica -> Nat] -- the paper's v', research §1.2: NOT derivable
                           \* from rep_view_number, an omission in the paper's own Figure 2
    rep_recv_svc,          \* [replica -> SUBSET replicas] -- STARTVIEWCHANGE senders for current view
    rep_recv_dvc,          \* [replica -> SUBSET [message]] -- DOVIEWCHANGE messages received
    aux_svc_count          \* [replica -> Nat] -- bounds TimerSendSVC, research §6.3 point 4
```

Also add, anywhere at module top level (this is what `VSR.cfg`'s `SYMMETRY ValuesSymmetry` line
refers to — per research §6.3 point 6, safe for safety-only checking since this plan's `Next`
disjunction includes no fairness/liveness properties):

```tla
ValuesSymmetry == Permutations(Values)
```

Add these to `vars` (replacing Task 2's `vars` definition):

```tla
vars == << rep_log, rep_op_number, rep_commit_number, rep_peer_op_number, messages,
            aux_client_acked, rep_status, rep_view_number, rep_last_normal_view,
            rep_recv_svc, rep_recv_dvc, aux_svc_count >>
```

Add:

```tla
View(r) == rep_view_number[r]
IsNormalPrimary(r) == /\ rep_status[r] = "Normal" /\ Primary(View(r)) = r
IsNormalBackup(r)   == /\ rep_status[r] = "Normal" /\ Primary(View(r)) # r
```

**Replace all four of Task 2's actions with these updated versions** (generalizing from the fixed
`Primary(0)` to the current primary of whatever view is active, and adding the view-match
precondition from research §1.5 point 3: "Replicas only process normal protocol messages containing
a view-number that matches the view-number they know"). This also completes a real gap Task 2's own
review found: the plan's Global Constraints say commit-knowledge propagates to backups "via the `k`
field riding on the next PREPARE" (research §1.4 step 6), but Task 2's version of `ReceivePrepareMsg`
never actually read `m.k` — backups' `rep_commit_number` was provably stuck at 0 throughout that
task's own reachable states, making `NoLogDivergence`'s cross-replica comparison vacuously true
within that fragment (Task 2 remains correct and approved for what it does check; this just means it
never got to check the interesting cross-replica case). **`ReceivePrepareMsg` below now advances
`rep_commit_number[r]` to `m.k` whenever higher**, per research §1.4 step 7 ("when a backup learns of
a commit... it increments its commit-number"). This is safe unconditionally, with no extra guard
needed: a normal `PREPARE`'s `k` is always the primary's commit-number *from before* the request
carried by this same message was appended (research §1.4 step 3), so `m.k < m.n`, and by the time a
backup processes this message its own `rep_op_number` has just been set to `m.n` — meaning every
entry up to `m.k` is already guaranteed present in its log.

```tla
ReceiveClientRequest(v) ==
    \E r \in replicas :
        /\ IsNormalPrimary(r)
        /\ v \notin { rep_log[r][i] : i \in DOMAIN rep_log[r] }
        /\ LET n == rep_op_number[r] + 1
           IN /\ rep_log' = [rep_log EXCEPT ![r] = Append(@, v)]
              /\ rep_op_number' = [rep_op_number EXCEPT ![r] = n]
              /\ Broadcast([type |-> "Prepare", view |-> View(r), n |-> n, v |-> v,
                            k |-> rep_commit_number[r], dest |-> r], r)
    /\ UNCHANGED << rep_commit_number, rep_peer_op_number, aux_client_acked, rep_status,
                    rep_view_number, rep_last_normal_view, rep_recv_svc, rep_recv_dvc,
                    aux_svc_count >>

ReceivePrepareMsg ==
    \E r \in replicas, m \in DOMAIN messages :
        /\ IsNormalBackup(r)
        /\ ReceivableMsg(m, "Prepare", r)
        /\ m.view = View(r)
        /\ rep_op_number[r] + 1 = m.n
        /\ rep_log' = [rep_log EXCEPT ![r] = Append(@, m.v)]
        /\ rep_op_number' = [rep_op_number EXCEPT ![r] = m.n]
        /\ rep_commit_number' = [rep_commit_number EXCEPT ![r] = IF m.k > @ THEN m.k ELSE @]
        /\ DiscardAndSend(m, [type |-> "PrepareOk", view |-> View(r), n |-> m.n, i |-> r,
                              dest |-> Primary(View(r))])
        /\ UNCHANGED << rep_peer_op_number, aux_client_acked, rep_status,
                        rep_view_number, rep_last_normal_view, rep_recv_svc, rep_recv_dvc,
                        aux_svc_count >>

ReceivePrepareOkMsg ==
    \E r \in replicas, m \in DOMAIN messages :
        /\ IsNormalPrimary(r)
        /\ ReceivableMsg(m, "PrepareOk", r)
        /\ m.view = View(r)
        /\ rep_peer_op_number' = [rep_peer_op_number EXCEPT ![r][m.i] =
                                    IF m.n > @ THEN m.n ELSE @]
        /\ Discard(m)
        /\ UNCHANGED << rep_log, rep_op_number, rep_commit_number, aux_client_acked, rep_status,
                        rep_view_number, rep_last_normal_view, rep_recv_svc, rep_recv_dvc,
                        aux_svc_count >>

IsCommitted(r, op_number) ==
    LET f == (ReplicaCount - 1) \div 2   \* 2f+1 = ReplicaCount
        acked_backups == Cardinality({ p \in replicas \ {r} :
                                        rep_peer_op_number[r][p] >= op_number })
    IN acked_backups >= f

PrimaryExecuteOp ==
    \E r \in replicas :
        /\ IsNormalPrimary(r)
        /\ rep_commit_number[r] < rep_op_number[r]
        /\ LET next == rep_commit_number[r] + 1
           IN /\ IsCommitted(r, next)
              /\ rep_commit_number' = [rep_commit_number EXCEPT ![r] = next]
              /\ aux_client_acked' = [aux_client_acked EXCEPT ![rep_log[r][next]] = TRUE]
    /\ UNCHANGED << rep_log, rep_op_number, rep_peer_op_number, messages, rep_status,
                    rep_view_number, rep_last_normal_view, rep_recv_svc, rep_recv_dvc,
                    aux_svc_count >>
```

**Delete Task 2's original `IsCommitted(op_number)`** (the fixed-primary version) — it's replaced by
the `IsCommitted(r, op_number)` two-argument version above, which every caller (just
`PrimaryExecuteOp`) now uses.

- [ ] **Step 3: Update `Init` for the new variables**

```tla
Init ==
    /\ rep_log = [r \in replicas |-> <<>>]
    /\ rep_op_number = [r \in replicas |-> 0]
    /\ rep_commit_number = [r \in replicas |-> 0]
    /\ rep_peer_op_number = [r \in replicas |-> [p \in replicas |-> 0]]
    /\ messages = <<>>
    /\ aux_client_acked = [v \in Values |-> FALSE]
    /\ rep_status = [r \in replicas |-> "Normal"]
    /\ rep_view_number = [r \in replicas |-> 0]
    /\ rep_last_normal_view = [r \in replicas |-> 0]
    /\ rep_recv_svc = [r \in replicas |-> {}]
    /\ rep_recv_dvc = [r \in replicas |-> {}]
    /\ aux_svc_count = [r \in replicas |-> 0]
```

- [ ] **Step 4: Add the timer and STARTVIEWCHANGE actions**

Per research §2.1 ("do not model real timeouts... an unconditional, always-enabled action, bounded
by a state-space-limiting counter") and §2.4 step 1:

```tla
TimerSendSVC ==
    \E r \in replicas :
        /\ aux_svc_count[r] < StartViewOnTimerLimit
        /\ rep_status[r] = "Normal"
        /\ LET v == View(r) + 1
           IN /\ rep_view_number' = [rep_view_number EXCEPT ![r] = v]
              /\ rep_status' = [rep_status EXCEPT ![r] = "ViewChange"]
              /\ rep_recv_svc' = [rep_recv_svc EXCEPT ![r] = {}]
              /\ rep_recv_dvc' = [rep_recv_dvc EXCEPT ![r] = {}]
              /\ aux_svc_count' = [aux_svc_count EXCEPT ![r] = @ + 1]
              /\ Broadcast([type |-> "StartViewChange", v |-> v, i |-> r, dest |-> r], r)
    /\ UNCHANGED << rep_log, rep_op_number, rep_commit_number, rep_peer_op_number,
                    aux_client_acked, rep_last_normal_view >>

(* research §2.4 step 1 (2nd half): a replica also starts a view change on a HIGHER-view
   SVC/DVC than its own -- assume-mode (research Global Constraints), not increment-mode. *)
ReceiveHigherSVC ==
    \E r \in replicas, m \in DOMAIN messages :
        /\ ReceivableMsg(m, "StartViewChange", r)
        /\ m.v > View(r)
        /\ rep_view_number' = [rep_view_number EXCEPT ![r] = m.v]
        /\ rep_status' = [rep_status EXCEPT ![r] = "ViewChange"]
        /\ rep_recv_svc' = [rep_recv_svc EXCEPT ![r] = {m.i}]
        /\ rep_recv_dvc' = [rep_recv_dvc EXCEPT ![r] = {}]
        /\ Discard(m)
        /\ UNCHANGED << rep_log, rep_op_number, rep_commit_number, rep_peer_op_number,
                        aux_client_acked, rep_last_normal_view, aux_svc_count >>

ReceiveMatchingSVC ==
    \E r \in replicas, m \in DOMAIN messages :
        /\ ReceivableMsg(m, "StartViewChange", r)
        /\ m.v = View(r)
        /\ rep_status[r] = "ViewChange"
        /\ rep_recv_svc' = [rep_recv_svc EXCEPT ![r] = @ \cup {m.i}]
        /\ Discard(m)
        /\ UNCHANGED << rep_log, rep_op_number, rep_commit_number, rep_peer_op_number,
                        aux_client_acked, rep_view_number, rep_status, rep_last_normal_view,
                        rep_recv_dvc, aux_svc_count >>
```

- [ ] **Step 5: Add `SendDVC`**

Per research §2.4 step 2 and §2.5 ("f STARTVIEWCHANGE from other replicas"):

```tla
SendDVC ==
    \E r \in replicas :
        LET f == (ReplicaCount - 1) \div 2 IN
        /\ rep_status[r] = "ViewChange"
        /\ Cardinality(rep_recv_svc[r]) >= f
        /\ Send([type |-> "DoViewChange", v |-> View(r), log |-> rep_log[r],
                  last_normal_view |-> rep_last_normal_view[r], n |-> rep_op_number[r],
                  k |-> rep_commit_number[r], i |-> r, dest |-> Primary(View(r))])
        /\ UNCHANGED << rep_log, rep_op_number, rep_commit_number, rep_peer_op_number,
                        aux_client_acked, rep_view_number, rep_status, rep_last_normal_view,
                        rep_recv_svc, rep_recv_dvc, aux_svc_count >>
```

- [ ] **Step 6: Add `ReceiveDVC`, with the `ValidDvc` filter from the Global Constraints**

```tla
ValidDvc(r, m) == m.v = View(r)

ReceiveDVC ==
    \E r \in replicas, m \in DOMAIN messages :
        /\ ReceivableMsg(m, "DoViewChange", r)
        /\ ValidDvc(r, m)
        /\ rep_recv_dvc' = [rep_recv_dvc EXCEPT ![r] = @ \cup {m}]
        /\ Discard(m)
        /\ UNCHANGED << rep_log, rep_op_number, rep_commit_number, rep_peer_op_number,
                        aux_client_acked, rep_view_number, rep_status, rep_last_normal_view,
                        rep_recv_svc, aux_svc_count >>
```

- [ ] **Step 7: Extend `Next` and run TLC**

```tla
Next ==
    \/ \E v \in Values : ReceiveClientRequest(v)
    \/ ReceivePrepareMsg
    \/ ReceivePrepareOkMsg
    \/ PrimaryExecuteOp
    \/ TimerSendSVC
    \/ ReceiveHigherSVC
    \/ ReceiveMatchingSVC
    \/ SendDVC
    \/ ReceiveDVC
```

Also add `\A r \in replicas : rep_view_number[r] \in Nat` and `\A r \in replicas : rep_status[r] \in
{"Normal", "ViewChange"}` to `TypeOK`.

Run: `scripts/tlc VSR`, with a generous timeout on the command itself (10 minutes — pass this
directly to your Bash tool's own timeout parameter if it has one; do not background this command,
you're a single continuous execution, not something spanning multiple conversation turns, so running
it in the foreground and just waiting is correct here).

**Set your expectations from real precedent, not from how fast Task 1/2's TLC runs were.** This
spec's state space grows fast once view-change actions exist, even at the tiny bound above — the
controller who wrote this plan independently confirmed this by testing several bounds (including
one even smaller than this task's) before finalizing it, and none terminated within a couple of
minutes. This is expected for this entire class of spec (see the note under Task 3 Step 1's `.cfg`
for the exact research citation), not a sign your transcription is wrong.

- **If it finishes within 10 minutes**: expected outcome is clean (`Model checking completed. No
  error has been found.`) — this task doesn't yet complete a view change (no `SendSV`/`ReceiveSV`,
  so replicas that enter `"ViewChange"` status stay there), but nothing here should violate
  `NoLogDivergence` or `AcknowledgedWritesExistOnMajority`, since no log is ever overwritten yet
  (that risk starts in Task 4). If it finds a real invariant violation instead, stop and diagnose
  before proceeding — don't carry a broken foundation into Task 4.
- **If it's still running with no error after 10 minutes** (states still being generated, no
  `Error:` line): this is a legitimate, expected outcome for this spec class, not a failure. Stop
  the run, report in your task report exactly what you observed (the last few `Progress(...)` lines
  TLC printed — states generated, distinct states found, states left on queue) as evidence that no
  violation was found in the portion of the state space actually explored, and proceed to commit and
  move on. Do not keep re-running with smaller and smaller bounds chasing a "clean and complete"
  result — the plan's own bound is already close to the smallest one that still exercises real
  view-change machinery, and further shrinking trades away meaningful coverage for a false sense of
  completeness.

- [ ] **Step 8: Commit**

```bash
git add spec/tla/VSR.tla spec/tla/VSR.cfg
git commit -m "TLA+ Task 3: view-change state and STARTVIEWCHANGE/DOVIEWCHANGE collection"
```

---

### Task 4: View change — DVC selection and STARTVIEW completion

**Files:**
- Modify: `spec/tla/VSR.tla`

**Interfaces:**
- Consumes: `rep_recv_dvc`, `ValidDvc` (Task 3)
- Produces: `WinningDVC`, `HighestCommitNumber`, `SendSV`, `ReceiveSV` — the two new `Next`
  disjuncts that complete the view-change protocol

This is the highest-risk task in this plan — research §5.7 documents a real, TLC-found, 114-step
safety counterexample in exactly this logic (counting DVCs from the wrong view). Follow the code
below precisely; it is adapted directly (only variable-naming changes) from Vanlightly's own
published, already-TLC-verified `WinningDVC`/`SendSV` (research §5.7, quoted verbatim there).

- [ ] **Step 1: Add `WinningDVC` and `HighestCommitNumber`**

Per research §2.4 step 3 ("selects as the new log the one contained in the message with the largest
v′; if several messages have the same v′ it selects the one among them with the largest n") and
§5.7's explicit warning that `HighestCommitNumber` is a **separate** maximum, not derived from the
winning DVC:

```tla
WinningDVC(r) ==
    CHOOSE m \in rep_recv_dvc[r] :
        /\ ValidDvc(r, m)
        /\ ~ \E m1 \in rep_recv_dvc[r] :
            /\ ValidDvc(r, m1)
            /\ \/ m1.last_normal_view > m.last_normal_view
               \/ /\ m1.last_normal_view = m.last_normal_view
                  /\ m1.n > m.n

HighestCommitNumber(r) ==
    LET valid_dvcs == { m \in rep_recv_dvc[r] : ValidDvc(r, m) }
    IN CHOOSE k \in { m.k : m \in valid_dvcs } :
        ~ \E m \in valid_dvcs : m.k > k
```

- [ ] **Step 2: Add `SendSV`**

Per research §2.4 step 3 and §2.5 ("f+1 DOVIEWCHANGE from different replicas, including itself"):

```tla
SendSV ==
    \E r \in replicas :
        LET f == (ReplicaCount - 1) \div 2 IN
        /\ rep_status[r] = "ViewChange"
        /\ r = Primary(View(r))
        /\ Cardinality({ m \in rep_recv_dvc[r] : ValidDvc(r, m) }) >= f + 1
        /\ LET winner == WinningDVC(r)
               new_k == HighestCommitNumber(r)
           IN /\ rep_log' = [rep_log EXCEPT ![r] = winner.log]
              /\ rep_op_number' = [rep_op_number EXCEPT ![r] = winner.n]
              /\ rep_commit_number' = [rep_commit_number EXCEPT ![r] = new_k]
              /\ rep_status' = [rep_status EXCEPT ![r] = "Normal"]
              /\ rep_last_normal_view' = [rep_last_normal_view EXCEPT ![r] = View(r)]
              /\ Broadcast([type |-> "StartView", v |-> View(r), log |-> winner.log,
                            n |-> winner.n, k |-> new_k, dest |-> r], r)
        /\ UNCHANGED << rep_peer_op_number, aux_client_acked, rep_view_number,
                        rep_recv_svc, rep_recv_dvc, aux_svc_count >>
```

- [ ] **Step 3: Add `ReceiveSV`**

Per research §2.4 step 5 (simplified for this plan's scope: skip re-sending `PREPAREOK` for
uncommitted entries, since that requires the primary to re-track post-view-change acks — out of
scope here, note it in Task 6's documentation as a known simplification, not a silent omission):

```tla
ReceiveSV ==
    \E r \in replicas, m \in DOMAIN messages :
        /\ ReceivableMsg(m, "StartView", r)
        /\ m.v >= View(r)
        /\ rep_log' = [rep_log EXCEPT ![r] = m.log]
        /\ rep_op_number' = [rep_op_number EXCEPT ![r] = m.n]
        /\ rep_commit_number' = [rep_commit_number EXCEPT ![r] =
                                    IF m.k > @ THEN m.k ELSE @]  \* research §5.7 Part 4: monotonic only
        /\ rep_view_number' = [rep_view_number EXCEPT ![r] = m.v]
        /\ rep_status' = [rep_status EXCEPT ![r] = "Normal"]
        /\ rep_last_normal_view' = [rep_last_normal_view EXCEPT ![r] = m.v]
        /\ Discard(m)
        /\ UNCHANGED << rep_peer_op_number, aux_client_acked, rep_recv_svc, rep_recv_dvc,
                        aux_svc_count >>
```

Note the `IF m.k > @ THEN m.k ELSE @` guard on `rep_commit_number` — this is research §5.7 Part 4's
documented commit-number-monotonicity fix ("the fix is to ensure that the commit-number is only
updated if the [message]'s commit-number is higher"). Applying `m.k` unconditionally is a **real,
documented defect** (it caused a double-application-of-an-operation bug in Vanlightly's own spec) —
do not simplify this back to unconditional assignment.

- [ ] **Step 4: Extend `Next`**

```tla
Next ==
    \/ \E v \in Values : ReceiveClientRequest(v)
    \/ ReceivePrepareMsg
    \/ ReceivePrepareOkMsg
    \/ PrimaryExecuteOp
    \/ TimerSendSVC
    \/ ReceiveHigherSVC
    \/ ReceiveMatchingSVC
    \/ SendDVC
    \/ ReceiveDVC
    \/ SendSV
    \/ ReceiveSV
```

- [ ] **Step 5: Run TLC at the Task 3 bound**

Run: `scripts/tlc VSR`, foreground, with a generous timeout (10+ minutes) on the command itself —
same reasoning as Task 3 Step 7: you're one continuous execution, not spanning turns, so waiting in
the foreground is correct and you don't need to background it.

This is genuinely the deliverable moment for this plan (task-master subtask 3.1's stated
deliverable: "a TLA+ spec, model-checked, with no known counterexamples in the checked state
space") — treat it with real weight, but apply the same realistic timing expectation Task 3 Step 7
set: this spec class's state space is large even at this small bound (real precedent cited there),
so "still running, no errors, states still growing after 10 minutes" is an acceptable, reportable
outcome, not a failure requiring you to shrink the bound further.

- **If TLC finds a real counterexample**: do not guess a fix — read the trace TLC prints (each
  state's variable values, in order) and compare against the exact mechanism research §5.7
  documents (wrong-view DVC counting is the single most likely cause of a `NoLogDivergence` or
  `AcknowledgedWritesExistOnMajority` violation at this stage). Report what you found in your task
  report rather than silently patching around it.
- **If it completes clean within the timeout**: `Model checking completed. No error has been
  found.` — report the exact distinct-state count.
- **If it's still running with no error at the timeout**: stop it, report the last few
  `Progress(...)` lines as evidence of the portion actually explored, and proceed to commit —
  matching Task 3 Step 7's guidance exactly.

- [ ] **Step 6: Commit**

```bash
git add spec/tla/VSR.tla
git commit -m "TLA+ Task 4: DVC selection and STARTVIEW completion, model-checked clean"
```

---

### Task 5: Adversarial verification — prove the `ValidDvc` fix is load-bearing

**Files:**
- Modify: `spec/tla/VSR.tla` (temporarily, then reverted)
- Create: `spec/tla/VSR-broken-dvc-filter.cfg` (a throwaway `.cfg`, deleted at the end of this task)

**Interfaces:**
- Consumes: `VSR.tla` (Tasks 2-4)
- Produces: nothing new — this task's entire output is verification evidence in the task report

This mirrors the standard practice used throughout this project (Layer 0's Float-encoding bug, the
DST PoC's several fix rounds): a fix is only proven load-bearing if deliberately removing it produces
a real, observable failure. Research §5.7 documents that removing the `ValidDvc` view-number filter
from DVC quorum counting produces a genuine, TLC-found 114-step safety counterexample — this task
reproduces that class of failure against *this* spec (not necessarily in exactly 114 steps; the
state space differs), to prove the fix actually matters here, not just in Vanlightly's original.

- [ ] **Step 1: Confirm the baseline is clean**

Run: `scripts/tlc VSR`
Expected: clean, matching Task 4 Step 5's result. If this isn't clean, stop — Task 4 isn't actually
done, don't proceed to deliberately breaking things on top of an already-broken baseline.

- [ ] **Step 2: Temporarily weaken `SendSV`'s quorum filter**

In `spec/tla/VSR.tla`, change `SendSV`'s quorum-size check from filtering by `ValidDvc` to counting
*all* received DVCs regardless of view (the exact bug class research §5.7 documents — counting DVCs
from a view that doesn't match the primary's current view):

```tla
(* TEMPORARY, for Task 5's adversarial verification only -- revert after this step *)
        /\ Cardinality(rep_recv_dvc[r]) >= f + 1    \* was: Cardinality({ m \in rep_recv_dvc[r] : ValidDvc(r, m) })
```

Leave `WinningDVC`/`HighestCommitNumber` as they are for this step (both still internally filter by
`ValidDvc` when choosing among the now-larger candidate set) — this isolates the test to exactly the
quorum-counting site, the specific one research §5.7's counterexample hinges on.

- [ ] **Step 3: Write `spec/tla/VSR-broken-dvc-filter.cfg`**

Use a bound with enough view churn to give TLC room to find the violation — per research §6.2's
documented "3 replicas, 3 view changes" as the minimum that exposed a related class of defect. Keep
`Values` at a single element (this bug is about which *view* a DVC came from, not about value
content, so this dimension doesn't need to be wide) and include `SYMMETRY`/`ValuesSymmetry` (defined
in Task 3 Step 2) for consistency, even though its effect is minimal with only one value:

```
SPECIFICATION Spec
CONSTANTS
    ReplicaCount = 3
    Values = {v1}
    StartViewOnTimerLimit = 3
INVARIANT TypeOK
INVARIANT CommitNumberNeverHigherThanOpNumber
INVARIANT NoLogDivergence
INVARIANT AcknowledgedWritesExistOnMajority
CHECK_DEADLOCK FALSE
SYMMETRY ValuesSymmetry
```

- [ ] **Step 4: Run TLC against the weakened spec**

Run: `java -jar /work/toolchain/tla/tla2tools.jar -config VSR-broken-dvc-filter.cfg VSR.tla` (from
`spec/tla/`), foreground, with a generous timeout (10+ minutes) — same reasoning as Task 3 Step 7
and Task 4 Step 5: you're one continuous execution, waiting in the foreground is correct.

Expected: TLC finds a real invariant violation with a full counterexample trace.
**`NoLogDivergence` cannot be the one that fires — this is now confirmed, not just unlikely.**
Task 4's own reviewer proved that at this plan's bound (`Values = {v1}`), `NoLogDivergence` is
structurally vacuous: with only one possible value in the whole system, two committed log entries
can never actually disagree with each other, so the invariant is permanently true regardless of
whether the protocol logic is correct. **Watch `AcknowledgedWritesExistOnMajority` instead** — that
one doesn't depend on log *content* being distinguishable, only on which *replicas* hold an entry,
so it remains a genuine discriminator even with one value. Task 4's reviewer independently
pre-tested this exact mutation at `StartViewOnTimerLimit = 1` (not caught within 240 seconds) and
confirmed this task's own bound of `3` is well-chosen for actually catching it. `StartViewOnTimerLimit
= 3` means more view churn than Tasks 3-4's own default bound, so per the same real-precedent timing
note from Task 3 Step 1, this may well still be running with no result at 10 minutes even though
the bug is genuinely present in the weakened spec; that's expected, not a sign the attempt failed.

- **If TLC finds a violation within the timeout**: that's the expected, positive result — capture
  the trace for your report.
- **If it's still running with no error at 10 minutes**: stop it, and before concluding anything,
  try `StartViewOnTimerLimit = 2` once (smaller bound, still has real view churn, sometimes finds
  the same class of bug faster with less state to explore) — same 10-minute foreground budget.
- **If TLC does NOT find a violation at either bound, or neither terminates in time**, do not treat
  that as success — it means one of: this spec's structure differs from Vanlightly's in some way
  that happens to avoid the bug (report this honestly, with your reasoning about why), the bound is
  too small to expose it, or the bound is large enough to expose it but too large to *finish*
  exploring in the time available (a real, reportable "inconclusive," not a silent pass). This task's
  job is to honestly probe
for the failure, not to manufacture a clean report either way.

- [ ] **Step 5: Revert the temporary change and the throwaway config**

```bash
git checkout -- spec/tla/VSR.tla
rm spec/tla/VSR-broken-dvc-filter.cfg
```

- [ ] **Step 6: Re-run the real spec to confirm it's back to clean**

Run: `scripts/tlc VSR`
Expected: clean, matching Task 4 Step 5 again — confirms the revert was complete and nothing else
changed.

- [ ] **Step 7: Nothing to commit for the reverted file — confirm the tree is clean**

```bash
git status --short
```

Expected: empty (the `.cfg` was deleted and never committed; `VSR.tla` is back to its Task 4 state).

---

### Task 6: Documentation

**Files:**
- Modify: `spec/tla/README.md`

**Interfaces:**
- Consumes: nothing (documentation only)
- Produces: nothing new; describes what Tasks 1-5 built and what a follow-up plan must still do

- [ ] **Step 1: Extend `spec/tla/README.md`'s "Scope" section**

Replace the placeholder "(added in later tasks of this plan)" parenthetical from Task 1 Step 8 with
the real, final scope description:

```markdown
## Scope

`VSR.tla` specifies VSR's **core safety protocol**: normal-case replication and view change,
model-checked at `ReplicaCount=3, Values={v1}, StartViewOnTimerLimit=1` (`spec/tla/VSR.cfg`) — zero
counterexamples in whatever portion of the state space Task 3/4's own runs actually completed
exploring (see their task reports for the exact outcome: a full clean exhaustive run, or a
bounded-time partial exploration with no violations found so far; both are legitimate per this
plan's own Task 3 Step 1 note on real precedent for this spec class's state-space size). Every
documented defect in the original VSR paper (Liskov & Cowling, 2012) that this scope touches is
pre-fixed, not left for TLC to (re)discover: the `ValidDvc` view-filtered DVC quorum counting (fixes
a real, published 114-step safety counterexample), and commit-number monotonicity on `STARTVIEW`
(fixes a real, published double-application defect). Task 5's adversarial verification (`git log`
for its commit) proves the `ValidDvc` fix is load-bearing against this exact spec, not just against
the original research.

**Known simplification, not an omission:** `ReceiveSV` does not re-send `PREPAREOK` for uncommitted
entries carried into the new view (the paper's own §4.2 step 5 final clause). A replica that starts
a new view with an uncommitted log tail relies on that tail's entries eventually being
re-replicated by ordinary `PREPARE` traffic once the new primary resumes accepting client requests,
rather than on an explicit re-ack step. This is safe for this scope (no entry is ever lost by it —
`NoLogDivergence`/`AcknowledgedWritesExistOnMajority` do not depend on it) but may cost extra
round-trips in practice; revisit if a later plan needs tighter liveness bounds.

**Known limitation of the shipped bound, disclosed rather than silently accepted:**
`NoLogDivergence` is one of this scope's two headline safety invariants, but at
`Values = {v1}` (chosen for tractability — see Task 3 Step 1's own note on this spec class's
state-space size) it is structurally unfalsifiable: with only one possible value anywhere in the
system, two committed log entries can never actually disagree with each other, so the invariant is
permanently true regardless of whether the underlying protocol logic is correct. Task 4's reviewer
found and proved this precisely (confirmed by mutation-testing: inverting the safety-critical
`WinningDVC` comparison is still caught in seconds — but by `CommitNumberNeverHigherThanOpNumber`,
not by `NoLogDivergence`). **The real evidence this scope's model-checking provides comes from the
other three invariants** (`TypeOK`, `CommitNumberNeverHigherThanOpNumber`,
`AcknowledgedWritesExistOnMajority` — the last of these does remain a genuine discriminator, since
it depends on which replicas hold an entry, not on distinguishing entry content). A follow-up plan
that wants `NoLogDivergence` to mean something should widen `Values` to at least 2 elements for
that specific check — expect the state-space cost documented throughout this plan when doing so.

**Explicitly out of scope, for a follow-up plan (not this one):**
- **State-transfer** (`GETSTATE`/`NEWSTATE`) — the paper's own version has a documented, real
  data-loss defect (research §5.7 Part 3), and TigerBeetle's fix replaces the mechanism entirely
  with `get_view`/`view` (research §4.11) — building the textbook version now would be discarded.
- **Storage-fault-aware recovery** — nacks, nack quorums, the `nack_bitset`/`present_bitset` on
  `join_view`, the "never nack a corrupt entry" rule (research §4.2, §4.8-§4.10). This is the part
  of Task 3 (per `docs/superpowers/specs/2026-09-16-distributed-consensus-design.md`'s Decision 1)
  that most directly delivers on "storage-fault-aware" — it is real, substantial, separate work,
  not owed by this plan.
- **Crash/restart modeling and reconfiguration** — research §5's own finding: reconfiguration has
  zero public formal treatment anywhere (Vanlightly's own Part 7 was announced and never published;
  TigerBeetle's own docs mark it "TODO (Unimplemented)"). Anything Riptide does here is original
  work, not transcription from prior art.

**Four decisions a follow-up storage-fault-aware plan must make explicitly** (research §7.3 — none
of these are settled by prior art, and none are needed by this plan's own scope):
1. Storage-fault abstraction level — a per-op tri-state `{present, absent, corrupt}` (recommended
   starting point: simpler, still expresses the core "don't nack corrupt" rule) vs. a faithful
   two-ring WAL model (research §4.13; much more faithful, probably not exhaustively checkable).
2. Keep VSR's textbook Recovery sub-protocol, or follow TigerBeetle and persist `view`/`log_view`
   to a durable, checksummed state (recommended: persist — Riptide's Layer 0 log is already
   durable and checksummed, so this costs little and removes an entire class of liveness hazard
   Vanlightly documented in his own Parts 5-6).
3. Atomic vs. multi-step view-change completion — storage-fault-awareness forces multi-step
   (research §4.12's seven-step sequence with a "forfeit" escape); this is the single biggest
   state-space cost of the follow-up plan and the most expensive to retrofit if decided late.
4. Flexible quorums (three distinct quorum sizes, research §4.7) vs. uniform `f+1` everywhere
   (recommended starting point: uniform — flexible quorums are a real latency win but triple the
   number of quorum constants and every intersection argument; this spec's `f`-based thresholds
   already assume uniform quorums throughout and would need generalizing).

**A concrete, empirically-confirmed constraint for whoever plans the follow-up:** this plan's own
Tasks 3-5 needed to shrink their bounds all the way to `Values = {v1}, StartViewOnTimerLimit = 1`
(down from the research's own cited "3 replicas, 2 values, 2 view changes, known to terminate") and
even that bound did not reliably finish exhaustively within a 10-minute budget on this box. Adding
storage-fault recovery — nack bitsets, present bitsets, the multi-step interruptible view-change
completion (open decision 3 above) — will only grow the state space further. Budget the follow-up
plan's own model-checking tasks for simulation-mode-only verification (research §6.3 point 3) as the
realistic default, not exhaustive brute-force checking, and set the same "bounded-time,
inconclusive-is-a-legitimate-outcome" expectation in that plan's own task text from the start,
rather than rediscovering this the way this plan's own author did mid-authoring.
```

- [ ] **Step 2: Commit**

```bash
git add spec/tla/README.md
git commit -m "TLA+ Task 6: document scope, simplifications, and follow-up-plan decisions"
```

## Self-Review Notes

- **Spec coverage:** Decision 1's protocol-family choice (VSR-derived, storage-fault-aware, CFT) is
  served by this plan's core-safety scope plus its explicit deferral of the storage-fault-aware parts
  to a follow-up plan, documented in Task 6 — matching this project's own established pattern (the
  DST PoC plan similarly scoped to Decision 2's *required first deliverable*, not all of Decision 2).
- **Placeholder scan:** clean. Task 5's adversarial-verification step explicitly instructs honest
  reporting if the deliberately-broken spec does NOT reproduce a violation, rather than silently
  declaring success either way — this is deliberate, not a gap.
- **Type consistency:** `rep_*` variable names, `View(r)`, `Primary(v)`, and the message-bag
  combinators are introduced once (Task 2) and used identically in Tasks 3-5. `ValidDvc`,
  `WinningDVC`, `HighestCommitNumber` are introduced in Tasks 3-4 exactly where first used and not
  redefined elsewhere.
- **Toolchain grounding:** the entire Task 2 `VSR.tla` normal-case fragment, the message-bag
  technique, the `EXTENDS TLC` requirement, and the `CHECK_DEADLOCK FALSE` requirement were written
  and independently model-checked (TLC 2.19, this exact box, `tla2tools.jar` durably installed at
  `/work/toolchain/tla/tla2tools.jar`) before this plan was finalized — not assumed from the research
  document alone. Tasks 3-5's view-change logic is adapted directly from Jack Vanlightly's own
  published, already-TLC-verified `vsr-tlaplus` repository (cited exhaustively in the research file)
  rather than independently re-derived — re-deriving and re-verifying an entire multi-week formal
  methods research effort from scratch was judged out of scope for grounding one implementation
  plan; Task 4 Step 5 and Task 5 both require the implementer to independently re-verify the
  transcription against this exact box's TLC, which is the right level of verification for adapted
  (not self-authored) protocol logic.
- **State-space reality check, found and fixed during self-review, not left for an implementer to
  discover mid-task:** the first draft of this plan set Tasks 3-5's bound to "3 replicas, 2 values, 2
  view changes" on the strength of research §6.3 calling that bound "known to terminate" — but that
  characterization was of Vanlightly's own (differently structured) specs, not this one. Before
  finalizing, the controller actually ran the combined Tasks 2-4 spec at that bound and at
  successively smaller ones (down to a single value, a single view-change limit, with `SYMMETRY`
  added) against this box's real TLC, and none terminated within a short window — consistent with,
  not contradicting, the research's own repeated real-world data (Vanlightly's own most complete spec
  aborted after 41 hours and 3.6 trillion states at a comparably small bound). Fixed by: lowering the
  plan's own default bound to `Values={v1}, StartViewOnTimerLimit=1`, adding `SYMMETRY` (real if
  modest benefit), and rewriting every task step that runs TLC (Task 3 Step 7, Task 4 Step 5, Task 5
  Steps 3-4) to set honest timing expectations and give concrete, actionable guidance for a
  bounded-time run that's still running with no error rather than implying a fast, complete,
  clean-or-broken result is the only legitimate outcome.
