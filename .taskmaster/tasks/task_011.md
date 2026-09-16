# Task ID: 11

**Title:** Multi-region and further hardware-heterogeneity extensions

**Status:** pending

**Dependencies:** 8, 10

**Priority:** low

**Description:** Per-region independent consensus groups with async cross-region replication, geo-partitioning for data residency, and any further extension of the epoch-barrier coupling pattern to region-to-region coupling.

**Details:**

Furthest from the correctness-critical core and least urgent - extends reach, doesn't establish trust. Per-region independent consensus groups (Spanner, CockroachDB, TiDB, Oracle all do this) is genuinely industry-standard; extending epoch-barrier coupling from control-plane/data-plane to region-to-region is a plausible but NOVEL extension of proven patterns, not itself directly precedented - treat it as needing its own validation, not assumed to work by analogy alone.

**Test Strategy:**

See subtask-level test strategy; each subtask must ship with real, running, tested code in the same cycle as any formal rule it implements — never spec-only.

## Subtasks

### 11.11.1. Implement per-region independent consensus groups with async replication

**Status:** pending  
**Dependencies:** None  

Each region runs its own Tier 1 consensus group; cross-region coupling is async, never synchronous global consensus.

**Details:**

Test: a regional outage does not block writes in other regions; cross-region reads have a defined, bounded staleness.

### 11.11.2. Implement geo-partitioning for data residency

**Status:** pending  
**Dependencies:** None  

Tag data/tenants with a locality key, pin storage and consensus replicas to matching region(s) - CockroachDB's REGIONAL BY ROW is the concrete proven mechanism to match.

**Details:**

Test: data tagged to a jurisdiction never physically replicates outside it.

### 11.11.3. Validate (don't assume) the epoch-barrier pattern extended to region coupling

**Status:** pending  
**Dependencies:** None  

This is explicitly new synthesis, not established practice - budget real validation effort, potentially including its own TLA+ model, before trusting it the way Task 3's core consensus protocol is trusted.

**Details:**

Test: under simulated region partition, verify the coupling mechanism's actual guarantees match what's claimed, not just that it superficially works in the happy path.
