# Riptide — Production Readiness Roadmap

**Last updated:** 2026-08-23

This tracks Riptide's path from "working reference implementation" (shipped: see
[PR #1](https://github.com/OpenFASTER-Standard/riptide/pull/1)) to "production-grade centerpiece
of an organization's data architecture." Kept proactively up to date as work lands — this is the
first place to check for current status, not a historical log.

## Sub-projects

| # | Sub-project | Status |
|---|---|---|
| 1 | Persistence & durability | **In design** — see below |
| 2 | Docker image + CI/CD | Not started |
| 3 | Clustering / horizontal scale / HA | Not started (multi-node `Ra` replication belongs here — see §1) |
| 4 | Security & multi-tenancy (auth, WAC/ACP, TLS) | Not started |
| 5 | Observability & operability (metrics, logging, health probes) | Not started |

Sequencing rationale: persistence first, since clustering/HA are meaningless without durable
storage to replicate, and every other sub-project assumes data actually survives a restart.

## 1. Persistence & durability — in design

**Scope for this sub-project**: a single-node `Ra`-replicated (cluster size 1) durable log per
stream, replacing the current in-memory `state.events` list in `Riptide.Stream.StreamServer`.
Solves the most urgent gap: a crash today loses all data and silently resets sequence numbers
from 1, which can break a reconnecting subscriber's `Last-Event-ID` resumption without even
signaling a gap.

**Key decisions made (with rationale — see chat history / eventual design doc for full research
citations):**

- **Durability model**: majority-commit over a `Ra`-replicated (Raft) write-ahead log — same
  model RabbitMQ quorum queues use in production. Resolves the fsync-vs-replication tension
  (Kafka's replication-only model vs. EventStoreDB's fsync-first model) by getting both at once,
  rather than picking one.
- **Storage medium**: local segment-log now; hybrid tiering to object storage for cold retention
  (Kafka KIP-405 pattern) is real production precedent but deferred as additive, not a Phase-1
  requirement.
- **Ordering guarantee**: StreamLD's single monotonic sequence-number-per-stream guarantee is
  preserved, not sacrificed for throughput (a deliberate choice — Kafka's own per-partition
  model was the recommended alternative and was explicitly turned down).
- **Horizontal throughput beyond one `Ra` group**: deferred behind an explicit "measure first"
  gate. No production system on any stack has done this at Kafka-adjacent scale — the closest
  precedent (Scalog, NSDI'20) needs a Paxos-coordinated ordering layer on top of sharded storage
  and only hit 255K/sec in its real (non-emulated) prototype. Build the proven single-shard
  durable log first, benchmark it for real, and only build the sequencer layer if a real ceiling
  shows up for a specific high-volume stream.
- **Khepri (RabbitMQ's `Ra`-based Mnesia replacement) is NOT the storage engine** — it keeps the
  entire dataset in memory as well as on disk, a hard ceiling below multi-TB/PB retention. `Ra`
  itself (the underlying Raft library) is the right substrate; Riptide builds its own segment-log
  storage on top of it rather than routing through Khepri's tree abstraction.

**Known operational risk to design around from day one**: a shared `Ra` WAL under disk
contention can collapse throughput by orders of magnitude (RabbitMQ's own published numbers:
13k→6k→300 msg/s as contention increased). High-volume streams need real disk isolation, not
just "add more Ra groups on the same disk."

**Status**: design approved through the "Testing" section; not yet written to a formal design
doc or implementation plan.

## 2-5. Not yet started

Will be filled in as each sub-project reaches design.

## Carried-forward open items (from the initial implementation, PR #1)

These predate this roadmap but are real, tracked gaps — not to be lost:

- **PATCH `removals` are non-functional.** `Event`'s payload model has no way to represent a
  delta removal. Needs an Event/payload redesign (e.g. separate additions/removals fields).
  Documented in-code (`resource_controller.ex`).
- **PUT with an empty body is indistinguishable from DELETE** (both 404 on GET) — same root
  cause as above.
- **No committed test for WebSocket cross-stream isolation** (verified correct ad-hoc during
  review, no regression guard).
- **No automated drift-detection test** between the SHACL shapes and their `shacl2code`-mirror
  copies in the spec repo's `envelope.ttl` (comment-enforced only).
- **StreamLD's design doc doesn't yet document the in-memory-only durability limitation** and
  its sharper-than-usual consequence (silent sequence-number reissue after a crash breaks
  `Last-Event-ID` resumption without a gap signal) — this roadmap is the interim record until
  that's folded into the design doc.
