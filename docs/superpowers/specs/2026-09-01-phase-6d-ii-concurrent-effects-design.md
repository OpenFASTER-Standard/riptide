# Concurrent-Effects Coordination — Design

**Status:** Draft, first revision. Implements Sub-project 6, phase **6d-ii**
(Track D — design spike). Parent spec:
`docs/superpowers/specs/2026-08-27-derivation-and-execution-layer-design.md`
(§4 — Capability; §7 — 6d-ii's own roadmap entry; §8.8 — "ExecuteInterpretation
concurrency has no equivalent answer (6d-ii)"; §10 — "still open... real design
work this project owes directly, not a literature gap a further research pass
would close"). Research trail:
`docs/superpowers/specs/2026-08-27-derivation-and-execution-layer-research-log.md`
Part 4. **This document itself is the deliverable — 6d-ii's exit criterion is a
written design decision, not code.**

## 1. Scope

Per the parent spec's §7 entry and issue #65: coordinating concurrent
`ExecuteInterpretation`s over overlapping, irreversible external resources.

**Exit criterion:** a written design decision (not a test) for how concurrent,
overlapping EffectCapability invocations are coordinated.

**Depends on:** 6b-i (EffectCapability semantics — shipped). Benefits from,
but isn't blocked on, 6d-i's concrete wiring; both are shipped as of this
writing, which is what makes this design concrete rather than speculative.

**Why now, not later:** this phase was scoped as a low-dependency design
spike, schedulable any time after 6b-i. It's written now because 6l (Reactive
Job-Triggering, shipped 2026-08-31) made the risk this phase addresses a live
production path rather than a hypothetical: whichever node is the Ra leader of
a Job's own stream independently executes it, so two different Job streams,
owned by two different leader nodes, can invoke overlapping or conflicting
EffectCapabilities fully concurrently today, with zero coordination.

## 2. Problem statement

A **Capability** (parent spec §4) is an opaque, sandboxed WASI component.
Riptide invokes it (`Riptide.Capability.invoke/4`) but has no visibility into
what it does internally, or what external resource(s) it actually touches —
that's inside the component, not statically knowable by the host. Three call
sites in the current codebase invoke Capabilities and could race each other
against the same real-world resource:

- `Riptide.Derivation.JobTrigger.execute/3` — a `jobCapability` Job, invoked
  directly.
- `Riptide.Derivation.ExecuteInterpreter.call_template/3` — a `jobRule` Job's
  Rule body, resolved and invoked via `ContextResolver`; dispatched from
  within `JobTrigger`'s own execution path (same `Task.Supervisor`, same
  node).
- `Riptide.Derivation.GeneralizationFidelity` — re-invokes a real
  EffectCapability during DedupGate's `Admit` path (6e-ii), to compare
  against a recorded Trace. Triggered by an HTTP-driven Catalog-review
  action, not by `JobTrigger` — a genuinely separate call path, potentially
  on a different node.

**Failure scenario this design prevents:** two Jobs for the same Tenant,
targeting the same real-world resource (e.g. both invoking a
`restart-payments-service` Capability against the literal same service, or
both invoking a `charge-customer` Capability against the literal same
customer), land on Ra leaders of two different streams (or one lands via
`JobTrigger`, the other via a concurrent `GeneralizationFidelity` replay) and
execute concurrently — a real, irreversible double-effect with no way to
compensate after the fact, since sagas' compensation model doesn't apply to
externally opaque effects (research log Part 4) and there's no transactional
rollback across a real external system.

**Required guarantee, per direct instruction during brainstorming:** hard and
load-bearing — not a soft mitigation (idempotency, monitoring, "usually
fine"). Two concurrent invocations against the same declared resource must
never both execute.

## 3. Key research findings (full detail: research log Part 4)

- **Sagas are the wrong tool category, provably, not just "checked
  informally."** Garcia-Molina & Salem's own definition requires a saga's
  sub-transactions to be interleavable with other transactions — permitting
  concurrency is the design goal, not a gap.
- **CRDTs don't apply**, because their correctness is defined in terms of
  operations proven to commute, and Capabilities are opaque — commutativity
  can't be established. The one adjacent technique found (LSCRDT, handling
  non-commutative ops via total log order) requires rollback-and-replay on
  conflict, incompatible with irreversible external effects.
- **Idempotency keys solve a different, narrower problem** — safe retry of
  the *same* request, not mutual exclusion between *different* concurrent
  requests. Confirmed via Stripe's own key-to-payload binding and an
  independent Temporal blog post demonstrating the exact race idempotency
  alone leaves open.
- **Distributed locks layered on existing Raft consensus are real,
  precedented** (etcd's `concurrency` package on top of etcd's own Raft-backed
  store) — directly transferable to `:ra`, though (§4 below) the recommended
  design doesn't end up needing an explicit lock object.
- **Fencing tokens patch a specific failure mode — a paused lock holder
  waking up and acting after its lease expired — that requires the protected
  resource to cooperate by checking the token.** Riptide's Capabilities are
  external and can't be made to do that. This is a real limitation of any
  "acquire lock, then separately invoke the effect" design, and motivates
  finding a design where that two-step separation doesn't exist.
- **Temporal and Argo Workflows solve this exact problem in production**, via
  a caller-supplied resource/workflow identity that the orchestrator enforces
  exclusivity over — Temporal's real guarantee (corrected during adversarial
  verification — the *default* reuse policy is `ALLOW_DUPLICATE`, not
  `REJECT_DUPLICATE`) is that at most one Workflow Execution with a given
  Workflow Id is ever open at a time, unconditionally. Confirms: resource
  identity must be caller-supplied, not inferred from or declared by the
  Capability itself.
- **Akka Cluster Sharding is the closest architectural analogue** (at most
  one actor instance per entity id, cluster-wide) — but its guarantee is
  conditional on the operator choosing a safe cluster-downing strategy;
  documented unsafe windows exist under partition/long-GC-pause with a bad
  one. `:ra`'s Raft implementation doesn't share this weakness — a leader
  requires an actual quorum majority, so split-brain is structurally
  impossible rather than avoided by correct configuration.

## 4. Design decision

**Route every effectful, resource-key-bearing Capability invocation through
the Tenant's existing Job-stream Ra leader, and make resource-key exclusion a
purely local, in-memory concern of the already-running `JobTrigger` process.
No new Ra cluster, no claim/CAS row, no lock, no lease, no fencing token.**

### 4.1 Why this, and not a new coordination primitive

All of a Tenant's Jobs — regardless of which Capability or resource they
target — already live as Facts on that Tenant's single Job stream
(`Riptide.Derivation.Catalog.job_stream_id/1`). 6l's `JobTrigger` already
guarantees exactly one node in the cluster — whichever is currently that
stream's Ra leader — executes Jobs for that Tenant at any moment
(`Riptide.RaCluster.stream_leader?/1`). That property isn't something this
design adds; it's a fact 6l already established for a different reason (who
executes a Job at all), which happens to be exactly the granularity
resource-key exclusion needs: two Jobs for the same Tenant targeting the same
resource are *already* guaranteed to be evaluated by the same single process
before either executes, no matter how far apart in time they were written or
which node originally received them.

Given that, resource-key exclusion doesn't need a distributed primitive at
all. It reduces to: `JobTrigger` keeps a `MapSet` of resource keys currently
in flight, in its own `GenServer` state. Before executing a Job that declares
one, it checks the set; if occupied, it skips the Job this sweep and retries
on the next — the same self-healing retry loop 6l's `periodic_sweep` already
runs for every other transient condition, no new retry mechanism needed.

This strictly dominates every alternative considered (full comparison,
research log Part 4):

- **vs. a CAS+TTL claim in `Riptide.Placement.PlacementMachine`** (the
  natural first instinct, mirroring `ReplicaHealer`'s existing repair-claim):
  no lease-expiry window, no fencing-token gap — there's no lock object that
  can go stale, since "am I still the leader" is checked directly and `:ra`
  can't split-brain. Leaked state self-heals for free: a durable claim that's
  never released needs an explicit TTL and cleanup path; in-memory state
  vanishes the instant the process restarts or loses leadership, for any
  reason, with no cleanup code required.
- **vs. a dedicated Ra cluster per resource key**: no cardinality problem.
  A per-resource Ra cluster is fine at dozens of keys and a real
  infrastructure cost at high cardinality (e.g. one key per customer). This
  design adds zero new Ra clusters at any cardinality.
- **vs. an etcd/Redlock-style external lock**: those need fencing tokens
  specifically because the lock and the resource are decoupled — a paused
  holder can wake up and act after losing the lock. Here there's no "acting
  after losing the lock" possible: the code that invokes the Capability only
  ever runs *as a direct consequence of currently being the leader*, on the
  same process holding the in-memory state. There's no window for a stale
  holder to act, because there's no separate lock-then-act step to begin
  with.

### 4.2 Scope of the guarantee: why it has to cover all three call sites

Two separate in-memory sets, in two separate processes, can never jointly
guarantee mutual exclusion — nothing forces them onto the same node. So the
guarantee holding at all requires every call site that needs it to share one
point of truth, which means every one of them has to route through the same
Tenant's Job-stream leader:

- `JobTrigger`'s own `jobCapability` and `jobRule` paths already do — both
  dispatch through `JobTrigger`'s `Task.Supervisor.start_child/2` on the same
  node as the `GenServer` holding the in-flight set.
- `GeneralizationFidelity`'s replay currently calls `Capability.invoke/4`
  directly (`lib/riptide/derivation/generalization_fidelity.ex:84`),
  bypassing `JobTrigger` entirely. **This must change**: a fidelity replay
  that declares a resource key needs to be submitted through the same
  per-Tenant Job stream — as a new Job "kind" (e.g. `{:fidelity_replay,
  capability_iri, trace_id}` alongside the existing `{:capability, iri} |
  {:rule, iri}` reference type) rather than invoked inline — so that
  `JobTrigger`, not the DedupGate HTTP handler, is the one that actually
  calls `Capability.invoke/4` and checks the in-flight set first. This is a
  real change to 6e-ii's already-shipped implementation, not free, but it's
  the same mechanism extended uniformly rather than a bespoke second
  mechanism for one call site.

### 4.3 Resource identity: caller-supplied, Tenant-scoped

Per the Temporal/Argo precedent (§3): resource identity comes from the
caller, not from the Capability. Concretely, `Riptide.Derivation.Job` gains
an optional field — `resource_key: String.t() | nil` — set by whoever writes
the Job (a Rule author, an operator, or `GeneralizationFidelity`'s own
replay-submission code). A Job with `resource_key: nil` is never subject to
this coordination at all (most Jobs won't declare one — this is opt-in for
Capabilities whose author/caller knows they touch something exclusive, not a
default tax on every invocation).

The key is implicitly scoped to `{tenant_id, resource_key}`, not global —
this isn't a limitation being imposed, it's a consequence already forced by
Capabilities themselves being Tenant-scoped grants (parent spec §4): there is
no notion anywhere in the existing type system of "the same resource" shared
across two Tenants, since each Tenant's Capabilities are separately
registered and separately authorized. A coordination layer can't serialize
access to something it has no way to know is shared, and neither can any
system researched here — Temporal and Argo only coordinate within what the
caller declares. Genuine cross-Tenant sharing of one real external resource
(e.g. two Tenants' Capabilities both happening to hit the same underlying
payment-processor account) is an operational/deployment concern outside
Riptide's own visibility, not something addressable by a Riptide-internal
mechanism without omniscient knowledge of what's outside the system.

### 4.4 Correctness argument

1. At most one node is ever the Ra leader of a given Tenant's Job stream at a
   time — Raft's own quorum-election guarantee, not something this design
   adds.
2. Every resource-key-bearing effectful invocation for that Tenant — from all
   three call sites, per §4.2 — is dispatched only from that leader's own
   `JobTrigger` process.
3. Within that single process, "at most one invocation per resource key" is
   checked against ordinary local state before dispatch, and is therefore
   trivially correct for as long as the process remains the leader.
4. The moment it stops being the leader (crash, restart, planned failover),
   its in-memory state — including anything "in flight" — ceases to matter:
   the new leader starts with an empty set. A Job that was genuinely mid-
   invocation when the old leader died gets re-attempted by the new one, on
   the next sweep. This is not a new failure mode: it's the same
   at-least-once (not exactly-once) contract 6l's Job execution already
   documents and already accepts for every Job, resource-key or not.

### 4.5 Required implementation detail: crash-safe cleanup

`JobTrigger` dispatches invocations via `Task.Supervisor.start_child/2`
(6l). For the in-flight set to stay correct, removal from it must not depend
on the Task returning normally — an abnormal exit (a raised exception inside
the Task, not a controlled `{:error, _}` return) still has to free the
resource key. The implementer should `Process.monitor/1` each dispatched
Task and remove its resource key from the set on the corresponding
`{:DOWN, ...}` message, regardless of exit reason — not only on the Task's
own return value. This is a correctness requirement for the implementation
plan, not a gap in this design: an unmonitored crash-path leak would
permanently and incorrectly block that resource key until the leader itself
restarted.

## 5. Explicitly out of scope / residual limits

- **Cross-Tenant resource sharing.** Per §4.3 — not a gap in this design,
  a boundary forced by Capabilities already being Tenant-scoped. If a future
  need for genuine cross-Tenant resource coordination emerges, it would need
  its own explicit resource-registration mechanism (Capability authors or
  operators declaring a shared external identity) — out of scope here.
- **Exactly-once execution.** This design gives hard mutual exclusion
  between *concurrent* invocations; it does not upgrade 6l's existing
  at-least-once Job-execution contract to exactly-once (§4.4). A Capability
  invocation could still, in principle, execute twice across a leader
  failover, exactly as any Job can today — resource-key exclusion prevents
  two *concurrent* executions, not a retried one after a crash. Capability
  authors for whom this matters should still use their own idempotency keys
  (research log Part 4) as a complementary layer; this design doesn't
  preclude or replace that.
- **`GeneralizationFidelity`'s refactor cost.** §4.2 requires a real change
  to already-shipped 6e-ii code (routing replay through `JobTrigger` instead
  of invoking directly) — left as a concrete task for the implementation
  plan, not designed in full code-level detail here.
- **Non-Job-triggered invocation paths that don't yet exist.** If a future
  phase adds another way to invoke a Capability outside `JobTrigger`/
  `GeneralizationFidelity`, it inherits the same obligation from §4.2: route
  through the Tenant's Job stream if it needs this guarantee, or explicitly
  accept it doesn't participate.

## 6. Exit criterion (from parent spec §7, restated)

Met by this document: a written design decision for how concurrent,
overlapping EffectCapability invocations are coordinated (§4), grounded in a
real research pass (§3, research log Part 4) rather than the parent spec's
original informal note, with an explicit correctness argument (§4.4) and
stated residual limits (§5) rather than an implied completeness this design
doesn't actually have.
