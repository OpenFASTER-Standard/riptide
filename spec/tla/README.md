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
reachable state. See the caveat below on how much of that is real evidence — three of the five
discriminate less than they look at `Values = {v1}`.

Every documented defect in the original VSR paper (Liskov & Cowling, 2012) that this scope touches
is pre-fixed, not left for TLC to (re)discover: the `ValidDvc` view-filtered DVC quorum counting
(fixes a real, published 114-step safety counterexample), and commit-number monotonicity on
`STARTVIEW` (fixes a real, published double-application defect). See "What the `ValidDvc` filter
is actually doing here" below for exactly how much verification evidence backs the first of those
against *this* spec, as opposed to against the original research.

**Known simplifications, not omissions.** All four are liveness-only: none can lose a committed
entry, and neither `NoLogDivergence` nor `AcknowledgedWritesExistOnMajority` — this scope's two
headline safety invariants — depends on any of them. The third and fourth (below) were found later
than the first two — the third during Task 4's own adversarial cluster-level testing, the fourth
during this plan's final whole-branch review, neither during this spec's own design — and are
disclosed here for the same reason the first two are: an incomplete disclosed-gaps list would
undermine the credibility every other claim in this file depends on.

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

3. **A replica already in `View_change` has no mechanism to try a NEWER view on its own — so two
   consecutive dead `Primary`-designates can wedge the whole cluster permanently, even with a live
   quorum and a live, eligible next primary.** `TimerSendSVC` (`check_timeout` in the OCaml
   implementation) is gated on `rep_status[r] = "Normal"` (`VSR.tla:164`), faithfully transcribed —
   a replica that has already moved to `"ViewChange"` cannot re-fire it to escalate to `v+1` if the
   view it is currently trying to reach also turns out to have a dead primary. Concretely (found by
   adversarial cluster-level testing during Task 4's review, not by TLC — see
   `test/test_vsr_replica_view_change.ml`'s own regression test for the reproduction): in a
   5-replica cluster, kill a BACKUP first (this alone triggers nothing — a backup dying is
   invisible to the rest of the cluster), then kill the PRIMARY. The 3 survivors are exactly
   `f + 1`, a live quorum, and they correctly time out and complete a view change into the next
   view — but if `Primary` of THAT next view also happens to be the replica that was killed first
   (the backup), the cluster is now permanently stuck: all 3 survivors sit at
   `status = "ViewChange"` forever, `check_timeout`'s own guard blocks every further call as a
   no-op, and there is no other mechanism anywhere in this module's scope that re-arms the timer or
   escalates the view while already mid-view-change. Real VSR/Viewstamped Replication Revisited
   re-arms the view-change timer while already in `ViewChange` status specifically to handle this;
   neither the original paper's formalization here nor this implementation does.

   Safety is completely unaffected — nothing is lost, nothing is corrupted, no committed entry
   becomes uncommitted or divergent; every replica's own log and `commit_number` simply stop
   advancing. This is therefore a THIRD liveness-only simplification, more consequential than the
   two above (those cost extra round-trips; this one is an unrecoverable wedge with a live quorum
   and a live, legitimate next primary sitting right there, unreachable), and — unlike the two
   above — was not identified during this spec's own design or its TLC run; it surfaced only once
   real, running, multi-replica code was driven through an adversarial two-failure scenario Task 4
   itself did not originally construct. Not modeled or checked by `VSR.tla`/TLC at all (TLC checks
   no liveness properties at this scope, per point 2's own note); fixing it for real (e.g.
   re-triggering `TimerSendSVC` from within `View_change` status, or bounding how long a replica
   waits there before trying a newer view) is real, separate design work, out of scope for this
   plan.

4. **`ReceiveHigherSVC` adopts a higher view but never re-broadcasts its own `STARTVIEWCHANGE` —
   so a single primary failure can wedge the cluster permanently if survivors' timers don't fire
   near-simultaneously, which is the ordinary case for independent real timers, not an edge case.**
   The shared root cause with point 3 above is broader than either gap's own specific missing
   emission site (point 3's is `TimerSendSVC`'s own `rep_status[r] = "Normal"` gate blocking
   re-arming; this point's is `ReceiveHigherSVC` never emitting anything at all): no replica in
   this module EVER sends a `STARTVIEWCHANGE` once it has left `"Normal"` status, by any path. This
   gap is reachable with only ONE dead replica, not two, which makes it strictly more consequential
   on its own terms: `ReceiveHigherSVC`
   (`VSR.tla:183-194`) seeds `rep_recv_svc[r]` with a singleton (just the sender it heard from) and
   never sends a `STARTVIEWCHANGE` of its own — a real divergence from the original paper's own
   §4.2 step 1, where a replica that notices the need for a view change *because it heard a higher
   view* also sends `STARTVIEWCHANGE`. Consequence, composed with `SendDVC`'s own
   `Cardinality(rep_recv_svc[r]) >= f` threshold (`VSR.tla:221`): only a replica whose OWN
   `TimerSendSVC` fires ever produces a `STARTVIEWCHANGE` that anyone else can count; a replica
   that only ever adopts passively contributes nothing to any other replica's own threshold.

   Concretely, in a 3-replica cluster (`f = 1`) with the primary dead: if only ONE surviving
   backup's timer fires, that backup broadcasts `STARTVIEWCHANGE`, and the OTHER backup (which
   happens to be `Primary` of the new view) adopts it via `ReceiveHigherSVC` — its own singleton
   `rep_recv_svc` already meets `f = 1`, so it immediately sends its own, self-addressed
   `DOVIEWCHANGE`. But the FIRST backup (the one whose timer actually fired) never receives a
   matching `STARTVIEWCHANGE` back — the second backup never sent one — so its own
   `rep_recv_svc` stays empty and it never sends a `DOVIEWCHANGE` at all. The new primary ends up
   with exactly ONE valid `DOVIEWCHANGE` (its own), one short of `SendSV`'s own `>= f + 1 = 2`
   threshold (`VSR.tla:269`) — permanently, the same way point 3's own wedge is permanent, since
   `TimerSendSVC` is gated on `rep_status[r] = "Normal"` and both survivors are now
   `"ViewChange"`. Reproduced live in a throwaway clone (3 replicas, primary stopped, only one
   survivor's `check_timeout` called): both survivors stuck at `status = "ViewChange"` forever,
   including the one that IS `Primary` of the new view and IS alive.

   Safety is unaffected, for the same reason as point 3. Unlike point 3, this does not require an
   adversarial two-failure construction — an ordinary deployment where `check_timeout` is driven
   by independent real wall-clock timers per replica (this module's own intended driver shape, see
   `check_timeout`'s own doc comment in `replica.mli`) will routinely have survivors' timers fire
   at slightly different times, and whichever one fires first is, by this mechanism, not
   guaranteed to be enough on its own — a correct driver must expect that completing a view
   change can require as many as `f + 1` replicas' own timers to fire independently (worst case,
   the dead-primary scenario this point demonstrates; a fully-live cluster with no crash needs
   only `f`, since each of the `f + 1` non-firing replicas still independently accumulates enough
   adopted `STARTVIEWCHANGE`s to send its own `DOVIEWCHANGE`) — not just one replica noticing,
   with the rest merely overhearing — and design its timer policy accordingly. Not modeled or
   checked
   by `VSR.tla`/TLC at all, for the same reason as point 3; fixing it for real (adding the missing
   re-broadcast to `ReceiveHigherSVC`, matching the original paper) is real, separate protocol
   work, out of scope for this plan.

**Known limitation of the shipped bound, disclosed rather than silently accepted:**
`NoLogDivergence` is one of this scope's two headline safety invariants (the other is
`AcknowledgedWritesExistOnMajority`), but at
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
file — and, as the next paragraph shows, that is a proof rather than a coincidence: at this bound
the weakened spec and the correct spec have the same reachable state graph, so removing the filter
changes nothing, exhaustively.

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

## The finiteness check was run. Here is what it measured (`VSR_RecoveryDraft.tla`)

The section above asked the follow-up plan's first task to run a throwaway finiteness probe before
any real storage-fault design effort. That has now been done, and it earned its place twice — it
caught one genuine infinite-state-space defect and one severe (but finite) state-space blowup, both
in the first draft, both cheaply.

`spec/tla/VSR_RecoveryDraft.tla` is that draft: a **throwaway copy** of `VSR.tla` plus a minimal
sketch of the tri-state storage abstraction (decision 1 above) and nack accumulation piggybacked on
`DOVIEWCHANGE` (decision 3's multi-step shape). It is deliberately *not* the real extension — it
accumulates nacks and never uses them, has no new safety invariants, and should be deleted rather
than grown into the real thing. It is a **copy** specifically so `VSR.tla` stays byte-identical and
the `264,376`-state result quoted at the top of this file stays literally reproducible.

**Finding 1 — the predicted defect, confirmed.** `SendNack` was drafted the natural way: guarded on
`rep_status[r] = "ViewChange"` and "this op is provably absent," effect = send a NACK. Neither guard
is falsified by the action's own effect, and the only state change is a message-bag increment — the
`SendDVC` defect exactly, in exactly the action class this file predicted would reproduce it. The
probe caught it **at depth 6, in under a second**:

```
Error: Invariant NoUnboundedGrowth is violated.
...
3003 states generated, 1333 distinct states found, 879 states left on queue.
The depth of the complete state graph search is 6.
```

Fixed with a `rep_sent_nack` one-shot flag mirroring `rep_sent_dvc` verbatim. **This is a modeling
device, not protocol logic** — a real implementation retransmits, so the follow-up must bound
retransmission explicitly rather than inherit the flag as though it were a design.

**Finding 2 — not everything that fails to terminate is infinite.** With the self-loop fixed, the
draft modeled storage faults as an interleaved `InjectStorageFault` action. That never tripped the
finiteness tripwire, but it did not converge either: **still expanding at 8,016,933 distinct states
and 1,027,038 states queued after 12 minutes**, at depth 28 of a graph whose unfaulted baseline
completes at depth 40. The cause is structural and worth naming, because it is the *dual* of the
`SendDVC` lesson: an action enabled in **every** reachable state does not add states, it multiplies
the entire base state graph by every distinct point at which it could first fire. Nothing about the
safety question depends on a fault interleaving with consensus steps at a particular moment — only
on a replica *having* a faulted op while it participates in a view change — so the fault became a
one-time initial-state choice (`FaultConfigs`, 7 initial states at this bound) instead of an action.

**Result after both fixes — terminates, exhaustively.** `scripts/tlc VSR_RecoveryDraft` at
`ReplicaCount=3, Values={v1}, StartViewOnTimerLimit=1, MaxOp=1, FaultLimit=1`, quoted verbatim:

```
Model checking completed. No error has been found.
20404014 states generated, 8670448 distinct states found, 0 states left on queue.
The depth of the complete state graph search is 46.
Finished in 15min 48s
```

**What this means for the real extension, stated as a budget rather than a reassurance.** Exhaustive
checking of a storage-fault-aware model is realistic — `0 states left on queue` — but it costs
roughly **33x the distinct states and 41x the wall-clock** of the core spec (`8,670,448` vs
`264,376`; `15min 48s` vs `23s`) for the *most minimal possible* sketch: one op, one fault, no
nack-quorum logic, no truncation, no forfeit escape, no durable `view`/`log_view`, and no new safety
invariants. Every one of those additions is still to come. Three concrete consequences:

1. **Budget before widening anything.** The earlier suggestion in this file that widening `Values`
   to 2 is "a cheap experiment worth trying first" was measured against the *core* spec. Against a
   storage-fault-aware model it is not obviously cheap, and should be measured, not assumed.
2. **Model faults as configuration, not as events**, unless a specific property genuinely needs
   fault timing to interleave — and if one does, expect to pay for it and say so explicitly.
3. **Bound every new sending action at the moment it is written.** Two of this draft's three new
   actions needed an explicit bound; the one that did not (`ReceiveNack`) is a receive action that
   consumes from the bag. Treat "does this action's own effect falsify any of its own guards?" as a
   checklist item for each new action, not as something to discover from a non-terminating run.

Reproduce all of the above with `scripts/tlc VSR_RecoveryDraft`. One honest caveat on the headline
run: TLC's own fingerprint-collision estimate for it is `3.6E-5` (based on actual fingerprints),
versus `4.4E-9` for the core spec's much smaller run — still small, but four orders of magnitude
larger, and worth re-checking with a second `fp` seed if this number is ever load-bearing for a real
safety claim rather than, as here, a finiteness measurement.
