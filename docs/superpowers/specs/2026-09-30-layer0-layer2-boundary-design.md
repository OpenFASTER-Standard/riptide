# Layer 0/Layer 2 boundary: a real, running, provisional admission/isolation/ABI boundary for pluggable modules

Design spec for task-master task 5 ("Define the Layer 0/Layer 2 boundary — treat it as
provisional"), covering all five of its subtasks as one coherent design, per this session's
brainstorm. This document is the argument; the implementation plan and running code that follow
it are the authority, per `CLAUDE.md`'s "no spec without running code" rule.

## Context

Task 5 is explicitly provisional: its own description says to expect real revision after Task 6
builds the first actual Layer 2 module against this boundary — "that's healthy, not failure," per
the ThirdPartyResources→CustomResourceDefinitions precedent this project's own `CLAUDE.md` cites.
Nothing in this spec should be read as a permanent commitment; several decisions below name their
own disclosed, honest scope limits rather than pretending to a completeness the underlying tooling
doesn't actually have yet.

Dependencies (both satisfied): Task 4 (lattice merge-law contract) and Task 12 (Layer 0 hardening,
merged 2026-09-30).

Two things fall under `CLAUDE.md`'s "small, aligned governance for Layer 0" rule and are named here
rather than decided unilaterally: Decision 1 (the execution model — whether module logic is
replicated or not) and Decision 7 (the authorization checkpoint, which touches the already-hardened
`Batch_commit`/`propose` path).

Every opam-availability claim below was checked live against this box's own OCaml toolchain
(`opam search`/`opam show`) during the brainstorm that produced this spec, not assumed from
general knowledge — see each Decision's own "Verified" note.

## Decision 1: modules execute outside consensus, reacting to materialized state

**Two models were considered.** *Inside consensus*: every replica re-executes a module
deterministically on every committed entry, like a smart-contract VM (Ethereum's EVM, CosmWasm) —
the module's own logic becomes part of what replicas agree on, requiring strict determinism (no
floats that diverge across CPUs, no wall-clock reads, no real I/O, no unseeded randomness) and
N-way re-execution cost. *Outside consensus, reacting*: a module runs on one node, reads
already-agreed materialized state, and — if it wants an effect — calls back through the existing
`propose` path, the same one every client already uses.

**Chosen: outside consensus, reacting.** Three reasons: it matches every real-world reference this
task's own subtask descriptions already cite (wasmCloud, AWS Lambda, Cloudflare Workers — all
reactive/serverless, none a replicated VM); it imposes no new determinism requirement on module
code, because safety comes from VSR's existing quorum on whatever a module proposes back, not from
N replicas agreeing on the module's own execution; and it avoids duplicating a mechanism Layer 0
already has — Task 4's lattice/materializer is already riptide's deterministic-replicated-
computation path. A second "deterministic WASM VM" pathway would be a second, less-integrated
implementation of the same idea.

## Decision 2: modules are triggered by materialized state changes, not raw commits

Riptide separates two layers of "settled" data: raw VSR-committed envelopes (an ordered,
append-only log — `Replica`'s `?on_event` hook, added by Task 34, observes this layer) and
materialized state (the lattice's merged output per `merge_key`, which can coalesce several
commits into one visible change).

**Chosen: materialized state changes.** A module subscribes to a `merge_key` and is invoked when
that key's *merged* value changes — the same output the `Materializer` itself already produces.
This is the natural read surface for business logic ("react to the current state of X"), and
avoids pushing merge/coalescing logic into every module that needs current state, which reacting to
raw commits would require.

## Decision 3 (subtask 1): a real, hand-rolled module ABI on core WASM — not the Component Model

**Verified before designing, not assumed:** none of the three OCaml-accessible WASM runtimes
(`wasmtime` 0.0.3 by Laurent Mazare, `wasmer` 1.2.1, `extism` 1.4.0 — all checked via
`opam show` and their own READMEs) support the WebAssembly Component Model or WIT interfaces.
`wasmtime` and `wasmer`'s OCaml bindings are thin, hand-written FFI wrappers around core-module-only
C APIs. `extism` has its own plugin convention (PDKs / XTP IDL), explicitly not Component-Model-
based.

**Chosen: core WASM modules (via the `wasmtime` OCaml bindings — the more minimal, directly-
Wasmtime-backed option) plus riptide's own versioned, hand-rolled calling convention**, in the same
style this codebase already uses for `Message.encode`/`Value`'s canonical encoding rather than
reaching for a heavier framework. A new library, `Riptide_module`, exposes a small, fixed host-
function surface to the guest:

```ocaml
val read_materialized : merge_key:string -> bytes option
val propose_write : bytes -> propose_result
val log : string -> unit
(* extended only as Task 6's real module reveals real needs *)
```

Nothing else is reachable from guest code — WASM's own import model makes "downward-only
dependencies" structural, not conventional: a module cannot call anything not explicitly imported,
full stop.

**Disclosed exception, not a silent downgrade:** true WIT/Component-Model compliance is a real,
named future upgrade path once OCaml tooling for it exists (or riptide chooses to invest in
building it), not something this task claims to deliver. The alternatives considered and rejected —
writing new Component-Model FFI stubs ourselves, or standing up a sidecar process to host a
Rust-level Wasmtime with real Component Model support — are both substantial, standalone projects
better justified by real usage from Task 6 than built speculatively against a boundary this task's
own text already expects to revise.

## Decision 4 (subtask 2): session-type checking via a hand-rolled per-module state machine

**Verified before designing:** real OCaml session-type tooling exists — `nuscr` (v2.1.1, actively
maintained, real OCaml code generation), built on classical multiparty session type theory
(global protocols, projected to per-role local protocols, compiled to CFSMs).

**Chosen: a hand-rolled finite-state-machine validator, not `nuscr`.** `nuscr` is sized for
multiparty protocols (several roles negotiating a global protocol); task 5 only ever has two
parties — one module, one host. Each module declares its own valid call sequence as an explicit
state machine alongside its ABI manifest (e.g. "`init` before `handle`," "no concurrent
`propose_write`"). The loader validates a module's declared automaton is well-formed before
instantiation, and enforces it at every host-function call at runtime — checked twice, load time
and call time, mirroring the "check, don't trust" convention `Sender_mismatch`/
`Committed_prefix_mismatch` already establish elsewhere in this codebase. Session types here check
sequencing safety only, never business invariants — those stay a Layer 2 concern, per the task's
own description.

## Decision 5 (subtask 3): uniform SFI isolation, built now; microVM tier designed, not built

**The gap:** subtask 3 asks for an optional hardware-virtualization microVM tier (Firecracker-
style) alongside a mandatory SFI baseline. Riptide has no deployment/runtime environment defined
at all yet — no `bin/` entrypoint, no known target OS or hypervisor (that's Task 8, still pending).

**Chosen: build the SFI baseline for real now (one fresh WASM instance per invocation — no
instance is reused across invocations, removing any stale-state-between-invocations question by
construction; pooling is a possible later performance optimization, not part of this decision;
separate linear memory; wasmtime's own fuel/memory resource limits); design, but do not build, the
microVM tier.** The microVM tier's real
interface/contract is written into this spec (below) so Task 8 has a concrete target to build
against once a real deployment environment exists, rather than either skipping it entirely or
building Firecracker integration against a stand-in environment that isn't riptide's actual target.

**Microvm tier contract (for Task 8 to implement against):** a `Riptide_module.Isolation_tier`
variant (`Sfi | Microvm`) selected per module at admission time (subtask 4); `Microvm` wraps the
same host-function ABI (Decision 3) behind a real VM boundary (Firecracker-style: AOT-compile-once,
snapshot-restore in milliseconds) instead of WASM's own sandboxing; never a *weaker* tier for
"trusted" code — SFI is always at least as strong a baseline, matching AWS Lambda's real production
philosophy over Cloudflare Workers' trust-tiered model (which had a real, demonstrated Spectre leak
as the direct cost of that shortcut). No module ever shares a heap with the core or another module,
under either tier.

## Decision 6 (subtask 4): admission gate shells out to real, audited tooling

**Verified before designing:** no OCaml library exists for Sigstore, cosign, OCI registry
operations, in-toto, or SLSA (`opam search` returned zero matches for all five). Unlike Decision 3,
this is a security-critical verification surface, not a project-owned convention.

**Chosen: shell out to the real, official `cosign` binary** (signature verification via
`cosign verify`, provenance verification via `cosign verify-attestation` against SLSA/in-toto
attestations) as a subprocess, checking its exit code and parsed output — never hand-rolled
cryptographic or attestation-verification logic in OCaml. "Don't roll your own crypto" applies
here in a way it doesn't for Decision 3's ABI, which is inherently project-specific and safe to
own directly. Modules are distributed as OCI artifacts addressed by content digest, never a
mutable tag. A failing artifact — unsigned, tampered, or missing valid provenance — never enters
the log and never reaches the loader. A module's isolation tier (Decision 5's `Sfi | Microvm`) is
recorded as part of admission — the gate is the one place that durably decides which tier a given
module's artifact runs under, so Decision 5's loader has a single source of truth to read rather
than a second, independent configuration surface.

## Decision 7 (subtask 5): a universal authorization checkpoint inside the existing write path

Every write — module-originated (via Decision 1's `propose_write`) and ordinary client-originated
alike — passes through one mandatory checkpoint, placed inside `Batch_commit`'s shared `propose`
path rather than as a separate wrapper around only the new module-facing ABI. This matches the
task's own literal wording ("every write/read passes a mandatory checkpoint") and avoids a
two-tier system where module writes are checked but pre-existing client writes aren't.

The checkpoint's decision is itself a logged, causally-linked fact — a new envelope in riptide's
own content-addressed event log, not a side-channel record. This is **mechanism only**: the actual
policy model (RBAC/ABAC/ReBAC) is explicitly Layer 2's problem, implemented against this checkpoint
by a future module or core extension, never baked into Layer 0 itself.

A denial extends the *existing* classified-refusal pattern (`Replica.append_refusal`'s five shapes,
from Tasks 3/12/34) rather than inventing a new refusal convention — `propose` already has an
established, tested vocabulary for "this write did not happen, and here is precisely why."

## Data flow (end to end)

`Materializer` merges committed values for `merge_key K` → produces new materialized state → a new
reactor dispatch loop, one per module subscribed to `K`, spins up a fresh sandboxed WASM instance
(Decision 5) and invokes the module's `handle` entrypoint (Decision 3's ABI) with the new bytes →
the module may call `propose_write` → the call is checked against the module's declared session
type (Decision 4) → the real `Batch_commit.propose` runs → the new universal authorization
checkpoint (Decision 7) decides → normal VSR quorum replication (unchanged, already hardened by
Task 12) → committed → re-materialized → may re-trigger the same or other subscribed modules.

Before any of this: the module's own artifact passed the admission gate (Decision 6) at
install/deploy time, not at every invocation.

## Error handling

- A trapped or crashed module (out-of-bounds access, fuel exhausted) is caught at the host
  boundary by wasmtime's own trap mechanism. It never crashes Layer 0; it is logged via a new
  event variant on `?on_event` (Task 34's hook).
- A session-type violation is a safe rejection, at load time or call time — the same
  "guard failure ⇒ total no-op" convention `replica.ml` already uses throughout.
- An admission-gate failure means the artifact never loads; nothing about it enters any log.
- An authorization denial makes `propose` return a refusal via the existing classified-refusal
  vocabulary, not a new one.

## Testing strategy

Per `CLAUDE.md`'s "no spec without running code" rule, every decision above ships with real,
running tests in the same change that introduces it — not a spec-only rule anywhere in this
document:

- **ABI (Decision 3):** a real toy WASM guest (hand-written `.wat`, or compiled from a minimal
  Rust/C guest) exercises `read_materialized`/`propose_write`/`log` end to end through a real
  `wasmtime` instance.
- **Session types (Decision 4):** a module that violates its own declared protocol is rejected,
  at load time and mid-run; a module that follows its protocol succeeds. Both driven through real
  instantiation, not a unit test of the automaton in isolation.
- **Isolation (Decision 5):** a module that deliberately loops forever or overruns its own memory
  is contained — doesn't crash the host, doesn't touch another module's or the core's memory,
  triggers fuel exhaustion or a trap as designed.
- **Admission gate (Decision 6):** a real signed, provenance-valid artifact passes; a tampered or
  unsigned one is rejected — via real `cosign` subprocess invocations. **Open question, named
  rather than silently decided:** whether CI runs against a live Sigstore/Fulcio/Rekor instance or
  a documented local stand-in; resolve this in the implementation plan once cosign's own testing
  conventions are checked, not assumed here.
- **Authorization checkpoint (Decision 7):** an exhaustive call-site audit (grep-based, in the
  style `scripts/check-citations` already established this session for a different invariant)
  plus fuzzing, proving no write can bypass the checkpoint under any code path — exactly the
  task's own stated test strategy for this subtask.

## Non-goals (explicitly out of scope for this task)

- Any actual policy model (RBAC/ABAC/ReBAC) built against the Decision 7 checkpoint — Layer 2's
  problem, not this boundary's.
- Building the microVM tier's real Firecracker integration (Decision 5) — deferred to Task 8,
  which owns the deployment environment it needs to target.
- True WebAssembly Component Model/WIT compliance (Decision 3) — deferred until OCaml tooling
  exists or a dedicated investment is justified by real usage.
- Multi-language guest support beyond "anything that compiles to core WASM" — no PDK-style
  multi-SDK convenience layer is being built.
