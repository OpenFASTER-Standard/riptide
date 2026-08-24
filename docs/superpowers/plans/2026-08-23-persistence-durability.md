# Riptide Persistence & Durability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Riptide's in-memory, restart-losing event log with a single-node `Ra`-replicated durable log per stream, and close the two real Event-model bugs (non-functional PATCH removals, PUT-empty-body indistinguishable from DELETE) plus two missing regression tests — so Phase 1 of the Persistence & durability sub-project ships as a complete, tidy unit with nothing carried forward.

**Architecture:** `Riptide.Stream.StreamServer`'s public API (`append/2`, `get_since/2`) stays byte-identical so `resource_controller.ex`/`sse_controller.ex`/`replication_channel.ex` need zero changes. Underneath, it becomes a thin client over a new `Riptide.RaCluster` wrapper (the verified `:ra` API surface) and a new `Riptide.Stream.RaMachine` (`:ra_machine` behaviour — pure `init/1`/`apply/3`, unit-testable without a running Ra process) that ports the exact sequence-assignment/retention/gap logic already in `StreamServer` today. Separately, `Riptide.Event` gains an explicit `:replace | :delete | :patch` operation field (replacing the `is_snapshot?` boolean), which lets `resource_controller.ex`'s fold correctly apply stored removals and correctly distinguish "deleted" from "explicitly empty" — fixing both bugs with one model change, exactly as scoped in `PROGRESS.md`.

**Tech Stack:** Elixir 1.18 / OTP 25, Phoenix, `:ra` (Erlang Raft library, new dependency), ExUnit, `RDF.ex`.

**Spec:** `docs/superpowers/specs/2026-08-23-persistence-durability-design.md` (as revised 2026-08-23 — the Kafka-scale/Scalog-sequencer follow-on is out of scope, not deferred-but-planned; see its §6).

## Global Constraints

- Elixir `~> 1.17` (currently running 1.18.4 / OTP 25) — `mix.exs:6`.
- Test command: `mix test`, run from `/work/riptide`.
- New deps use the existing house style: `{:name, "~> X.Y"}`, one per line, in `mix.exs`'s `deps/0` (`mix.exs:24-31`).
- `stream_id` is an arbitrary string (a full URI, e.g. `"https://riptide.example/resources/foo"`) — **never** call `String.to_atom/1` on it directly; Ra server IDs need atoms, so always hash first (unbounded atom-table growth is a real risk otherwise).
- `Riptide.Stream.StreamServer.append/2` and `get_since/2` — signatures and the `{:ok, [Event.t()]} | {:gap, pos_integer() | nil}` return contract must not change shape. `resource_controller.ex`, `sse_controller.ex`, `replication_channel.ex` all call through these and must need zero changes for the Ra migration itself (Task 6's Event changes are a separate, deliberate exception).
- The StreamLD wire protocol (SSE `data:` payloads, WebSocket `"replication_frame"` shape — `isSnapshot`/`payload` fields) must stay byte-compatible with today's output. Task 6 changes Riptide's *internal* `Event` representation but must not change what goes out over the wire — no cross-repo StreamLD spec change is in scope here.
- Branch: stay on the existing `persistence-durability` branch (already checked out in `/work/riptide`, already carries the design-doc commit `7ff81a6`). No new branch, no worktree (this box's standing no-worktree rule).
- Out of scope, do not implement: multi-node `Ra` replication, tiered/cold object storage, any multi-shard sequencer/coordinator — see design doc §6 (revised 2026-08-23).

---

## File Structure

New files:
- `lib/riptide/ra_cluster.ex` — thin wrapper around the specific `:ra` calls Riptide needs (deterministic naming, start-or-restart, command submission, local query).
- `lib/riptide/stream/ra_machine.ex` — the `:ra_machine` behaviour implementation (pure state machine, ported from today's `StreamServer` GenServer callbacks).
- `test/riptide/ra_cluster_test.exs`, `test/riptide/stream/ra_machine_test.exs` — new test files matching the two files above.
- `test/support/ra_test_helpers.ex` — shared `on_exit` cleanup helper so Ra-backed tests don't leak on-disk data between runs.
- `/work/openfaster-spec/streamld/tests/test_shape_mirror_drift.py` — the SHACL/shacl2code drift-detection test, in the sibling spec repo.

Modified files:
- `lib/riptide/stream/stream_server.ex` — full rewrite: thin Ra client instead of a GenServer.
- `lib/riptide/stream/stream_supervisor.ex` — simplified: `get_or_start/1` now just calls `StreamServer.start_link/1` (Ra manages its own process lifecycle; no more DynamicSupervisor/Registry needed for this).
- `lib/riptide/application.ex` — remove the now-unused `Riptide.Stream.Registry` and `Riptide.Stream.StreamSupervisor` supervision-tree children.
- `lib/riptide/event.ex` — operation-type redesign.
- `lib/riptide_web/ldp/resource_controller.ex` — use the new `Event.new/3` operation API; fold correctly applies patches/deletes.
- `lib/riptide_web/realtime/replication_channel.ex`, `lib/riptide_web/realtime/sse_controller.ex` — read wire `isSnapshot`/`payload` via new `Event.wire_snapshot?/1`/`Event.wire_payload/1` helpers instead of the removed `is_snapshot?` field.
- `test/riptide/stream/stream_server_test.exs`, `test/riptide/stream/stream_supervisor_test.exs`, `test/riptide_web/realtime/replication_channel_test.exs`, `test/riptide_web/realtime/sse_controller_test.exs`, `test/riptide/event_test.exs`, `test/riptide_web/ldp/resource_controller_test.exs` — updated for the above.
- `mix.exs`, `config/config.exs`, `config/test.exs`, `.gitignore` — new `:ra` dependency and its data-directory config.
- `PROGRESS.md`, `README.md` — status update once shipped.

---

### Task 1: Pin `:ra` and verify its API with a real crash-and-restart spike

**Files:**
- Modify: `mix.exs`, `config/config.exs`, `config/test.exs`, `.gitignore`
- Create: `lib/riptide/ra_cluster.ex`
- Test: `test/riptide/ra_cluster_test.exs`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: `Riptide.RaCluster.server_id/1`, `uid_for/1`, `start_or_restart/2`, `process_command/2`, `local_query/2` — every later task's Ra access goes through these, so their exact `:ra` call shapes must be nailed down and proven working here, not guessed at downstream.

- [ ] **Step 1: Find and pin the current `:ra` version**

Run: `mix hex.info ra`

Note the latest version. Add it to `mix.exs`'s `deps/0` matching house style (adjust the minor version below to whatever `hex.info` reports if different from `2.x`):

```elixir
defp deps do
  [
    {:phoenix, "~> 1.8"},
    {:plug_cowboy, "~> 2.7"},
    {:jason, "~> 1.4"},
    {:rdf, "~> 3.0"},
    {:json_ld, "~> 1.0"},
    {:uniq, "~> 0.6"},
    {:ra, "~> 2.0"}
  ]
end
```

- [ ] **Step 2: Fetch the dependency**

Run: `mix deps.get`
Expected: `ra` (and its own deps, e.g. `gen_batch_server`) appear in `mix.lock`.

- [ ] **Step 3: Configure a data directory and make sure it's `.gitignore`d**

Add to `config/config.exs` (after the existing config, before any environment-specific `import_config`):

```elixir
config :ra, data_dir: System.get_env("RIPTIDE_RA_DATA_DIR", "priv/ra_data")
```

Add to `config/test.exs`:

```elixir
config :ra, data_dir: "priv/ra_data_test"
```

Append to `.gitignore`:

```
priv/ra_data/
priv/ra_data_test/
```

- [ ] **Step 4: Write the `RaCluster` wrapper**

Create `lib/riptide/ra_cluster.ex`:

```elixir
defmodule Riptide.RaCluster do
  @moduledoc """
  The only module that calls into `:ra` directly. Every function here is
  verified against the pinned `:ra` version by `test/riptide/ra_cluster_test.exs`
  before any other module builds on top of it — if your pinned version's API
  differs from what's written here, this is the one place to fix it.
  """

  @system :default

  @spec server_id(String.t()) :: :ra.server_id()
  def server_id(stream_id) do
    {String.to_atom(uid_for(stream_id)), node()}
  end

  @spec uid_for(String.t()) :: binary()
  def uid_for(stream_id) do
    "riptide_" <> Base.encode16(:crypto.hash(:sha256, stream_id), case: :lower)
  end

  @spec start_or_restart(String.t(), :ra_machine.machine()) :: :ra.server_id()
  def start_or_restart(stream_id, machine) do
    server_id = server_id(stream_id)

    case :ra.restart_server(@system, server_id) do
      :ok ->
        server_id

      {:error, {:already_started, _pid}} ->
        server_id

      {:error, _reason} ->
        cluster_name = uid_for(stream_id) <> "_cluster"

        case :ra.start_cluster(@system, cluster_name, machine, [server_id]) do
          {:ok, [_server_id], []} -> server_id
          {:error, {:already_started, _pid}} -> server_id
        end
    end
  end

  @spec process_command(:ra.server_id(), term()) :: term()
  def process_command(server_id, command) do
    case :ra.process_command(server_id, command) do
      {:ok, reply, _leader} -> reply
      {:error, reason} -> raise "Ra command failed for #{inspect(server_id)}: #{inspect(reason)}"
      {:timeout, _} -> raise "Ra command timed out for #{inspect(server_id)}"
    end
  end

  @spec local_query(:ra.server_id(), (term() -> term())) :: term()
  def local_query(server_id, query_fun) do
    case :ra.local_query(server_id, query_fun) do
      {:ok, {_index_term, result}, _leader} -> result
      {:error, reason} -> raise "Ra query failed for #{inspect(server_id)}: #{inspect(reason)}"
      {:timeout, _} -> raise "Ra query timed out for #{inspect(server_id)}"
    end
  end

  @spec force_delete(String.t()) :: :ok
  def force_delete(stream_id) do
    server_id = server_id(stream_id)
    _ = :ra.force_delete_server(@system, server_id)
    :ok
  end
end
```

- [ ] **Step 5: Write the crash-and-restart spike test**

This is the step that actually proves the API calls above are correct for your pinned `:ra` version — expect to adjust Step 4's code based on what you learn running this. Create `test/riptide/ra_cluster_test.exs`:

```elixir
defmodule Riptide.RaClusterTest do
  use ExUnit.Case, async: true

  alias Riptide.RaCluster

  defmodule EchoMachine do
    @behaviour :ra_machine

    @impl :ra_machine
    def init(_config), do: []

    @impl :ra_machine
    def apply(_meta, {:add, item}, state) do
      new_state = [item | state]
      {new_state, new_state, []}
    end
  end

  setup do
    stream_id = "ra-spike-" <> Uniq.UUID.uuid4()
    on_exit(fn -> RaCluster.force_delete(stream_id) end)
    %{stream_id: stream_id}
  end

  test "data survives stopping and restarting the Ra server", %{stream_id: stream_id} do
    machine = {:module, EchoMachine, %{}}
    server_id = RaCluster.start_or_restart(stream_id, machine)

    assert RaCluster.process_command(server_id, {:add, "a"}) == ["a"]
    assert RaCluster.process_command(server_id, {:add, "b"}) == ["b", "a"]
    assert RaCluster.local_query(server_id, & &1) == ["b", "a"]

    {name, _node} = server_id
    pid = Process.whereis(name)
    assert is_pid(pid)
    Process.exit(pid, :kill)
    refute Process.alive?(pid)

    restarted_id = RaCluster.start_or_restart(stream_id, machine)
    assert restarted_id == server_id
    assert RaCluster.local_query(restarted_id, & &1) == ["b", "a"]
  end

  test "server_id/1 never turns an arbitrary stream_id into an unbounded atom", %{
    stream_id: stream_id
  } do
    {name, _node} = RaCluster.server_id(stream_id)
    assert is_atom(name)
    assert String.starts_with?(Atom.to_string(name), "riptide_")
    assert RaCluster.server_id(stream_id) == RaCluster.server_id(stream_id)
  end
end
```

- [ ] **Step 6: Run the test and fix the API calls until it passes**

Run: `mix test test/riptide/ra_cluster_test.exs`

If any `:ra` call in Step 4 doesn't match your pinned version's actual signature, run `mix hex.docs open ra` (or read `deps/ra/src/ra.erl` directly) to find the correct one, fix `ra_cluster.ex`, and rerun until both tests pass.

Expected: 2 tests, 0 failures.

- [ ] **Step 7: Commit**

```bash
git add mix.exs mix.lock config/config.exs config/test.exs .gitignore lib/riptide/ra_cluster.ex test/riptide/ra_cluster_test.exs
git commit -m "Add :ra dependency and a verified low-level cluster wrapper"
```

---

### Task 2: `Riptide.Stream.RaMachine` — the pure state machine

**Files:**
- Create: `lib/riptide/stream/ra_machine.ex`
- Test: `test/riptide/stream/ra_machine_test.exs`

**Interfaces:**
- Consumes: `Riptide.Event.new/3`, `Event.with_sequence/2` (unchanged today; Task 6 changes `Event.new/3`'s arity/signature, but `RaMachine` only ever stores/returns whatever `Event.t()` it's given — it doesn't need to know about Task 6's operation types, no coupling).
- Produces: `RaMachine.init/1` and `apply/3` (the `:ra_machine` behaviour callbacks, wired into Ra by Task 3), plus `RaMachine.get_since/2` (a plain query function, not a Ra command — called via `RaCluster.local_query/2` in Task 3).

- [ ] **Step 1: Write the failing tests** (ported directly from today's `stream_server_test.exs` assertions, but calling the pure functions with no process/Ra involved)

Create `test/riptide/stream/ra_machine_test.exs`:

```elixir
defmodule Riptide.Stream.RaMachineTest do
  use ExUnit.Case, async: true

  alias Riptide.Event
  alias Riptide.Stream.RaMachine

  defp append(state, stream_id) do
    {new_state, event, []} = RaMachine.apply(%{}, {:append, Event.new(stream_id, RDF.Graph.new())}, state)
    {new_state, event}
  end

  test "sequence starts at 1 and increases strictly" do
    state = RaMachine.init(%{retention: :infinity})
    {state, first} = append(state, "s")
    {_state, second} = append(state, "s")

    assert first.sequence == 1
    assert second.sequence == 2
  end

  test "get_since(nil) returns an empty backlog (live-tail semantics)" do
    state = RaMachine.init(%{retention: :infinity})
    assert RaMachine.get_since(state, nil) == {:ok, []}
  end

  test "get_since(cursor) filters to events after the cursor" do
    state = RaMachine.init(%{retention: :infinity})
    {state, _} = append(state, "s")
    {state, second} = append(state, "s")

    assert RaMachine.get_since(state, 1) == {:ok, [second]}
  end

  test "retention trims old events and get_since signals a gap past the window" do
    state = RaMachine.init(%{retention: 2})
    {state, _} = append(state, "s")
    {state, _} = append(state, "s")
    {state, third} = append(state, "s")

    assert RaMachine.get_since(state, 0) == {:gap, 2}
    assert RaMachine.get_since(state, 2) == {:ok, [third]}
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/riptide/stream/ra_machine_test.exs`
Expected: FAIL — `Riptide.Stream.RaMachine` is undefined.

- [ ] **Step 3: Implement `RaMachine`**

Create `lib/riptide/stream/ra_machine.ex`:

```elixir
defmodule Riptide.Stream.RaMachine do
  @moduledoc """
  The `:ra_machine` for a single stream's durable event log. Pure and
  process-free by design — `init/1`/`apply/3` are the only functions Ra
  itself calls; `get_since/2` is a plain query function run via
  `Riptide.RaCluster.local_query/2`, never a Ra command (reads don't need
  to go through consensus).
  """
  @behaviour :ra_machine

  alias Riptide.Event

  @type state :: %{
          next_sequence: pos_integer(),
          events: [Event.t()],
          retention: :infinity | pos_integer()
        }

  @impl :ra_machine
  def init(%{retention: retention}) do
    %{next_sequence: 1, events: [], retention: retention}
  end

  @impl :ra_machine
  def apply(_meta, {:append, %Event{} = event}, state) do
    stamped = Event.with_sequence(event, state.next_sequence)
    events = trim(state.events ++ [stamped], state.retention)
    new_state = %{state | next_sequence: state.next_sequence + 1, events: events}
    {new_state, stamped, []}
  end

  @spec get_since(state(), non_neg_integer() | nil) ::
          {:ok, [Event.t()]} | {:gap, pos_integer() | nil}
  def get_since(_state, nil), do: {:ok, []}

  def get_since(state, cursor) do
    oldest = List.first(state.events) |> then(&(&1 && &1.sequence))

    if oldest != nil and cursor < oldest - 1 do
      {:gap, oldest}
    else
      {:ok, Enum.filter(state.events, &(&1.sequence > cursor))}
    end
  end

  defp trim(events, :infinity), do: events

  defp trim(events, retention) when is_integer(retention) do
    count = length(events)
    if count > retention, do: Enum.drop(events, count - retention), else: events
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/riptide/stream/ra_machine_test.exs`
Expected: 4 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/riptide/stream/ra_machine.ex test/riptide/stream/ra_machine_test.exs
git commit -m "Add RaMachine: pure, ported sequence/retention/gap logic for the Ra state machine"
```

---

### Task 3: Rewrite `StreamServer` as a thin Ra client

**Files:**
- Modify: `lib/riptide/stream/stream_server.ex`

**Interfaces:**
- Consumes: `Riptide.RaCluster.{server_id/1, start_or_restart/2, process_command/2, local_query/2}` (Task 1), `Riptide.Stream.RaMachine.{get_since/2}` + the `{:module, RaMachine, config}` machine tuple (Task 2).
- Produces: `StreamServer.start_link/1` (accepts `{stream_id, opts}` or a bare `stream_id` string, returns `{:ok, pid}` — kept `start_supervised!`-compatible for existing/new tests), `append/2`, `get_since/2` — **signatures unchanged from today**, per Global Constraints.

- [ ] **Step 1: Replace the file**

Replace the full contents of `lib/riptide/stream/stream_server.ex`:

```elixir
defmodule Riptide.Stream.StreamServer do
  @moduledoc """
  Per-stream durable event log. A thin client over a single-node `Ra`
  cluster (see `Riptide.RaCluster`) running `Riptide.Stream.RaMachine` —
  no GenServer of our own; Ra owns the process and its durability.
  """

  alias Riptide.Event
  alias Riptide.RaCluster
  alias Riptide.Stream.RaMachine

  @spec start_link({String.t(), keyword()}) :: {:ok, pid()} | {:error, term()}
  def start_link({stream_id, opts}) do
    retention = Keyword.get(opts, :retention, :infinity)
    machine = {:module, RaMachine, %{retention: retention}}
    {name, _node} = RaCluster.start_or_restart(stream_id, machine)

    case Process.whereis(name) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> {:error, :not_started}
    end
  end

  @spec start_link(String.t()) :: {:ok, pid()} | {:error, term()}
  def start_link(stream_id) when is_binary(stream_id) do
    start_link({stream_id, []})
  end

  @spec append(String.t(), Event.t()) :: Event.t()
  def append(stream_id, %Event{} = event) do
    server_id = RaCluster.server_id(stream_id)
    stamped = RaCluster.process_command(server_id, {:append, event})
    Phoenix.PubSub.broadcast(Riptide.PubSub, "stream:" <> stream_id, {:new_event, stamped})
    stamped
  end

  @spec get_since(String.t(), non_neg_integer() | nil) ::
          {:ok, [Event.t()]} | {:gap, pos_integer() | nil}
  def get_since(stream_id, cursor) do
    server_id = RaCluster.server_id(stream_id)
    RaCluster.local_query(server_id, &RaMachine.get_since(&1, cursor))
  end
end
```

Note the ordering improvement over today's code: `append/2` now broadcasts to `Phoenix.PubSub` only *after* `RaCluster.process_command/2` returns — i.e. only after the event is durably committed — instead of broadcasting from inside a GenServer `handle_call` before the durability guarantee existed at all.

- [ ] **Step 2: Confirm it compiles**

Run: `mix compile`
Expected: compiles (callers in `resource_controller.ex`/`sse_controller.ex`/`replication_channel.ex`/`StreamSupervisor` still reference the same function names/arities, so no other file needs changes yet — `StreamSupervisor` is fixed next in Task 4).

- [ ] **Step 3: Commit**

```bash
git add lib/riptide/stream/stream_server.ex
git commit -m "Rewrite StreamServer as a thin Ra client, same public API"
```

(Existing tests for this file are deliberately left broken until Task 5 — Task 4 changes `StreamSupervisor` first, and Task 5 fixes/extends the test suite for both together, since several tests exercise both modules per call.)

---

### Task 4: Simplify `StreamSupervisor`, drop the now-unused Registry/DynamicSupervisor

**Files:**
- Modify: `lib/riptide/stream/stream_supervisor.ex`, `lib/riptide/application.ex`

**Interfaces:**
- Consumes: `StreamServer.start_link/1` (Task 3).
- Produces: `StreamSupervisor.get_or_start/1` — same name/arity/return (`pid()`) as today, so `resource_controller.ex`/`sse_controller.ex`/`replication_channel.ex` need no changes.

- [ ] **Step 1: Simplify `StreamSupervisor`**

Ra manages its own server's OTP process lifecycle (registered via `:ra_directory`, restart-from-disk handled by `RaCluster.start_or_restart/2`) — there's no longer anything for a `DynamicSupervisor`/`Registry` pair to do. Replace `lib/riptide/stream/stream_supervisor.ex`:

```elixir
defmodule Riptide.Stream.StreamSupervisor do
  @moduledoc """
  Entry point for "get me this stream's durable log, starting or restarting
  it from disk if needed." No longer a real OTP supervisor — `Ra` supervises
  its own server process; this just calls through to it.
  """

  alias Riptide.Stream.StreamServer

  @spec get_or_start(String.t()) :: pid()
  def get_or_start(stream_id) do
    {:ok, pid} = StreamServer.start_link({stream_id, []})
    pid
  end
end
```

- [ ] **Step 2: Remove the now-dead children from the supervision tree**

Read `lib/riptide/application.ex` and remove the `{Registry, keys: :unique, name: Riptide.Stream.Registry}` and `Riptide.Stream.StreamSupervisor` entries from its `children` list, leaving `Phoenix.PubSub` and `RiptideWeb.Endpoint` (and anything else already there that isn't stream-related).

- [ ] **Step 3: Confirm it compiles and the app boots**

Run: `mix compile && mix run --no-start -e ':ok = Application.ensure_started(:riptide) |> elem(0) |> then(fn _ -> :ok end)'`

(A simpler manual check is fine too: `iex -S mix` and confirm no crash on boot, then `Ctrl+C` twice.)

- [ ] **Step 4: Commit**

```bash
git add lib/riptide/stream/stream_supervisor.ex lib/riptide/application.ex
git commit -m "Simplify StreamSupervisor: Ra owns its own process lifecycle now"
```

---

### Task 5: Crash-recovery tests + fix the existing suite for the new process model

**Files:**
- Create: `test/support/ra_test_helpers.ex`
- Modify: `test/riptide/stream/stream_server_test.exs`, `test/riptide/stream/stream_supervisor_test.exs`, `test/riptide_web/realtime/replication_channel_test.exs`, `test/riptide_web/realtime/sse_controller_test.exs`

**Interfaces:**
- Consumes: `Riptide.RaCluster.force_delete/1` (Task 1), `StreamServer`/`StreamSupervisor` (Tasks 3–4).
- Produces: `Riptide.RaTestHelpers.cleanup_stream/1` — used by every Ra-backed test going forward (including Task 6/7's new tests) to avoid leaking on-disk Ra data between test runs, which today's plain-GenServer tests never had to worry about.

- [ ] **Step 1: Add the shared test cleanup helper**

Create `test/support/ra_test_helpers.ex`:

```elixir
defmodule Riptide.RaTestHelpers do
  @moduledoc """
  Ra persists to disk under a UID derived from stream_id (see
  `Riptide.RaCluster.uid_for/1`) — unlike the old in-memory GenServer,
  `start_supervised!`'s automatic teardown does NOT clean this up. Every
  test that starts a stream through `StreamServer`/`StreamSupervisor` must
  call this in `on_exit/1`, or a later test reusing the same stream_id will
  see stale data from a previous run.
  """

  alias Riptide.RaCluster

  @spec cleanup_stream(String.t()) :: :ok
  def cleanup_stream(stream_id), do: RaCluster.force_delete(stream_id)
end
```

- [ ] **Step 2: Write the new crash-recovery test** (the test that proves this whole sub-project's point)

Add to `test/riptide/stream/stream_server_test.exs`:

```elixir
  test "events and sequence numbers survive killing and restarting the Ra process" do
    stream_id = "stream-" <> Uniq.UUID.uuid4()
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id) end)

    {:ok, pid} = StreamServer.start_link(stream_id)
    StreamServer.append(stream_id, Event.new(stream_id, RDF.Graph.new()))
    StreamServer.append(stream_id, Event.new(stream_id, RDF.Graph.new()))

    Process.exit(pid, :kill)
    refute Process.alive?(pid)

    {:ok, _pid} = StreamServer.start_link(stream_id)

    assert {:ok, [%{sequence: 1}, %{sequence: 2}]} = StreamServer.get_since(stream_id, 0)

    third = StreamServer.append(stream_id, Event.new(stream_id, RDF.Graph.new()))
    assert third.sequence == 3
  end
```

(This intentionally uses `Event.new(stream_id, RDF.Graph.new())` — 2-arity, today's signature. Task 6 changes this to 3-arity; update this test's call sites then, not now, to keep this task's diff focused on persistence only.)

- [ ] **Step 3: Add `on_exit` cleanup to every existing test that starts a real stream**

In `test/riptide/stream/stream_server_test.exs`, `test/riptide/stream/stream_supervisor_test.exs`, `test/riptide_web/realtime/replication_channel_test.exs`, and `test/riptide_web/realtime/sse_controller_test.exs`: wherever a test currently does `start_supervised!({StreamServer, stream_id})` or `StreamServer.start_link({stream_id, retention: N})` directly, add (or extend an existing `setup` block with):

```elixir
on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id) end)
```

right after `stream_id` is bound, before the server is started.

- [ ] **Step 4: Run the full suite and fix fallout**

Run: `mix test`

Two categories of failure are expected and here's the fix for each:
- Any test still asserting on a bare `pid` returned by `start_supervised!({StreamServer, stream_id})` and expecting GenServer-style `:sys.get_state/1` introspection (if any exist) — Ra's process isn't a plain GenServer, so replace such introspection with the public `StreamServer.get_since/2` API instead.
- `test/riptide_web/realtime/sse_controller_test.exs`'s `Process.sleep(300)` / the SSE loop's hardcoded `1_000`ms timeout (`lib/riptide_web/realtime/sse_controller.ex`, the `loop/1` receive's `after` clause) — run this file 3 times in a row (`mix test test/riptide_web/realtime/sse_controller_test.exs --seed 0` repeated) to check for flakiness now that `append/2` involves real (if fast, single-node) disk I/O before replying. If it flakes, widen the `after 1_000` in `sse_controller.ex` to `after 3_000`.

Expected after fixes: full suite green, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add test/support/ra_test_helpers.ex test/riptide/stream/stream_server_test.exs test/riptide/stream/stream_supervisor_test.exs test/riptide_web/realtime/replication_channel_test.exs test/riptide_web/realtime/sse_controller_test.exs lib/riptide_web/realtime/sse_controller.ex
git commit -m "Add crash-recovery test, fix existing suite for the Ra-backed process model"
```

---

### Task 6: `Event` operation-type redesign — fix PATCH removals and PUT-empty-body/DELETE ambiguity

**Files:**
- Modify: `lib/riptide/event.ex`, `lib/riptide_web/ldp/resource_controller.ex`, `lib/riptide_web/realtime/replication_channel.ex`, `lib/riptide_web/realtime/sse_controller.ex`
- Test: `test/riptide/event_test.exs`, `test/riptide_web/ldp/resource_controller_test.exs`

**Interfaces:**
- Consumes: nothing from Tasks 1–5 — this task is independent of the Ra migration (it changes what an `Event`'s `payload` *means*, not how/where events are stored). Sequenced after Tasks 1–5 only so the whole sub-project lands as one coherent unit per `PROGRESS.md`.
- Produces: `Event.new/3` (now `(stream_id, operation, payload)` with `operation :: :replace | :delete | :patch`), `Event.wire_snapshot?/1`, `Event.wire_payload/1` — the two realtime controllers use these for wire serialization instead of reading a removed `is_snapshot?` field directly.

- [ ] **Step 1: Write the failing `Event` tests**

Replace `test/riptide/event_test.exs`:

```elixir
defmodule Riptide.EventTest do
  use ExUnit.Case, async: true

  alias Riptide.Event
  alias Riptide.RDF.Patch

  test "new/3 builds a :replace event carrying a full graph" do
    graph = RDF.Graph.new()
    event = Event.new("s", :replace, graph)

    assert event.operation == :replace
    assert event.payload == graph
    assert event.sequence == nil
  end

  test "new/3 builds a :delete event" do
    event = Event.new("s", :delete, RDF.Graph.new())
    assert event.operation == :delete
  end

  test "new/3 builds a :patch event carrying a Patch" do
    patch = %Patch{additions: [], removals: []}
    event = Event.new("s", :patch, patch)

    assert event.operation == :patch
    assert event.payload == patch
  end

  test "with_sequence/2 assigns a sequence" do
    event = Event.new("s", :replace, RDF.Graph.new()) |> Event.with_sequence(5)
    assert event.sequence == 5
  end

  test "with_sequence/2 rejects non-positive sequences" do
    assert_raise FunctionClauseError, fn ->
      Event.new("s", :replace, RDF.Graph.new()) |> Event.with_sequence(0)
    end
  end

  describe "wire_snapshot?/1 and wire_payload/1" do
    test ":replace is a wire snapshot carrying its full graph" do
      graph = RDF.Graph.new() |> RDF.Graph.add({RDF.iri("s"), RDF.iri("p"), RDF.iri("o")})
      event = Event.new("s", :replace, graph)

      assert Event.wire_snapshot?(event) == true
      assert Event.wire_payload(event) == graph
    end

    test ":delete is a wire snapshot carrying an empty graph" do
      event = Event.new("s", :delete, RDF.Graph.new())

      assert Event.wire_snapshot?(event) == true
      assert RDF.Graph.triples(Event.wire_payload(event)) == []
    end

    test ":patch is not a wire snapshot; wire payload is additions-only" do
      triple = {RDF.iri("s"), RDF.iri("p"), RDF.iri("o")}
      patch = %Patch{additions: [triple], removals: [{RDF.iri("s"), RDF.iri("p"), RDF.iri("o2")}]}
      event = Event.new("s", :patch, patch)

      assert Event.wire_snapshot?(event) == false
      assert RDF.Graph.triples(Event.wire_payload(event)) == [triple]
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/riptide/event_test.exs`
Expected: FAIL — `Event.new/3` still takes `(stream_id, payload, is_snapshot?)`.

- [ ] **Step 3: Rewrite `Event`**

Replace `lib/riptide/event.ex`:

```elixir
defmodule Riptide.Event do
  @moduledoc """
  Mirrors the StreamLD EventEnvelope SHACL shape
  (spec/streamld/model/envelope.ttl) on the wire, but internally carries an
  explicit operation instead of the wire's single `isSnapshot` boolean —
  `:patch` events store a real `Riptide.RDF.Patch` (additions AND removals),
  not just a merged graph, so replaying the log can actually apply a
  removal. See `wire_snapshot?/1`/`wire_payload/1` for how this maps back
  down to the wire's `isSnapshot`/`payload` fields unchanged.
  """

  alias Riptide.RDF.Patch

  @enforce_keys [:stream_id, :operation, :payload]
  defstruct [:sequence, :stream_id, :operation, :payload]

  @type operation :: :replace | :delete | :patch
  @type payload :: RDF.Graph.t() | Patch.t()
  @type t :: %__MODULE__{
          sequence: pos_integer() | nil,
          stream_id: String.t(),
          operation: operation(),
          payload: payload()
        }

  @spec new(String.t(), :replace, RDF.Graph.t()) :: t()
  @spec new(String.t(), :delete, RDF.Graph.t()) :: t()
  @spec new(String.t(), :patch, Patch.t()) :: t()
  def new(stream_id, :replace, %RDF.Graph{} = payload) do
    %__MODULE__{stream_id: stream_id, operation: :replace, payload: payload}
  end

  def new(stream_id, :delete, %RDF.Graph{} = payload) do
    %__MODULE__{stream_id: stream_id, operation: :delete, payload: payload}
  end

  def new(stream_id, :patch, %Patch{} = payload) do
    %__MODULE__{stream_id: stream_id, operation: :patch, payload: payload}
  end

  @spec with_sequence(t(), pos_integer()) :: t()
  def with_sequence(%__MODULE__{} = event, sequence)
      when is_integer(sequence) and sequence > 0 do
    %{event | sequence: sequence}
  end

  @spec wire_snapshot?(t()) :: boolean()
  def wire_snapshot?(%__MODULE__{operation: :replace}), do: true
  def wire_snapshot?(%__MODULE__{operation: :delete}), do: true
  def wire_snapshot?(%__MODULE__{operation: :patch}), do: false

  @spec wire_payload(t()) :: RDF.Graph.t()
  def wire_payload(%__MODULE__{operation: :replace, payload: graph}), do: graph
  def wire_payload(%__MODULE__{operation: :delete, payload: graph}), do: graph

  # The StreamLD wire protocol has no removals field today (out of scope —
  # see the design doc's Global Constraints); a :patch's wire payload is
  # additions-only, same net wire behavior as before this task.
  def wire_payload(%__MODULE__{operation: :patch, payload: %Patch{additions: additions}}) do
    RDF.Graph.new() |> RDF.Graph.add(additions)
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/riptide/event_test.exs`
Expected: 8 tests, 0 failures.

- [ ] **Step 5: Write the failing `resource_controller` tests for the two bugs**

Add to `test/riptide_web/ldp/resource_controller_test.exs` (matching that file's existing conn-test style):

```elixir
  test "PATCH removals actually remove a triple on the next GET", %{conn: conn} do
    path = ["removal-test-" <> Uniq.UUID.uuid4()]

    conn
    |> put(Enum.join(path, "/") |> then(&"/resources/#{&1}"), "<https://s> <https://p> <https://o> .")

    conn2 =
      patch(conn, "/resources/#{Enum.join(path, "/")}", %{
        "additions" => "",
        "removals" => "<https://s> <https://p> <https://o> ."
      })

    assert conn2.status == 200

    conn3 = get(conn, "/resources/#{Enum.join(path, "/")}")
    assert conn3.status == 404
  end

  test "PUT with an empty body is visible (200, empty) and distinct from DELETE (404)", %{
    conn: conn
  } do
    path = "empty-put-test-" <> Uniq.UUID.uuid4()

    conn |> put("/resources/#{path}", "")
    conn2 = get(conn, "/resources/#{path}")
    assert conn2.status == 200
    assert conn2.resp_body == ""

    conn3 = delete(conn, "/resources/#{path}")
    assert conn3.status == 204
    conn4 = get(conn, "/resources/#{path}")
    assert conn4.status == 404
  end
```

(Match these against whatever conn-building helpers/pipeline the rest of `resource_controller_test.exs` already uses — the file's existing PUT/GET/PATCH/DELETE tests show the exact pattern to follow; adapt the snippets above to it rather than introducing a second style.)

- [ ] **Step 6: Run tests to verify they fail**

Run: `mix test test/riptide_web/ldp/resource_controller_test.exs`
Expected: FAIL — removals still a no-op; empty PUT still 404s identically to DELETE.

- [ ] **Step 7: Fix `resource_controller.ex`**

In `lib/riptide_web/ldp/resource_controller.ex`:

Add the alias: `alias Riptide.RDF.{Patch, TurtleCodec}` (extend the existing `Riptide.RDF` alias line to include `Patch`).

Replace `replace/2`'s append line:
```elixir
        StreamServer.append(stream_id, Event.new(stream_id, :replace, graph))
```

Replace `delete/2`'s append line:
```elixir
    StreamServer.append(stream_id, Event.new(stream_id, :delete, RDF.Graph.new()))
```

Replace `patch/2`'s body (the `with` block's success path — remove the old "KNOWN LIMITATION" comment along with the code it was explaining, since the limitation is fixed):
```elixir
    with {:ok, additions_turtle} <- Map.fetch(params, "additions"),
         {:ok, removals_turtle} <- Map.fetch(params, "removals"),
         {:ok, additions_graph} <- TurtleCodec.decode(additions_turtle),
         {:ok, removals_graph} <- TurtleCodec.decode(removals_turtle) do
      patch = %Patch{
        additions: RDF.Graph.triples(additions_graph),
        removals: RDF.Graph.triples(removals_graph)
      }

      StreamSupervisor.get_or_start(stream_id)
      StreamServer.append(stream_id, Event.new(stream_id, :patch, patch))

      send_resp(conn, 200, "")
    else
      :error -> send_resp(conn, 400, "")
      {:error, _reason} -> send_resp(conn, 400, "")
    end
```

Replace `create_child/2`'s two append call sites:
```elixir
        StreamSupervisor.get_or_start(child_stream_id)
        StreamServer.append(child_stream_id, Event.new(child_stream_id, :replace, child_graph))

        containment_triple = {RDF.iri(container_stream_id), @ldp_contains, RDF.iri(child_stream_id)}
        containment_patch = %Patch{additions: [containment_triple], removals: []}

        StreamSupervisor.get_or_start(container_stream_id)

        StreamServer.append(
          container_stream_id,
          Event.new(container_stream_id, :patch, containment_patch)
        )
```

Replace `current_state/1` in full (remove its two "KNOWN LIMITATION" comments along with the code they explained):
```elixir
  defp current_state(stream_id) do
    StreamSupervisor.get_or_start(stream_id)

    case StreamServer.get_since(stream_id, 0) do
      {:ok, []} ->
        :not_found

      {:ok, events} ->
        case List.last(events) do
          %Event{operation: :delete} ->
            :not_found

          _ ->
            graph =
              Enum.reduce(events, RDF.Graph.new(), fn
                %Event{operation: :replace, payload: payload}, _acc -> payload
                %Event{operation: :delete}, _acc -> RDF.Graph.new()
                %Event{operation: :patch, payload: %Patch{} = patch}, acc -> Patch.apply(acc, patch)
              end)

            {:ok, graph}
        end
    end
  end
```

Note the `show/2` action's caller code doesn't need to change: it already pattern-matches `{:ok, graph} -> ... ; :not_found -> 404` and now correctly gets `{:ok, RDF.Graph.new()}` (→ 200, empty body) for an explicitly-empty PUT instead of `:not_found`.

- [ ] **Step 8: Update the two realtime controllers to use the new wire helpers**

In `lib/riptide_web/realtime/replication_channel.ex`, find `frame/1` (or equivalent) — wherever it currently reads `event.is_snapshot?` and `event.payload` to build the `"replication_frame"` JSON, replace with `Event.wire_snapshot?(event)` and `Event.wire_payload(event)`.

In `lib/riptide_web/realtime/sse_controller.ex`, find the equivalent event→wire-JSON encoding (used for both the backlog and the live-tail `receive` loop) and make the same replacement: `event.is_snapshot?` → `Event.wire_snapshot?(event)`, `event.payload` → `Event.wire_payload(event)`.

- [ ] **Step 9: Run the full suite**

Run: `mix test`
Expected: 0 failures, including the two new tests from Step 5.

- [ ] **Step 10: Commit**

```bash
git add lib/riptide/event.ex lib/riptide_web/ldp/resource_controller.ex lib/riptide_web/realtime/replication_channel.ex lib/riptide_web/realtime/sse_controller.ex test/riptide/event_test.exs test/riptide_web/ldp/resource_controller_test.exs
git commit -m "Give Event an explicit operation type; fixes PATCH removals and PUT-empty/DELETE ambiguity"
```

---

### Task 7: WebSocket cross-stream isolation regression test

**Files:**
- Modify: `test/riptide_web/realtime/replication_channel_test.exs`

**Interfaces:**
- Consumes: `RiptideWeb.Realtime.Socket`, `ReplicationChannel` (unchanged), `Riptide.RaTestHelpers.cleanup_stream/1` (Task 5).
- Produces: nothing new consumed elsewhere — a pure regression test.

- [ ] **Step 1: Write the failing test**

Add to `test/riptide_web/realtime/replication_channel_test.exs`, following the file's existing `connect(Socket, %{})` / `subscribe_and_join/4` pattern:

```elixir
  test "an append to stream A is not pushed to a socket joined to stream B" do
    stream_a = "stream-a-" <> Uniq.UUID.uuid4()
    stream_b = "stream-b-" <> Uniq.UUID.uuid4()
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_a) end)
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_b) end)

    {:ok, socket_a} = connect(Socket, %{})
    {:ok, socket_b} = connect(Socket, %{})

    {:ok, _reply, socket_a} =
      subscribe_and_join(socket_a, ReplicationChannel, "replication:" <> stream_a, %{"after" => 0})

    {:ok, _reply, socket_b} =
      subscribe_and_join(socket_b, ReplicationChannel, "replication:" <> stream_b, %{"after" => 0})

    StreamSupervisor.get_or_start(stream_a)
    StreamServer.append(stream_a, Event.new(stream_a, :replace, RDF.Graph.new()))

    assert_push "replication_frame", %{}, 500

    refute_push "replication_frame", %{}, 100
  end
```

(`assert_push` is asserted against `socket_a`'s join context by ExUnit's `Phoenix.ChannelTest` process-scoping — since both `subscribe_and_join` calls run in this same test process, use two separate test processes via `Task` if `assert_push`/`refute_push` can't otherwise be scoped per-socket in this file's existing helper setup; check how `replication_channel_test.exs`'s existing single-stream tests scope their `assert_push` calls and mirror that exactly.)

- [ ] **Step 2: Run to verify it fails or passes for the wrong reason**

Run: `mix test test/riptide_web/realtime/replication_channel_test.exs`

If it passes immediately without ever proving isolation (e.g. because both `assert_push`/`refute_push` end up scoped to the same process ambiguously), that's a false pass — fix the test's process-scoping per the note in Step 1 before trusting it.

- [ ] **Step 3: Confirm it passes for the right reason**

Temporarily change `"replication:" <> stream_a` in the append line to `"replication:" <> stream_b` in a scratch copy and confirm the test now fails (proving it actually detects cross-stream leakage) — then revert. Run: `mix test test/riptide_web/realtime/replication_channel_test.exs` again to confirm it's back to green.

- [ ] **Step 4: Commit**

```bash
git add test/riptide_web/realtime/replication_channel_test.exs
git commit -m "Add WebSocket cross-stream isolation regression test"
```

---

### Task 8: SHACL-shape vs shacl2code-mirror drift-detection test

**Files:**
- Create: `/work/openfaster-spec/streamld/tests/test_shape_mirror_drift.py`

**Interfaces:**
- Consumes: `streamld/generator/shacl_model.py`'s `load_shapes`/`fields_for_shape` (existing, unchanged), `streamld/model/envelope.ttl` (existing, unchanged).
- Produces: nothing consumed elsewhere — a pure regression test in the sibling spec repo.

- [ ] **Step 1: Write the test**

This repo is separate from `riptide` (`/work/openfaster-spec`, Python/pytest). Create `streamld/tests/test_shape_mirror_drift.py`, following `test_shacl_model.py`'s existing import/path pattern exactly:

```python
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from generator.shacl_model import load_shapes, fields_for_shape
from rdflib.namespace import Namespace

SHAPES_PATH = Path(__file__).parent.parent / "model" / "envelope.ttl"
STREAMLD = Namespace("https://openfaster.org/streamld#")

SHAPE_CLASS_PAIRS = [
    (STREAMLD.EventEnvelopeShape, STREAMLD.EventEnvelope),
    (STREAMLD.ReplicationFrameShape, STREAMLD.ReplicationFrame),
    (STREAMLD.SubscriptionRequestShape, STREAMLD.SubscriptionRequest),
    (STREAMLD.GapSignalShape, STREAMLD.GapSignal),
]


def test_shacl2code_mirror_matches_pyshacl_shapes():
    graph = load_shapes(SHAPES_PATH)

    for shape_iri, class_iri in SHAPE_CLASS_PAIRS:
        shape_fields = fields_for_shape(graph, shape_iri)
        mirror_fields = fields_for_shape(graph, class_iri)

        assert shape_fields == mirror_fields, (
            f"{shape_iri} (validated by pyshacl) and its shacl2code mirror "
            f"{class_iri} have drifted — keep their sh:property lists in "
            f"sync in envelope.ttl."
        )
```

Verify the exact `STREAMLD` namespace IRI and the 4 shape/class local names against `envelope.ttl` itself before running (the values above are taken from the research pass on this repo — confirm the literal `STREAMLD = Namespace(...)` string matches what `envelope.ttl`'s `@prefix streamld:` line declares, and adjust if it differs).

- [ ] **Step 2: Run it against the current (in-sync) file to confirm it passes**

Run (from `/work/openfaster-spec`): `pytest streamld/tests/test_shape_mirror_drift.py -v`
Expected: 1 test, pass (the NodeShape and mirror blocks are in sync today).

- [ ] **Step 3: Confirm it actually detects drift**

Temporarily add a `sh:property` block to one mirror class (not its NodeShape counterpart) in a scratch copy of `envelope.ttl`, rerun the test, confirm it fails with the drift message, then revert the scratch edit (do not commit it).

- [ ] **Step 4: Commit**

```bash
cd /work/openfaster-spec
git add streamld/tests/test_shape_mirror_drift.py
git commit -m "Add drift-detection test between SHACL NodeShapes and their shacl2code mirror"
```

(This is a separate repo/remote from `riptide` — this commit goes to `OpenFASTER-Standard/spec`, most likely via its own small branch + PR rather than the `riptide` repo's `persistence-durability` branch; open that PR the same way PR #2 was opened for this repo earlier in the project.)

---

### Task 9: Wrap up — docs, full verification, PR

**Files:**
- Modify: `PROGRESS.md`, `README.md`

- [ ] **Step 1: Run the full Riptide suite one more time end to end**

Run: `mix test`
Expected: 0 failures.

- [ ] **Step 2: Update `PROGRESS.md`**

Change sub-project 1's status in the table from `**In design** — see below` to `**Shipped** — see below`. Update the `## 1. Persistence & durability` section's `**Status**` line to reflect it shipped (link the PR once opened in Step 4). Delete the `## Cleanup folded into Persistence work` section entirely — everything in it is now done, and per the earlier discussion nothing should be "carried forward" a second time.

- [ ] **Step 3: Update `README.md`**

In the "How the pieces fit together" section, update the sentence describing `StreamServer` (currently: *"a GenServer (one process per stream, ...) that owns write serialization and the in-memory list of `Riptide.Event` structs..."*) to describe the Ra-backed durable log instead, in the same style/length as the surrounding prose.

- [ ] **Step 4: Push and open the PR**

```bash
git push -u origin persistence-durability
gh pr create --repo OpenFASTER-Standard/riptide --title "Persistence & durability: single-node Ra-replicated event log" --body "$(cat <<'EOF'
## Summary
- Replaces StreamServer's in-memory event list with a single-node (cluster size 1) Ra-replicated durable log per stream — data and sequence numbers now survive a crash/restart instead of silently resetting.
- Gives Event an explicit operation type (:replace/:delete/:patch), fixing two known bugs: PATCH removals were previously non-functional, and PUT-with-an-empty-body was indistinguishable from DELETE.
- Adds the two regression tests carried forward from PR #1: WebSocket cross-stream isolation, and SHACL-shape vs shacl2code-mirror drift detection (companion PR in OpenFASTER-Standard/spec).

## Test plan
- [ ] `mix test` passes in full
- [ ] Manually verified: kill -9 the Ra server process mid-stream, restart, confirm events and sequence numbers survived
- [ ] Manually verified: PATCH removals now take effect on the next GET
- [ ] Manually verified: PUT with an empty Turtle body returns 200 with an empty representation, DELETE still returns 404 on the next GET
EOF
)"
```

- [ ] **Step 5: Final commit for docs**

```bash
git add PROGRESS.md README.md
git commit -m "Update PROGRESS.md and README for shipped Persistence & durability sub-project"
git push
```

---

## Self-Review Notes

- **Spec coverage**: design doc §3.2 (Ra state machine, one cluster per stream, dynamic start) → Tasks 1–4. §3.3 write/read/restart paths → Tasks 3, 5. §3.4 error handling (atomic commits) → inherent to Ra's `process_command` semantics used in Task 3, no separate task needed (there's no partial-write state to handle — that's the point of using Ra). §4 testing → Task 5 (crash recovery + suite audit). §5 dependencies → Task 1. §6 disk-isolation operator guidance is explicitly named in the design doc as **not yet written** even after this plan ships — correctly left out of this plan's scope (it's deployment documentation, sequenced with sub-project 2's Docker/CI work, not code).
- **PROGRESS.md's "Cleanup folded into Persistence work" list**: `Event` operation-type fix → Task 6. WebSocket isolation test → Task 7. SHACL drift test → Task 8. Durability-limitation doc note → resolved implicitly (the limitation itself is gone) and PROGRESS.md's own cleanup section is deleted in Task 9.
- **Type/signature consistency checked**: `Event.new/3`'s 3 clauses (Task 6) all take `(stream_id, operation, payload)` — every call site updated in the same task (`resource_controller.ex`'s 5 call sites). `StreamServer.append/2`/`get_since/2` signatures identical from Task 3 through Task 9 — verified against every caller file listed in File Structure. `RaCluster`'s 5 functions (Task 1) are the only functions any later task calls into `:ra` through — no other task calls `:ra.*` directly.
