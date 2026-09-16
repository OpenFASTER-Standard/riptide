# Task ID: 9

**Title:** Client-facing API layer

**Status:** pending

**Dependencies:** 6

**Priority:** medium

**Description:** Generate a GraphQL-shaped query surface and protobuf-style versioned command surface directly from the functorial schema, exposing only materialized/lattice-projected views - never the raw log.

**Details:**

Deferred until Task 6 gives it a real schema to generate against - building this earlier means designing against imagined data shapes. Mirrors the proven EventStoreDB/Marten/Axon pattern (event log to projection to conventional queryable store to REST/GraphQL layer) and Kubernetes' own OpenAPI-generated-from-types-plus-mandatory-conformance-suite discipline, applied one layer up from Layer 0's own SpecTec-style pattern.

**Test Strategy:**

See subtask-level test strategy; each subtask must ship with real, running, tested code in the same cycle as any formal rule it implements — never spec-only.

## Subtasks

### 9.1. Generate a GraphQL-shaped query surface from the functorial schema

**Status:** pending  
**Dependencies:** None  

Schema objects/fields map to GraphQL types/fields, morphisms map to resolvers - introspection and client codegen come free.

**Details:**

Test: any schema change is reflected in the generated GraphQL surface with no manual sync step.

### 9.2. Expose mutations as versioned, protobuf-style commands

**Status:** pending  
**Dependencies:** None  

Field-number-style permanent identifiers and explicit forward/backward compatibility rules for command payloads.

**Details:**

Test: an old client's command remains valid against a newer server version, and vice versa within the documented compatibility window.

### 9.3. Ensure clients only ever see materialized, lattice-projected views

**Status:** pending  
**Dependencies:** None  

Never the raw content-addressed log - matches the proven event-sourced-system client-API pattern exactly.

**Details:**

Test: no client-facing code path can read the raw log directly.

### 9.4. Make the generated API surface a mandatory conformance artifact

**Status:** pending  
**Dependencies:** None  

Kubernetes-conformance-suite style: any server implementation must pass a test suite generated from the functorial schema to claim compatibility.

**Details:**

Test: a server implementation missing any generated-surface guarantee fails the conformance suite.
