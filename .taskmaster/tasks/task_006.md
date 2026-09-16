# Task ID: 6

**Title:** Build one real, demanding Layer 2 module end to end

**Status:** pending

**Dependencies:** 5

**Priority:** high

**Description:** Pick ONE genuine, demanding real use case - not several imagined ones - and build it fully against the Task 5 boundary. This is what actually proves or breaks the boundary design.

**Details:**

The single most important sequencing lesson from the entire historical-precedent research: WASM proved itself on real C/C++-via-Emscripten workloads for ~2 years before WASI opened it to genuinely diverse use; Kubernetes' CRD mechanism proved itself on real Prometheus/cert-manager/Istio deployments. Building for several imagined domains simultaneously, before any one is real, is the specific pattern that failed in every historical case researched (Multics, OSI, Palladium). Domain-agnostic ambition was never the problem - policy accumulating ahead of real running code was.

**Test Strategy:**

See subtask-level test strategy; each subtask must ship with real, running, tested code in the same cycle as any formal rule it implements — never spec-only.

## Subtasks

### 6.1. Choose the first real, demanding domain and use case

**Status:** pending  
**Dependencies:** None  

DECISION NEEDED from the project owner - must be a genuine, currently-real need, not a demonstration of generality. Candidates already surfaced across this design process include a real ledger/accounting use case (TigerBeetle-style double-entry, directly informed by the extensive banking-readiness research already done) but this must be a real, owned need, not chosen for architectural symmetry.

**Details:**

Not test-strategy-applicable - this is a decision gate, not an implementation step.

### 6.2. Design and formally specify the module's own domain invariant

**Status:** pending  
**Dependencies:** None  

TigerBeetle's lesson: the invariant is domain-specific by design, not domain-agnostic - do not try to make it generalize prematurely. Give it its own conformance suite, following the mandatory-certification discipline from Task 5.5.

**Details:**

Test: the invariant cannot be violated by any sequence of valid-looking module operations.

### 6.3. Build the module's schema using Task 2.1's functorial value universe

**Status:** pending  
**Dependencies:** None  

A concrete domain schema, not the mechanism itself - built using the schema-morphism machinery, not extending it.

**Details:**

Test: schema evolution within this module is checked via the morphism mechanism, never an unchecked migration script.

### 6.4. Integrate against the Task 5 boundary and run real production-shaped load

**Status:** pending  
**Dependencies:** None  

This is the actual pressure test. Document every friction point, every place the boundary made something harder than it should have been - this record feeds directly into Task 7.

**Details:**

Test: the module operates correctly under the deterministic simulation harness from Task 3.4, including injected node failures.
