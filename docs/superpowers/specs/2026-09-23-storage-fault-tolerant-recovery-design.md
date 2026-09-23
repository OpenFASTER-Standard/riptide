# Storage-fault-tolerant recovery and the deterministic simulation harness

Design spec for task-master subtask 3.4 ("Build the deterministic simulation harness (VOPR-style)
as a first-class artifact") and everything it turned out to depend on. This document is the
argument; the implementation plan and running code that follow it are the authority, per this
project's own "no spec without running code" rule in `CLAUDE.md` — nothing here is binding until a
task ships working, tested code against it.

## Context

Subtask 3.4 asks for a real fault-injection DST harness in the TigerBeetle/VOPR tradition. Deep
research into what that actually requires (three parallel research passes, cross-checked against
the FAST'18 "Protocol-Aware Recovery" paper and TigerBeetle's own shipped source) found a blocking
gap: **Riptide has no persistence layer at all** — every VSR replica's state lives only in memory
— and storage-fault tolerance cannot be added as a layer underneath an unchanged consensus
protocol. Every local-reaction strategy to a corrupted or missing log entry (truncate it, rebuild
it, mark the replica non-voting) causes silent, undetectable global data loss in some real
scenario; the paper's central result is that this requires a genuine protocol extension, not a
storage-layer bolt-on. TigerBeetle's real, production implementation confirms this is buildable,
not just theoretically necessary — it ships an "abbreviated CTRL" mechanism doing exactly this.

Rather than treat this as four independent sub-projects, this spec covers the whole dependency
chain as one design, because the pieces are not independent: protocol-aware recovery (piece 2)
has nothing to recover *into* without durable storage (piece 1); fault injection (piece 3) has
nothing to attack without piece 2's recovery protocol; the DST harness (piece 4, subtask 3.4
itself) is meaningless without all three. One implementation plan sequences them as ordered tasks.

**Fidelity target: full CTRL-equivalent, not a reduced v1** — chosen explicitly, despite the
larger scope, over a deliberately simplified subset that would have traded away real crash-vs-
corruption disentanglement for a smaller diff.

**This spec inherits, rather than re-derives, real prior work already committed to this repo.**
`spec/tla/README.md`'s own "Explicitly out of scope, for a follow-up plan" section (written during
subtask 3.2, the VSR view-change work) already scoped much of piece 2 in detail: the recommended
storage-fault abstraction level, the recommendation to persist `view`/`log_view` durably, the
warning that storage-fault-awareness forces multi-step view-change completion, and a mandatory
finiteness check for the follow-up plan's first TLA+ task. An earlier draft of this spec's own
Decision 4 undersold that guidance (describing a single-message piggyback where the real shape is
a multi-step, interruptible sequence) before being corrected against the actual committed text —
recorded here so the correction is visible, not smoothed over.

## Decision 1: Persisted state — WAL and superblock, split from day one

A replica persists two distinct things, structurally separated the way TigerBeetle separates them,
even in this first piece before piece 2 adds fault-tolerance semantics on top: the **WAL** (the
replicated log entries, `rep_log[r]`, indexed by op-number) and the **superblock** (view state:
`view_number`, `status`, `commit_number`, `op_number`). The split matters this early because
piece 2's recovery protocol needs to reason about a corrupted WAL entry and a corrupted superblock
as different fault surfaces, and retrofitting the split later would touch both this piece's format
and piece 2's protocol simultaneously.

## Decision 2: Storage I/O — `eio_linux` low-level API, `O_DIRECT`/`O_DSYNC`, Linux-only

Per this session's own empirically-verified spike research (tested live against the actual
installed toolchain, not assumed): Eio 0.12, tied to this project's installed OCaml 5.0.0, has no
`fsync` in its portable API — that landed in Eio ≥0.13, needing OCaml ≥5.1, not available here.
`eio_linux`'s low-level API with `O_DIRECT`+`O_DSYNC` was verified working directly against this
toolchain, and is exactly what TigerBeetle itself uses in production. Riptide's storage layer uses
`eio_linux` directly, the same way — making it Linux-specific for now. Disclosed explicitly, not
hidden: TigerBeetle itself was Linux-only for the same reason during its own early development.

## Decision 3: `Storage.S`, mirroring `Transport_intf.S`

No `Eio_mock` filesystem exists in this Eio version, so — matching how `Transport_intf.S` already
gives this project two conforming implementations (`Tcp`/`Sim_transport`) behind one signature — a
new `Storage.S` signature gets two implementations: `File_storage` (this piece, real
`eio_linux`-backed) and `Fault_injecting_storage` (Decision 7, built once this piece's real format
exists to inject faults against). New library, `lib/storage/`, matching `lib/transport/`'s shape.
This piece does not touch `lib/vsr/replica.ml` — it proves the storage primitive (durable write,
correct read-back after a simulated restart) in isolation first, the same "prove the PoC before
wiring it into VSR" discipline `lib/sim/` and `lib/transport/` already used.

## Decision 4: Protocol-aware recovery is multi-step and interruptible, not a single-message add-on

Storage-fault-aware recovery forces **multi-step, interruptible view-change completion** — a
sequence (the seven-step shape `spec/tla/README.md` already identifies, with a "forfeit" escape
hatch) rather than one extra field on `DoViewChange`. This is structural: a replica may need to
pause mid-view-change to resolve nacks against cross-replica evidence — determining, for a
contested op, whether a quorum of replicas can jointly prove no correctly-functioning replica ever
held it (safe to discard) versus a quorum simply hasn't reported yet (must wait) — and that
resolution cannot happen atomically inside today's single (storage-fault-*unaware*) view-change
exchange. Every log entry gets a checksum in a redundant header, physically separate from the
entry's own data (Decision 6), so a checksum mismatch cleanly means "corrupted," never conflated
with "legitimately absent." `view`/`log_view` are persisted durably (Decision 1's superblock)
rather than relying on VSR's textbook in-memory-only Recovery sub-protocol, per the README's own
recommendation — Riptide's Layer 0 log is already durable and checksummed by this point in the
plan, so this costs little and removes a class of liveness hazard documented against the textbook
approach.

**Disclosed research risk, not hidden:** crash/restart modeling and its interaction with
reconfiguration has zero public formal treatment anywhere — not the original VSR paper, not
TigerBeetle's own docs, which mark reconfiguration "TODO (Unimplemented)." This piece is genuine
novel synthesis for parts of its design, unlike most of this project's other VSR work, which has
had a paper or a production system to check the result against.

## Decision 5: TLA+ extension — abstraction level, quorum model, mandatory finiteness check

Extends `spec/tla/VSR.tla`, following its own already-recorded recommendations rather than
re-deciding them:
- **Storage-fault abstraction**: a per-op tri-state `{present, absent, corrupt}`, not a faithful
  two-ring WAL model — deliberately less detailed than the real OCaml storage format (Decision 6),
  because the safety property being verified doesn't need byte-level fidelity, and the fuller model
  is flagged as probably not exhaustively checkable.
- **Quorums**: uniform `f+1` everywhere, not three separate flexible quorum sizes — keeps
  intersection arguments tractable; revisit only if real usage later shows the latency cost matters.
- **Mandatory first task, before any other TLA+ work on this piece**: a throwaway finiteness check
  (an invariant like `∀ message-bag entries: count < 3`) run against the first draft of the
  extended model. This project already paid the cost of misdiagnosing an unbounded-state-space
  defect as "this spec class is just intractable" once (`SendDVC`'s unguarded self-loop, found only
  after a mistaken conclusion nearly shipped as planning advice) — nack-accumulation and
  retransmission actions are exactly the shape `spec/tla/README.md` flags as likely to reproduce
  that defect class.
- Re-run TLC to the same exhaustive-model-checking bar the existing spec already holds
  (reproducible, quoted verbatim, `0 states left on queue`) once the finiteness check passes.

OCaml side: extends `lib/vsr/replica.ml`'s `handle_do_view_change`/`try_send_dvc` — the functions
this piece actually touches — to carry out the multi-step completion sequence, reading/writing
through `Storage.S` (Decision 3).

## Decision 6: On-disk format — fixed-size ring WAL, redundant headers, 3-copy superblock

Mirrors TigerBeetle's real layout, since Decision 4's recovery protocol depends on it structurally:
- **Fixed-size ring WAL** (pre-allocated, wraps around), not an unbounded append-only file — a
  fixed set of physically-separated header slots is what makes redundant-header recovery meaningful
  to reason about.
- **Redundant WAL headers**, stored separately from the log entries' own bodies, multiple copies.
- **3-copy superblock** with flexible read/write quorums (rather than TigerBeetle's 4) — the
  flexible-quorum recovery mechanism's soundness doesn't depend on the exact copy count; 3 is
  enough to demonstrate it working for real.
- **Checksums**: this project's existing content-hash primitive (`Value.content_hash`, via
  `digestif`), not AEGIS-128L — same "checksum stored outside the data it protects" property,
  without adding a new authenticated-encryption dependency to a PoC-scale system with no encryption
  requirement yet (see Non-goals).

## Decision 7: Fault injection — `Fault_injecting_storage`

The second `Storage.S` implementation (Decision 3): supports the same fault classes TigerBeetle's
`ClusterFaultAtlas` models (bit corruption, misdirected read/write, torn write, lost write),
deterministic and content-seeded (reusing `lib/sim/prng.ml`'s existing seeded PRNG, so retries
never accidentally heal a fault), capped at `faults_max = replication_quorum − 1` per chunk — the
same bound TigerBeetle enforces so the harness never injects more damage than any protocol could
theoretically survive, which would only produce false-positive "failures."

## Decision 8: The DST harness itself (subtask 3.4)

With Decisions 1-7 in place: the whole cluster (all replicas, as fibers in one Eio event loop) runs
against `Sim_transport` (network faults, already built and merged) and `Fault_injecting_storage`
(storage faults, Decision 7) simultaneously, driven by `Eio_mock.Clock` for the virtual clock
(already validated in `lib/sim/`'s PoC as giving deterministic, ~1000x-real-time scheduling). One
root seed drives both the network and storage PRNGs, so an entire multi-replica run is exactly
reproducible from that seed, satisfying subtask 3.4's own stated test strategy. New module
(placement — `lib/dst/` vs. extending `lib/sim/` — is a call to make once the code exists to look
at, not fixed here).

## Testing

- **Piece 1 (persistence)**: unit tests proving durable write + correct read-back after a
  simulated restart, in isolation, no VSR wiring yet — matching the "prove the primitive alone
  first" discipline `lib/transport/`'s own `Tcp` implementation used.
- **Piece 2 (protocol-aware recovery)**: the mandatory finiteness check (Decision 5) before any
  other TLA+ work; then exhaustive TLC model-checking to the existing spec's own evidence bar. Once
  the OCaml implementation exists: extend `test_vsr_replica_view_change.ml`'s existing
  `with_cluster` harness with real injected storage faults, proving recovery via the multi-step
  completion sequence over an actual cluster, not just against the TLA+ model.
- **Piece 3 (storage format + fault injection)**: a shared functor test body run against both
  `File_storage` and `Fault_injecting_storage`, mirroring `test_transport_shared.ml`'s existing
  pattern; adversarial mutation testing to prove the fault injection is actually exercised, the
  same way `Transport_intf`'s own suite proved a deliberately injected misrouting bug was caught.
- **Piece 4 (DST harness)**: the real success criterion is empirical, not structural — this harness
  must find and lead to fixing at least one genuine bug in pieces 1-3's interaction that unit tests
  alone would not have caught, the same way `batch_commit`'s and `Transport_intf`'s own guarantees
  were proven this way rather than asserted by construction. Every discovered failure must be
  perfectly reproducible from its seed.

## Non-goals, explicitly out of scope

- **Non-Linux storage backends** (macOS/Windows) — Linux-only via `eio_linux` for now (Decision 2).
- **Encryption at rest / mTLS** — task-master Task 4.4's job, separate and later; this storage
  format is plaintext on disk.
- **AEGIS-128L or any new authenticated-encryption primitive** — reusing the existing content-hash
  checksum instead (Decision 6).
- **Cross-region/multi-datacenter recovery** — task-master Task 11's job.
- **Real hardware-specific fault behaviors** beyond the synthetic fault atlas (e.g. actual SMART
  monitoring integration) — this is a DST-level synthetic fault model, not hardware certification.
- **Storage performance/throughput tuning** beyond "correct and durable" — no benchmarking
  requirement here.
- **A standalone CTRL round-trip protocol**, closer to the original paper's own presentation —
  this spec commits to TigerBeetle's real mechanism (multi-step view-change completion carrying
  nack information) instead (Decision 4).
- **Reconfiguration** — `spec/tla/README.md` already scoped this out of the VSR view-change work
  as needing its own, separate, original-research plan; this spec does not pull it back in.
