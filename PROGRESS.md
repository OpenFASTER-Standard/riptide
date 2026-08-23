# Riptide — Production Readiness Roadmap

**Last updated:** 2026-08-23

This tracks Riptide's path from "working reference implementation" (shipped: see
[PR #1](https://github.com/OpenFASTER-Standard/riptide/pull/1)) to "production-grade centerpiece
of an organization's data architecture." Kept proactively up to date as work lands — this is the
first place to check for current status, not a historical log.

## Sub-projects

| # | Sub-project | Status |
|---|---|---|
| 1 | Persistence & durability | **Shipped** — see below |
| 2 | Docker image + CI/CD | Not started |
| 3 | Clustering / horizontal scale / HA | Not started (multi-node `Ra` replication belongs here — see §1) |
| 4 | Security & multi-tenancy (auth, WAC/ACP, TLS) | Not started |
| 5 | Observability & operability (metrics, logging, health probes) | Not started |

Sequencing rationale: persistence first, since clustering/HA are meaningless without durable
storage to replicate, and every other sub-project assumes data actually survives a restart.

## 1. Persistence & durability — shipped

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
- **Horizontal throughput beyond one `Ra` group**: not being pursued. **Revised 2026-08-23** —
  the earlier "Kafka-scale from the start" ambition is walked back in favor of a simple system
  that is efficient and actually works: a single `Ra` group (the same model RabbitMQ quorum
  queues run in production) comfortably handles tens of thousands of msgs/sec per stream, well
  above real workload needs, with none of the unproven-coordinator risk a multi-shard sequencer
  would add. Not scoped as future work at all — only revisited if a real, measured stream ever
  actually hits that ceiling.
- **Khepri (RabbitMQ's `Ra`-based Mnesia replacement) is NOT the storage engine** — it keeps the
  entire dataset in memory as well as on disk, a hard ceiling below multi-TB/PB retention. `Ra`
  itself (the underlying Raft library) is the right substrate; Riptide builds its own segment-log
  storage on top of it rather than routing through Khepri's tree abstraction.

**Known operational risk to design around from day one**: a shared `Ra` WAL under disk
contention can collapse throughput by orders of magnitude (RabbitMQ's own published numbers:
13k→6k→300 msg/s as contention increased). High-volume streams need real disk isolation, not
just "add more Ra groups on the same disk."

**Status**: implementation complete, PR pending — see
[`docs/superpowers/specs/2026-08-23-persistence-durability-design.md`](docs/superpowers/specs/2026-08-23-persistence-durability-design.md)
for the design and its implementation plan.

## 2-5. Not yet started

Will be filled in as each sub-project reaches design.
