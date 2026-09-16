# Task ID: 8

**Title:** Distribution, deployment, and heterogeneous-hardware infrastructure

**Status:** pending

**Dependencies:** 7

**Priority:** medium

**Description:** OCI/cosign/SLSA supply chain, bootc-based minimal bootstrap image, SPIFFE/SPIRE pluggable attestation, the 3-tier node model, and the constrained-hardware module story - all deferred until there's a real module worth distributing at scale.

**Details:**

Building this earlier would be securing an empty building. Node tiering (consensus-voting / workload-execution-only-non-voting / pure leaf) is directly precedented by k3s's server/agent split and Raft's own formal 'learner' node concept - a genuinely different axis from trust-based isolation tiering, which was explicitly rejected. Attestation must be pluggable (SPIFFE/SPIRE, TPM where available, join-token fallback elsewhere, honestly labeled as a weaker trust tier) since TPM coverage is real but not universal, especially on Pi-Zero-class and industrial/embedded hardware.

**Test Strategy:**

See subtask-level test strategy; each subtask must ship with real, running, tested code in the same cycle as any formal rule it implements — never spec-only.

## Subtasks

### 8.8.1. Build the bootc-based minimal immutable bootstrap image

**Status:** pending  
**Dependencies:** None  

Kernel + systemd + WASM-component-capable runtime + a tiny bootstrap agent, nothing else mutable - mirrors what a real Kubernetes node has baked in before everything else arrives as a pulled workload.

**Details:**

Test: the image boots and joins the control-plane consensus group with zero manual configuration.

### 8.8.2. Wire the OCI + cosign + SLSA supply-chain pipeline

**Status:** pending  
**Dependencies:** None  

Reuse wasmCloud's real, working reference wiring for WASM components specifically, rather than re-deriving it.

**Details:**

Test: an artifact missing any part of the chain (digest, signature, provenance) is refused by the admission gate from Task 5.4.

### 8.8.3. Implement SPIFFE/SPIRE pluggable node attestation

**Status:** pending  
**Dependencies:** None  

TPM/vTPM plugin where available, cloud-instance-identity plugins for cloud VMs, join-token fallback for bare metal/ICS/embedded hardware with no hardware root - explicitly label the join-token tier as weaker trust, not equivalent.

**Details:**

Test: a node attested via each available plugin type receives a correctly-scoped workload identity credential.

### 8.8.4. Implement the 3-tier node model with separate control-plane consensus group

**Status:** pending  
**Dependencies:** None  

Tier 1 (voting, control-plane-capable) / Tier 2 (workload-execution-only, non-voting, Raft learner) / Tier 3 (pure leaf, no code execution). Control-plane state lives in its OWN consensus group (same underlying code, separate instance from domain-data groups), coupled to the data log by an epoch-barrier reference, not shared consensus - avoiding etcd's well-documented single-Raft-leader scaling ceiling and the real blast-radius incidents (e.g. OpenAI's Dec 2024 outage) from coupling control-plane and data-plane state.

**Details:**

Test: a Tier 1 outage does not prevent Tier 2/3 nodes from continuing to serve already-committed data; a data-plane overload does not strand the control plane's ability to reconfigure.

### 8.8.5. Build the constrained-hardware (Pi-Zero-class) module deployment path

**Status:** pending  
**Dependencies:** None  

Componentize normally with full WIT/Component Model rigor on capable build infrastructure, then for Tier 2/3 targets: `wasm-tools component unbundle` + generated Canonical-ABI-lowering glue + Binaryen `wasm-merge`, producing one flat core-WASM module runnable on WAMR/wasm3 with no Component-Model-aware runtime needed on-device. Distribute through the same OCI/cosign/SLSA pipeline unchanged - OCI already has a distinct media type for plain core modules.

**Details:**

Test: a flattened module built this way passes the same admission gate and runs correctly on a genuinely constrained target (Cortex-M-class or Pi-Zero-class hardware).
