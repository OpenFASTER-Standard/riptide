# Task ID: 5

**Title:** Define the Layer 0/Layer 2 boundary - treat it as provisional

**Status:** pending

**Dependencies:** 4

**Priority:** high

**Description:** The WASM Component loading ABI, session-type protocol checking, SFI-sandbox-baseline isolation with optional microVM tier, and the mandatory admission/conformance gate. Per the ThirdPartyResources to CRD lesson, expect this to need real revision after Task 6 - that's healthy, not failure.

**Details:**

This is 'the boundary' category from the mechanism/policy analysis: a trusted, frozen CHECK-POINT whose CONTENT is pluggable. WASM Components are genuinely production-mature (2025-2026, WASI 0.3 shipped native async I/O). Isolation must be UNIFORM strong (SFI baseline everywhere, since it needs no hardware virtualization and is proven down to Cortex-M0 microcontrollers; hardware-virtualization microVM as an optional stronger tier where available) - NEVER tiered by trust level, per the corrected finding: AWS Lambda's real production philosophy is one strong boundary for everyone, and Cloudflare's trust-tiered Workers model had a real demonstrated Spectre leak as the direct cost of that shortcut.

**Test Strategy:**

See subtask-level test strategy; each subtask must ship with real, running, tested code in the same cycle as any formal rule it implements — never spec-only.

## Subtasks

### 5.1. Define the WASM Component loading ABI (WIT interfaces)

**Status:** pending  
**Dependencies:** None  

The frozen, stable surface modules plug into. Strictly downward-only dependencies enforced structurally, not by convention - the OSGi/'distributed monolith' microservices lesson: physical separation alone doesn't prevent dependency hell.

**Details:**

Test: a module cannot depend on anything not explicitly exposed through this interface.

### 5.2. Implement session-type protocol checking for module/core interaction

**Status:** pending  
**Dependencies:** None  

Local, compositional, compile-time conformance checking for message-sequencing - genuinely more practical than coalgebra/bisimulation, which even MongoDB found impractical against real running code. Session types only check sequencing safety, not business invariants - that stays a separate, Layer 2 concern.

**Details:**

Test: a module violating its declared interaction protocol is rejected at load time, not at runtime.

### 5.3. Implement uniform SFI-sandbox isolation with optional hardware-virtualization microVM tier

**Status:** pending  
**Dependencies:** None  

WASM's own software-fault-isolation is the universal baseline (proven on Cortex-M0/M3/M4 with zero virtualization silicon); hardware-virtualization microVM (Firecracker-style, AOT-compile-once-snapshot-restore-in-milliseconds) is an optional STRONGER tier used wherever hardware supports it - never a weaker tier for 'trusted' code. No module ever shares a heap with the core or with another module.

**Details:**

Test: a module that would crash the host under weaker isolation must be contained under the chosen isolation model on every supported hardware tier.

### 5.4. Implement the mandatory admission/conformance gate

**Status:** pending  
**Dependencies:** None  

OCI-artifact distribution by content digest (not mutable tag), Sigstore/cosign keyless signing, SLSA/in-toto build provenance, verified before ANY module loads - reusing wasmCloud's real, working reference pipeline for exactly this. A failing artifact never enters the log.

**Details:**

Test: an unsigned or provenance-failing artifact is rejected at the gate, not at runtime.

### 5.5. Implement the mandatory authorization decision point (mechanism only, no policy)

**Status:** pending  
**Dependencies:** None  

Every write/read passes a mandatory checkpoint, and the decision itself is a logged, causally-linked fact. The actual policy model (RBAC/ABAC/ReBAC) is Layer 2, built against this checkpoint, not baked into it - this was stated too strongly as an RBAC/ABAC mandate earlier in design; corrected here to just the checkpoint being mandatory.

**Details:**

Test: no write can bypass the checkpoint under any code path, verified by exhaustive call-site audit plus fuzzing.
