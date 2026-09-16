# Task ID: 4

**Title:** Lattice merge-law contract and incremental materialized state

**Status:** pending

**Dependencies:** 3

**Priority:** high

**Description:** Define the rule that mergeable types must satisfy join-semilattice laws, and build the incremental-projection mechanism so reads never replay the full log from sequence zero.

**Details:**

Directly, structurally fixes the single defect two independent investigations found in the old Riptide from different angles: every read replayed the entire event history. CRDTs/lattices are the one piece of this whole stack that's already fully mainstream (Riak, Redis CRDTs, Automerge) - no unproven bet required. Redaction-with-preserved-hash also belongs here: it can't be retrofitted later without a hard-fork-shaped migration touching every existing record, so it has to be structural from this step.

**Test Strategy:**

See subtask-level test strategy; each subtask must ship with real, running, tested code in the same cycle as any formal rule it implements — never spec-only.

## Subtasks

### 4.1. Define and formally specify the join-semilattice law contract

**Status:** pending  
**Dependencies:** None  

The RULE that any type claiming to be mergeable must satisfy commutative/associative/idempotent join - this is Layer 0 mechanism. Which concrete lattice a given domain module uses for its own data is Layer 2 policy.

**Details:**

Property-test: merge is order-independent and repeat-safe for any type claiming the contract.

### 4.2. Build the incremental-projection (CQRS) mechanism

**Status:** pending  
**Dependencies:** None  

Log is source of truth; every read hits a materialized, incrementally-maintained projection, never a full replay. Mirrors the proven EventStoreDB/Marten/Axon pattern.

**Details:**

Benchmark: read latency must stay flat as total log history grows, unlike the old Riptide's O(total history) get_since/2.

### 4.3. Implement redaction-with-preserved-hash (tombstone) capability

**Status:** pending  
**Dependencies:** None  

The mechanism to redact a record's payload while preserving its leaf hash - structural GDPR-erasure-vs-immutability answer, following the crypto-shredding/pseudonymization pattern researched. WHO is allowed to invoke it is Layer 2 policy; that the capability exists safely is Layer 0.

**Details:**

Test: a redacted record's hash-chain integrity is unaffected; the payload is genuinely unrecoverable.

### 4.4. Add encryption at rest and mTLS in transit as non-optional infrastructure

**Status:** pending  
**Dependencies:** None  

Every byte that hits disk or the wire is encrypted, no escape hatch - directly fixes the old Riptide's total absence of encryption at rest and edge-only TLS.

**Details:**

Test: inspect raw disk/wire bytes under test harness, confirm no plaintext domain data ever appears.
