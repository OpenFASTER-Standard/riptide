# Phase 7: Decade Simulation Testing — Design

## Context and motivation

Riptide has throughput micro-benchmarks (`test/bench/`) but nothing that tests *longevity*:
what a stream, a tenant, or a cluster looks like after years of real accumulated usage rather
than a few seconds of a test run. Reading `Riptide.Stream.RaMachine` during research for this
spec found a concrete bug this gap allows: a stream with `retention: :infinity` (the default for
an LDP resource keeping its full history) stores `state.events` as a plain list appended via
`events ++ [stamped_wire]` — O(n) per append — and deliberately never emits a `release_cursor`,
so both the in-memory list and the underlying Ra consensus log grow without bound. Append cost
degrades quadratically over a stream's lifetime. No existing test would ever notice this; it only
shows up at the scale a real years-old, actively-written resource would reach.

This project builds a permanent, reusable test capability that simulates a decade of realistic
usage — accumulated volume, calendar-time-dependent logic, diverse operation orderings, and
operational churn (node loss/restart) — as one coherent scenario, on demand (not wired into CI),
and fixes whatever it finds along the way, starting with the bug above.

## Architecture

Five layers, each independently runnable for fast iteration, composed into one umbrella scenario:

```
                    ┌─────────────────────────────┐
                    │   decade_simulation_test.exs  │  (:decade_simulation tag)
                    └───────────────┬───────────────┘
        ┌───────────────┬───────────┼───────────────┬───────────────┐
        ▼               ▼           ▼               ▼               ▼
   Riptide.Clock   Volume seed   PropCheck      Chaos driver    Assertions
   (virtual time)   (fast-       stateful       (peer kill/     (model vs.
                     forward)     model          restart)        real state,
                                  (diverse ops)                   latency)
```

### 1. `Riptide.Clock`

- `lib/riptide/clock.ex`: a `@behaviour` with a single callback, `now/0`, returning the same
  `:second`-granularity integer `System.system_time(:second)` already produces — matching
  `lib/riptide/placement.ex:88`'s existing shape exactly, so switching that call site to
  `Riptide.Clock.now()` is a pure refactor.
- `lib/riptide/clock/system.ex`: the default implementation, `System.system_time(:second)`.
- `test/support/clock_virtual.ex`: a test-only Agent-backed implementation holding a mutable
  "current time," with `Riptide.Clock.Virtual.advance(seconds)` to jump it forward. No real
  sleeping — a decade of clock advancement takes as long as the Agent call.
- Resolution via `Application.get_env(:riptide, :clock, Riptide.Clock.System)`, the same
  config-swap convention already used elsewhere in this codebase. Only the decade-simulation test
  (and any future test that needs it) overrides this config, scoped to its own `setup`/`on_exit`.

This is minimal now (one call site) deliberately — it's cheap today and becomes expensive to
retrofit once Phase 6a's bitemporal fact shape (spec'd, not yet in `lib/`) lands and adds more
wall-clock-dependent logic.

### 2. Volume seed layer

A tight append loop (no PropCheck, no model) against the real `Riptide.Stream.StreamServer`,
booted the same way `test/bench/*.exs` already boots a real single-node instance. Fast-forwards
one or two `:infinity`-retention streams to decade-scale volume before the rest of the scenario
runs — e.g. one resource updated every 5 minutes for 10 years ≈ ~1,000,000 events (an explicit,
adjustable module constant, not hardcoded inline). Records append latency at intervals so a
degrading trend (the bug above) is directly observable, not just inferred from a timeout.

This stays a separate, simpler layer rather than folding into the PropCheck model below, because
`:proper_statem` run lengths (hundreds of steps, so shrinking and runtime stay tractable) can't
reach real decade-scale event counts — volume and operational diversity are different axes and
need different mechanisms.

### 3. Stateful model layer (PropCheck)

- New dependency: `{:propcheck, "~> 1.4", only: [:test]}` in `mix.exs` (StreamData, already a
  transitive presence via Phoenix's test tooling, has no stateful/model-testing support).
- `test/decade/model.ex`: a `:proper_statem`-style model. Reference state is a plain map,
  `%{{tenant, resource_path} => MapSet.t(triple)}`. Commands: `put_resource`, `patch_resource`
  (additions/removals), `delete_resource`, `create_tenant`, `change_retention`.
- Postconditions call the real HTTP surface (matching `test/bench/http_server_test.exs`'s
  real-listener approach — the actual user-facing contract, not an internal API) and assert the
  returned graph matches the model's expected triple set.
- Runs *after* the volume seed layer, against the already-large stream — so generated operations
  exercise realistic accumulated scale, not a fresh empty one.

### 4. Chaos layer

- `test/decade/chaos.ex`: thin wrapper around `Riptide.MultiNodeTestHelpers` (already used by
  `test/riptide/stream/replica_healer_*_test.exs`) — forms a real 3-node placement cluster via
  `:peer.start_link`, and exposes `kill_random_replica/1` (`:peer.stop`) and
  `restart_replica/1` (spin up a fresh peer to rejoin).
- Injected periodically *during* the PropCheck command sequence, driving the real production
  `:sweep`/`Riptide.Stream.ReplicaHealer` repair path — not a mock — exactly as
  `replica_healer_leadership_gate_test.exs` already proves that path works in isolation. This
  project's addition is running it concurrently with sustained volume and diverse operations,
  which is where compounding bugs (a repair racing a retention change, a repair mid-decade-old
  stream) would actually surface.
- Explicitly out of scope: network partition simulation. Node kill/restart is already
  well-trodden territory here (`ReplicaHealer` exists and is tested for it); partitions are a
  different, larger mechanism with no current concrete need — YAGNI until one shows up.

### 5. Umbrella scenario

`test/decade/decade_simulation_test.exs`, tagged `:decade_simulation` (excluded by default from
`mix test`, same convention as `:benchmark` — run explicitly with
`mix test --include decade_simulation`):

1. Form a 3-node cluster (chaos layer's helper).
2. Fast-forward one hot stream to decade-scale volume (volume seed layer), recording latency.
3. Run the PropCheck-generated command sequence against that cluster, interleaving:
   - periodic `Riptide.Clock.Virtual.advance/1` jumps (days/weeks per jump), and
   - periodic chaos kill/restart rounds,
   asserting model-consistency after every command.
4. Final assertions: no latency-degradation trend from step 2, no crash-looped processes, model
   matches real state for every tracked resource.

Each layer (`Riptide.Clock.Virtual`, the volume loop, the PropCheck model, the chaos driver)
stays independently invocable in its own smaller test, so a failure in the umbrella scenario can
be reproduced and debugged one layer at a time.

## Error handling

- PropCheck postcondition failures shrink to a minimal reproducing command sequence
  (PropCheck's built-in behavior) — no custom shrinking logic needed.
- Chaos-induced timing (a kill followed by repair) is asserted with bounded polling/retry,
  matching the existing convention in `replica_healer_cluster_test.exs`, not fixed sleeps.
- A volume-loop latency regression fails the test with the recorded latency series attached to
  the failure message, so a regression is diagnosable without re-running.

## Testing the harness itself

Each new module gets its own unit-level coverage before being wired into the umbrella scenario:
`Riptide.Clock.Virtual`'s `advance/1` semantics, the volume loop's latency-recording logic on a
short run, the PropCheck model's commands/preconditions against a handful of manually-reasoned
cases, and the chaos wrapper's kill/restart against the existing multi-node test pattern. The
umbrella scenario itself is the integration point, not the first place any of this is exercised.

## Bugs found get fixed here

Starting with the `RaMachine` unbounded-growth issue this research already found: each bug this
harness surfaces gets fixed in its own commit as part of this project, with the harness re-run
green afterward as verification — consistent with how every other repo on this box is worked.
This is tracked as Phase 7 in `PROGRESS.md`, following the existing phase-numbered convention.

## Out of scope

- CI wiring (nightly/scheduled pipeline) — on-demand only for now, per explicit decision; revisit
  once a real run's wall-clock cost is known.
- Network partition chaos — node kill/restart only, for the reason stated above.
- Dependency/OTP/Elixir version-drift simulation — a real aging/maintenance concern, but a
  different kind of test than usage simulation; not part of this project.
