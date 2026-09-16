# Distributed consensus, deterministic-simulation-tested from the first commit

Design spec for task-master Task 3. Turns Layer 0's single-node hash-chained log (Task 2, merged)
into a genuinely replicated system. This document is the argument; the implementation plan and
running code that follow it are the authority, per this project's own "no spec without running
code" rule in `CLAUDE.md` — nothing here is binding until a task ships working, tested code
against it.

## Context

Layer 0 currently exists as a single-node, in-memory, hash-chained, tamper-evident log
(`Value`/`Envelope`/`Log`, all merged to `main`). It has no replication, no leader election, no
crash recovery, and no network layer at all. This task adds all of that, and — per this session's
own recorded lesson from the OLD Riptide's Phase 7 decade-simulation work — must treat
deterministic-simulation-testability as a day-one architectural input, not something retrofitted
after the concurrency model already exists. That earlier attempt built a virtual clock on top of
an existing concurrency model (Elixir/Erlang's Ra/Raft) and found the simulation still couldn't
drive the real, chaos-tested peer nodes — the fault injection and the real execution path never
actually composed.

Four research passes (consensus protocol/fault model, concurrency model + simulation harness,
atomic multi-entity commit, transport) plus two targeted follow-up passes (Eio determinism,
DST de-risking) ground every decision below. Full findings, with citations, are preserved at
`/work/riptide-task3-research/*.md` (outside this repo; not committed, since it's working
research material, not the spec itself).

## Decision 1: Fault model and consensus protocol

**Fault model: crash faults + storage faults, not crash-only. Crash-fault-tolerant (CFT), not
Byzantine-fault-tolerant (BFT).**

Standard Raft/Paxos implementations implicitly assume local disk reads are trustworthy. Alagappan
et al.'s FAST 2018 paper ("Protocol-Aware Recovery for Consensus-Based Storage") found LogCabin
and ZooKeeper failed safety or availability in ~98% of injected storage-fault scenarios (bit rot,
torn writes, misdirected I/O) because of this assumption. Layer 0's hash-chained log already
treats "what if the data is wrong" as a first-class concern (that's its entire purpose); a
consensus layer that doesn't would be inconsistent with what's already built. BFT has no real
precedent for single-organization critical infrastructure — its production use case is
cross-organizational/adversarial trust (blockchains) — and costs roughly 1.5x the nodes (3f+1 vs
2f+1) plus quadratic vs. linear messaging versus CFT. Riptide is a single operator's cluster, not
a multi-party trustless network.

**Protocol: VSR-derived (Viewstamped-Replication-derived), matching TigerBeetle's real-world
choice for the same reason.**

Three real options were evaluated:

| | VSR-derived | Raft | Multi-Paxos |
|---|---|---|---|
| Storage-fault-aware | Yes (TigerBeetle's actual production choice, citing the same FAST 2018 paper) | No, by default | No, by default |
| Formal-verification pedigree | Weakest — only third-party TLA+ exists; the most thorough one (Vanlightly) calls the source paper itself "hard to interpret, at times contradictory" | Strongest off-the-shelf — author-written TLA+, one real reconfiguration bug found and fixed pre-production | Strongest proof pedigree — TLAPS-checked, built on Lamport's own proof |
| OCaml precedent | None | `heidihoward/ocaml-raft` (built as a discrete-event simulator, by an actual Flexible Paxos researcher, but archived/academic) | None |
| Independent fault-injection track record | N/A (not independently tested in this research) | Antithesis's 2026 fault-injection testing found real safety/liveness bugs in every Raft implementation tested, including production-grade HashiCorp Raft | N/A |

VSR-derived is the only option that matches this project's own already-declared rigor bar. The
cost is real and explicit: more of the formal specification work is original rather than adapted
from mature prior art, and there's no OCaml implementation to reference. This is consistent with
this project's governance principle in `CLAUDE.md` (Layer 0 changes are decided by people who've
actually implemented against them, not by adopting someone else's spec wholesale) — doing the
harder, more original work here is the expected shape of Layer 0 work, not a shortcut avoided.

**Consequence for Task 3.1** (choose and TLA+-specify the protocol): expect to write substantially
original TLA+, informed by but not copied from Vanlightly's independent VSR effort and the VSR
paper itself, cross-checked against TigerBeetle's own public protocol description where their
implementation clarifies an ambiguity in the source paper.

## Decision 2: Concurrency model and deterministic simulation harness

**Single-domain, OCaml 5 effect-handler-driven concurrency via Eio, with a
FoundationDB-Flow/TigerBeetle-VOPR-style swappable I/O boundary.**

Eio's scheduler determinism is an explicit, documented maintainer guarantee, not an inference:
"within a domain, fibers are scheduled deterministically... `Fiber.both f g` always starts
running `f` first," with no internal scheduler randomization. OCaml's `Hashtbl` is deterministic
by default (favorable compared to Rust's `HashMap`, randomized by default — something Rust's own
DST frameworks had to explicitly work around). Production and simulation will run the same
application code; only what a network/disk/clock effect handler resolves to differs (real
sockets/files/OS clock vs. in-memory fault-injecting fakes driven by one seeded PRNG threaded
through every random decision in the system).

**Two facts to design against, not around:**

1. **Nobody has built a DST harness on Eio before** — confirmed by direct search (GitHub issues,
   GitHub Discussions, OCaml Discourse), not assumed. `Eio_mock` (the existing mock
   clock/network/flow scaffolding) is real but narrow: no fault injection (no delay/drop/reorder/
   corrupt/partition), no seeded-PRNG threading. All of that is unbuilt.
2. **This is the normal amount of unproven-ness for a first-mover DST project, not a uniquely
   OCaml risk.** Every cross-language precedent checked (Rust's madsim/turmoil, Go's
   gosim/detsim/a runtime-forked-to-WASM effort, Erlang's Eta) required real, hard, original
   engineering — libc interception, ecosystem-wide dependency patching, or forking the runtime.
   Nobody got this for free, in any language.

**Required first deliverable of subtask 3.2 (before any protocol implementation begins): a
proof-of-concept.** 2-3 toy Eio fibers running over a hand-rolled, in-memory, fault-injecting
network; one seeded PRNG threaded through all randomness; a virtual clock; byte-level (not just
whole-message) corruption injection; and a workload generator deliberately checked against the
exact blind spot that caused TigerBeetle's real, Jepsen-found bug (a workload generator that only
exercises structured/pre-registered queries misses classes of real bugs — this PoC's generator
must include unstructured/adversarial inputs from the start). This is cheap and should surface
within weeks whether OCaml hides some analog of the traps other languages hit (GC pauses
interacting badly with virtual time, `Domain`-crossing nondeterminism, a transitive dependency
that doesn't cooperate with Eio's effect handlers) — before the real consensus implementation is
architected around this substrate.

**DST is necessary, not sufficient, on an ongoing basis, not just once.** TigerBeetle's own
response to Jepsen's findings (two real bugs VOPR's fault model and workload generators missed)
was to widen VOPR itself — three times over three years (2023, 2025 post-Jepsen, 2026) — not to
treat the gaps as one-time fixes. Their own stated view: "when a fuzzer stops finding bugs, it may
simply mean it has exhausted the particular slice of state space it can reach." Riptide's DST
harness should be budgeted as continuous investment (wider fault models, wider workload
generators, as gaps are found — including via independent audit, not just internal fuzzing), not
a checkbox built once in Task 3.4 and left static.

**Scaling implication:** the consensus core stays single-domain. FoundationDB scales via one
single-threaded process per CPU core (a shardable KV workload); TigerBeetle instead makes one core
fast via mechanical sympathy, because its single-ledger workload isn't shardable. Riptide's single
hash-chained log is structurally closer to TigerBeetle's case — expect future horizontal scaling
to come from sharding the log (a later task, not this one), not from using OCaml 5 domains within
one consensus group.

## Decision 3: Atomic multi-entity commit

**Single-ordering-authority: a multi-entity commit is proposed as one envelope/batch, replicated
and applied atomically by construction — not Spanner-style two-phase commit (2PC) across
independently-partitioned shards.**

This directly fixes the old system's confirmed defect: no cross-stream/cross-resource atomic
transactions, only a best-effort saga with a compensating delete that logged "manual cleanup
needed" on failure and left the system possibly inconsistent with no recovery path.

2PC exists to coordinate data that's *already* partitioned across independent consensus groups
(Spanner's per-shard Paxos groups, CockroachDB's per-range Raft groups). Riptide's Layer 0 is one
global, unsharded, hash-chained log — there is nothing to coordinate across yet. Real precedent
for the simpler shape this implies: etcd (a multi-key `Txn` is just one Raft log entry, no 2PC),
Calvin/FaunaDB (deterministic pre-ordering eliminates 2PC even with partitioned storage), CORFU/
Delos (atomicity falls out of a contiguous log run).

Three concrete commitments:

- **Model the commit unit explicitly, now, as a real batch/multi-entity envelope structure** —
  not implicitly as "adjacent log positions." CockroachDB's own evolution (started as one range,
  later split) is precedent that this can survive an eventual move to sharding, though it's an
  imperfect analog: CockroachDB was designed for sharding from day one, and Riptide isn't yet.
  **This is a genuinely open question to carry forward, not one closed by precedent** — whatever
  Task 3.3 builds should be revisited explicitly if/when Layer 0 is ever sharded.
- **A distinct idempotency/intent key, separate from content-addressing.** Content-hashing a
  *request* is not always a safe dedup key (e.g., "increment counter X" submitted twice may be
  meant to apply twice). Standard fix: a client-supplied idempotency key, checked against a dedup
  log, independent of `Envelope.event_id`/`content_hash`.
- **Failure/recovery is an explicit, automatic protocol step, tested for the crash-during-commit
  case specifically** — never a logged manual-cleanup fallback. This should be one of the first
  scenarios the DST harness (Decision 2) exercises once it exists, alongside the general
  crash/restart fault model.

## Decision 4: Transport

**Plain TCP with custom framing — correcting the task tracker's own placeholder "QUIC
recommended" suggestion, which research found ungrounded.**

No real consensus/replication system surveyed uses QUIC for inter-node traffic: TigerBeetle (raw
TCP, own framing/checksums, explicitly states it needs only "very weak message passing
semantics"), FoundationDB (custom TCP wire protocol), Kafka KRaft (own binary protocol over TCP),
HashiCorp Raft (`TCPStreamLayer`), etcd (HTTP/1.x over long-lived TCP, historically because it
predated gRPC — not a principled choice, but not QUIC either). QUIC's actual advertised benefits
(0-RTT handshakes, connection migration) solve problems this workload doesn't have: long-lived
connections between a small, fixed, known peer set, not many short-lived client connections.
OCaml's only QUIC implementation (`anmonteiro/ocaml-quic`) is an early-research, NLnet-funded demo
project; TCP support via `Eio.Net` is mature and stdlib-adjacent by comparison.

**Abstract network interface: message-oriented `send(peer_id, msg)` / `on_receive(peer_id, msg)`
with explicit peer addressing — not a stream/connection abstraction.** This matches both
FoundationDB's (`Endpoint`-addressed RPC over a swappable `IConnection`) and TigerBeetle's
(`message_bus.zig`, generic over an `IO` type parameter swapped between io_uring and simulated
implementations) real designs, and it's exactly the boundary the DST harness's fault injection
needs to hook into — drop/delay/reorder/duplicate/corrupt all happen at the send/receive boundary,
not inside a connection's internal state machine.

**One real, narrow problem to watch for, not solve preemptively:** CockroachDB adopted gRPC/HTTP2
specifically because large Raft snapshot transfers were head-of-line-blocking small
heartbeat/vote messages on a single TCP connection. If Riptide hits the same problem, the fix is a
second TCP channel for bulk transfers (snapshots/catch-up) separate from the
heartbeat/vote/propose channel — not a reason to adopt QUIC's full complexity now.

## Decision 5: `event_id` domain separation (carried forward from Task 2's final review)

Task 2's final review found `Envelope.content_hash e = Value.content_hash (Envelope.to_value e)`
— envelope hashing reuses `Value`'s encoding directly, with no domain separation from a plain
payload `Value`'s hash. A crafted payload `Value` can therefore collide with a real `event_id`.
This was harmless in Task 2 (nothing treated `event_id` as security-relevant), but Task 3 is
exactly where that stops being true: `event_id`/`content_hash` becomes a real vote/reference
target inside the consensus protocol.

**Decision: add domain separation.** Prefix the hash preimage with a distinct domain tag
distinguishing "this is an envelope" from "this is a plain value" before hashing, so the two
hash spaces can never collide by construction. This is a small, cheap addition — implement it as
an early step of Task 3's work (before the protocol needs `event_id` as a reference target), not
deferred further. Exact mechanism (a leading domain-tag byte in the preimage vs. a separate
top-level hash function) is an implementation-plan-level detail, not a design-level one.

## Testing strategy

Per this project's own "no spec without running code" rule: the TLA+ specification (Task 3.1) and
its corresponding running implementation ship in the same task-master task, never TLA+ alone
followed by "implement later." The DST harness (Task 3.4) starts with the proof-of-concept
(Decision 2) before the real protocol is built against it. Atomic commit's crash-during-commit
scenario (Decision 3) and the transport layer's fault injection (Decision 4) are both exercised
through the same DST harness once it exists, not through separate ad hoc test infrastructure.

## Open questions carried forward, not resolved here

- **Atomic commit under future sharding** (Decision 3) — explicitly not closed by precedent;
  revisit when/if Layer 0 is ever sharded.
- **DST harness fault-model and workload-generator breadth is an ongoing investment, not a
  one-time deliverable** (Decision 2) — Task 3.4 builds the first version; expect it to need
  deliberate widening as real gaps are found, the way TigerBeetle's VOPR did.
- **Exact TLA+ formalization approach for the VSR-derived protocol** (Decision 1) — this design
  commits to the protocol family and fault model, not the specific TLA+ module structure; that's
  Task 3.1's own work.
