# Task ID: 7

**Title:** Revise the Layer 0/Layer 2 boundary based on real usage

**Status:** pending

**Dependencies:** 6

**Priority:** medium

**Description:** Redesign whatever Task 6 exposed as wrong or awkward in the boundary, following the ThirdPartyResources-to-CustomResourceDefinition pattern: fast, driven by real usage, not accumulated imagined requirements.

**Details:**

This is the expected, healthy version of 'the first mechanism needs revision' - not evidence of failure. Once this lands, the boundary is the thing that gets genuinely frozen; everything before this task was provisional by design.

**Test Strategy:**

See subtask-level test strategy; each subtask must ship with real, running, tested code in the same cycle as any formal rule it implements — never spec-only.

## Subtasks

### 7.1. Catalog every friction point Task 6 surfaced

**Status:** pending  
**Dependencies:** None  

A concrete list, grounded in what actually broke or was awkward while building a real module - not speculative future requirements.

**Details:**

Deliverable: a written record, not a code change.

### 7.2. Redesign the specific broken pieces of the boundary

**Status:** pending  
**Dependencies:** None  

Scoped fixes only - do not use this as an opportunity to add speculative generality for domains that don't exist yet.

**Details:**

Test: re-run Task 6's module against the revised boundary with no regression.

### 7.3. Freeze the boundary and document the freeze

**Status:** pending  
**Dependencies:** None  

Once 7.2 is verified, this boundary now gets the same 'changes require re-verification' discipline as the rest of Layer 0.

**Details:**

Deliverable: a versioned, documented boundary spec, treated as stable going forward.
