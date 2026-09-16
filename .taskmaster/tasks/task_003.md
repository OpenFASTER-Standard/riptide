# Task ID: 3

**Title:** Distributed consensus, deterministic-simulation-tested from the first commit

**Status:** pending

**Dependencies:** 2

**Priority:** high

**Description:** Turn the single-node log into a genuinely replicated system: TLA+-specified consensus/replication protocol, atomic multi-entity commit, with deterministic simulation testing (virtual clock, seeded fault injection) built into the concurrency model from day one.

**Details:**

This session's own Phase 7 work on the OLD Riptide is the direct cautionary tale for skipping this: retrofitting a virtual clock onto an existing concurrency model meant it still can't reach the chaos-tested peer nodes, because the concurrency model wasn't built for simulation from the start. FoundationDB's Flow actor model exists specifically to make full-system deterministic simulation possible - that has to be a day-one architectural input here, not bolted on later. TigerBeetle chose a VSR-derived protocol over Raft specifically for storage-fault-awareness; that tradeoff needs a real decision here too, not a default.

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

**Status:** pending  
**Dependencies:** None  

Choose an effect-mediated or actor-style concurrency model (algebraic effect handlers, per OCaml 5/Eio's real 2025 production adoption, are a live candidate) specifically because it's what makes full-system deterministic simulation possible, not because it's fashionable.

**Details:**

Test: the exact same code path must run identically against a real network and a simulated one.

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
