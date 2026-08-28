# WASI Execution Substrate — Design

**Status:** Draft, first revision. Implements Sub-project 6, phase **6b-i**
([issue #60](https://github.com/OpenFASTER-Standard/riptide/issues/60)) — a
Foundation-track phase with no dependency on any other Sub-project 6 phase.
Parent spec:
`docs/superpowers/specs/2026-08-27-derivation-and-execution-layer-design.md`
(§4, §7's 6b-i entry).

## 1. Scope, corrected from the parent spec

The parent spec's §4/§7 describe 6b-i as "Backed by WASI Preview 2... plus
WASIX where subprocess spawning is specifically granted." **This is not
achievable as written and this phase drops it.** Verified directly rather
than assumed: `wasmex` (the Elixir WASM host this stack uses) wraps
`wasmtime` (Bytecode Alliance's runtime); WASIX is a Wasmer-specific
technology (Wasmer's own announcement blog), built for Wasmer's runtime,
not wasmtime's. A GitHub code search across both `tessi/wasmex` and
`bytecodealliance/wasmtime` for "WASIX" returns zero results in either
repository. There is no subprocess-spawning path on this stack today. No
Capability in this project's own worked examples (parent spec §9) needs
subprocess spawning — this is dropped per YAGNI, matching the project's
established discipline elsewhere (6c-i-a's deferred negation/aggregation,
6c-i-b's deferred recursion), not silently narrowed. Revisit only when a
real Capability needs it, as its own design problem (a different runtime
entirely, or a privileged non-sandboxed mechanism built on 6b-ii's
supervised-process primitive — not decided here, because nothing requires
deciding it yet).

**This phase is the invocation substrate only** — given a Capability
definition, a tenant, and arguments, authorize and invoke a WASI Preview 2
component with resource metering. It does **not** build:

- A Capability catalog, registry, or Discovery mechanism (Track A's 6e-iii/
  6g-i own this).
- Trace/Provenance recording. A Trace records one concrete run of a *Rule*
  (parent spec §5) — that's fundamentally tied to Rule execution and
  variable bindings, which don't exist in this phase's scope at all (the
  parent spec's own "tested with no Rule representation involved" note).
  Recording belongs with 6d-i, the phase that actually wires
  ExecuteInterpretation to Capability invocation.
- Fidelity-replay semantics (6e-ii) — EffectCapability/ObserveCapability's
  *kind* is recorded here as plain metadata; the different replay
  treatment each kind gets is 6e-ii's own concern.
- Filesystem access grants — no current consumer needs a Capability to
  touch a filesystem, and (per §4 below) `wasmex`'s current WASI Preview 2
  options don't expose this yet regardless.

## 2. Module layout

Mirrors this codebase's existing `Riptide.Authz` (verb module) /
`Riptide.Authz.Policy` (noun struct) split.

```elixir
defmodule Riptide.Capability.Definition do
  defstruct [:name, :kind, :component, :fuel_limit, :memory_limits]
end
```

- `name` — `RDF.IRI.t()`, matching 6c-i-a's `urn:riptide:capability:<name>`
  convention (the same IRI a `Literal.CapabilityReference.capability` field
  already carries) — not yet cross-referenced against a real Rule in this
  phase, but sharing the convention avoids a second one appearing later.
- `kind` — `:effect | :observe`, plain metadata for now (§1).
- `component` — a filesystem path to a compiled `.wasm` component
  (`String.t()`); this phase does not fetch or cache components from
  anywhere — the caller supplies a path to a file already on disk.
- `fuel_limit` — `pos_integer()`.
- `memory_limits` — a map matching `Wasmex.StoreLimits`'s shape
  (`:memory_size`, `:table_elements`, `:instances`, `:tables`, `:memories`,
  each `non_neg_integer() | nil`).

`Riptide.Capability` — the orchestration module:

```elixir
@spec authorized?(Definition.t(), tenant_id :: String.t(), current_subject :: map() | nil) ::
        boolean()

@spec invoke(Definition.t(), tenant_id :: String.t(), args :: [term()]) ::
        {:ok, term()} | {:error, :unauthorized | :resource_exhausted | term()}
```

`invoke/3` calls `authorized?/3` first (§3) and returns `{:error,
:unauthorized}` without touching Wasmex at all if it fails — an
unauthorized invocation attempt never spins up a WASI instance.

## 3. Authorization — reuse ACP, not a parallel system

The parent spec is explicit: "A Capability grant in one Tenant is never
exercisable by a Rule in another; this composes with Riptide's shipped
Phase 4c ACP authorization... not a parallel system." Concretely:

- `Riptide.Authz.Policy.mode/0`'s type grows from `:read | :write` to
  `:read | :write | :invoke`. No other change to `Policy`, `Policy.matcher/0`,
  or `Riptide.Authz.evaluate/4`'s algorithm — deny-overrides-allow,
  container-path-prefix inheritance, and default-deny all apply to
  `:invoke` exactly as they already do to `:read`/`:write`, with zero new
  authorization logic.
- A Capability is addressed as a synthetic path: `["capabilities",
  capability_name]`, where `capability_name` is the Capability
  `Definition`'s `name` IRI's local name (the part after
  `urn:riptide:capability:`). `Riptide.Capability.authorized?/3` is a thin
  wrapper: `Riptide.Authz.evaluate(tenant_id, ["capabilities",
  local_name], current_subject, :invoke) == :allow`.
- Callers of `Riptide.Capability` never see the synthetic-path detail —
  the same interface-hiding discipline 6c-i-b used to keep `RDF.Query.BGP`
  out of every module but `Matcher`. A future change to how Capability
  grants are addressed only touches `Riptide.Capability.authorized?/3`.
- `current_subject` is threaded through from the caller (matching
  `Riptide.Authz.evaluate/4`'s own existing `current_subject` parameter) —
  this phase does not introduce a new principal/identity concept.

## 4. WASI sandboxing — safe-by-default, not library-default

`Wasmex.Wasi.WasiP2Options` (verified against `wasmex` v0.15.1's real
hexdocs, not assumed) defaults `inherit_stdin`/`inherit_stdout`/
`inherit_stderr` to `true` — a naively-configured component inherits the
host BEAM node's actual stdio streams, real ambient authority leaking into
what the parent spec calls a "no ambient authority" sandbox.
`Riptide.Capability.invoke/3` always constructs `WasiP2Options` explicitly:

```elixir
%Wasmex.Wasi.WasiP2Options{
  inherit_stdin: false,
  inherit_stdout: false,
  inherit_stderr: false,
  allow_http: false
}
```

`allow_http` is hardcoded `false` in this phase, not sourced from the
`Definition` — no Capability in the parent spec's worked examples needs
outbound HTTP yet (the tax-filing example's EffectCapability submission
and ObserveCapability check are both hypothetical, not implemented here),
and a per-Capability network grant is real scope that deserves its own
decision once a real consumer needs it, rather than adding an unused
`Definition` field speculatively. `args`/`env` are left at their library
defaults (`[]`/`%{}`) for the same reason.

## 5. Resource metering

The phase's stated hard requirement (parent spec §4), verified against
`wasmex`'s real API rather than assumed:

- `Wasmex.EngineConfig.consume_fuel(true)` — enables fuel accounting for
  the engine.
- `Wasmex.StoreOrCaller.set_fuel(store, definition.fuel_limit)` — sets the
  fuel budget before invocation.
- `Wasmex.StoreLimits` — constructed from `definition.memory_limits`,
  applied to the store.

A component that exhausts its fuel or exceeds a memory limit traps
deterministically (per `wasmex`'s documented behavior) rather than
degrading the host; `invoke/3` catches this and returns `{:error,
:resource_exhausted}` — a controlled result, not a crash that propagates
to the caller. This is the same resource-exhaustion risk shape already hit
twice in this codebase (unbounded atom creation; a ~3MB Turtle body
driving ~863MB/~19s in decoding, both fixed in PR #32) and the same
"trap, don't degrade" contract `Riptide.RDF.TurtleCodec.decode/1`'s
heap-cap guard already established.

## 6. Testing — a real compiled component, not a mock

The exit criterion needs an actual WASI Preview 2 component invoked, not a
stubbed interface. Verified this box can build one: `rustup target add
wasm32-wasip2` succeeds, and `cargo-component` (0.21.1) is published on
crates.io and installable. Rather than adding a Rust/WASM build toolchain
to CI (a real infrastructure change to `docker-build-check`/`test`'s own
environment), **one small, hand-authored fixture component is built once
during implementation and its compiled `.wasm` binary is checked into the
test fixtures directory** (a few KB) — CI never needs `cargo-component` or
the `wasm32-wasip2` target at all, only the already-present Elixir
toolchain to load and invoke the checked-in binary.

Golden-case suite:

- An authorized EffectCapability invocation succeeds and returns the
  component's result.
- An authorized ObserveCapability invocation succeeds (same invocation
  path — §1 confirms no behavioral difference between kinds in this
  phase).
- A denied invocation (no grant for the tenant/capability pair) returns
  `{:error, :unauthorized}` without invoking the component at all
  (verified via the fixture component recording whether it was actually
  called, e.g. a side-effect-free counter it increments, and asserting it
  did not increment).
- A fuel-exhaustion case (a fixture component built to loop until fuel
  runs out, or an artificially tiny fuel limit against the normal
  fixture) returns `{:error, :resource_exhausted}`.
- A memory-limit case (an artificially tiny `memory_size` limit against
  the normal fixture) returns `{:error, :resource_exhausted}`.

## 7. Exit criterion (from issue #60, restated and corrected)

A tenant-scoped WASI Preview 2 component can be invoked as an
EffectCapability or ObserveCapability, authorized against Riptide's
existing ACP surface (§3); a component that exceeds its configured fuel or
memory limit traps deterministically into `{:error, :resource_exhausted}`
instead of degrading the host (§5, §6). WASIX/subprocess spawning is
explicitly out of scope (§1) — the parent spec's original criterion
implied it was available; it is not, and this correction is the exit
criterion this phase is actually held to.

## 8. Explicitly deferred

- WASIX / subprocess spawning (§1) — no viable path on this stack, no
  current consumer.
- Capability catalog, registration, Discovery (6e-iii, 6g-i).
- Trace/Provenance recording (6d-i's concern once it exists).
- Fidelity-replay semantics distinguishing EffectCapability from
  ObserveCapability (6e-ii).
- Outbound HTTP / filesystem access grants on `Definition` — no current
  consumer, and `wasmex`'s WASI Preview 2 options don't expose filesystem
  access at all yet regardless (verified against its real hexdocs).
- Fetching/caching components from anywhere other than a caller-supplied
  local path — how a real Capability's `.wasm` bytes get onto disk in
  production is out of scope here, the same way 6c-i-b left "how does a
  caller assemble the input graph from real streams" to 6d-i.
