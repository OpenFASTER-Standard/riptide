# Task ID: 2

**Title:** Layer 0 seed: event envelope + content-addressed value universe (single node, no replication)

**Status:** pending

**Dependencies:** 1

**Priority:** high

**Description:** Build the smallest possible real slice of Layer 0: the event envelope format and the base algebraic value universe, as one real, running, single-node append-only log. Proves the data model and audit-trail primitives against real code before distributed consensus is layered on.

**Details:**

Per the mechanism/policy (Hydra/seL4) test, this is unambiguously Layer 0: every module needs deterministic ordering and a tamper-evident audit trail, and it must be fully formalizable with zero implementation-defined gaps (the POSIX/SQL/HTTP-request-smuggling lesson - anything left 'implementation-defined' is where real bugs cluster later). Directly fixes two confirmed Riptide/StreamLD defects: StreamLD's spec never mentions actor/provenance/causality at all, and Riptide's own implementation resolves identity at the HTTP layer then drops it before the event is built.

**Test Strategy:**

See subtask-level test strategy; each subtask must ship with real, running, tested code in the same cycle as any formal rule it implements — never spec-only.

## Subtasks

### 2.1. Define the content-addressed algebraic value universe

**Status:** pending  
**Dependencies:** None  

Scalars, records, sums, sequences, finite maps - a small typed core category (schemas as categories, instances as functors, per Spivak's functorial data model) that RDF, JSON, or any other domain payload becomes ONE instance of, not the universal substrate.

**Details:**

Directly fixes the RDF-only limitation the euro-office bridge integration hit (had to build a whole separate JSON codec). Borrow the schema-morphism IDEA from CQL/Conexus without adopting the full boutique tooling wholesale.

### 2.2. Define the event envelope: actor, causation, correlation, predecessor hash, sequence - all mandatory

**Status:** pending  
**Dependencies:** None  

Every field is required, none optional, none droppable at any layer. This is the audit-trail fix for both Riptide's actual bug and StreamLD's total silence on provenance.

**Details:**

Validate: an event literally cannot be constructed without a real actor identity - not merely a documented best practice.

### 2.3. Implement single-node append-only log with hash-chaining

**Status:** pending  
**Dependencies:** None  

No replication yet. Tamper-evidence (Merkle/hash-chain linkage) is structural from the first commit, not retrofitted - Riptide's `force_delete` had zero production safeguards because this wasn't designed in from the start.

**Details:**

Test: any single-byte alteration anywhere in history is detectable via hash-chain verification.

### 2.4. Build the SpecTec-style single formal source generating spec + reference implementation + conformance tests

**Status:** pending  
**Dependencies:** None  

One formal definition of the envelope format generates the prose spec, a reference interpreter, and the test suite - never three hand-maintained artifacts drifting apart. This is what let WASM's formal semantics catch a real pre-standardization type-soundness bug; Ethereum's weaker 'executable reference implementation as spec' model is what let it ship two real spec-level chain-splitting bugs.

**Details:**

Verify: changing the formal definition regenerates all three artifacts with no manual sync step.
