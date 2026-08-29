# WASI Execution Substrate — Design

**Status:** Revision 2. Implements Sub-project 6, phase **6b-i**
([issue #60](https://github.com/OpenFASTER-Standard/riptide/issues/60)) — a
Foundation-track phase with no dependency on any other Sub-project 6 phase.
Parent spec:
`docs/superpowers/specs/2026-08-27-derivation-and-execution-layer-design.md`
(§4, §7's 6b-i entry).

**Revision 2 corrects a load-bearing error in Revision 1** (merged as
[PR #86](https://github.com/OpenFASTER-Standard/riptide/pull/86)):
Revision 1 assumed `wasmex`'s in-process `Wasmex.Components` API (fuel via
`Wasmex.EngineConfig.consume_fuel/2` + `Wasmex.StoreOrCaller.set_fuel/2`)
would bound a component's execution time. It does not — §5 below documents
the empirical proof and the corrected mechanism (an external `wasmtime` CLI
process, not the in-process NIF). §1-§3 (scope, module layout,
authorization) are materially unchanged from Revision 1; only §4/§5/§6/§7
change.

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
real Capability needs it, as its own design problem.

**This phase is the invocation substrate only** — given a Capability
definition, a tenant, and arguments, authorize and invoke a WASI Preview 2
component with resource metering. It does **not** build:

- A Capability catalog, registry, or Discovery mechanism (Track A's 6e-iii/
  6g-i own this).
- Trace/Provenance recording — that's tied to Rule execution and belongs
  with 6d-i, the phase that actually wires ExecuteInterpretation to
  Capability invocation.
- Fidelity-replay semantics (6e-ii) — EffectCapability/ObserveCapability's
  *kind* is recorded here as plain metadata; the different replay
  treatment each kind gets is 6e-ii's own concern.
- Filesystem access grants — no current consumer needs a Capability to
  touch a filesystem.

## 2. Module layout

Mirrors this codebase's existing `Riptide.Authz` (verb module) /
`Riptide.Authz.Policy` (noun struct) split.

```elixir
defmodule Riptide.Capability.Definition do
  defstruct [:name, :kind, :component, :fuel_limit, :timeout_ms, :memory_limits]
end
```

- `name` — `RDF.IRI.t()`, matching 6c-i-a's `urn:riptide:capability:<name>`
  convention.
- `kind` — `:effect | :observe`, plain metadata (§1).
- `component` — a filesystem path to a compiled `.wasm` component
  (`String.t()`); this phase does not fetch or cache components from
  anywhere — the caller supplies a path to a file already on disk.
- `fuel_limit` — `pos_integer()`. wasmtime instruction-count-based fuel
  (§5) — deterministic regardless of host CPU speed or load.
- `timeout_ms` — `pos_integer()`, **required, not optional** (§5 explains
  why this field can't be optional the way it might first seem).
- `memory_limits` — a map: `:max_memory_size`, `:max_table_elements`,
  `:max_instances`, `:max_tables`, each `non_neg_integer() | nil` —
  matching wasmtime's own CLI flag names directly (§5), not `wasmex`'s
  `StoreLimits` field names, since this revision no longer goes through
  `wasmex` for invocation at all.

`Riptide.Capability` — the orchestration module:

```elixir
@spec authorized?(Definition.t(), tenant_id :: String.t(), current_subject :: map() | nil) ::
        boolean()

@spec invoke(Definition.t(), tenant_id :: String.t(), args :: [String.t()]) ::
        {:ok, String.t()} | {:error, :unauthorized | :resource_exhausted | {:trap, String.t()} | term()}
```

`args` is scoped to `[String.t()]` for this phase — the exit criterion's
golden cases only need a single string argument (§6); general WIT-typed
argument/return marshaling is out of scope until a real consumer needs a
richer type (§8). `invoke/3` calls `authorized?/3` first (§3) and returns
`{:error, :unauthorized}` without spawning any process at all if it fails.

Each string argument is embedded into wasmtime's `--invoke
'function-name(arg1, arg2)'` wave-syntax call as a double-quoted literal.
Verified directly that wave string literals use the same backslash-escape
convention as Elixir's own `inspect/1` output (`\"` for an embedded
quote) — `wasmtime run ... --invoke 'greet("has \"quotes\" inside")'`
round-trips correctly. `invoke/3` builds each argument via `inspect/1`
rather than hand-rolled string interpolation, so this composes correctly
without a separate escaping step.

## 3. Authorization — reuse ACP, not a parallel system

Unchanged from Revision 1. The parent spec is explicit: "A Capability
grant in one Tenant is never exercisable by a Rule in another; this
composes with Riptide's shipped Phase 4c ACP authorization... not a
parallel system." Concretely:

- `Riptide.Authz.Policy.mode/0`'s type grows from `:read | :write` to
  `:read | :write | :invoke`. No other change to `Policy`,
  `Policy.matcher/0`, or `Riptide.Authz.evaluate/4`'s algorithm —
  deny-overrides-allow, container-path-prefix inheritance, and
  default-deny all apply to `:invoke` exactly as they already do to
  `:read`/`:write`, with zero new authorization logic. Verified low-risk:
  only 2 reference sites for `Policy.mode()` exist in the whole codebase.
- A Capability is addressed as a synthetic path: `["capabilities",
  capability_name]`, where `capability_name` is the Capability
  `Definition`'s `name` IRI's local name (the part after
  `urn:riptide:capability:`, extracted via `RDF.IRI.to_string/1` +
  `String.trim_leading/2` — verified against a real `RDF.IRI.t()` value).
  `Riptide.Capability.authorized?/3` is a thin wrapper:
  `Riptide.Authz.evaluate(tenant_id, ["capabilities", local_name],
  current_subject, :invoke) == :allow`.
- Callers of `Riptide.Capability` never see the synthetic-path detail —
  the same interface-hiding discipline 6c-i-b used to keep `RDF.Query.BGP`
  out of every module but `Matcher`.

## 4. WASI sandboxing — safe-by-default via CLI flags, not library defaults

Both `wasmex`'s `WasiP2Options` and the `wasmtime` CLI's own `-S` flag
group default `inherit-stdin`/`inherit-stdout`/`inherit-stderr` to `true`
(verified directly against `wasmtime run -S help`'s own text: "On by
default") and `inherit-network` to off by default — real ambient
authority leaking into what's supposed to be a sandbox unless explicitly
suppressed. `Riptide.Capability.invoke/3` always passes:

```
-S inherit-stdin=n -S inherit-stdout=n -S inherit-stderr=n -S inherit-network=n
```

No `Definition` field controls this in v1 — no Capability in the parent
spec's worked examples needs outbound network access or inherited stdio
yet, and a per-Capability network grant deserves its own decision once a
real consumer needs it (matching Revision 1's reasoning, unchanged).

## 5. Resource metering — corrected mechanism

**This is the section that changed.** Revision 1 assumed
`Wasmex.EngineConfig.consume_fuel(true)` +
`Wasmex.StoreOrCaller.set_fuel/2` would bound a `Wasmex.Components`
invocation's execution time, the same as it does for `wasmex`'s older
core-module API. It does not, and no working mechanism exists to bound
CPU/execution-time on `wasmex` 0.15.1's Components API at all. This was
established empirically, not by reading documentation:

- **Fuel is a different native resource type for Components.** Reading
  `wasmex`'s Rust source (`native/wasmex/src/store.rs`) shows
  `store_or_caller_set_fuel` only accepts a `ResourceArc<StoreOrCallerResource>`
  — a distinct Rust type from the `ResourceArc<ComponentStoreResource>` a
  `Wasmex.Components.Store` produces. Calling `Wasmex.StoreOrCaller.set_fuel/2`
  on a Components store raises `ArgumentError` at the NIF boundary — confirmed
  by actually calling it against a real component.
- **`call_function/4`'s `timeout` parameter does not interrupt execution.**
  Reading `native/wasmex/src/component_instance.rs`'s
  `call_exported_function` shows the deadline is checked only *before*
  starting the call and *before* replying — it never wraps the actual
  execution in the epoch-interruption machinery (`with_deadline`) that
  exists elsewhere in the same codebase for exactly this purpose. Proven
  by building a real WASI P2 fixture component with an intentionally
  infinite-looping export and calling it with `timeout: 1000`: the call
  hangs, the GenServer becomes permanently wedged (a second, unrelated
  call to the same store also hangs forever), and — the most severe part
  — **forcibly killing the Elixir process does not reclaim the native
  computation**: measuring this OS process's own CPU ticks
  (`/proc/self/stat`) before and after `Process.exit(pid, :kill)` showed
  ~100 ticks/sec of continued consumption for the 2 seconds sampled,
  fully independent of the BEAM process table
  (`Process.alive?(pid) == false` throughout). A CPU-bound infinite loop
  in a Capability would permanently burn a core with no recovery short of
  restarting the whole node.
- **Memory limits do work correctly for Components** — confirmed in the
  same Rust source (`component_store_new_wasi` calls
  `store.limiter(|state| &mut state.limits)` with the real `StoreLimits`)
  — this part of Revision 1 was correct and isn't why this section
  changed.

**Corrected mechanism: invoke via the `wasmtime` CLI as an external OS
process, not `wasmex`'s in-process Components API.** Verified directly
against the same real fixture component:

- `wasmtime run -W component-model=y -W timeout=1s --invoke 'burn-fuel()' <path>`
  trapped the infinite loop at exactly 1.035s wall-clock with a clean
  `wasm trap: interrupt` and exit code 134.
- `wasmtime run -W component-model=y -W fuel=1000000 --invoke 'burn-fuel()' <path>`
  trapped it in 0.035s with `wasm trap: all fuel consumed by WebAssembly`,
  exit code 134.
- `wasmtime run -W max-memory-size=1024 --invoke 'greet("Riptide")' <path>`
  failed instantiation with `memory minimum size of 17 pages exceeds
  memory limits`, exit code 1 (not 134 — a pre-execution instantiation
  failure, not a runtime trap).
- Because this runs as a genuinely separate OS process, killing it (or
  letting it exit on its own, which both the timeout and fuel mechanisms
  do reliably here, unlike `wasmex`'s Components path) is a
  kernel-enforced reclaim of every resource it holds — the "process died
  but native execution kept running" failure mode above is structurally
  impossible here.
- `wasmtime run -W max-table-elements=N -W max-instances=N -W max-tables=N`
  round out full parity with what `Wasmex.StoreLimits` offered in
  Revision 1's design.

**Why `timeout_ms` is required, not optional (§2):** `Riptide.Capability.invoke/3`
calls the `wasmtime` binary via `System.cmd/3`, which blocks until the
external process exits — it has no built-in timeout of its own. This is
safe specifically *because* `-W timeout=` is always passed and wasmtime's
own CLI-level deadline enforcement is verified to reliably terminate the
process on its own (unlike the Components-API path). Making `timeout_ms`
mandatory is what makes `System.cmd/3` an adequate (not merely
convenient) choice — there is no code path where `invoke/3` waits
unboundedly on an external process.

**Result parsing, from real observed output (not assumed):**

| Condition | Exit code | Distinguishing signal | Mapped to |
|---|---|---|---|
| Success | `0` | stdout is the wave-encoded return value | `{:ok, stdout}` |
| Fuel exhausted | `134` | stderr contains `"all fuel consumed"` | `{:error, :resource_exhausted}` |
| Timeout exceeded | `134` | stderr contains `"interrupt"` | `{:error, :resource_exhausted}` |
| Memory limit exceeded | `1` | stderr contains `"exceeds memory limits"` | `{:error, :resource_exhausted}` |
| Anything else | any | — | `{:error, {:trap, stderr}}` |

The exact stderr substrings above are real, observed strings from
wasmtime 48.0.1 against this phase's own fixture component — the
implementation plan's tasks verify these afresh via TDD (write the test
asserting the mapped result, run it, confirm the actual raw stderr
matches before hardcoding the pattern) rather than trusting this table
blindly, the same discipline 6c-i-a's plan used for uncertain parser
error shapes.

**New operational dependency:** a `wasmtime` CLI binary (this phase was
verified against 48.0.1) must be present wherever Riptide runs — this
dev box, CI, and production — not just the `wasmex` hex package (which is
no longer used for invocation at all; see §8 for whether it's still used
anywhere in this phase). How that binary gets installed in each of those
environments (Dockerfile step, CI workflow step, etc.) is an
implementation-plan-level concern, not decided here, but is a real new
piece of infrastructure this phase introduces.

## 6. Testing — a real compiled component, not a mock

The exit criterion needs an actual WASI Preview 2 component invoked, not
a stubbed interface. Verified this box can build one:
`rustup target add wasm32-wasip2` succeeds (though `cargo-component`
0.21.1 actually targets `wasm32-wasip1` internally and produces a real
component via its own componentization step — confirmed by building and
then loading the result into both `wasmex` and the `wasmtime` CLI
successfully), and `cargo-component` is installable from crates.io.
Rather than adding a Rust/WASM build toolchain to CI, **one small,
hand-authored fixture component is built once during implementation and
its compiled `.wasm` binary is checked into the test fixtures directory**
(a few KB) — CI never needs `cargo-component` or the `wasm32-wasip2`
target, only the `wasmtime` CLI binary (§5) to invoke the checked-in
fixture.

The fixture built and verified during this design's research exports
exactly two functions, sufficient for every golden case below:

```rust
impl Guest for Component {
    fn greet(name: String) -> String {
        format!("Hello, {name}!")
    }

    fn burn_fuel() {
        let mut counter: u64 = 0;
        loop {
            counter = counter.wrapping_add(1);
            std::hint::black_box(counter);
        }
    }
}
```

Golden-case suite:

- An authorized EffectCapability invocation (`greet`) succeeds and
  returns the component's result.
- An authorized ObserveCapability invocation succeeds (same invocation
  path — §1 confirms no behavioral difference between kinds in this
  phase).
- A denied invocation (no grant for the tenant/capability pair) returns
  `{:error, :unauthorized}` without spawning any process at all.
- A fuel-exhaustion case (`burn-fuel` against a small `fuel_limit`)
  returns `{:error, :resource_exhausted}`.
- A timeout case (`burn-fuel` against a short `timeout_ms`) returns
  `{:error, :resource_exhausted}`.
- A memory-limit case (`greet` against an artificially tiny
  `max_memory_size`) returns `{:error, :resource_exhausted}`.

## 7. Exit criterion (from issue #60, restated and corrected)

A tenant-scoped WASI Preview 2 component can be invoked as an
EffectCapability or ObserveCapability, authorized against Riptide's
existing ACP surface (§3); a component that exceeds its configured fuel,
timeout, or memory limit traps deterministically into `{:error,
:resource_exhausted}` instead of degrading the host (§5, §6) — verified
achievable only via the external `wasmtime` CLI process mechanism, not
`wasmex`'s in-process Components API. WASIX/subprocess spawning is
explicitly out of scope (§1).

## 8. Explicitly deferred

- WASIX / subprocess spawning (§1) — no viable path on this stack, no
  current consumer.
- Capability catalog, registration, Discovery (6e-iii, 6g-i).
- Trace/Provenance recording (6d-i's concern once it exists).
- Fidelity-replay semantics distinguishing EffectCapability from
  ObserveCapability (6e-ii).
- Outbound HTTP / filesystem access grants on `Definition` — no current
  consumer.
- General WIT-typed argument/return marshaling (§2) — v1 supports
  `[String.t()]` args and a string return only, matching what the golden
  cases need; richer types (records, lists, `result<T,E>`, etc.) are
  real future work once a Capability needs them.
- **Whether `wasmex` has any remaining role in this phase.** Revision 1
  used it for both invocation and (implicitly) as the only WASM tooling
  this codebase touched. Revision 2 no longer needs `wasmex` for
  invocation (§5) — whether it's still worth adding as a dependency for
  anything else in this phase (there is no other use identified) is an
  implementation-plan-level question; the default assumption going into
  planning is that `wasmex` is **not** added as a dependency at all for
  this phase, since the `wasmtime` CLI covers everything §5 needs.
- Fuel/timeout/memory-limit CLI flag exact syntax was verified against
  wasmtime 48.0.1 specifically — pin the CLI version explicitly rather
  than floating on "latest," since flag names have changed across major
  wasmtime versions historically (the `-O`/`-C`/`-D`/`-W`/`-S` grouped-flag
  scheme itself is relatively recent).
