# Phase 7: Decade Simulation Testing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a permanent, on-demand test capability that simulates a decade of realistic Riptide usage — accumulated event volume, calendar-time-dependent logic, diverse operation orderings, and node loss/restart — as one composed scenario, and fix the real bug this research already found along the way.

**Architecture:** Five independently-testable layers (`Riptide.Clock`, a volume-seed helper, a PropCheck stateful model, a chaos driver reusing existing multi-node test infra, and an umbrella test composing all four), tagged `:decade_simulation`/`:benchmark` and excluded from default `mix test`, matching this repo's existing `:benchmark` convention.

**Tech Stack:** Elixir/Phoenix, `:ra` (Raft), ExUnit, PropCheck (new dependency), Erlang `:peer` for multi-node tests.

**Spec:** `docs/superpowers/specs/2026-09-15-phase-7-decade-simulation-testing-design.md`

## Global Constraints

- Nothing in this plan gets wired into GitLab CI — every new test stays excluded from a bare `mix test` (tagged `:benchmark` or `:decade_simulation`), run explicitly, per the spec's explicit "on-demand only" decision.
- Bugs this work finds get fixed as part of this same plan, each in its own commit, re-verified green afterward — not filed for later (spec, "Bugs found get fixed here").
- No network-partition chaos, no dependency/OTP version-drift simulation — both explicitly out of scope per the spec.
- Two corrections made during this plan's own research, beyond what the spec says verbatim, both noted where they apply: (1) "the real HTTP surface" means Phoenix's own in-process `Plug.Test.conn/2` + `RiptideWeb.Endpoint.call/2` pattern (exactly what `test/riptide_web/ldp/resource_controller_test.exs` already uses) — not a live TCP listener like `test/bench/http_server_test.exs`, which exists only for external `wrk` load-testing and has no place in an assertion-driven test. (2) the spec's `change_retention` model command is dropped: `Riptide.Stream.StreamServer`'s own moduledoc documents that a live stream's retention cannot be changed after creation ("not in scope for Phase 1"), and every normal write path (`StreamSupervisor.ensure_ready/1`) already hardcodes `:infinity` — so there is no such operation to model.

---

### Task 1: Fix `RaMachine`'s O(n²) append for `:infinity`-retention streams

**Files:**
- Modify: `lib/riptide/stream/ra_machine.ex`
- Test: `test/riptide/stream/ra_machine_append_scaling_test.exs` (new)

**Interfaces:**
- Consumes: nothing new — `Riptide.Stream.RaMachine.init/1`, `apply/3`, `get_since/2` keep their existing public signatures unchanged.
- Produces: `state.events` changes internal representation from `[map()]` to `:queue.queue(map())`. No other module reads `.events` directly (verified: `grep -rn "\.events\b" lib/ test/` matches only this file), so this is safe to change unilaterally.

- [ ] **Step 1: Write the failing performance-regression test**

```elixir
defmodule Riptide.Stream.RaMachineAppendScalingTest do
  use ExUnit.Case, async: true

  alias Riptide.Event
  alias Riptide.Stream.RaMachine

  @moduletag :benchmark
  @moduletag timeout: 120_000

  defp append_n(state, stream_id, count, start_index) do
    Enum.reduce(1..count, state, fn i, acc ->
      {new_state, _event, _effects} =
        RaMachine.apply(
          %{index: start_index + i},
          {:append, Event.encode(Event.new(stream_id, :replace, RDF.Graph.new()))},
          acc
        )

      new_state
    end)
  end

  defp time_appends(state, stream_id, count, start_index) do
    {micros, _state} =
      :timer.tc(fn -> append_n(state, stream_id, count, start_index) end)

    micros
  end

  test "append throughput does not degrade as an :infinity-retention stream accumulates events" do
    # A stream with only a small prior history.
    small = RaMachine.init(%{retention: :infinity})
    small = append_n(small, "scaling-small", 2_000, 0)
    small_micros = time_appends(small, "scaling-small", 500, 2_000)

    # The same shape of work, but against a stream with 20x the prior
    # history. A per-append cost proportional to total history size (the
    # `events ++ [x]` bug) makes this take roughly 20x as long; O(1)
    # amortized append keeps it close to the small case regardless of
    # prior history.
    large = RaMachine.init(%{retention: :infinity})
    large = append_n(large, "scaling-large", 40_000, 0)
    large_micros = time_appends(large, "scaling-large", 500, 40_000)

    ratio = large_micros / small_micros

    assert ratio < 5,
           "appending 500 events after 40,000 prior events took #{ratio}x as long as " <>
             "after 2,000 prior events (#{large_micros}us vs #{small_micros}us) — append " <>
             "cost looks proportional to total history size, not O(1)"
  end
end
```

- [ ] **Step 2: Run it and confirm it fails against the current implementation**

Run: `mix test test/riptide/stream/ra_machine_append_scaling_test.exs --include benchmark --trace`
Expected: FAIL — the assertion on `ratio < 5` fails (the current `events ++ [stamped_wire]` implementation should show a ratio close to 20, matching the 40,000-vs-2,000 prior-history size ratio).

- [ ] **Step 3: Implement the fix — store `events` as a `:queue`, not a list**

```elixir
  @type state :: %{
          next_sequence: pos_integer(),
          events: :queue.queue(map()),
          retention: :infinity | pos_integer()
        }

  @impl :ra_machine
  def init(%{retention: retention}) do
    %{next_sequence: 1, events: :queue.new(), retention: retention}
  end

  @impl :ra_machine
  def apply(meta, {:append, wire}, state) do
    case safe_decode(wire) do
      {:ok, event} ->
        stamped = Event.with_sequence(event, state.next_sequence)
        stamped_wire = Event.encode(stamped)
        {events, trimmed?} = trim(:queue.in(stamped_wire, state.events), state.retention)
        new_state = %{state | next_sequence: state.next_sequence + 1, events: events}
        {new_state, stamped, release_cursor_effects(trimmed?, meta, new_state)}

      {:error, reason} ->
        Logger.error(
          "Riptide.Stream.RaMachine dropped an unparseable committed event " <>
            "(#{reason}) — state left unchanged rather than crashing this " <>
            "replica; likely a wire-version mismatch from a rolling upgrade"
        )

        :telemetry.execute([:riptide, :stream, :poison_command], %{}, %{})
        {state, {:error, {:undecodable_event, reason}}, []}
    end
  end
```

`get_since/2` and `trim/2` both need updating for the new `:queue` representation — `List.first/1` and `Enum.filter/2`/`length/1`/`Enum.drop/2` all assumed a plain list:

```elixir
  @spec get_since(state(), non_neg_integer() | nil) ::
          {:ok, [Event.t()]} | {:gap, pos_integer() | nil}
  def get_since(_state, nil), do: {:ok, []}

  def get_since(state, cursor) do
    oldest =
      case :queue.peek(state.events) do
        {:value, event} -> event.sequence
        :empty -> nil
      end

    if oldest != nil and cursor < oldest - 1 do
      {:gap, oldest}
    else
      state.events
      |> :queue.to_list()
      |> Enum.filter(&(&1.sequence > cursor))
      |> Enum.map(&Event.decode/1)
      |> then(&{:ok, &1})
    end
  end

  defp trim(events, :infinity), do: {events, false}

  defp trim(events, retention) when is_integer(retention) do
    count = :queue.len(events)

    if count > retention do
      {drop_n(events, count - retention), true}
    else
      {events, false}
    end
  end

  defp drop_n(queue, 0), do: queue
  defp drop_n(queue, n) when n > 0, do: drop_n(:queue.drop(queue), n - 1)
```

- [ ] **Step 4: Run the new test and confirm it passes**

Run: `mix test test/riptide/stream/ra_machine_append_scaling_test.exs --include benchmark --trace`
Expected: PASS — `:queue.in/2` is O(1) amortized, so the ratio should now be close to 1, well under the `< 5` threshold.

- [ ] **Step 5: Run the existing behavior tests to confirm no regression**

Run: `mix test test/riptide/stream/ra_machine_test.exs`
Expected: PASS — all 4 existing tests (`sequence starts at 1...`, `get_since(nil)...`, `get_since(cursor)...`, `retention trims old events...`) pass unchanged, since none of them touch `.events` directly and `get_since`/`apply`'s external behavior is unchanged.

Also run: `mix test test/riptide/ra_cluster/ test/riptide/stream/` (the broader area — release-cursor/snapshot behavior is exercised by `RaClusterTest` per the existing test file's own comment) to confirm the `release_cursor` effect still fires correctly for finite-retention streams.
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/riptide/stream/ra_machine.ex test/riptide/stream/ra_machine_append_scaling_test.exs
git commit -m "$(cat <<'EOF'
Fix O(n) per-append cost for :infinity-retention streams

RaMachine.apply/3 stored events in a plain list, appended via
`events ++ [x]` — O(n) per append, so append cost grew linearly with
a stream's total history and the full lifetime cost was O(n^2). Every
:infinity-retention stream (the default for a normal LDP write path)
was affected; invisible at test scale, catastrophic for a real,
years-old, actively-written resource. Switched internal storage to
Erlang's :queue for O(1) amortized append.

Found during research for Phase 7 (decade-usage simulation testing).
EOF
)"
```

---

### Task 2: `Riptide.Clock` behaviour + `System` implementation, wired into `placement.ex`

**Files:**
- Create: `lib/riptide/clock.ex`
- Create: `lib/riptide/clock/system.ex`
- Modify: `lib/riptide/placement.ex:88`
- Test: `test/riptide/clock_test.exs` (new)

**Interfaces:**
- Produces: `Riptide.Clock.now/0` (facade, returns `integer()`), `@behaviour Riptide.Clock` with callback `now/0`, `Riptide.Clock.System.now/0`.
- Consumed by: Task 3's `Riptide.Clock.Virtual` (implements the same behaviour); Task 7's umbrella scenario (configures `Application.put_env(:riptide, :clock, Riptide.Clock.Virtual)`).

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Riptide.ClockTest do
  use ExUnit.Case, async: false

  defmodule FakeClock do
    @behaviour Riptide.Clock
    def now, do: 123_456
  end

  setup do
    previous = Application.get_env(:riptide, :clock)
    on_exit(fn -> Application.put_env(:riptide, :clock, previous) end)
    :ok
  end

  test "System.now/0 returns a real, current second-granularity timestamp" do
    before = System.system_time(:second)
    now = Riptide.Clock.System.now()
    afterward = System.system_time(:second)

    assert now >= before
    assert now <= afterward
  end

  test "Clock.now/0 defaults to Clock.System when unconfigured" do
    Application.delete_env(:riptide, :clock)
    assert Riptide.Clock.now() == Riptide.Clock.System.now()
  end

  test "Clock.now/0 delegates to whichever module is configured" do
    Application.put_env(:riptide, :clock, FakeClock)
    assert Riptide.Clock.now() == 123_456
  end
end
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `mix test test/riptide/clock_test.exs`
Expected: FAIL — `Riptide.Clock`/`Riptide.Clock.System` don't exist yet (`UndefinedFunctionError` / compile error).

- [ ] **Step 3: Implement `Riptide.Clock` and `Riptide.Clock.System`**

```elixir
# lib/riptide/clock.ex
defmodule Riptide.Clock do
  @moduledoc """
  Indirection over "what time is it," swappable via `config :riptide, :clock`
  — lets tests (e.g. Phase 7's decade simulation) advance time without real
  sleeping. Defaults to `Riptide.Clock.System`, which is what every non-test
  environment uses. Returns the same `:second`-granularity integer
  `System.system_time(:second)` already produced, so adopting this at any
  call site is a pure refactor.
  """

  @callback now() :: integer()

  @spec now() :: integer()
  def now do
    Application.get_env(:riptide, :clock, Riptide.Clock.System).now()
  end
end
```

```elixir
# lib/riptide/clock/system.ex
defmodule Riptide.Clock.System do
  @moduledoc "The real wall clock — `Riptide.Clock`'s default implementation."

  @behaviour Riptide.Clock

  @impl Riptide.Clock
  def now, do: System.system_time(:second)
end
```

- [ ] **Step 4: Run the test and confirm it passes**

Run: `mix test test/riptide/clock_test.exs`
Expected: PASS.

- [ ] **Step 5: Wire the one existing call site**

In `lib/riptide/placement.ex`, replace:

```elixir
    now_ts = System.system_time(:second)
```

with:

```elixir
    now_ts = Riptide.Clock.now()
```

- [ ] **Step 6: Run the placement test suite to confirm no regression**

Run: `mix test test/riptide/placement/`
Expected: PASS — `claim_repair/2`'s behavior is unchanged (same integer, same granularity), just sourced through the new indirection.

- [ ] **Step 7: Commit**

```bash
git add lib/riptide/clock.ex lib/riptide/clock/system.ex lib/riptide/placement.ex test/riptide/clock_test.exs
git commit -m "$(cat <<'EOF'
Add Riptide.Clock behaviour, wire placement.ex's wall-clock read through it

Prep for Phase 7's decade-usage simulation: a swappable clock lets a
test advance "time" by years without real sleeping. Pure refactor —
placement.ex's claim_repair/2 gets the identical integer as before,
just through Riptide.Clock.now() instead of a raw System.system_time
call.
EOF
)"
```

---

### Task 3: `Riptide.Clock.Virtual` test-support implementation

**Files:**
- Create: `test/support/clock_virtual.ex`
- Test: `test/support/clock_virtual_test.exs` (new)

**Interfaces:**
- Consumes: `@behaviour Riptide.Clock` (Task 2).
- Produces: `Riptide.Clock.Virtual.start_link(initial_seconds)`, `now/0` (behaviour callback), `advance/1` (seconds to add).

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Riptide.Clock.VirtualTest do
  use ExUnit.Case, async: false

  setup do
    {:ok, _pid} = start_supervised({Riptide.Clock.Virtual, 1_000})
    :ok
  end

  test "now/0 returns the seeded initial value" do
    assert Riptide.Clock.Virtual.now() == 1_000
  end

  test "advance/1 moves the clock forward without any real waiting" do
    Riptide.Clock.Virtual.advance(86_400 * 365 * 10)
    assert Riptide.Clock.Virtual.now() == 1_000 + 86_400 * 365 * 10
  end

  test "advance/1 is cumulative across multiple calls" do
    Riptide.Clock.Virtual.advance(100)
    Riptide.Clock.Virtual.advance(200)
    assert Riptide.Clock.Virtual.now() == 1_300
  end
end
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `mix test test/support/clock_virtual_test.exs`
Expected: FAIL — `Riptide.Clock.Virtual` doesn't exist yet.

- [ ] **Step 3: Implement `Riptide.Clock.Virtual`**

```elixir
defmodule Riptide.Clock.Virtual do
  @moduledoc """
  Test-only `Riptide.Clock` implementation: an Agent holding a mutable
  "current time," advanced explicitly via `advance/1` instead of real
  sleeping. Named (`__MODULE__`) rather than referenced by pid, matching
  this codebase's existing convention for singleton test-coordination
  processes in `async: false` suites (e.g. `Riptide.Stream.ReplicaHealer`).
  Only one test process should configure `config :riptide, :clock,
  Riptide.Clock.Virtual` at a time.
  """

  use Agent

  @behaviour Riptide.Clock

  @spec start_link(integer()) :: Agent.on_start()
  def start_link(initial_seconds) do
    Agent.start_link(fn -> initial_seconds end, name: __MODULE__)
  end

  @impl Riptide.Clock
  @spec now() :: integer()
  def now, do: Agent.get(__MODULE__, & &1)

  @spec advance(non_neg_integer()) :: :ok
  def advance(seconds) when is_integer(seconds) and seconds >= 0 do
    Agent.update(__MODULE__, &(&1 + seconds))
  end
end
```

- [ ] **Step 4: Run the test and confirm it passes**

Run: `mix test test/support/clock_virtual_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add test/support/clock_virtual.ex test/support/clock_virtual_test.exs
git commit -m "$(cat <<'EOF'
Add Riptide.Clock.Virtual test-support implementation

Agent-backed Riptide.Clock impl for compressing years of simulated
time into instant advance/1 calls, no real sleeping. Used by Phase
7's decade simulation.
EOF
)"
```

---

### Task 4: Volume-seed helper

**Files:**
- Create: `test/decade/volume_seed.ex`
- Test: `test/decade/volume_seed_test.exs` (new)

**Interfaces:**
- Consumes: `Riptide.Stream.StreamServer.append/2` (existing), `Riptide.Event.new/3` (existing).
- Produces: `Riptide.Decade.VolumeSeed.seed_stream(stream_id, event_count)`, returning `%{count: non_neg_integer(), latencies_us: [non_neg_integer()]}` — one latency sample per 10% of progress, in order.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Riptide.Decade.VolumeSeedTest do
  use ExUnit.Case, async: true

  alias Riptide.Decade.VolumeSeed
  alias Riptide.Stream.StreamServer

  @moduletag :benchmark
  @moduletag timeout: 120_000

  test "seeds the requested number of events and reports one latency sample per decile" do
    stream_id = "decade-volume-seed-" <> Uniq.UUID.uuid4()
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id) end)

    result = VolumeSeed.seed_stream(stream_id, 5_000)

    assert result.count == 5_000
    assert length(result.latencies_us) == 10

    {:ok, events} = StreamServer.get_since(stream_id, 0)
    assert length(events) == 5_000
    assert List.last(events).sequence == 5_000
  end

  test "append latency does not trend upward across the run (regression guard for the RaMachine fix)" do
    stream_id = "decade-volume-seed-trend-" <> Uniq.UUID.uuid4()
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id) end)

    %{latencies_us: samples} = VolumeSeed.seed_stream(stream_id, 20_000)

    first_half_avg = samples |> Enum.take(5) |> Enum.sum() |> Kernel./(5)
    second_half_avg = samples |> Enum.take(-5) |> Enum.sum() |> Kernel./(5)

    ratio = second_half_avg / first_half_avg

    assert ratio < 3,
           "later append-latency samples averaged #{ratio}x the earlier ones " <>
             "(#{inspect(samples)}) — looks like a growth-proportional slowdown"
  end
end
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `mix test test/decade/volume_seed_test.exs --include benchmark --trace`
Expected: FAIL — `Riptide.Decade.VolumeSeed` doesn't exist yet.

- [ ] **Step 3: Implement `Riptide.Decade.VolumeSeed`**

```elixir
defmodule Riptide.Decade.VolumeSeed do
  @moduledoc """
  Fast-forwards a stream to a realistic decade-scale event count by
  appending in a tight loop against the real `Riptide.Stream.StreamServer`
  — no HTTP, no PropCheck, just raw volume. Records one latency sample per
  10% of progress so a growth-proportional slowdown (the bug Task 1 of
  Phase 7 fixed) shows up directly in the numbers instead of just a
  timeout. See the design spec's "Volume seed layer" section.
  """

  alias Riptide.Event
  alias Riptide.Stream.StreamServer

  @spec seed_stream(String.t(), pos_integer()) :: %{
          count: non_neg_integer(),
          latencies_us: [non_neg_integer()]
        }
  def seed_stream(stream_id, event_count) when is_integer(event_count) and event_count > 0 do
    sample_every = max(div(event_count, 10), 1)

    {latencies, _} =
      Enum.reduce(1..event_count, {[], 0}, fn i, {samples, running_micros} ->
        {micros, _event} =
          :timer.tc(fn ->
            StreamServer.append(stream_id, Event.new(stream_id, :replace, RDF.Graph.new()))
          end)

        samples =
          if rem(i, sample_every) == 0 and length(samples) < 10 do
            [micros | samples]
          else
            samples
          end

        {samples, running_micros + micros}
      end)

    %{count: event_count, latencies_us: Enum.reverse(latencies)}
  end
end
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `mix test test/decade/volume_seed_test.exs --include benchmark --trace`
Expected: PASS — the second test in particular re-validates Task 1's fix at the real `StreamServer`/Ra-consensus level, not just the pure-state-machine level.

- [ ] **Step 5: Commit**

```bash
git add test/decade/volume_seed.ex test/decade/volume_seed_test.exs
git commit -m "Add Riptide.Decade.VolumeSeed: fast-forward a stream to decade-scale event volume"
```

---

### Task 5: PropCheck dependency + stateful model

**Files:**
- Modify: `mix.exs`
- Create: `test/decade/model.ex`
- Test: `test/decade/model_test.exs` (new)

**Interfaces:**
- Consumes: `RiptideWeb.Endpoint.call/2`, `Riptide.Authz.Store.TenantFacts.add_policy/3`, `Riptide.Authz.Policy` (all existing, per `test/riptide_web/ldp/resource_controller_test.exs`'s established pattern).
- Produces: `Riptide.Decade.Model` (a `PropCheck.StateM` implementation) and a `PropCheck` property in `model_test.exs` that Task 7's umbrella test reuses (imports `Riptide.Decade.Model`'s command implementations directly, with a different `runner`).

- [ ] **Step 1: Add the dependency and inspect its actual API**

In `mix.exs`, add to `deps/0` (alongside the other `only: [:test]` deps):

```elixir
      {:propcheck, "~> 1.4", only: [:test]},
```

Run: `mix deps.get`

PropCheck has never been used in this codebase before. Before writing `model.ex`, run `mix hex.docs open propcheck` (or read `deps/propcheck/lib/prop_check/state_m.ex` and `deps/propcheck/README.md` directly) and confirm the exact `PropCheck.StateM` callback names/arities (`initial_state/0`, `command/1`, `precondition/2`, `next_state/3`, `postcondition/3`) and generator macros (`oneof/1`, `frequency/1`, `let`) match what Step 3 below assumes — PropCheck's version may have shifted these since this plan was written; adjust Step 3's code to match whatever the installed version actually exposes before moving on.

- [ ] **Step 2: Write the failing test**

```elixir
defmodule Riptide.Decade.ModelTest do
  use ExUnit.Case, async: false
  use PropCheck

  alias Riptide.Decade.Model

  @moduletag :benchmark
  @moduletag timeout: 300_000

  property "a random sequence of tenant/resource operations always matches the model", [:verbose] do
    forall cmds <- commands(Model) do
      {history, state, result} = run_commands(Model, cmds)

      (result == :ok)
      |> when_fail(
        IO.puts("""
        History: #{inspect(history)}
        State: #{inspect(state)}
        Result: #{inspect(result)}
        """)
      )
      |> aggregate(command_names(cmds))
    end
  end
end
```

- [ ] **Step 3: Run it and confirm it fails**

Run: `mix test test/decade/model_test.exs --include benchmark --trace`
Expected: FAIL — `Riptide.Decade.Model` doesn't exist yet.

- [ ] **Step 4: Implement `Riptide.Decade.Model`**

```elixir
defmodule Riptide.Decade.Model do
  @moduledoc """
  A `PropCheck.StateM` reference model for Riptide's LDP resource
  semantics: PUT/PATCH/DELETE and tenant creation, generated in long
  random sequences and checked against the real HTTP surface
  (`Plug.Test.conn/2` + `RiptideWeb.Endpoint.call/2` — the same in-process
  pattern `test/riptide_web/ldp/resource_controller_test.exs` already
  uses; not a live TCP listener) after every step.

  Model state tracks, per `{tenant_id, path}`, the exact set of Turtle
  triple-lines expected to be present — real GET responses are compared
  against this set line-for-line.

  There is no `change_retention` command: `Riptide.Stream.StreamServer`
  only applies `retention` when a stream is first created, and every
  normal write path already hardcodes `:infinity` — there is no live
  retention-mutation operation in this codebase to model.
  """

  use PropCheck
  use PropCheck.StateM

  alias Riptide.Authz.{Policy, Store}
  alias RiptideWeb.LDP.ResourceController

  @endpoint_opts RiptideWeb.Endpoint.init([])

  @impl PropCheck.StateM
  def initial_state, do: %{tenants: [], resources: %{}}

  @impl PropCheck.StateM
  def command(%{tenants: []}) do
    {:call, __MODULE__, :create_tenant, []}
  end

  def command(state) do
    frequency([
      {1, {:call, __MODULE__, :create_tenant, []}},
      {5, {:call, __MODULE__, :put_resource, [oneof(state.tenants), path_gen(), triple_gen()]}},
      {3,
       {:call, __MODULE__, :patch_resource,
        [oneof(state.tenants), path_gen(), triple_gen(), triple_gen()]}},
      {2, {:call, __MODULE__, :delete_resource, [oneof(state.tenants), path_gen()]}}
    ])
  end

  defp path_gen do
    let n <- integer(1, 20) do
      "decade-res-#{n}"
    end
  end

  defp triple_gen do
    let {p, o} <- {oneof(["p1", "p2", "p3"]), integer(1, 1_000)} do
      "<https://decade.example/s> <https://decade.example/#{p}> \"#{o}\" .\n"
    end
  end

  @impl PropCheck.StateM
  def precondition(_state, _call), do: true

  @impl PropCheck.StateM
  def next_state(state, tenant_id, {:call, __MODULE__, :create_tenant, []}) do
    %{state | tenants: [tenant_id | state.tenants]}
  end

  def next_state(state, _result, {:call, __MODULE__, :put_resource, [tenant_id, path, triple]}) do
    put_in(state, [:resources, {tenant_id, path}], MapSet.new([triple]))
  end

  def next_state(
        state,
        _result,
        {:call, __MODULE__, :patch_resource, [tenant_id, path, addition, removal]}
      ) do
    current = Map.get(state.resources, {tenant_id, path}, MapSet.new())
    updated = current |> MapSet.delete(removal) |> MapSet.put(addition)
    put_in(state, [:resources, {tenant_id, path}], updated)
  end

  def next_state(
        state,
        _result,
        {:call, __MODULE__, :delete_resource, [tenant_id, path]}
      ) do
    %{state | resources: Map.delete(state.resources, {tenant_id, path})}
  end

  @impl PropCheck.StateM
  def postcondition(_state, {:call, __MODULE__, :create_tenant, []}, tenant_id) do
    is_binary(tenant_id)
  end

  def postcondition(state, {:call, __MODULE__, :put_resource, [tenant_id, path, triple]}, status) do
    status == 201 and
      current_triples(tenant_id, path) == MapSet.new([triple])
  end

  def postcondition(
        state,
        {:call, __MODULE__, :patch_resource, [tenant_id, path, addition, removal]},
        status
      ) do
    expected =
      state.resources
      |> Map.get({tenant_id, path}, MapSet.new())
      |> MapSet.delete(removal)
      |> MapSet.put(addition)

    status == 200 and current_triples(tenant_id, path) == expected
  end

  def postcondition(_state, {:call, __MODULE__, :delete_resource, [tenant_id, path]}, status) do
    status == 204 and current_triples(tenant_id, path) == MapSet.new()
  end

  @spec current_triples(String.t(), String.t()) :: MapSet.t(String.t())
  defp current_triples(tenant_id, path) do
    conn =
      :get
      |> Plug.Test.conn("/tenants/#{tenant_id}/resources/#{path}")
      |> RiptideWeb.Endpoint.call(@endpoint_opts)

    case conn.status do
      404 -> MapSet.new()
      200 -> conn.resp_body |> String.split("\n", trim: true) |> Enum.map(&(&1 <> "\n")) |> MapSet.new()
    end
  end

  @doc false
  @spec create_tenant() :: String.t()
  def create_tenant do
    tenant_id = Uniq.UUID.uuid4()

    :ok =
      Store.TenantFacts.add_policy(tenant_id, [], %Policy{
        effect: :allow,
        modes: [:read, :write],
        matcher: :public
      })

    tenant_id
  end

  @doc false
  @spec put_resource(String.t(), String.t(), String.t()) :: integer()
  def put_resource(tenant_id, path, triple) do
    :put
    |> Plug.Test.conn("/tenants/#{tenant_id}/resources/#{path}", triple)
    |> Plug.Conn.put_req_header("content-type", "text/turtle")
    |> RiptideWeb.Endpoint.call(@endpoint_opts)
    |> Map.fetch!(:status)
  end

  @doc false
  @spec patch_resource(String.t(), String.t(), String.t(), String.t()) :: integer()
  def patch_resource(tenant_id, path, addition, removal) do
    body = Jason.encode!(%{"additions" => addition, "removals" => removal})

    :patch
    |> Plug.Test.conn("/tenants/#{tenant_id}/resources/#{path}", body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> RiptideWeb.Endpoint.call(@endpoint_opts)
    |> Map.fetch!(:status)
  end

  @doc false
  @spec delete_resource(String.t(), String.t()) :: integer()
  def delete_resource(tenant_id, path) do
    :delete
    |> Plug.Test.conn("/tenants/#{tenant_id}/resources/#{path}")
    |> RiptideWeb.Endpoint.call(@endpoint_opts)
    |> Map.fetch!(:status)
  end
end
```

Note: `put_resource`'s postcondition assumes a fresh `path` per call in practice (the small `path_gen/0` range means real collisions between an earlier `put`/`patch` on the same `{tenant, path}` and a later `put_resource` overwriting it are expected and handled correctly by both the model's `next_state/3`, which always replaces wholesale, and the real `PUT` semantics, which also always replace wholesale — this is intentional, not a bug in the model).

- [ ] **Step 5: Run the test, expect real failures the first few times, fix, repeat**

Run: `mix test test/decade/model_test.exs --include benchmark --trace`

This is the step most likely to need iteration — a first-time PropCheck integration commonly needs adjustment (macro names from Step 1's own API check, off-by-one in `current_triples/2`'s Turtle-line splitting, etc.). Fix forward against real output until green. Do not weaken postconditions to force a pass — a genuine mismatch here is either a model bug (fix the model) or a real product bug (fix the product, per this plan's Global Constraints).

Expected once fixed: PASS, with PropCheck's `aggregate/2` output showing a roughly even spread across the four command names.

- [ ] **Step 6: Commit**

```bash
git add mix.exs mix.lock test/decade/model.ex test/decade/model_test.exs
git commit -m "Add Riptide.Decade.Model: PropCheck stateful model for LDP resource semantics"
```

---

### Task 6: Chaos helper (node kill/restart, reusing existing multi-node test infra)

**Files:**
- Create: `test/decade/chaos.ex`
- Test: `test/decade/chaos_test.exs` (new)

**Interfaces:**
- Consumes: `Riptide.MultiNodeTestHelpers.unique_pairs/1` and `own_module_bytecode/1` (existing), the exact peer-bootstrap sequence already proven in `test/riptide/stream/replica_healer_leadership_gate_test.exs`.
- Produces: `Riptide.Decade.Chaos.start_cluster/1` (peer specs → `[{pid, node, ordinal}]`, with every peer running `:ra`, `Phoenix.PubSub`, `Riptide.Stream.Placement`, and `Riptide.Stream.ReplicaHealer`), `kill_node/2`, `await_leader/1`. Task 7 uses these directly.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Riptide.Decade.ChaosTest do
  use ExUnit.Case, async: false

  alias Riptide.Decade.Chaos

  @moduletag timeout: 60_000

  # A 4th, deliberately-unassigned "spare" peer is required, not optional:
  # `ReplicaHealer.pick_replacement/2` only ever picks a live fleet node
  # NOT already among a stream's current members — with only 3 total nodes
  # and all 3 already assigned to the stream, there is no candidate to
  # promote and a "repair" silently no-ops (`do_claimed_repair`'s `nil ->
  # :ok` branch). This exactly mirrors `replica_healer_leadership_gate_test.exs`'s
  # own `@replacement` peer for the identical reason.
  @peers [
    {:chaos_a, "chaos-riptide-0", ~c"127.0.0.80"},
    {:chaos_b, "chaos-riptide-1", ~c"127.0.0.81"},
    {:chaos_c, "chaos-riptide-2", ~c"127.0.0.82"}
  ]
  @spare {:chaos_spare, "chaos-riptide-spare", ~c"127.0.0.83"}

  setup_all do
    unless Node.alive?() do
      {:ok, _pid} = Node.start(:"decade_chaos_test_origin@127.0.0.1", :longnames)
    end

    :ok
  end

  test "a killed replica is detected and repaired by the real ReplicaHealer sweep path" do
    all_specs = @peers ++ [@spare]
    peers = Chaos.start_cluster(all_specs)
    on_exit(fn -> Chaos.stop_cluster(peers, all_specs) end)

    [{_pid_a, node_a, _}, {_pid_b, node_b, _}, {_pid_c, node_c, _}, {_pid_spare, _node_spare, _}] =
      peers

    original_nodes = [node_a, node_b, node_c]

    stream_id = "decade-chaos-" <> Uniq.UUID.uuid4()
    assert Enum.sort(:erpc.call(node_a, Riptide.Placement, :assign, [stream_id, original_nodes])) ==
             Enum.sort(original_nodes)

    assert :ok = :erpc.call(node_a, Riptide.Stream.StreamSupervisor, :ensure_ready, [stream_id])

    Chaos.kill_node(peers, node_c)

    leader_node = Chaos.await_leader([node_a, node_b])
    assert leader_node != nil

    :erpc.call(leader_node, :erlang, :send, [Riptide.Stream.ReplicaHealer, :sweep])
    :erpc.call(leader_node, :sys, :get_state, [Riptide.Stream.ReplicaHealer, 30_000])

    repaired_nodes = :erpc.call(node_a, Riptide.Placement, :lookup, [stream_id])
    assert length(repaired_nodes) == 3
    refute node_c in repaired_nodes
  end
end
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `mix test test/decade/chaos_test.exs`
Expected: FAIL — `Riptide.Decade.Chaos` doesn't exist yet.

- [ ] **Step 3: Implement `Riptide.Decade.Chaos`**

This directly extracts and generalizes the exact, already-proven bootstrap sequence from `test/riptide/stream/replica_healer_leadership_gate_test.exs` (peer start → push bytecode → connect nodes → start `:ra`/PubSub/Placement/ReplicaHealer on each) rather than inventing a new one — see that file for the line-by-line precedent this follows.

```elixir
defmodule Riptide.Decade.Chaos do
  @moduledoc """
  Reusable wrapper around this codebase's existing `:peer`-based multi-node
  test pattern (see `test/riptide/stream/replica_healer_leadership_gate_test.exs`,
  the first place this sequence was proven) — bootstraps a real N-node
  cluster with `:ra`, `Phoenix.PubSub`, `Riptide.Stream.Placement`, and
  `Riptide.Stream.ReplicaHealer` running on every node, and exposes
  `kill_node/2` to drive the real production repair path during Phase 7's
  decade simulation.
  """

  import Riptide.MultiNodeTestHelpers, only: [unique_pairs: 1]

  @type peer_spec :: {atom(), String.t(), charlist()}
  @type started_peer :: {pid(), node(), String.t()}

  @spec start_cluster([peer_spec()]) :: [started_peer()]
  def start_cluster(peer_specs) do
    pa_args = Enum.flat_map(:code.get_path(), fn p -> [~c"-pa", p] end)

    peers =
      for {alive_name, ordinal, host} <- peer_specs do
        {:ok, pid, node} =
          :peer.start_link(%{
            name: alive_name,
            host: host,
            longnames: true,
            args: pa_args,
            env: [{~c"HOSTNAME", to_charlist(ordinal)}]
          })

        {pid, node, ordinal}
      end

    nodes = Enum.map(peers, fn {_pid, node, _ordinal} -> node end)

    for {_pid, node, _ordinal} <- peers do
      :erpc.call(node, Application, :put_env, [
        :riptide,
        :replica_healer_sweep_interval_ms,
        3_600_000
      ])
    end

    for {n1, n2} <- unique_pairs(nodes) do
      true = :erpc.call(n1, :net_kernel, :connect_node, [n2])
    end

    for {_pid, node, _ordinal} <- peers do
      {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:ra])

      case :erpc.call(node, :ra_system, :start, [
             :erpc.call(node, Riptide.RaCluster, :system_config, [])
           ]) do
        {:ok, _pid} -> :ok
        {:ok, _pid, _info} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    :ok =
      case Enum.map(peers, fn {_pid, node, _ordinal} ->
             :erpc.call(node, Riptide.RaCluster.Placement, :start_genesis_placement_cluster, [
               nodes
             ])
           end) do
        results -> if Enum.any?(results, &(&1 == :ok)), do: :ok
      end

    for {_pid, node, _ordinal} <- peers do
      {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:phoenix_pubsub])
      {:ok, _} = start_unlinked(node, Phoenix.PubSub.Supervisor, :start_link, [[name: Riptide.PubSub]])
      {:ok, _} = start_unlinked(node, Riptide.Stream.Placement, :start_link, [[]])
      {:ok, _} = start_unlinked(node, Riptide.Stream.ReplicaHealer, :start_link, [[]])
    end

    peers
  end

  @spec stop_cluster([started_peer()], [peer_spec()]) :: :ok
  def stop_cluster(peers, peer_specs) do
    Enum.each(peers, fn {pid, _node, _ordinal} ->
      if Process.alive?(pid) do
        try do
          :peer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    Enum.each(peer_specs, fn {_alive_name, ordinal, _host} ->
      File.rm_rf!(Path.join(File.cwd!(), ordinal))
    end)

    :ok
  end

  @spec kill_node([started_peer()], node()) :: :ok
  def kill_node(peers, target_node) do
    {pid, ^target_node, _ordinal} =
      Enum.find(peers, fn {_pid, node, _ordinal} -> node == target_node end)

    try do
      :peer.stop(pid)
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  @spec await_leader([node()], pos_integer()) :: node() | nil
  def await_leader(candidate_nodes, attempts_left \\ 50) do
    case Enum.find(candidate_nodes, fn node ->
           :erpc.call(node, Riptide.RaCluster.Placement, :placement_leader?, [])
         end) do
      nil when attempts_left > 1 ->
        Process.sleep(200)
        await_leader(candidate_nodes, attempts_left - 1)

      found ->
        found
    end
  end

  defp start_unlinked(node, mod, fun, args, timeout \\ 5_000) do
    parent = self()

    :erlang.spawn(node, fn ->
      result = apply(mod, fun, args)
      send(parent, {:start_unlinked_result, result})
      Process.sleep(:infinity)
    end)

    receive do
      {:start_unlinked_result, result} -> result
    after
      timeout -> {:error, :timeout}
    end
  end
end
```

Note one deliberate deviation from the source test: that file pushes its own test module's bytecode to each peer (`own_module_bytecode(__MODULE__)` + `:code.load_binary/3`) because its `test "..."` body itself runs partly via closures captured by value — `Riptide.Decade.Chaos` doesn't need this, since every function it calls remotely (`Riptide.Placement`, `Riptide.Stream.StreamSupervisor`, etc.) is already compiled application code available on every peer via `-pa`, not test-file-local code.

- [ ] **Step 4: Run the test and confirm it passes**

Run: `mix test test/decade/chaos_test.exs --trace`
Expected: PASS. This test is deliberately *not* tagged `:benchmark` — unlike the volume/model layers it's fast (a few seconds) and is exactly the kind of correctness check that should run in a normal `mix test` if run explicitly by file, matching `replica_healer_leadership_gate_test.exs`'s own precedent of running untagged.

- [ ] **Step 5: Commit**

```bash
git add test/decade/chaos.ex test/decade/chaos_test.exs
git commit -m "Add Riptide.Decade.Chaos: reusable node kill/restart for multi-node tests"
```

---

### Task 7: Umbrella `decade_simulation_test.exs`

**Files:**
- Create: `test/decade/decade_simulation_test.exs`

**Interfaces:**
- Consumes: `Riptide.Decade.VolumeSeed.seed_stream/2` (Task 4), `Riptide.Decade.Model` command functions (Task 5), `Riptide.Decade.Chaos.start_cluster/1`/`kill_node/2`/`await_leader/2` (Task 6), `Riptide.Clock.Virtual.start_link/1`/`advance/1` (Task 3).

Per this plan's Global Constraints (correction 1), the model's HTTP-surface commands (`Plug.Test` + `Endpoint.call/2`) only work against a node running the full Phoenix app — which none of the `:peer`-spawned chaos nodes do (they only start the specific GenServers `Chaos.start_cluster/1` starts, matching every existing multi-node test in this repo). Rather than also bootstrapping a full `RiptideWeb.Endpoint` on every peer (unproven anywhere in this codebase, meaningfully riskier), this task drives the chaos-interleaved phase's writes directly against a peer node's `Riptide.Stream.StreamServer` via `:erpc.call` — the same production LDP-shaping primitives the model's own `put_resource/3` etc. ultimately call into, just one layer below the HTTP router. The Authz/router pipeline is still fully exercised, separately, by Task 5's own standalone `model_test.exs`.

- [ ] **Step 1: Write the test**

There's no separate "failing then passing" cycle here in the usual TDD sense — this task composes already-implemented, already-tested pieces; the test itself is the deliverable, and "run it, watch it fail for a real integration reason, fix the integration, rerun" is the loop.

```elixir
defmodule Riptide.Decade.SimulationTest do
  use ExUnit.Case, async: false

  alias Riptide.Decade.{Chaos, VolumeSeed}

  @moduletag :decade_simulation
  @moduletag timeout: :infinity

  @peers [
    {:decade_a, "decade-riptide-0", ~c"127.0.0.90"},
    {:decade_b, "decade-riptide-1", ~c"127.0.0.91"},
    {:decade_c, "decade-riptide-2", ~c"127.0.0.92"}
  ]

  # Two spares, not one: each real repair (see Task 6's own note on this)
  # consumes exactly one live non-member node as its replacement, so
  # driving two full kill+repair rounds — proving the healer keeps working
  # across *repeated* chaos, not just once — needs two. A third round would
  # need a third spare; two is enough to prove the mechanism repeats.
  @spares [
    {:decade_spare_1, "decade-riptide-spare-1", ~c"127.0.0.93"},
    {:decade_spare_2, "decade-riptide-spare-2", ~c"127.0.0.94"}
  ]

  # ~10 years at one write every 5 minutes.
  @decade_event_count 10 * 365 * 24 * 12
  @seconds_per_chaos_round 86_400 * 180

  setup_all do
    unless Node.alive?() do
      {:ok, _pid} = Node.start(:"decade_simulation_origin@127.0.0.1", :longnames)
    end

    :ok
  end

  test "a decade of usage: volume, diverse operations, and chaos, all at once" do
    {:ok, _clock} = Riptide.Clock.Virtual.start_link(System.system_time(:second))
    previous_clock_config = Application.get_env(:riptide, :clock)
    Application.put_env(:riptide, :clock, Riptide.Clock.Virtual)
    on_exit(fn -> Application.put_env(:riptide, :clock, previous_clock_config) end)

    all_specs = @peers ++ @spares
    peers = Chaos.start_cluster(all_specs)
    on_exit(fn -> Chaos.stop_cluster(peers, all_specs) end)

    [{_pid_a, node_a, _}, {_pid_b, node_b, _}, {_pid_c, node_c, _} | _spares] = peers
    original_nodes = [node_a, node_b, node_c]

    # Phase 1: fast-forward a hot stream to decade-scale volume, directly
    # on the real local (origin) app instance test_helper.exs already
    # booted — this is the same regression guard as volume_seed_test.exs,
    # kept here so a real degrading trend fails the umbrella scenario too.
    hot_stream_id = "decade-hot-" <> Uniq.UUID.uuid4()
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(hot_stream_id) end)
    seed_result = VolumeSeed.seed_stream(hot_stream_id, @decade_event_count)

    first_avg = seed_result.latencies_us |> Enum.take(3) |> Enum.sum() |> Kernel./(3)
    last_avg = seed_result.latencies_us |> Enum.take(-3) |> Enum.sum() |> Kernel./(3)
    assert last_avg / first_avg < 3

    # Phase 2: diverse operations against the multi-node chaos cluster,
    # interleaved with node kills, real repairs, and virtual-clock jumps.
    remote_stream_id = "decade-remote-" <> Uniq.UUID.uuid4()
    assert Enum.sort(:erpc.call(node_a, Riptide.Placement, :assign, [remote_stream_id, original_nodes])) ==
             Enum.sort(original_nodes)

    assert :ok = :erpc.call(node_a, Riptide.Stream.StreamSupervisor, :ensure_ready, [remote_stream_id])

    Enum.reduce(1..2, original_nodes, fn round, current_members ->
      graph = :erpc.call(node_a, RDF.Graph, :new, [])
      event = :erpc.call(node_a, Riptide.Event, :new, [remote_stream_id, :replace, graph])
      stamped = :erpc.call(node_a, Riptide.Stream.StreamServer, :append, [remote_stream_id, event])
      assert stamped.sequence == round

      Riptide.Clock.Virtual.advance(@seconds_per_chaos_round)

      # Always kill a still-live *original* member (node_a keeps
      # orchestrating via :erpc from the origin, so never kill it).
      target = Enum.find(current_members, &(&1 != node_a))
      Chaos.kill_node(peers, target)

      survivors = current_members -- [target]
      leader = Chaos.await_leader(survivors)
      assert leader != nil, "no survivor became placement leader after killing #{inspect(target)}"

      :erpc.call(leader, :erlang, :send, [Riptide.Stream.ReplicaHealer, :sweep])
      :erpc.call(leader, :sys, :get_state, [Riptide.Stream.ReplicaHealer, 30_000])

      repaired = :erpc.call(node_a, Riptide.Placement, :lookup, [remote_stream_id])
      assert length(repaired) == 3
      refute target in repaired

      repaired
    end)

    {:ok, final_events} = :erpc.call(node_a, Riptide.Stream.StreamServer, :get_since, [remote_stream_id, 0])
    assert length(final_events) == 2
  end
end
```

- [ ] **Step 2: Run it, iterate to green**

Run: `mix test test/decade/decade_simulation_test.exs --include decade_simulation --trace`

Expect real friction here — this is the first time all four layers run together. The two-spare
design keeps each round's repair using a genuinely fresh replacement (avoiding Task 6's
no-op-repair pitfall twice over), but if the second round's repair doesn't settle in time, widen
`await_leader/2`'s attempt budget before assuming something is actually broken — a cold-started
peer's placement cluster can take longer to elect a leader than the existing 50×200ms budget
assumes under load from Phase 1's volume seeding still running nearby. Adjust whichever part
actually flakes until the test passes reliably across at least 3 consecutive runs.

Expected once stable: PASS, consistently across at least 3 consecutive runs (run it 3x in a row to confirm — chaos/multi-node tests are exactly the kind that pass once by luck).

- [ ] **Step 3: Commit**

```bash
git add test/decade/decade_simulation_test.exs
git commit -m "$(cat <<'EOF'
Add the Phase 7 umbrella decade-simulation test

Composes volume-seeding, a virtual clock, and chaos (node kill +
real ReplicaHealer repair) into one scenario approximating a decade
of Riptide usage. Tagged :decade_simulation, excluded by default —
run explicitly with `mix test --include decade_simulation`.
EOF
)"
```

---

### Task 8: `PROGRESS.md` Phase 7 entry + final full-suite verification

**Files:**
- Modify: `PROGRESS.md`

**Interfaces:** None — documentation and verification only.

- [ ] **Step 1: Read `PROGRESS.md`'s existing phase-entry format**

Match the exact style of the most recent entries (e.g. "6r — Generic OpenAI-Compatible LLM Client", "6p-iii — The Sub-project 6 Demo Page"): a `### 7 — <Title>` heading, a **Shipped <date>** line linking the spec and plan, a prose summary of what was built and why, and a closing **Status** line.

- [ ] **Step 2: Write the entry**

Append to `PROGRESS.md`:

```markdown
### 7 — Decade Simulation Testing

**Shipped 2026-09-15** — see
`docs/superpowers/specs/2026-09-15-phase-7-decade-simulation-testing-design.md` and
`docs/superpowers/plans/2026-09-15-phase-7-decade-simulation-testing.md`. Direct origin: a
request to test Riptide against ten years of simulated usage, decomposed during brainstorming
into four composable layers rather than a literal ten-year run.

Found and fixed a real bug during the research phase, before any new code was written:
`Riptide.Stream.RaMachine` stored an `:infinity`-retention stream's events in a plain list
appended via `events ++ [x]` — O(n) per append, O(n^2) over a stream's lifetime, invisible at
test scale. Fixed by switching internal storage to Erlang's `:queue` (O(1) amortized append),
proven with a scaling-ratio regression test at both the pure-state-machine level and, via the
new volume-seed layer, at the real `Riptide.Stream.StreamServer`/Ra-consensus level.

Four new permanent, on-demand (never CI-wired, per explicit decision) test capabilities, each
independently runnable:
- `Riptide.Clock` — a swappable wall-clock indirection (`Riptide.Clock.System` default,
  `Riptide.Clock.Virtual` test-only) wired into the one production call site that read
  `System.system_time/1` directly. Minimal today, deliberately — cheap now, expensive to
  retrofit once Phase 6a's bitemporal fact shape lands.
- `Riptide.Decade.VolumeSeed` — fast-forwards a stream to realistic decade-scale event volume
  against the real `StreamServer`, recording latency samples to catch growth-proportional
  regressions directly.
- `Riptide.Decade.Model` — a PropCheck stateful model of LDP resource semantics (PUT/PATCH/
  DELETE/tenant creation), checked against the real in-process HTTP surface after every
  generated step.
- `Riptide.Decade.Chaos` — reusable node kill/restart, extracted from the existing
  `replica_healer_leadership_gate_test.exs` `:peer`-bootstrap pattern rather than inventing a
  new one, driving the real production `ReplicaHealer` repair path.

`test/decade/decade_simulation_test.exs` (tag `:decade_simulation`) composes all four into one
scenario. Explicitly out of scope, per the design spec: CI wiring, network-partition chaos, and
dependency/OTP version-drift simulation (a real but different concern from usage simulation).

**Status**: Phase 7 shipped 2026-09-15.
```

Adjust the "Shipped" date to whatever date Task 7 actually completes on, if different from when this entry is written.

- [ ] **Step 3: Run the full, untagged test suite to confirm nothing else broke**

Run: `mix test`
Expected: PASS — every pre-existing test (none of this plan's new files run by default; the RaMachine/Clock/placement changes from Tasks 1–2 are the only production-code edits, both already re-verified in their own tasks, but a full run catches any cross-area interaction those tasks' own narrower runs wouldn't).

- [ ] **Step 4: Run every new benchmark/decade-simulation test together, explicitly, to confirm the whole set is stable**

Run: `mix test --include benchmark --include decade_simulation`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add PROGRESS.md
git commit -m "Update PROGRESS.md for Phase 7 (decade simulation testing)"
```

## Self-Review Notes

- **Spec coverage:** Clock (§1) → Tasks 2–3. Volume seed (§2) → Task 4. PropCheck model (§3) → Task 5. Chaos (§4) → Task 6. Umbrella scenario (§5) → Task 7. "Bugs found get fixed here" (§6) → Task 1. `PROGRESS.md` tracking → Task 8. All spec sections covered.
- **Placeholder scan:** no TBD/TODO; the one place this plan explicitly asks the implementer to adapt code in place (Task 7 Step 2, restart-vs-skip fallback) is a real, bounded engineering decision with a concrete fallback given, not an unspecified gap.
- **Type consistency:** `Riptide.Decade.VolumeSeed.seed_stream/2` return shape (`%{count:, latencies_us:}`) used consistently in Tasks 4 and 7. `Riptide.Decade.Chaos` function names (`start_cluster/1`, `stop_cluster/2`, `kill_node/2`, `await_leader/1,2`) used consistently in Tasks 6 and 7.
