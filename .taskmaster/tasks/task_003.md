# Task ID: 3

**Title:** Distributed consensus, deterministic-simulation-tested from the first commit

**Status:** pending

**Dependencies:** 2 ✓

**Priority:** high

**Description:** Turn the single-node log into a genuinely replicated system: TLA+-specified consensus/replication protocol, atomic multi-entity commit, with deterministic simulation testing (virtual clock, seeded fault injection) built into the concurrency model from day one.

**Details:**

This session's own Phase 7 work on the OLD Riptide is the direct cautionary tale for skipping this: retrofitting a virtual clock onto an existing concurrency model meant it still can't reach the chaos-tested peer nodes, because the concurrency model wasn't built for simulation from the start. FoundationDB's Flow actor model exists specifically to make full-system deterministic simulation possible - that has to be a day-one architectural input here, not bolted on later. TigerBeetle chose a VSR-derived protocol over Raft specifically for storage-fault-awareness; that tradeoff needs a real decision here too, not a default.

 ~~Carried forward from Layer 0 seed (Task 2)'s final review: Envelope.content_hash reuses Value.content_hash directly (Envelope.content_hash e = Value.content_hash (Envelope.to_value e)), so there is no domain separation between an envelope's event_id and a plain payload Value's hash - a crafted payload Value can collide with a real event_id. Harmless today because verify_chain_list always recomputes from actual envelopes, but this task is where event_id first gets asked to carry real security/consensus meaning (e.g. as a vote/reference target) - decide explicitly at the start of this task whether domain separation (e.g. a leading domain tag before hashing) is needed, rather than inheriting the Layer 0 seed's reuse-one-encoding choice by default.~~

**RESOLVED (2026-09-18):** implemented as the prerequisite step described in
`docs/superpowers/plans/2026-09-18-event-id-domain-separation.md` (Task 1 of that plan, branch
`task3-event-id-domain-separation`; see that branch's `lib/envelope.ml` history for the exact
commit and `.superpowers/sdd/2026-09-18-event-id-domain-separation/task-1-report.md` for full
verification). `Envelope.content_hash` now hashes `Value.Sum (Envelope.domain_tag, to_value e)`
instead of a bare `Record`, so an envelope's hash space can never collide with a plain payload
`Value.value`'s hash space (distinct `Sum`/`Record` leading tag bytes in
`Value.canonical_encode` make this hold by construction). `Envelope.to_value`'s shape and the
golden fixtures that hash it directly are unchanged. Proven, not just asserted, by a concrete
positive/negative pair plus a QCheck2 property test in `test/test_envelope.ml`.

**Test Strategy:**

See subtask-level test strategy; each subtask must ship with real, running, tested code in the same cycle as any formal rule it implements — never spec-only.

## Subtasks

### 3.1. Choose and TLA+-specify the consensus/replication protocol

**Status:** pending  
**Dependencies:** None  

VSR-derived (TigerBeetle's choice, storage-fault-aware) vs Raft (simpler, larger ecosystem) - make the call explicitly, with the tradeoff reasoning documented, and get it model-checked before implementation, the way AWS's TLA+ practice found 35-step bugs that survived design review, code review, and testing.

**Details:**

Deliverable: a TLA+ spec, model-checked, with no known counterexamples in the checked state space.

### 3.2. Design the concurrency model for simulation-testability as a day-one input

**Status:** in-progress  
**Dependencies:** None  

Choose an effect-mediated or actor-style concurrency model (algebraic effect handlers, per OCaml 5/Eio's real 2025 production adoption, are a live candidate) specifically because it's what makes full-system deterministic simulation possible, not because it's fashionable.

**Details:**

Test: the exact same code path must run identically against a real network and a simulated one.

 PoC complete (merged to main, commits c78c698..93fc798): OCaml 5 / Eio (single-domain, effect-handler-based) confirmed as the right substrate for this. Concretely validated with real, running, tested code (not by inference): Eio's cooperative fiber scheduling is deterministic (an explicit maintainer guarantee, empirically re-confirmed); a from-scratch fault-injecting network (delay/drop/duplicate/byte-level-corrupt, seeded PRNG) composes correctly with genuinely blocking fibers under active faults, reproducing byte-identical traces; a fiber can genuinely sleep on simulated virtual time and be woken only by the simulation's own delivery mechanism (not a parallel clock); and the whole thing runs correctly under Eio_mock.Backend (Eio's own deterministic no-IO backend) rather than a real OS backend, which is what any real DST harness must use. Full design spec: docs/superpowers/specs/2026-09-16-distributed-consensus-design.md (Decision 2). Full plan + code: docs/superpowers/plans/2026-09-16-dst-proof-of-concept.md, lib/sim/. This closes the PoC/de-risking step only - the REAL concurrency model for the actual VSR-derived protocol (subtask 3.1) still needs to be designed and built against this now-validated substrate; this subtask is not done, the highest-risk unknown blocking it is.

### 3.3. Implement atomic multi-entity commit

**Status:** pending  
**Dependencies:** None  

Real cross-resource transactions - fixes the confirmed Riptide defect where the only multi-resource write pattern was a best-effort saga logging 'manual cleanup needed' on failure.

**Details:**

Test: a delta touching N entities either all commits or none does, verified under injected mid-commit node failure.

### 3.4. Build the deterministic simulation harness (VOPR-style) as a first-class artifact

**Status:** pending  
**Dependencies:** None  

Entire cluster runs as real code in one process, virtual clock, seed-reproducible fault injection, ~1000x speed - TigerBeetle's actual discipline, treated as more load-bearing than unit tests, not a testing afterthought.

**Details:**

Verify: any discovered failure is perfectly reproducible from its seed.

### 3.5. Choose the transport carrier (QUIC recommended) behind an abstract network interface

**Status:** pending  
**Dependencies:** None  

Per every top-tier system researched (TigerBeetle, FoundationDB, CockroachDB, DFINITY): formalize the message semantics riding on the wire, treat the literal carrier as swappable and verified by simulation/fuzzing, not proof. QUIC has a real production consensus precedent (DFINITY's Internet Computer) for exactly the head-of-line-blocking and lossy-network reasons relevant here.

**Details:**

Test: swapping the transport carrier implementation must not require touching the application-level protocol code.
