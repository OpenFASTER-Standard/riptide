# Phase 6l — Reactive Job-Triggering

## 1. Context and motivation

Sub-project 6 (Derivation and execution layer) is being built phase-by-phase against
`docs/superpowers/specs/2026-08-27-derivation-and-execution-layer-design.md`. This phase implements
**6l — reactive Job-triggering** ("a write triggers computation"): writing an explicit, narrow "please
run this Capability/Rule with these args" Fact reliably causes it to actually run, with its result
written back as another Fact — closing the loop the original `examples/` walking-skeleton motivation
needed (a concrete `restart-payments-service` action, triggered by a write, not invoked by hand).
Depends on **6k** (Dynamic Capability Registration), which this phase's own Job execution resolves
Capabilities through.

This phase deliberately narrows "a write triggers computation" to explicit Job Facts only — not "any
Fact write matching any Rule's own `FactPattern` conditions auto-fires that Rule," which would be a
full forward-chaining/production-rule engine (cascading triggers, termination/ordering/storm concerns)
and is out of scope (§3).

## 2. Scope

- A `Job` Fact vocabulary: an explicit request to invoke a specific Capability or Rule (by IRI) with
  concrete args, living in the requesting tenant's own stream (§5).
- A leader-based execution-ownership mechanism requiring **no new Ra cluster, no CAS, no TTL** —
  whichever node is currently the Ra leader of a Job's own stream is that Job's sole executor,
  discovered via the previously-unused `:ra_leaderboard` primitive the `:ra` dependency already
  ships (§4).
- `Riptide.Derivation.ContextResolver`: builds an `ExecuteInterpreter.Context` for a `jobRule` Job by
  transitively resolving its Rule body's Capability/Rule IRI references through 6k's
  `CapabilityCatalog` and the existing Rule `Catalog`, with cycle detection (§6).
- A trigger worker (reactive PubSub trigger + periodic self-healing sweep, execution isolated into a
  spawned child) that claims nothing: a `jobCapability` Job resolves and invokes directly (6k's
  `materialize/1` + the unmodified `Capability.invoke/4`, no interpreter involved); a `jobRule` Job
  resolves a `Context` and invokes via the unmodified `ExecuteInterpreter.call_template/3`. Either way
  the result is written back as an ordinary Fact (§7).
- `Riptide.PeriodicSweep`: a shared GenServer scaffolding extracted from `ReplicaHealer`'s and
  `BlobStore.Healer`'s identical boilerplate, now that this phase's own worker needs the same shape a
  third time — retrofitted onto both existing consumers to eliminate the duplication entirely, not
  just avoid adding a third copy of it (§8).

## 3. Out of scope

- "Any Fact write matching any Rule's `FactPattern` triggers that Rule" — a full production-rule
  engine. Named explicitly and rejected during brainstorming: every node would need to evaluate every
  Rule against every write, and a Rule's own output write triggering another Rule raises real
  termination/ordering/storm problems this phase's narrow, explicit-Job scope avoids entirely.
- Any change to `Riptide.Derivation.ExecuteInterpreter` itself. `Context.capabilities`/`rules` stay
  the same plain, pre-resolved maps every existing call site (`llm_fallback.ex`, every test) already
  builds by hand; `ContextResolver` is a new, separate, optional helper the trigger worker uses, not a
  change to how `Context` or `call_template/3` work.
- Retrofitting `llm_fallback.ex` (or any other existing `Context`-building call site) onto
  `ContextResolver`. It's designed to be adoptable there later without a redesign, but doing so is
  unrelated to this phase's own goal and stays out of scope.
- Bounding concurrent Job executions (e.g. a `max_children` cap on the execution supervisor). A real
  operational knob eventually, not required by this phase's own exit criterion — YAGNI until a real
  throughput problem is observed.
- Exactly-once execution semantics. This phase is at-least-once, same as every claim/leadership-based
  design in this codebase (`ReplicaHealer`'s own TTL-based claim has the identical property) — named
  explicitly as an accepted trade-off, not solved (§9).

## 4. The leader-based ownership mechanism

`Riptide.Placement.PlacementMachine.claim_repair/2`'s CAS+TTL claim exists because stream *repair*
coordinates a stream that might itself be broken (no working quorum) — the coordinating cluster
(placement) must be a *different*, healthy cluster from the thing being repaired. Job execution has no
such problem: a Job Fact, by definition, just succeeded through its *own* stream's Ra consensus,
proof that stream's leadership is healthy right now. So Job-execution ownership needs no separate
claim mechanism at all — **whichever node is currently that stream's own Ra leader is the executor**.

```elixir
# Riptide.RaCluster — new function, generalizing the shape of
# RaCluster.Placement.placement_leader?/0 to an arbitrary stream.
@spec stream_leader?(String.t()) :: boolean()
def stream_leader?(stream_id) do
  cluster_name = String.to_atom(uid_for(stream_id) <> "_cluster")

  case :ra_leaderboard.lookup_leader(cluster_name) do
    {_name, leader_node} -> leader_node == node()
    :undefined -> false
  end
end
```

`:ra_leaderboard` (`deps/ra/src/ra_leaderboard.erl`) is a plain, public ETS table every local Ra server
process keeps current on every leadership/membership change — `lookup_leader/1` is an `ets:lookup/2`,
not a consensus round-trip, cheaper even than `placement_leader?/0`'s own existing `:ra.members/1`
call. Riptide doesn't use this module yet; wiring it up is new but the primitive itself is not.

On the current leader crashing mid-execution: Ra re-elects a new leader for that stream via its normal
election timeout (the same mechanism that already handles this for every other stream in the fleet);
the new leader's own trigger worker (§7) notices the still-pending Job via its periodic sweep and
re-executes it. This is the same at-least-once/idempotency contract `ReplicaHealer`'s own TTL-expiry
already has (§3, §9) — not a new failure mode introduced by dropping the claim mechanism.

**Accepted trade-off:** Jobs on the same stream execute sequentially, one at a time, by whichever node
currently leads it — no intra-stream parallelism. Cross-stream/cross-tenant parallelism is preserved
(leadership is already spread across the fleet by `Placement`). For operational actions naturally
scoped to one tenant's own stream, this is a feature (no two concurrent, conflicting
`restart-payments-service` runs for the same tenant) rather than a limitation.

## 5. Job Fact vocabulary

A Job lives in the requesting tenant's own dedicated stream, `job_stream_id(tenant_id)` (deterministic
suffix naming, matching `pending_review_stream_id/1`'s/`crosswalk_stream_id/0`'s own established
pattern: `"https://riptide.example/tenants/#{tenant_id}/jobs"`), created lazily on first write, same
as every other Sub-project 6 stream. Each Job is its own node (`urn:riptide:vocab:Job`) with:

- `urn:riptide:vocab:jobStatus` — `pending` / `done` / `failed`.
- Exactly one of `urn:riptide:vocab:jobCapability` (a `CapabilityReference`-shaped IRI, resolved
  through 6k) or `urn:riptide:vocab:jobRule` (a `RuleReference`-shaped IRI, resolved through the
  existing Rule `Catalog`).
- `urn:riptide:vocab:jobArgs` — an `RDF.List`, matching how `CapabilityReference`/`RuleReference` args
  are already list-encoded elsewhere in the codebase.
- `urn:riptide:vocab:jobGraph` — **required for a `jobRule` Job, absent for a `jobCapability` Job**:
  the `stream_id` whose current Fact state the Rule's own `FactPattern` conditions should be matched
  against. `call_template/3` takes `(Rule.t(), RDF.Graph.t(), Context.t())` — a real, materialized
  graph, not something inferable automatically (a tenant can have more than one resource stream), so
  the Job itself has to name it explicitly. A `jobCapability` Job has no `FactPattern` to match and
  needs no graph at all (§7).
- `urn:riptide:vocab:jobResult` (set only once `done`) / `urn:riptide:vocab:jobError` (set only once
  `failed`, a plain string — the invocation error or resolution failure reason).

Writing a Job is an ordinary `Patch` append (`Event.new(stream_id, :patch, %Patch{...})` via
`StreamServer.append/2`) — no new `apply/3` logic anywhere, and no codec as heavyweight as
`RuleRDFCodec`'s own reification style, since a Job has no nested `body` literal list the way a Rule
does.

## 6. `ContextResolver`

```elixir
@spec resolve(String.t(), map() | nil, RDF.IRI.t()) ::
        {:ok, ExecuteInterpreter.Context.t()} | {:error, term()}
def resolve(tenant_id, current_subject, rule_iri)
```

**Used only for `jobRule` Jobs** — a `jobCapability` Job needs no `Context`/`ExecuteInterpreter`
involvement at all (§7). Transitively walks `rule_iri`'s own `body`: a Rule can contain further
`CapabilityReference`/`RuleReference` literals (`ExecuteInterpreter.invoke_rule/4` already recurses
into them via `call_template/4` with the *same* `Context`, confirmed unchanged), so
`Context.capabilities`/`rules` must arrive pre-populated with every transitively-referenced entry, not
just the top-level one. Resolution is a depth-first walk with a per-path `visited` `MapSet` — not
global memoization — so a diamond dependency (two Rules both referencing a shared third Rule) resolves
fine, but revisiting an IRI already on the *current* path returns `{:error, {:cycle_detected, iri}}`
rather than looping forever. Each Capability reference is resolved via 6k's
`CapabilityCatalog.materialize/1` (which also handles bringing its WASM bytes locally); each Rule
reference via the existing `Catalog.list_entries/1`. A reference to a Capability/Rule IRI not found in
either catalog (never registered, still pending review, revoked) returns `{:error, {:not_found, iri}}`
— a first-class resolution failure, not a crash.

## 7. Trigger worker

```elixir
defmodule Riptide.Derivation.JobTrigger do
  use Riptide.PeriodicSweep, default_interval_ms: 30_000, interval_env_key: :job_trigger_sweep_interval_ms
  use GenServer
  ...
end
```

Two ways work is discovered:

1. **Reactive.** Writing a Job additionally broadcasts `{:job_written, stream_id}` on a single,
   fixed, well-known PubSub topic (`"riptide_jobs"`) — mirroring the existing
   `"stream_placement_changed"` broadcast's own shape (a fixed topic every interested process
   subscribes to once, not per-stream dynamic subscription management). Every `JobTrigger` instance
   subscribes to this one topic at startup; on receipt, checks `RaCluster.stream_leader?(stream_id)`
   before doing anything.
2. **Periodic sweep** (`Riptide.PeriodicSweep`'s own callback, §8), for self-healing on a missed
   broadcast or crash recovery: `Placement.list_all/1`, filtered to stream ids matching the job-stream
   naming pattern (§5), checking `stream_leader?/1` per matching stream before inspecting it for
   pending Jobs.

On a pending Job this node leads, execution takes one of two distinct paths depending on which
reference the Job carries — **a `jobCapability` Job never touches `ExecuteInterpreter` at all**: it
has no `FactPattern` to match, so routing it through the full interpreter would be unnecessary
machinery. Instead: `CapabilityCatalog.materialize/1` (6k §5) resolves it straight to an invokable
`Definition`, then `Capability.invoke/4` is called directly with the Job's own `jobArgs`.

A `jobRule` Job genuinely needs the interpreter: its `jobGraph` (§5) is read into an `RDF.Graph` via
the same fold-from-`StreamServer.get_since/2` pattern `LocationIndex.read_graph/0` (6j) already
establishes, a `Context` is built via `ContextResolver.resolve/3` (§6), and
`ExecuteInterpreter.call_template/3` is called with `(rule, graph, context)` — all three genuinely
required by its own existing signature.

Both paths spawn a supervised child (`Task.Supervisor.start_child/2` against a new, dedicated
supervisor added to the application tree) to actually perform the invocation and write back the
result — keeping the trigger worker's own process responsive to *other* pending Jobs (possibly across
many different streams this node happens to lead) while one potentially-slow `wasmtime` invocation (up
to `timeout_ms`) is in flight. On failure (`Capability.invoke/4`'s own `:unauthorized`/
`:resource_exhausted`/trap, or `call_template/3`'s own `{:error, {:unresolvable, iri}}`/
`{:error, {:unsupported_arity, iri}}`), writes back `jobStatus: failed` with the reason; on success,
`jobStatus: done` with the result.

## 8. `Riptide.PeriodicSweep` extraction

`ReplicaHealer` and `BlobStore.Healer` already share an identical shape — a `safe_sweep/0`
rescue/catch wrapper around a `sweep/0` callback, and `schedule_sweep/0` via `Process.send_after` with
a configurable interval (`replica_healer.ex:52-73`, `healer.ex` (6j) matching exactly). This phase's
own `JobTrigger` needs the identical scaffolding a third time — a rule-of-three moment, the same
signal that led to extracting `Riptide.SupervisedProcess` in 6b-ii. Extracted now, and **retrofitted
onto both existing consumers**, not left as a pattern only the new module follows (avoiding relocating
the duplication rather than removing it):

```elixir
defmodule Riptide.PeriodicSweep do
  @moduledoc """
  Shared "wake up, do a bounded unit of work, reschedule" GenServer
  scaffolding. Deliberately owns none of who's allowed to act on a given
  tick (a global leader-gate, no gate, a per-stream leader-gate all vary by
  consumer) — that stays inside each consumer's own sweep/0.
  """
  @callback sweep() :: :ok

  defmacro __using__(opts), do: # injects init/1, handle_info(:sweep, state), safe_sweep/schedule wiring
end
```

`ReplicaHealer`'s own gate (`RaCluster.Placement.placement_leader?/0`) and `BlobStore.Healer`'s own
lack of a gate (every node sweeps, tolerating harmless over-replication, per 6j §7) both stay exactly
as they are today, entirely inside their own `sweep/0` bodies — `PeriodicSweep` only removes the
duplicated timer/rescue scaffolding around them, changing no behavior. Both existing test suites
(`ReplicaHealerTest`, `test/riptide/blob_store/healer_test.exs`) are the regression check for this
retrofit — a passing rerun with zero behavioral changes is the acceptance bar, not new test coverage.

## 9. Error handling and at-least-once semantics

- Resolution failure (missing/unapproved Capability or Rule, cycle detected) → `jobStatus: failed`,
  no execution attempted.
- Invocation failure (`Capability.invoke/4`'s own `:unauthorized`/`:resource_exhausted`/trap) →
  `jobStatus: failed` with the reason.
- Executor crash mid-invocation, before writing back a result → Job stays `pending`; a newly-elected
  leader's own sweep re-executes it. **This can cause a non-idempotent side effect (e.g. an actual
  service restart) to happen twice** — the same accepted trade-off any claim-based design in this
  codebase already carries (`ReplicaHealer`'s TTL-expiry has the identical property). Named here
  explicitly as an accepted residual risk, not solved, matching how 6j named its own cross-tenant
  dedup side channel and 6h-i named anonymous Hub-read enumeration.

## 10. Testing

- `ContextResolver`: single-level resolution, transitive resolution through nested `RuleReference`s,
  diamond dependencies (shared sub-Rule resolves once, not twice), cycle detection, and resolution
  failure for a missing/unapproved Capability or Rule IRI.
- `Riptide.PeriodicSweep`: extracted-behaviour unit tests, plus full reruns of `ReplicaHealerTest` and
  `test/riptide/blob_store/healer_test.exs` after retrofit, confirming zero behavioral change.
- `RaCluster.stream_leader?/1`: unit-level against a real multi-node test cluster, confirming exactly
  one node reports itself leader for a given stream.
- Trigger worker, real multi-node integration test (mirroring 6j's own `:peer`-based convention):
  writing a Job on stream X is picked up only by whichever peer currently leads X; killing that leader
  mid-flight (before it writes back a result) causes the newly-elected leader to pick up and complete
  the still-pending Job. Covers both execution paths: a `jobCapability` Job (direct
  `materialize/1` + `invoke/4`, no interpreter) and a `jobRule` Job (real `jobGraph` Fact state,
  `ContextResolver`, `call_template/3`).
- **Capstone, tying 6k and 6l together end to end**: register and approve a Capability through 6k's
  real HTTP flow, write a Job referencing it by IRI, confirm it's claimed (by the correct leader),
  invoked, and its result written back — the full `restart-payments-service` walking skeleton from the
  original `examples/` motivation, achieved with zero caller-supplied `Definition`/`Context` anywhere
  in the path.

## 11. Exit criterion

Writing an explicit Job Fact — referencing a Capability or Rule by IRI, resolved entirely through 6k's
and the existing Rule catalog, with no caller-supplied `Context` — reliably causes it to execute
exactly on the node currently leading that Job's own stream, with the result (or failure reason)
written back as an ordinary Fact, self-healing across a leader crash, using no new Ra cluster, CAS, or
TTL-based claim mechanism.
