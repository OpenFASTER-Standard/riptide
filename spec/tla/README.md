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
