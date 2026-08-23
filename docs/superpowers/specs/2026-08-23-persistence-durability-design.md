# Riptide Persistence & Durability — Design

**Status:** Approved 2026-08-23. Sub-project 1 of Riptide's production-readiness roadmap (see
`PROGRESS.md`).

**Revision, same day**: the "Kafka-scale from the start" ambition originally driving §6's deferred
work is walked back. Explicit operator direction: prioritize a system that is simple, efficient,
and actually works over one architected for a scale target that was never a measured requirement.
Phase 1 (below) is unchanged — it was already the efficient, unglamorous choice. What changes is
that the speculative follow-on (a Scalog-style multi-shard sequencer) is no longer scoped as future
work at all; see the shortened §6.

## 1. Context and motivation

Riptide's event log (`Riptide.Stream.StreamServer`) is currently fully in-memory: a plain list
in a GenServer's state. A crash loses all data and silently resets sequence numbers to 1 — a
reconnecting subscriber's `Last-Event-ID` can end up pointing at a sequence number that "looks"
valid in the fresh, empty log (since the new sequence 1 is `>=` almost any old cursor check),
so resumption can silently fail without even triggering the gap signal designed for exactly this
kind of situation. This is the most foundational gap standing between Riptide and being usable
as "the centerpiece of an organization's data architecture" — every other production concern
(clustering, security, observability) presupposes that data actually survives a restart.

This design is scoped to persistence and durability only. It does not cover multi-node
replication, tiered cold storage, or horizontal write-scaling beyond a single stream's current
throughput — see §6 for why each is deferred and what would trigger revisiting it.

## 2. Research summary

This design followed three rounds of deep, adversarially-verified research. Key findings:

1. **The fsync-vs-replication durability question has a real answer, not just a tradeoff.**
   Kafka's durability comes from replication (`acks=all`/`min.insync.replicas`), not per-write
   fsync — Kafka explicitly rejects per-write fsync as costing 2-3 orders of magnitude in
   throughput. EventStoreDB, being an actual system-of-record rather than a transient bus, takes
   the opposite default: it flushes to disk on every write (batched in a small window), only
   skippable via an explicit `--unsafe` flag with a documented data-loss warning.
   **RabbitMQ's quorum queues resolve this cleanly, not as a compromise**: durability from
   replicated consensus (the `Ra` Raft library), where each replica's write-ahead log is written
   to disk as part of the commit path, and a write is only acknowledged once a *majority* of
   replicas have durably committed. This gets Kafka-scale-friendly replication and
   EventStoreDB-grade local durability simultaneously.
2. **Storage medium**: hybrid tiered storage (local disk for hot segments, object storage for
   cold) is the only pattern with real production precedent at Kafka-adjacent scale — Kafka's
   own KIP-405, production-ready since Kafka 3.9. Deferred here as additive (§6).
3. **`Ra` is the right BEAM-native replication substrate; `Khepri` is not the storage engine.**
   `Ra` (the Raft library underlying RabbitMQ's quorum queues and streams) is independently
   production-proven, described by its maintainers as "extensively tested and suitable for
   production use." `Khepri` (RabbitMQ's own `Ra`-based Mnesia replacement) is genuinely
   production-proven as of RabbitMQ 4.2+, but keeps the entire dataset in memory as well as on
   disk — a hard ceiling well below multi-TB/PB retention. Riptide builds its own segment-log
   storage on top of `Ra`'s replication machinery directly, not through `Khepri`'s tree
   abstraction.
4. **Preserving StreamLD's single-sequence-per-stream guarantee at Kafka-adjacent throughput is
   genuinely unprecedented** — no production system on any stack does this today. The closest
   academic precedent (Scalog, NSDI'20) needs a Paxos-coordinated ordering layer on top of
   sharded storage and only achieved 255K/sec in its real (non-emulated) prototype across 17
   shards; a second precedent (Corfu) was found to have a real, verified single-sequencer
   bottleneck (a claim that it "achieves cluster-scale throughput" did not survive adversarial
   verification). This is a deliberate, informed choice: StreamLD's ordering guarantee is
   preserved rather than traded for Kafka's own per-partition-ordering-only model, and the
   throughput cost of that choice is treated honestly (§6), not hidden.
5. **A real, named operational risk**: RabbitMQ's own published benchmarks show a *shared* `Ra`
   write-ahead log under disk contention collapsing throughput by orders of magnitude (13k→6k→
   300 msg/s as a competing workload's load increased) — high-volume streams need real disk
   isolation designed in from the start, not discovered in production.

## 3. Architecture

### 3.1 Scope boundary

This sub-project delivers a **single-node `Ra`-replicated (cluster size 1) durable log per
stream**, replacing `Riptide.Stream.StreamServer`'s in-memory list. Running `Ra` at cluster size
1 still yields real disk-backed durability (survives a BEAM/process crash or restart) even
before any multi-node work exists — the value of adopting `Ra` now, rather than a bespoke
single-node WAL, is that scaling to a real multi-node cluster later is a configuration change to
an already-correct state machine, not a rewrite.

Three things are explicitly deferred:

- **Multi-node replication** (`Ra` cluster size 3+, surviving actual node failure) — becomes the
  main content of the next sub-project (Clustering/HA), since it needs node discovery/cluster
  membership infrastructure shared with the rest of that sub-project.
- **Tiered/cold storage to object storage** — real production pattern, but additive on top of
  working local durability.
- **The Scalog-style global sequencer** for horizontal per-stream throughput beyond one `Ra`
  group's ceiling — gated behind actually measuring that ceiling (§6), not built preemptively.

### 3.2 Components

- **`Riptide.Stream.StreamServer` becomes a `Ra` state machine** instead of a plain GenServer
  holding a list. `Ra`'s `apply/3` callback is where sequence assignment happens deterministically
  — the same logic that exists today (`Event.with_sequence/2`, strictly-increasing per stream),
  now running inside `Ra`'s replicated-log machinery instead of a bare `handle_call`.
- **One `Ra` cluster per stream**, matching RabbitMQ quorum queues' own pattern (one `Ra` cluster
  per queue), started/stopped dynamically the same way `StreamSupervisor.get_or_start/1` does
  today — just starting a `Ra` cluster instead of a GenServer.
- **Retention reconciliation**: `Ra` needs its own periodic snapshots so its consensus log
  doesn't grow unboundedly (log compaction, a `Ra`-level concern) — this must cooperate with
  Riptide's own retention policy (Task 15's concept: how far back subscribers can read) rather
  than conflict with it. A snapshot is a full serialization of current stream state; it's safe
  to truncate `Ra`'s log up to a point once Riptide's retention policy no longer needs those
  entries individually.

### 3.3 Data flow

- **Write path**: `StreamServer.append/2` becomes a `Ra` command submission instead of a
  `GenServer.call`. `Ra` handles replication (trivial at cluster size 1) and durability (fsync
  as part of the commit path) before the command is considered applied; only then does the
  caller get the stamped event back. This is where "durable before ack" actually happens now,
  not just an in-memory GenServer reply.
- **Read path** (`get_since/2`, the LDP `current_state/1` fold, SSE/WebSocket backlog replay):
  unchanged in shape — still returns `{:ok, [Event.t()]} | {:gap, _}` — now reading from `Ra`'s
  log instead of an in-memory list.
- **Restart/recovery**: on a `StreamServer`/`Ra` cluster restart, `Ra` replays its durable log to
  reconstruct state — the piece that's completely missing today (a crash currently just starts
  fresh at sequence 1).

### 3.4 Error handling

- **Crash during a write**: `Ra`'s commit semantics mean a command is either fully applied
  (durable, sequence assigned) or not applied at all — no half-written state, unlike today's
  plain GenServer where a crash mid-`handle_call` could theoretically lose an
  already-computed-but-unreplied sequence number.
- **Disk contention**: per §2 finding 5, high-volume streams need real disk isolation as an
  explicit deployment/configuration concern, documented for operators rather than discovered in
  production.

## 4. Testing

- **Correctness**: sequence assignment, durability-across-restart, and retention/snapshot
  interaction all need real crash-recovery tests (kill the BEAM process mid-write, restart,
  verify state) — not just the existing in-memory GenServer unit tests, which assumed state
  simply doesn't survive a restart.
- **Existing test suite audit**: several current tests assume synchronous, in-memory GenServer
  semantics. These need auditing for whether `Ra`'s command-submission model (still synchronous
  from the caller's perspective, but now involving actual disk I/O) changes any timing
  assumptions the tests currently make.

## 5. Dependencies

- **`Ra`** (Erlang/OTP Raft library, `hex.pm` package `:ra`) — to be verified for exact current
  version and Elixir-usability during implementation planning.

## 6. Deferred work and honest limits

- **Multi-node `Ra` replication** — next sub-project (Clustering/HA).
- **Tiered/cold object storage** — additive future work once local durability is solid.
- **Horizontal per-stream throughput beyond one `Ra` group** — not being designed, scoped, or
  built, full stop. A single `Ra` group is the same replication model RabbitMQ quorum queues run
  in production, where a single queue comfortably handles tens of thousands of messages/sec — far
  above what a real Solid-pod-style workload needs per stream. There is no measured need driving a
  multi-shard sequencer, and no production system anywhere has actually built the kind of
  coordinator that would require (see §2 finding 4) — building it speculatively would trade a
  simple, working system for unproven complexity in exchange for headroom nothing has asked for.
  If a specific stream's real, measured throughput ever exceeds one `Ra` group's ceiling, that
  measurement is the trigger to design a solution then, not before.
- **Disk-isolation guidance for operators** is named as a requirement here but not yet written
  as actual deployment documentation — a real gap to close before this ships to a real operator,
  not before the code itself is written.
