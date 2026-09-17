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

`VSR.tla` specifies VSR's **core safety protocol**: normal-case replication and view change,
model-checked at `ReplicaCount=3, Values={v1}, StartViewOnTimerLimit=1` (`spec/tla/VSR.cfg`).

**The run is exhaustive and clean.** Reproduce it with `scripts/tlc VSR`; the result, quoted
verbatim from TLC 2.19 so a reader of this branch can check the claim without access to any
out-of-tree scratch directory:

```
Model checking completed. No error has been found.
553084 states generated, 264376 distinct states found, 0 states left on queue.
The depth of the complete state graph search is 40.
Finished in 23s
```

`0 states left on queue` is the part that matters: the entire reachable state space at this bound
was explored, and all five invariants (`TypeOK`, `CommitNumberNeverHigherThanOpNumber`,
`LogLengthMatchesOpNumber`, `NoLogDivergence`, `AcknowledgedWritesExistOnMajority`) hold on every
reachable state. See the caveat below on how much two of those five actually discriminate at
`Values = {v1}`.

Every documented defect in the original VSR paper (Liskov & Cowling, 2012) that this scope touches
is pre-fixed, not left for TLC to (re)discover: the `ValidDvc` view-filtered DVC quorum counting
(fixes a real, published 114-step safety counterexample), and commit-number monotonicity on
`STARTVIEW` (fixes a real, published double-application defect). See "What the `ValidDvc` filter
is actually doing here" below for exactly how much verification evidence backs the first of those
against *this* spec, as opposed to against the original research.

**Known simplifications, not omissions.** Both are liveness-only: neither can lose a committed
entry, and neither of this scope's two headline safety invariants depends on either.

1. **No `PREPAREOK` re-send on `STARTVIEW`.** `ReceiveSV` does not re-send `PREPAREOK` for
   uncommitted entries carried into the new view (the paper's own §4.2 step 5 final clause). A
   replica that starts a new view with an uncommitted log tail relies on that tail's entries
   eventually being re-replicated by ordinary `PREPARE` traffic once the new primary resumes
   accepting client requests, rather than on an explicit re-ack step. This may cost extra
   round-trips in practice; revisit if a later plan needs tighter liveness bounds.

2. **Only a higher-view `STARTVIEWCHANGE` makes a replica adopt a higher view — a higher-view
   `DOVIEWCHANGE` does not.** The paper's §4.2 step 1 has a replica start a view change on any
   message carrying a view above its own. Here, `ReceiveHigherSVC` implements that for
   `STARTVIEWCHANGE` only; `ReceiveDVC` is gated on `ValidDvc` (`m.v = View(r)`), so a
   `DOVIEWCHANGE` carrying a *higher* view than the recipient's is matched by no action at all and
   simply sits in the message bag. A replica that observes only such a message — and never a
   `STARTVIEWCHANGE` at that view — will not adopt the higher view from it.

   Why this is believed safe at this scope: a `DOVIEWCHANGE` is *unicast*, not broadcast.
   `SendDVC` uses `Send(...)` with `dest |-> Primary(View(r))` — a single message to the intended
   primary of the new view — whereas `TimerSendSVC` uses `Broadcast(...)` to send its
   `STARTVIEWCHANGE` to every other replica. So any view change that a `DOVIEWCHANGE` could
   announce was necessarily announced first, to *every* replica including this one, by the
   `STARTVIEWCHANGE` broadcast that caused the `DOVIEWCHANGE` to be sent in the first place
   (`SendDVC` is guarded on having already collected `f` `STARTVIEWCHANGE`s for that view). The
   omitted path is therefore strictly narrower than the one that is modeled, and it costs only the
   chance to *learn about* a view change sooner — never the ability to complete one. It is a
   liveness simplification: the missing transition cannot make a replica accept state it should
   have rejected, only make it slower to join a view it would have joined anyway. Nothing here is
   a proof, and TLC checks no liveness properties at this scope; a follow-up plan that adds
   liveness checking should model this path properly rather than inherit the simplification.

**Known limitation of the shipped bound, disclosed rather than silently accepted:**
`NoLogDivergence` is one of this scope's two headline safety invariants, but at
`Values = {v1}` — a bound originally chosen for tractability, for reasons the last section of this
file shows were a misdiagnosis — it is structurally unfalsifiable: with only one possible value
anywhere in the system, two committed log entries can never actually disagree with each other, so
the invariant is permanently true regardless of whether the underlying protocol logic is correct.
This was found and proved precisely during review (confirmed by mutation-testing: inverting the
safety-critical
`WinningDVC` comparison is still caught in seconds — but by `CommitNumberNeverHigherThanOpNumber`,
not by `NoLogDivergence`).

**The real evidence this scope's model-checking provides therefore comes from exactly two of the
five invariants**: `CommitNumberNeverHigherThanOpNumber` (the one that actually catches the
`WinningDVC` mutation, in 9s) and `AcknowledgedWritesExistOnMajority` (a genuine discriminator even
at `Values = {v1}`, since it depends on *which replicas* hold an entry, not on distinguishing entry
content). The other three are weaker than they look and should not be counted as safety evidence:

- `NoLogDivergence` — structurally unfalsifiable at `Values = {v1}`, as described above.
- `TypeOK` — a type-shape check, not a safety discriminator. It covers 5 of the module's 13
  variables and asserts only `\in Nat` for three numeric ones, a two-element domain for
  `rep_status`, and `\in BOOLEAN` for `rep_sent_dvc`. No action in the module can assign anything
  outside those domains (there is no subtraction anywhere except inside `DiscardFunc`, which
  touches none of them), so it cannot fail on a reachable state. It is worth keeping as a
  cheap regression guard against future edits, not as evidence about the protocol.
- `LogLengthMatchesOpNumber` — a structural well-formedness check (`Len(rep_log[r]) =
  rep_op_number[r]`), added because `NoLogDivergence` indexes `rep_log[r][op_number]` and its
  freedom from out-of-domain application rests on this relationship holding. It is genuinely
  falsifiable by a bad edit — unlike `TypeOK` — but it constrains bookkeeping, not agreement.

A follow-up plan that wants `NoLogDivergence` to mean something should widen `Values` to at least
2 elements for that specific check — expect a state-space cost when doing so, though see the note
at the end of this file: with the `SendDVC` self-loop fixed, that cost is now far lower than this
plan's own earlier runs suggested, and re-testing a wider `Values` is a cheap first experiment
rather than the expensive one it was assumed to be.

## What the `ValidDvc` filter is actually doing here

`SendSV` counts its `DOVIEWCHANGE` quorum as
`Cardinality({ m \in rep_recv_dvc[r] : ValidDvc(r, m) }) >= f + 1` rather than over the raw set.
Counting DVCs from a view other than the primary's own is the exact bug class behind a real,
published 114-step safety counterexample in the original formalization effort, so the filter is
pre-applied here rather than left for TLC to rediscover. An honest account of how much this
branch's own model-checking actually says about that filter, since an earlier draft of this file
overstated it:

**What was tried, and what it showed.** An adversarial run removed the filter — counting all
received DVCs regardless of view, the exact historical bug — and model-checked the weakened spec.
At the larger bounds tried while the `SendDVC` self-loop described below was still present, that
run was **inconclusive**: no violation was found, but no run terminated either, so nothing was
proven in either direction. No commit was made for that experiment; it was a pure verification
exercise, reverted afterwards. With the self-loop fixed, the same weakened spec now runs to
completion at the shipped bound, and the result is not "inconclusive" but a precise negative:

```
Model checking completed. No error has been found.
553084 states generated, 264376 distinct states found, 0 states left on queue.
```

Those are the *same* counts, state for state, as the unmodified spec quoted at the top of this
file. At this bound the weakened spec and the correct spec have the same reachable state graph:
removing the filter changes nothing, exhaustively.

**Why — and the reason is more interesting than "stale DVCs can never accumulate".** That simpler
explanation is false, and TLC says so. A temporary invariant asserting that `rep_recv_dvc[r]` only
ever contains valid DVCs —

```tla
RecvDvcAlwaysValid == \A r \in replicas : \A m \in rep_recv_dvc[r] : ValidDvc(r, m)
```

— is **violated**, at depth 21, in 9 seconds. `ReceiveSV` advances `rep_view_number[r]` without
clearing `rep_recv_dvc[r]`, so a replica really does carry DVCs from its previous view forward into
the new one. Stale entries genuinely accumulate.

They just can never be *read*. The narrower invariant that matches `SendSV`'s actual guard —

```tla
RecvDvcValidWhenViewChange ==
    \A r \in replicas :
        rep_status[r] = "ViewChange" => \A m \in rep_recv_dvc[r] : ValidDvc(r, m)
```

— **holds on all 264,376 reachable states, exhaustively, 0 left on queue.** The contamination
`ReceiveSV` creates exists only while `rep_status[r] = "Normal"` (`ReceiveSV` always sets exactly
that), and the only two actions that can put a replica back into `"ViewChange"` — `TimerSendSVC`
and `ReceiveHigherSVC` — both unconditionally reset `rep_recv_dvc[r]` to `{}` in the same step.
`SendSV` is guarded on `rep_status[r] = "ViewChange"`, and it is the only reader of
`rep_recv_dvc[r]` (`WinningDVC` and `HighestCommitNumber` are evaluated only inside it). So every
element `SendSV` ever sees is already valid, and the filter has nothing left to remove.

**What this does and does not mean.** It does **not** mean the historical bug is fake — it is real,
published, and the filter is the correct fix for it. It means that *in this model*, the
reset-on-every-new-view-change-episode discipline already prevents the accumulation pattern that
bug needs, by a different mechanism than the filter. This scope's model-checking therefore provides
no independent evidence that the filter is load-bearing, because at this bound it provably is not.

**The filter stays in the spec anyway**, deliberately. Its redundancy is a property of the current
reset discipline, not of the protocol: `ReceiveSV` already fails to reset `rep_recv_dvc`, and a
follow-up plan that adds state transfer, recovery, or multi-step view-change completion (all of
which add new ways to change a replica's view or status) could easily open a path where a stale DVC
does reach `SendSV`. Removing a correct, defensive, currently-inert filter to save an intersection
would be trading a real safety property for nothing. Whoever touches the view-transition actions
next should re-run `RecvDvcValidWhenViewChange` as a regression check before assuming the filter is
still inert.

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

## A lesson for whoever plans the follow-up: check that the model is finite before blaming the bound

This is worth recording because this spec got it wrong for most of its construction, and the
mistaken conclusion nearly shipped as planning advice.

Throughout development, TLC runs against this module never terminated. Successive rounds of work
responded by shrinking the bound — all the way down from the research's own cited "3 replicas, 2
values, 2 view changes, known to terminate" to `Values = {v1}, StartViewOnTimerLimit = 1` — and
still saw no convergence. The natural inference was that this spec class simply has an intractable
state space on this hardware, and an earlier draft of this file said exactly that, recommending the
follow-up plan budget for simulation-mode-only verification rather than exhaustive checking.

That inference was wrong. The state space was not large; it was **infinite**, because of a
one-action defect. `SendDVC` was an unguarded self-loop: every condition it tested stayed true after
it fired, and its only effect was to increment a message-bag counter, so it re-enabled itself
forever, each firing producing a distinct state. No bound, on any hardware, could ever have
terminated. The fix is the `rep_sent_dvc` one-shot flag now in the module — a modeling device, not
protocol logic, mirroring how `aux_svc_count` already bounds `TimerSendSVC`. With it, the *original
shipped bound* exhausts in 23 seconds over 264,376 distinct states.

Two things follow:

- **The simulation-mode-only recommendation is withdrawn.** It was inferred from a defect in one
  action, not from the protocol's combinatorics. Exhaustive checking is entirely realistic for this
  spec class at these bounds; the follow-up plan should default to it and fall back to simulation
  only when a *measured* run says otherwise. Widening `Values` to 2 — which is what
  `NoLogDivergence` needs to stop being vacuous — is now a cheap experiment worth trying first.
- **Add a finiteness check to the follow-up plan's first task.** An unbounded-state-space defect is
  cheap to detect and expensive to misdiagnose: add a throwaway invariant like
  `\A m \in DOMAIN messages : messages[m] < 3` and run it. Against the broken spec here, that probe
  finds the self-loop at depth 6 in under a second. Any action whose effect leaves all of its own
  guards true, and whose only state change is monotonic (a counter, a growing bag), deserves that
  check before any conclusion is drawn from a non-terminating run. Storage-fault recovery will add
  several such actions (nack accumulation, retransmission), so this is not a hypothetical risk.

Storage-fault recovery — nack bitsets, present bitsets, the multi-step interruptible view-change
completion (open decision 3 above) — will still grow the state space, possibly a lot. The point is
that this branch has no evidence about how much, and neither does anything written here before the
`SendDVC` fix. Measure it; do not inherit this plan's earlier guess.
