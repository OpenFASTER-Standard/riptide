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

`VSR.tla` specifies VSR's **core safety protocol** — normal-case replication and view change —
**plus storage-fault-aware recovery**: a per-op tri-state `{present, absent, corrupt}` storage
abstraction, nack evidence piggybacked on `DOVIEWCHANGE`, nack-quorum-driven log truncation, a
multi-step and interruptible view-change completion with a forfeit escape, and durable
`view`/`log_view` across a simulated crash/restart. Model-checked at `ReplicaCount=3,
Values={v1}, StartViewOnTimerLimit=1, MaxOp=1, CorruptLimit=1, RestartLimit=1, ForfeitLimit=1`
(`spec/tla/VSR.cfg`).

Storage-fault-aware recovery was "explicitly out of scope, for a follow-up plan" in the version of
this file that shipped with the core spec. That follow-up plan is
`docs/superpowers/plans/2026-09-23-storage-fault-tolerant-recovery.md`, and this is it — see
"Storage-fault-aware recovery: what is modeled, and the evidence for it" below for the mechanism
and its disclosed gaps.

**The run is exhaustive and clean.** Reproduce it with `scripts/tlc VSR`; the result, quoted
verbatim from TLC 2.19 so a reader of this branch can check the claim without access to any
out-of-tree scratch directory:

```
Model checking completed. No error has been found.
9226786 states generated, 3678650 distinct states found, 0 states left on queue.
The depth of the complete state graph search is 45.
Finished in 02min 35s
```

`0 states left on queue` is the part that matters: the entire reachable state space at this bound
was explored, and all **fifteen** invariants listed in `VSR.cfg` hold on every reachable state. See
the caveat below on how much of that is real evidence — several of the fifteen discriminate less
than they look at `Values = {v1}`, and this file names which.

Two notes on reproducing this exact block, both of which are differences from the core spec's own
earlier numbers rather than anything about the protocol:

- **Wall-clock is not comparable across runs with different worker counts; state counts are.**
  `scripts/tlc` now passes `-workers auto` (TLC defaults to a single worker), so `02min 35s` is a
  16-core figure. The state counts — `9226786` / `3678650` / depth `45` — are properties of the
  state graph and are unaffected by worker count. Compare those, not the clock. (Re-run on the
  committed tree at 12:40 to confirm: same three numbers, `Finished in 02min 36s`.)
- **The fingerprint-collision estimate is `1.6E-6`**, three orders of magnitude larger than the
  core spec's `4.4E-9`, because the run is 14x bigger. This file's own earlier advice was to
  re-check with a second `fp` seed whenever that number is load-bearing for a real safety claim,
  which it now is, so that was done: `scripts/tlc VSR -fp 7` returns
  `9226786 states generated, 3678650 distinct states found, 0 states left on queue`, depth `45` —
  byte-identical counts under an independent fingerprint function, and no error.

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

**So the fifteen invariants are not fifteen independent pieces of evidence.** Sorted by how much
each actually discriminates at the shipped bound, so a reader can weight them rather than counting
them:

*Genuine discriminators (the evidence):*
- `AcknowledgedWritesExistOnMajority` — real even at `Values = {v1}`, since it depends on *which
  replicas* hold an entry, not on distinguishing entry content.
- `CommitNumberNeverHigherThanOpNumber` — the invariant that actually catches the `WinningDVC`
  mutation (in 9s), and the one that catches a `ReceiveSV` truncating below its own destination's
  commit point.
- `NoCommittedOpProvablyAbsent`, `AcknowledgedWritesReadableSomewhere`,
  `StartViewNeverDropsACommittedOp`, `StartViewCoversItsOwnCommitPoint` — the four new
  storage-fault-aware ones. All four are non-vacuous at this bound by *measurement*, not by
  argument; see the probe table in the storage-fault section below.
- `DvcEntriesAgreeWithinLogView` — the premise that licenses repairing a corrupt slot from a
  same-`log_view` peer. Falsifiable and load-bearing.

*Structural / regression guards (keep them, don't count them as safety evidence):*
- `NoLogDivergence` — still structurally unfalsifiable at `Values = {v1}`, as described above. The
  storage-fault extension makes this gap matter *more* than it did for the core spec, because
  nack-quorum-driven truncation is a brand-new way for two logs to end up disagreeing. This is
  measured rather than left as a worry — see "Widening `Values`" below.
- `TypeOK` — a type-shape check, not a safety discriminator, for the same reason as before. It now
  also asserts the tri-state domain for `rep_storage`, which is the one part of it a bad edit
  could plausibly break.
- `LogLengthMatchesOpNumber`, `OpNumberWithinMaxOp`, `StorageWellFormed` — well-formedness.
  `OpNumberWithinMaxOp` and `StorageWellFormed` are the runtime checks of the two domain-boundedness
  arguments `VSR.tla`'s `ASSUME`s state, added because `rep_storage` is indexed by `1..MaxOp` and an
  escaped op-number would be an out-of-domain index, not merely a large number.
- `NeverNackCorruptOrHeld` — structural at this scope (`CanNack` is *defined* as
  `rep_storage[r][o] = "absent"`), kept so that an edit widening `CanNack` has to confront
  research §4.2's rule explicitly rather than silently drop it.
- `RecvDvcValidWhenViewChange` — the reset-discipline regression check; see the `ValidDvc` section.
- `NoUnboundedGrowth` — a finiteness tripwire, not a safety property at all. See the last section.

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
exercise, reverted afterwards. With the self-loop fixed, the same weakened spec ran to completion
against the **pre-recovery core spec**, and the result was not "inconclusive" but a precise
negative:

```
Model checking completed. No error has been found.
553084 states generated, 264376 distinct states found, 0 states left on queue.
```

Those were the *same* counts, state for state, as the core spec's own run — at that bound the
weakened spec and the correct spec had the same reachable state graph, so removing the filter
changed nothing, exhaustively. (Those numbers are the core spec's, at commit `169a4d3`, before
storage-fault-aware recovery was added; they are no longer what `scripts/tlc VSR` prints. The
current numbers are at the top of this file.)

**That conclusion has now expired, exactly as the last paragraph of this section warned it might.**
It said a follow-up plan adding "state transfer, recovery, or multi-step view-change completion
(all of which add new ways to change a replica's view or status) could easily open a path where a
stale DVC does reach `SendSV`", and asked whoever touched the view-transition actions next to
re-run the check rather than assume. This plan touched them — it added `ForfeitViewChange` and
`CrashRestart`, two new ways to change a replica's view or status — so it was re-run, twice:

- `RecvDvcValidWhenViewChange` **still holds**, exhaustively, on all `3678650` reachable states of
  the current spec, `0 states left on queue`. It is in the shipped `VSR.cfg`. The reset discipline
  it checks now covers **four** actions, not two — `TimerSendSVC`, `ReceiveHigherSVC`,
  `ForfeitViewChange` and `CrashRestart` all reset `rep_recv_dvc[r]` to `{}` in the same step in
  which they put (or keep) a replica in `"ViewChange"`.
- **The filter is no longer inert, though.** Re-running the same adversarial weakening against the
  *current* spec — regenerate it with

  ```bash
  cd spec/tla
  sed -e 's/^---- MODULE VSR ----/---- MODULE VSR_NoFilter ----/' \
      -e 's/^ValidDvc(r, m) == m.v = View(r)$/ValidDvc(r, m) == TRUE/' VSR.tla > VSR_NoFilter.tla
  grep -v 'INVARIANT RecvDvcValidWhenViewChange' VSR.cfg > VSR_NoFilter.cfg   # trivially true once ValidDvc is TRUE
  cd ../.. && scripts/tlc VSR_NoFilter
  ```

  (not committed — it is a two-line derivation of the real module, and a committed copy would rot
  the moment `VSR.tla` changed, which is precisely the failure this experiment exists to detect) —
  gives
  `12153929 states generated, 4787391 distinct states found, 0 states left on queue` — **not** the
  same state graph as the unweakened `3678650`. Removing the filter now makes ~30% more states
  reachable, because `ValidDvcs` feeds five readers in this module (`HasDvcQuorum`, `NackCount`,
  `EntrySources`, `WinningDVC`, `HighestCommitNumber`) and unfiltered stale DVCs enable `SendSV`
  and `ForfeitViewChange` in states where they were not enabled.

  Stated precisely, because the honest version is weaker than "the filter is now proven necessary":
  no safety violation was found in those 4,787,391 states either. So the filter is demonstrably
  doing *work* on the state space now, where against the core spec it provably did none — but this
  bound still provides no evidence that the work it does is *safety*-relevant. It stays in the spec
  for the same reason as before, now with a better one: the margin it defends has visibly narrowed.

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

— **held on all 264,376 of the core spec's reachable states, and holds on all 3,678,650 of the
current spec's, exhaustively, 0 left on queue.** The contamination `ReceiveSV` creates exists only
while `rep_status[r] = "Normal"` (`ReceiveSV` always sets exactly that), and every action that can
put a replica into — or keep it in — `"ViewChange"` resets `rep_recv_dvc[r]` to `{}` in the same
step. That was two actions in the core spec (`TimerSendSVC`, `ReceiveHigherSVC`) and is **four**
now (`ForfeitViewChange` and `CrashRestart` added by this plan; `CrashRestart` is the interesting
one, since it *reconstructs* `"ViewChange"` status from durable `view > log_view` rather than being
told to enter it). Every reader of `rep_recv_dvc[r]` — `SendSV` and `ForfeitViewChange`, both via
`HasDvcQuorum` — is guarded on `rep_status[r] = "ViewChange"`.

**Why this matters more than it did, and why there is deliberately no separate nack accumulator.**
Task 4's draft extension kept nack evidence in its own `rep_recv_nacks` variable, which would have
reproduced exactly this stale-across-a-view-bump hazard for a *second* kind of evidence, needing a
second reset discipline and a second regression invariant to defend it. This spec folds nacks into
the `DOVIEWCHANGE` record instead (`SendDVC`'s `nacks` and `entries` fields), so every reader
reaches nack evidence through `ValidDvcs(r)` and therefore through the same filter and the same
reset discipline that already guard log selection. `RecvDvcValidWhenViewChange` covers nack
evidence for free as a result. That is a structural removal of the hazard, not a defence against
it, and it is the main reason the piggyback is preferred here over a separate accumulator.

**What this does and does not mean.** It does **not** mean the historical bug is fake — it is real,
published, and the filter is the correct fix for it. Against the core spec it meant that the
reset-on-every-new-view-change-episode discipline already prevented the accumulation pattern that
bug needs, by a different mechanism than the filter. Against the current spec, per the measurement
above, the filter has stopped being state-graph-inert but has still not been shown
safety-load-bearing at this bound.

**Explicitly out of scope, for a follow-up plan (not this one):**
- **State-transfer** (`GETSTATE`/`NEWSTATE`) — the paper's own version has a documented, real
  data-loss defect (research §5.7 Part 3), and TigerBeetle's fix replaces the mechanism entirely
  with `get_view`/`view` (research §4.11) — building the textbook version now would be discarded.
- **Reconfiguration** — research §5's own finding: it has zero public formal treatment anywhere
  (Vanlightly's own Part 7 was announced and never published; TigerBeetle's own docs mark it
  "TODO (Unimplemented)"). Anything Riptide does here is original work, not transcription from
  prior art.
- **General crash modeling beyond `CrashRestart`** — this spec models one crash/restart shape: a
  replica loses its volatile view-change bookkeeping, keeps its durable state, and may discover up
  to `CorruptLimit` slots corrupt. It does not model a replica being down for a stretch of the
  behaviour, partial writes in flight at the moment of the crash, or a corrupted *superblock* (only
  corrupted WAL slots). The superblock gap is the most consequential of the three and is called out
  again in the storage-fault section's own disclosed-gaps list below.

**The four decisions this file asked a follow-up storage-fault-aware plan to make have now been
made** (research §7.3), by
`docs/superpowers/specs/2026-09-23-storage-fault-tolerant-recovery-design.md`'s Decisions 4 and 5,
and are implemented in `VSR.tla` as described in the next section. For the record, each was decided
as this file recommended:
1. Storage-fault abstraction level — **per-op tri-state** `{present, absent, corrupt}`, not a
   faithful two-ring WAL model (research §4.13).
2. Keep VSR's textbook Recovery sub-protocol, or follow TigerBeetle and persist `view`/`log_view`
   to a durable, checksummed state — **persist** (`rep_view_number`/`rep_last_normal_view` survive
   `CrashRestart`; `rep_status` is reconstructed from them rather than stored).
3. Atomic vs. multi-step view-change completion — **multi-step**, with the forfeit escape.
4. Flexible vs. uniform quorums — **uniform `f+1`** everywhere (`Quorum == f + 1`, one definition,
   used by `HasDvcQuorum`, `ProvenAbsent` and both `AcknowledgedWrites*` invariants).

The original wording of those four, kept because the reasoning behind the recommendations is still
the reasoning behind the decisions:
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

## Storage-fault-aware recovery: what is modeled, and the evidence for it

This is the section that used to be a bullet under "explicitly out of scope". The mechanism, in the
order a reader of `VSR.tla` meets it:

1. **Per-op tri-state storage.** `rep_storage[r][o] \in {"present", "absent", "corrupt"}`.
   The load-bearing modelling decision, stated in the module and asserted as the invariant
   `StorageWellFormed`, is that a slot a replica has already durably written can fault only to
   `"corrupt"` — never to `"absent"`. `"absent"` means "I can prove I never wrote here", and holds
   precisely for `o > Len(rep_log[r])`. This is the spec-level statement of design Decision 6's
   redundant, physically-separate checksum header: a checksum mismatch means *corrupted*, never
   conflated with *legitimately absent*. A storage layer that could let a durably-acknowledged
   entry read back as a valid-but-empty slot would defeat **any** nack-based recovery protocol —
   two replicas could then jointly "prove" a committed op was never held.
2. **`CanNack(r, o) == rep_storage[r][o] = "absent"`** — research §4.2's "never nack a corrupt
   entry" rule. A corrupt slot is exactly the case where a replica *cannot* prove it never held the
   entry. `NeverNackCorruptOrHeld` is the regression guard.
3. **Evidence piggybacked on `DOVIEWCHANGE`, not a separate round trip.** `SendDVC` carries
   `entries` (a *partial* function, defined exactly on the ops the sender can actually read — a
   replica cannot send bytes it cannot read), `nacks`, and the op-number/`log_view` it still knows
   from durable superblock state even when entry bodies are unreadable. See the `ValidDvc` section
   above for why this placement is a safety property and not just an economy.
4. **Multi-step, interruptible completion.** `SendSV` is gated on `CanComplete(r)`: a completion at
   length `L` is admissible only if every op it keeps can be reconstructed from canonical evidence
   (`CanFill`), every op it drops was proven absent by an `f+1` nack quorum (`ProvenAbsent`), and
   `L` never falls below the highest commit-number any quorum member reported. An op in neither
   category is **contested** and blocks completion — the coordinator stays in `"ViewChange"`, keeps
   accepting DVCs, and can be interrupted at any point by a higher view. `CompletionPoint` takes
   the *longest* admissible log: truncation is a last resort taken only where a nack quorum forces
   it.
5. **The forfeit escape.** `ForfeitViewChange` is enabled precisely when a coordinator has
   everything the storage-fault-*unaware* protocol needed to complete — primary of its view, in
   `ViewChange`, holding a valid `f+1` DVC quorum — and still cannot, because an op is contested.
   It abandons the attempt at `view+1` so a replica with different storage gets to coordinate. It
   is deliberately **not** enabled short of a quorum: more DVCs can only add evidence, never remove
   it, so forfeiting early would abandon an attempt that was still making progress.
6. **Durable `view`/`log_view`.** `CrashRestart` keeps `rep_log`, `rep_op_number`,
   `rep_commit_number`, `rep_view_number` and `rep_last_normal_view`; it loses `rep_peer_op_number`,
   `rep_recv_svc`, `rep_recv_dvc` and `rep_sent_dvc`; and it *reconstructs* `rep_status` from
   `view > log_view`. That reconstruction is the whole point of persisting the pair: a replica that
   crashed mid-view-change resumes there instead of re-entering the old view as if nothing had
   happened.

### The defect this found, which is the main reason to trust the exercise at all

The nack-quorum truncation argument is: a committed op is durably held by `f+1` replicas, any two
`f+1` subsets of `2f+1` intersect, and a replica that durably held an entry can never nack it (a
lost write reads back corrupt, and a corrupt slot is never nacked) — so an `f+1` nack quorum
*proves* the op was never committed. Every word of that is about `f+1` **distinct replicas**.

`HasDvcQuorum` originally tested `Cardinality(ValidDvcs(r)) >= Quorum` — the number of DVC
*messages*. That is inherited, unremarkable-looking code, and against the core spec it was
harmless: a replica sent at most one `DOVIEWCHANGE` per view-change episode, so messages and
senders coincided. **This plan broke that coincidence**, and did so correctly: `CrashRestart` clears
`rep_sent_dvc`, because it is volatile in-memory state, so a replica that restarts mid-view-change
re-sends its `DOVIEWCHANGE` — and its second one differs from its first, because its `entries`
field shrank when a slot faulted to corrupt. Two distinct records, one replica, counted as a quorum
of two.

TLC found it at the widened bound (`scripts/tlc VSR_Wide`, below) as a violation of
`AcknowledgedWritesExistOnMajority` at depth 19: a coordinator formed a "quorum" out of two DVCs
from the same restarted replica, neither of which knew about op 2, and completed a view change that
truncated an op a third replica had already committed and acknowledged to a client.

**Why the shipped bound is blind to it, exactly.** At `MaxOp = 1` the defect is still *reachable*
(the fix removes real states: `3728294` distinct before, `3678650` after) but cannot produce a
violation. To lose data you need the fake quorum's own op-number to be *shorter* than a committed
op elsewhere. At `MaxOp = 1` the only way a duplicate-sending replica reports a short log is to
report an empty one — but a replica with an empty log has written nothing, so a restart has nothing
to corrupt, so its two `DOVIEWCHANGE`s are *identical records*, and `rep_recv_dvc` is a set, so they
collapse to one. The second value is what breaks the symmetry. This is the most concrete answer
this branch has to "how much does widening `Values` actually buy" — it bought a real safety defect
that 3.7 million exhaustively-checked states at the narrow bound did not.

### Non-vacuity: every part of the machinery is measured as reachable, not argued to be

A safety invariant that holds because the state which would test it is unreachable is worth
nothing, and this file already applies that scepticism to `NoLogDivergence`. `spec/tla/VSR_Probe.tla`
applies it to the recovery machinery: each probe is written to be **false** on some reachable
state, so an `Invariant ... is violated` result is the *success* case. Run them with
`scripts/probe-vacuity` (one at a time — TLC stops at the first violation). All seven are reachable
at the shipped bound:

| Probe | Asks | Result |
| --- | --- | --- |
| `NoCorruptionEver` | is a storage fault ever actually discovered? | reachable, depth 4 |
| `NoRestartEver` | does a crash/restart ever happen? | reachable, depth 3 |
| `NoContestedCompletion` | is a coordinator ever stuck holding a full `f+1` DVC quorum and still unable to complete? | reachable, depth 10 |
| `NoForfeitEver` | does the forfeit escape ever fire? | reachable, depth 11 |
| `NoNackQuorumInRange` | does an `f+1` nack quorum ever form for an op in the candidate range? | reachable, depth 13 |
| `NoNackOfACommittedOp` | is `NoCommittedOpProvablyAbsent`'s antecedent reachable at all? | reachable, depth 5 |
| `NoStartViewShortensALog` | does a completed view change ever actually *truncate*? | reachable, depth 10 |

`NoContestedCompletion` is the one that matters most: it is the direct test of whether
storage-fault-awareness genuinely forces a multi-step sequence at this bound, or whether completion
is still effectively atomic and the whole design is untested decoration. It is reachable, so the
multi-step shape is exercised for real. `NoNackOfACommittedOp` is the second most important: it
proves `NoCommittedOpProvablyAbsent` is guarding a situation that actually arises.

### Widening `Values`: what it cost and what it is worth

`spec/tla/VSR_Wide.tla`/`.cfg` is `VSR.tla` unmodified (by `EXTENDS`) at `Values = {v1, v2},
MaxOp = 2`, with the shipped invariant set verbatim. `Values` and `MaxOp` move in lockstep because
`VSR.tla`'s own `ASSUME MaxOp >= Cardinality(Values)` requires it: op-numbers are bounded by the
number of distinct values (`ReceiveClientRequest` refuses a value already in the primary's log) and
`rep_storage` is indexed by `1..MaxOp`, so widening `Values` alone would silently under-cover the
fault model and widening it past `MaxOp` would index out of domain. That `ASSUME` did not exist
before this plan; it was added because this exact coupling is easy to break with a one-line config
edit.

**It does not terminate, and that is the reportable result.** `scripts/tlc VSR_Wide` was run to a
34-minute budget decided before the run started, on 16 cores with a 20G heap. It was still
expanding, with a queue that grew monotonically for the entire run:

| elapsed | distinct states | states left on queue | depth |
| --- | --- | --- | --- |
| 1 min | 6,017,885 | 1,893,678 | 20 |
| 5 min | 9,948,909 | 2,846,367 | 21 |
| 12 min | 21,920,289 | 5,556,676 | 24 |
| 20 min | 36,584,832 | 7,947,110 | 26 |
| 34 min | 53,282,218 | 9,526,285 | 27 |

Depth 27 of a graph whose narrow-bound analogue completes at 45, with the frontier still widening
after 53 million distinct states — this is not a run that was nearly done. It was stopped
deliberately rather than left to run: at the measured ~115 MB of TLC scratch per million distinct
states, the disk headroom on this box runs out before the state space does, so waiting longer
changes the failure mode, not the answer. **Exhaustive checking at `Values = {v1, v2}, MaxOp = 2`
is not feasible on this hardware.**

**The fallback, run rather than recommended.** TLC's simulation mode at the same widened bound,
`scripts/tlc VSR_Wide -simulate -depth 60`, checks randomly-sampled behaviours instead of the whole
graph:

```
Progress: 61197752 states checked.
```

No invariant violation in ~61.2 million simulated states (14 minutes, then stopped). This is real evidence and it is weaker
evidence than exhaustion — simulation cannot prove absence, and a defect reachable only through a
narrow interleaving can be missed by any amount of sampling. It is reported as what it is.

**So the widened bound is kept in the tree as an experiment module, not as a second shipped bar.**
`scripts/tlc VSR` remains the claim this branch makes. Widening earned its place anyway: it is what
found the `HasDvcQuorum` defect, which 3.7 million exhaustively-checked states at the narrow bound
could not, and it is the obvious first thing to re-run on hardware with more memory and disk.

### Disclosed gaps in this scope, beyond the four liveness simplifications above

- **The superblock itself never faults.** `CrashRestart` corrupts WAL slots only. `rep_view_number`,
  `rep_last_normal_view`, `rep_op_number` and `rep_commit_number` always survive intact — which is
  exactly the assumption design Decision 6's 3-copy superblock with flexible read/write quorums
  exists to earn, but this spec assumes it rather than modelling it. A corrupted-superblock model is
  separate work.
- **Repair is wholesale, not incremental.** `SendSV`/`ReceiveSV` reset `rep_storage` to
  `FreshStorage(n)`: adopting the new view's canonical log means durably writing and verifying it,
  so corruption heals. `STARTVIEW` carries the complete log in this spec. A real implementation
  repairs incrementally and would need its own treatment.
- **`rep_peer_op_number` is not reset when a replica becomes primary.** A replica that was primary
  in an earlier view and becomes primary again can count `PREPAREOK`s from that earlier view toward
  `IsCommitted` in the new one. Textbook VSR starts a new primary's ack tracking fresh. This is
  pre-existing (it is not introduced by this plan) and no run has produced a violation from it, at
  either bound — but no run has *cleared* it either, and it was noticed rather than tested, so it
  is recorded here rather than left implicit.
- **`NoUnboundedGrowth` is a finiteness tripwire shipped in `VSR.cfg`, not a safety property.**
  Nothing in the protocol requires a message-bag count to stay below 4. A breach means "some action
  is growing the bag monotonically" — the `SendDVC`/`SendNack` self-loop defect class — not "the
  protocol is unsafe". It is kept in the shipped config because that defect class is the single
  most expensive mistake to misdiagnose in this spec; see the next two sections.

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
  (Follow-up, measured: it was tried, it is **not** cheap against the storage-fault-aware model,
  and it was worth doing anyway because it found a real safety defect. See "Widening `Values`"
  above. The `default to exhaustive, fall back only on a measured run` advice held up exactly as
  written: the shipped bound exhausts, and the widened one is reported with its real numbers rather
  than with a guess.)
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
the `264,376`-state result then quoted at the top of this file stays literally reproducible.

*(Written during Task 4, kept in the present tense it was written in. The file has since been
deleted and the top of this file now quotes the storage-fault-aware spec's own numbers instead —
see the subsection at the end of this section for both changes and why.)*

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

One honest caveat on the headline run: TLC's own fingerprint-collision estimate for it is `3.6E-5`
(based on actual fingerprints), versus `4.4E-9` for the core spec's much smaller run — still small,
but four orders of magnitude larger, and worth re-checking with a second `fp` seed if this number is
ever load-bearing for a real safety claim rather than, as here, a finiteness measurement.

### `VSR_RecoveryDraft.tla` has been deleted, and the budget above turned out to be pessimistic

The draft is gone from the tree. Its own module header and Task 4's report both said it should be
deleted rather than grown into the real extension once that existed, and it now does — the real
extension lives in `VSR.tla`, as described in the storage-fault section above. The numbers quoted in
this section remain reproducible at commit `169a4d3`, which is the last commit that contains the
file; nothing here is unverifiable, it is just historical. `scripts/tlc VSR_RecoveryDraft` no longer
works on `main`-line checkouts of this branch, by design.

The draft was written as a copy specifically to keep `VSR.tla`'s own quoted numbers reproducible
while the churn happened elsewhere. That was the right call for Task 4, and the reason it no longer
applies is that Task 5 changed `VSR.tla` itself, so the numbers at the top of this file moved
anyway — deliberately, and with the new run quoted in their place.

**The measured outcome, against the budget this section set.** The prediction was that the real
extension — nack quorums, truncation, forfeit, durable view state, new invariants — would cost
"substantially more" than the minimal draft's `8,670,448` distinct states. It cost **less than
half**:

| | distinct states | depth |
| --- | --- | --- |
| core spec (pre-recovery, commit `169a4d3`) | 264,376 | 40 |
| Task 4's minimal draft | 8,670,448 | 46 |
| the real extension (`VSR.tla` today) | 3,678,650 | 45 |

Compare the state counts, not the wall-clocks: `scripts/tlc` now defaults to `-workers auto`, and
the draft's `15min 48s` was a single-worker figure, so the clocks are not comparable while the
graphs are.

The reason is finding 2 of this section, applied harder than the draft applied it. The draft turned
its always-enabled `InjectStorageFault` action into **7 initial fault configurations** — which
removed the interleaving blowup but multiplied the entire base graph by 7 unconditionally, paying
for fault configurations on behaviours that never reach a view change at all. `VSR.tla` instead
folds fault discovery into `CrashRestart` (they are the same event in reality — a replica discovers
a slot no longer verifies when it re-reads its WAL after a restart) and then *narrows enablement to
restarts that can matter*: a restart that corrupts nothing **and** happens while the replica is not
mid-view-change is a pure volatile-state reset with no bearing on any property here, and is not
modelled. That guard is where the factor of two-and-a-bit comes from.

The generalisable form of finding 2 is therefore stronger than the draft's version of it. It is not
"model faults as configuration rather than as events" — configuration has its own multiplier. It is:
**a fault must be able to reach the states where it matters, and must not be paid for anywhere
else.** Ask which behaviours the fault can actually change the outcome of, and guard on that.
