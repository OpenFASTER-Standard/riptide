# Phase 3c-iii: Request Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every request entry point (LDP HTTP, SSE, WebSocket replication) work correctly regardless of which node in the fleet receives it, by making `Riptide.Stream.Placement`/`StreamSupervisor` resolve and address a stream's real replica nodes remotely instead of assuming the local node always hosts the stream.

**Architecture:** No HTTP-level proxy layer. `Riptide.Stream.Placement.ensure_started/2` gains a member/non-member branch so a non-member node resolving an existing assignment skips cluster formation entirely (nothing to form/join locally) instead of always failing. `Riptide.Stream.StreamSupervisor.get_or_start/1` is renamed to `ensure_ready/1`, calling `Riptide.Stream.Placement.ensure_started/2` directly (bypassing `StreamServer.start_link/1`'s local-pid requirement) and returning `:ok | {:error, term()}`. The 3 web entry points switch to `ensure_ready/1` and map failure to a clean `503`/error response.

**Tech Stack:** Elixir/OTP, `:ra` (Erlang Raft, pinned `2.15.4`), Phoenix, ExUnit, OTP 25's `:peer` module for real multi-node integration tests.

**Spec:** `docs/superpowers/specs/2026-08-25-phase-3c-iii-request-routing-design.md`

## Global Constraints

- No HTTP-level proxy, redirect, or forwarding layer of any kind.
- `StreamServer.start_link/1` itself is unchanged — still fully valid, still covered by its own existing tests, just no longer the production request path.
- `StreamServer.append/2`/`get_since/2` need no changes.
- No load/latency-aware replica preference, no new steady-state resilience beyond what Phase 3c-ii already established, no placement-algorithm changes.
- Web-layer failure mapping: `StreamSupervisor.ensure_ready/1` returning `{:error, _}` maps to HTTP `503` (LDP + SSE controllers) or `{:error, %{"reason" => "service_unavailable"}}` (WebSocket channel `join/3`).

---

### Task 1: `Riptide.Stream.Placement`'s member/non-member branch

**Files:**
- Modify: `lib/riptide/stream/placement.ex`
- Test: `test/riptide/stream/placement_test.exs`

**Interfaces:**
- Consumes: `Riptide.Placement.lookup/1`, `Riptide.RaCluster.uid_for/1` (existing).
- Produces: no change to `ensure_started/4`'s own public signature — this task only changes its internal resolution logic. Consumed identically by Task 2.

- [ ] **Step 1: Write the failing tests**

Add to `test/riptide/stream/placement_test.exs`, inside `describe "ensure_started/4"`:

```elixir
    test "a stream already assigned to nodes not including this one skips formation entirely" do
      stream_id = "stream-placement-remote-" <> Uniq.UUID.uuid4()
      on_exit(fn -> RaCluster.force_delete(stream_id) end)
      remote_node = :"other-node@nowhere"

      assert Placement.assign(stream_id, [remote_node]) == [remote_node]

      unreachable_formation_fun = fn _uid, _nodes, _machine -> raise "should never be called" end

      assert {:ok, server_ids} =
               StreamPlacement.ensure_started(
                 stream_id,
                 {:module, EchoMachine, %{}},
                 unreachable_formation_fun
               )

      uid = RaCluster.uid_for(stream_id)
      assert server_ids == [{String.to_atom(uid), remote_node}]
    end

    test "a stream already assigned to nodes including this one re-forms/rejoins for real" do
      stream_id = "stream-placement-rejoin-" <> Uniq.UUID.uuid4()
      on_exit(fn -> RaCluster.force_delete(stream_id) end)
      machine = {:module, EchoMachine, %{}}

      assert Placement.assign(stream_id, [node()]) == [node()]

      assert {:ok, server_ids} = StreamPlacement.ensure_started(stream_id, machine)
      uid = RaCluster.uid_for(stream_id)
      assert server_ids == [{String.to_atom(uid), node()}]

      pid = Process.whereis(String.to_atom(uid))
      assert is_pid(pid)
      assert Process.alive?(pid)
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/riptide/stream/placement_test.exs --trace`
Expected: FAIL — the first test fails because `resolve_and_start/4` currently always calls `formation_fun` regardless of membership, so `unreachable_formation_fun` raises. The second test currently passes already (this is the pre-existing, unaffected "member" path) — confirm it stays green; it's here as a regression guard for Step 3's refactor, not a new-behavior test.

- [ ] **Step 3: Implement the member/non-member branch**

Modify `lib/riptide/stream/placement.ex` — replace `resolve_and_start/4` and `resolve_nodes/1`:

```elixir
  defp resolve_and_start(stream_id, machine, formation_fun, sleep_fun) do
    uid = RaCluster.uid_for(stream_id)

    case resolve_nodes(stream_id) do
      {:member, nodes} ->
        case start_with_retry(uid, nodes, machine, formation_fun, sleep_fun, @max_formation_attempts) do
          {:ok, server_ids} ->
            :ets.insert(@table, {stream_id, server_ids})
            {:ok, server_ids}

          {:error, _} = error ->
            error
        end

      {:remote, nodes} ->
        server_ids = Enum.map(nodes, &{String.to_atom(uid), &1})
        :ets.insert(@table, {stream_id, server_ids})
        {:ok, server_ids}
    end
  end

  # Distinguishes "this node needs to form/join the cluster" from "this node
  # is just resolving an existing assignment it isn't part of." A genuinely
  # new stream (nil lookup) always lands in {:member, _} — `propose_nodes/2`
  # (Phase 3c-ii) always puts the local node first, and backfill always
  # proposes exactly [node()] — so this node always needs to form it.  An
  # already-assigned stream this node isn't a replica of has nothing to
  # form or join locally: attempting `formation_fun` there would only ever
  # fail (`:ra.start_cluster/2` can't succeed for a node whose id was never
  # in the config), even though the stream is perfectly healthy elsewhere
  # (Phase 3c-iii design spec §1/§4).
  @spec resolve_nodes(String.t()) :: {:member, [node()]} | {:remote, [node()]}
  defp resolve_nodes(stream_id) do
    case Placement.lookup(stream_id) do
      nil ->
        {:member, backfill_or_propose(stream_id)}

      nodes ->
        if node() in nodes do
          {:member, nodes}
        else
          {:remote, nodes}
        end
    end
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/riptide/stream/placement_test.exs --trace`
Expected: PASS.

- [ ] **Step 5: Run the full suite**

Run: `mix test`
Expected: PASS, no regressions.

- [ ] **Step 6: Commit**

```bash
git add lib/riptide/stream/placement.ex test/riptide/stream/placement_test.exs
git commit -m "Riptide.Stream.Placement: skip cluster formation for a non-member node"
```

---

### Task 2: `StreamSupervisor.get_or_start/1` → `ensure_ready/1`

**Files:**
- Modify: `lib/riptide/stream/stream_supervisor.ex`
- Modify: `test/riptide/stream/stream_supervisor_test.exs`

**Interfaces:**
- Consumes: `Riptide.Stream.Placement.ensure_started/2` (existing, unchanged signature).
- Produces: `Riptide.Stream.StreamSupervisor.ensure_ready(stream_id :: String.t()) :: :ok | {:error, term()}` — consumed by Task 3.

- [ ] **Step 1: Write the failing tests**

Replace `test/riptide/stream/stream_supervisor_test.exs` in full:

```elixir
defmodule Riptide.Stream.StreamSupervisorTest do
  use ExUnit.Case, async: true

  alias Riptide.Event
  alias Riptide.Stream.{StreamServer, StreamSupervisor}

  test "ensure_ready/1 returns :ok for an unseen stream id" do
    stream_id = "stream-#{System.unique_integer([:positive])}"
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id) end)

    assert StreamSupervisor.ensure_ready(stream_id) == :ok
  end

  test "ensure_ready/1 is idempotent for the same stream id" do
    stream_id = "stream-#{System.unique_integer([:positive])}"
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id) end)

    assert StreamSupervisor.ensure_ready(stream_id) == :ok
    assert StreamSupervisor.ensure_ready(stream_id) == :ok
  end

  test "ensure_ready/1 isolates state between different streams" do
    stream_a = "stream-#{System.unique_integer([:positive])}"
    stream_b = "stream-#{System.unique_integer([:positive])}"
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_a) end)
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_b) end)
    StreamSupervisor.ensure_ready(stream_a)
    StreamSupervisor.ensure_ready(stream_b)

    StreamServer.append(
      stream_a,
      Event.new(stream_a, :replace, RDF.Graph.new())
    )

    {:ok, events_b} = StreamServer.get_since(stream_b, 0)
    assert events_b == []
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/riptide/stream/stream_supervisor_test.exs --trace`
Expected: FAIL — `ensure_ready/1` doesn't exist yet.

- [ ] **Step 3: Implement `ensure_ready/1`**

Replace `lib/riptide/stream/stream_supervisor.ex` in full:

```elixir
defmodule Riptide.Stream.StreamSupervisor do
  @moduledoc """
  Entry point for "make sure this stream's real, placement-driven Ra
  cluster is resolved and ready" — used by every request path (LDP HTTP,
  SSE, WebSocket replication). Calls `Riptide.Stream.Placement.
  ensure_started/2` directly rather than through `StreamServer.start_link/1`,
  since a stream's actual replicas may not include this node (Phase 3c-iii
  design spec §3) — `start_link/1`'s own "return a local pid" contract only
  ever made sense when this node was always assumed to be a replica.
  """

  alias Riptide.Stream.{Placement, RaMachine}

  @spec ensure_ready(String.t()) :: :ok | {:error, term()}
  def ensure_ready(stream_id) do
    case Placement.ensure_started(stream_id, {:module, RaMachine, %{retention: :infinity}}) do
      {:ok, _server_ids} -> :ok
      {:error, _reason} = error -> error
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/riptide/stream/stream_supervisor_test.exs --trace`
Expected: PASS.

- [ ] **Step 5: Run the full suite**

Run: `mix test`
Expected: FAIL — this is expected at this point: `StreamSupervisor.get_or_start/1` no longer exists, and the 3 web entry points plus their tests still call it. Task 3 fixes this. Confirm the *only* failures are `UndefinedFunctionError: StreamSupervisor.get_or_start/1` (or equivalent compile errors) in `lib/riptide_web/` and its tests — nothing else should be newly broken.

- [ ] **Step 6: Commit**

```bash
git add lib/riptide/stream/stream_supervisor.ex test/riptide/stream/stream_supervisor_test.exs
git commit -m "StreamSupervisor: rename get_or_start/1 to ensure_ready/1, drop the pid contract"
```

---

### Task 3: Wire the 3 web entry points

**Files:**
- Modify: `lib/riptide_web/ldp/resource_controller.ex`
- Modify: `lib/riptide_web/realtime/sse_controller.ex`
- Modify: `lib/riptide_web/realtime/replication_channel.ex`
- Modify: `test/riptide_web/realtime/sse_controller_test.exs`
- Modify: `test/riptide_web/realtime/replication_channel_test.exs`

**Interfaces:**
- Consumes: `Riptide.Stream.StreamSupervisor.ensure_ready/1` (Task 2).
- Produces: nothing further downstream — this is the last task that touches production code.

Each of the 3 modules gets its own small, identically-shaped, directly-testable mapping function:

```elixir
@spec ensure_ready_status(:ok | {:error, term()}) :: :ok | :error
def ensure_ready_status(:ok), do: :ok
def ensure_ready_status({:error, _reason}), do: :error
```

Deliberately `def`, not `defp` — the whole point is to be directly unit-testable (fabricate `:ok`/`{:error, _}` inputs, no real `Placement`/formation call needed) without threading dependency injection through Phoenix controllers, matching Phase 3c-iii's own design spec §5.

- [ ] **Step 1: Write the failing tests**

Add to `test/riptide_web/ldp/resource_controller_test.exs` (new file section — check the existing file's `describe`/module structure and add at the top level, matching its existing bare `test "..."` style):

```elixir
  test "ensure_ready_status/1 maps :ok and {:error, _} correctly" do
    assert RiptideWeb.LDP.ResourceController.ensure_ready_status(:ok) == :ok
    assert RiptideWeb.LDP.ResourceController.ensure_ready_status({:error, :cluster_not_formed}) == :error
  end
```

Add to `test/riptide_web/realtime/sse_controller_test.exs`:

```elixir
  test "ensure_ready_status/1 maps :ok and {:error, _} correctly" do
    assert RiptideWeb.Realtime.SseController.ensure_ready_status(:ok) == :ok
    assert RiptideWeb.Realtime.SseController.ensure_ready_status({:error, :cluster_not_formed}) == :error
  end
```

Add to `test/riptide_web/realtime/replication_channel_test.exs`:

```elixir
  test "ensure_ready_status/1 maps :ok and {:error, _} correctly" do
    assert RiptideWeb.Realtime.ReplicationChannel.ensure_ready_status(:ok) == :ok
    assert RiptideWeb.Realtime.ReplicationChannel.ensure_ready_status({:error, :cluster_not_formed}) == :error
  end
```

Also, in both `test/riptide_web/realtime/sse_controller_test.exs` and `test/riptide_web/realtime/replication_channel_test.exs`, replace every `StreamSupervisor.get_or_start(...)` call with `StreamSupervisor.ensure_ready(...)` (same call sites, same arguments — these are pre-test setup calls, not the new behavior under test; they're just renamed to compile against Task 2's change).

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/riptide_web/ --trace`
Expected: FAIL — `ensure_ready_status/1` doesn't exist in any of the 3 modules yet; the whole `test/riptide_web/` tree still fails to compile from Task 2's rename until this task's Step 3 lands.

- [ ] **Step 3: Update `RiptideWeb.LDP.ResourceController`**

Replace `lib/riptide_web/ldp/resource_controller.ex` in full:

```elixir
defmodule RiptideWeb.LDP.ResourceController do
  use Phoenix.Controller

  alias Riptide.Event
  alias Riptide.RDF.{Patch, TurtleCodec}
  alias Riptide.Stream.{StreamServer, StreamSupervisor}

  @ldp_contains RDF.iri("http://www.w3.org/ns/ldp#contains")

  def show(conn, %{"path" => path_segments}) do
    stream_id = stream_id_for(path_segments)

    case current_state(stream_id) do
      {:ok, graph} ->
        {:ok, turtle} = TurtleCodec.encode(graph)
        send_resp(conn, 200, turtle)

      :not_found ->
        send_resp(conn, 404, "")

      :service_unavailable ->
        send_resp(conn, 503, "")
    end
  end

  def replace(conn, %{"path" => path_segments}) do
    stream_id = stream_id_for(path_segments)
    {:ok, body, conn} = Plug.Conn.read_body(conn)

    case TurtleCodec.decode(body) do
      {:ok, graph} ->
        case stream_id |> StreamSupervisor.ensure_ready() |> ensure_ready_status() do
          :ok ->
            StreamServer.append(stream_id, Event.new(stream_id, :replace, graph))
            send_resp(conn, 201, "")

          :error ->
            send_resp(conn, 503, "")
        end

      {:error, _reason} ->
        send_resp(conn, 400, "")
    end
  end

  def delete(conn, %{"path" => path_segments}) do
    stream_id = stream_id_for(path_segments)

    case stream_id |> StreamSupervisor.ensure_ready() |> ensure_ready_status() do
      :ok ->
        StreamServer.append(stream_id, Event.new(stream_id, :delete, RDF.Graph.new()))
        send_resp(conn, 204, "")

      :error ->
        send_resp(conn, 503, "")
    end
  end

  def patch(conn, %{"path" => path_segments} = params) do
    stream_id = stream_id_for(path_segments)

    # NOTE: the endpoint's `Plug.Parsers` (see Task 6's scaffold) already
    # parses and consumes the request body for `content-type:
    # application/json`, merging the decoded fields into `conn.params`
    # before this action runs. Calling `Plug.Conn.read_body/1` here (as an
    # earlier draft did, mirroring the brief's literal example) reads an
    # already-drained body and crashes `Jason.decode!/1` on an empty
    # string. Read the already-decoded fields from `params` instead.
    with {:ok, additions_turtle} <- Map.fetch(params, "additions"),
         {:ok, removals_turtle} <- Map.fetch(params, "removals"),
         {:ok, additions_graph} <- TurtleCodec.decode(additions_turtle),
         {:ok, removals_graph} <- TurtleCodec.decode(removals_turtle) do
      patch = %Patch{
        additions: RDF.Graph.triples(additions_graph),
        removals: RDF.Graph.triples(removals_graph)
      }

      case stream_id |> StreamSupervisor.ensure_ready() |> ensure_ready_status() do
        :ok ->
          StreamServer.append(stream_id, Event.new(stream_id, :patch, patch))
          send_resp(conn, 200, "")

        :error ->
          send_resp(conn, 503, "")
      end
    else
      :error -> send_resp(conn, 400, "")
      {:error, _reason} -> send_resp(conn, 400, "")
    end
  end

  def create_child(conn, %{"path" => path_segments}) do
    container_stream_id = stream_id_for(path_segments)
    {:ok, body, conn} = Plug.Conn.read_body(conn)

    case TurtleCodec.decode(body) do
      {:ok, child_graph} ->
        child_id = Uniq.UUID.uuid4()
        child_stream_id = container_stream_id <> "/" <> child_id

        with :ok <- child_stream_id |> StreamSupervisor.ensure_ready() |> ensure_ready_status(),
             :ok <- container_stream_id |> StreamSupervisor.ensure_ready() |> ensure_ready_status() do
          StreamServer.append(child_stream_id, Event.new(child_stream_id, :replace, child_graph))

          containment_triple =
            {RDF.iri(container_stream_id), @ldp_contains, RDF.iri(child_stream_id)}

          containment_patch = %Patch{additions: [containment_triple], removals: []}

          StreamServer.append(
            container_stream_id,
            Event.new(container_stream_id, :patch, containment_patch)
          )

          location = "/resources/" <> Enum.join(path_segments, "/") <> "/" <> child_id

          conn
          |> put_resp_header("location", location)
          |> send_resp(201, "")
        else
          :error -> send_resp(conn, 503, "")
        end

      {:error, _reason} ->
        send_resp(conn, 400, "")
    end
  end

  @spec ensure_ready_status(:ok | {:error, term()}) :: :ok | :error
  def ensure_ready_status(:ok), do: :ok
  def ensure_ready_status({:error, _reason}), do: :error

  defp stream_id_for(path_segments) do
    "https://riptide.example/resources/" <> Enum.join(path_segments, "/")
  end

  defp current_state(stream_id) do
    case stream_id |> StreamSupervisor.ensure_ready() |> ensure_ready_status() do
      :error ->
        :service_unavailable

      :ok ->
        case StreamServer.get_since(stream_id, 0) do
          {:ok, []} ->
            :not_found

          # LDP streams use `:infinity` retention today, so `get_since/2` from
          # cursor 0 can't currently return a gap. Handle it defensively anyway:
          # if a future retention change trims the oldest events, a full-history
          # fold from 0 can no longer be reconstructed, so the resource can't be
          # faithfully rendered — treat it as not-found (404) rather than letting
          # an unmatched `{:gap, _}` crash the request into a 500.
          {:gap, _} ->
            :not_found

          {:ok, events} ->
            resolve_state(events)
        end
    end
  end

  defp resolve_state(events) do
    last_event = List.last(events)

    case last_event do
      %Event{operation: :delete} ->
        :not_found

      _ ->
        # An empty representation is not the same as not-found: only an
        # explicit DELETE reads as not-found. A PUT with an empty body
        # and a PATCH that removes the last remaining triple both leave
        # the resource visible as 200 with an empty body — the fold
        # below already reflects the real accumulated state either way,
        # including a removal actually taking effect (bug 1's fix).
        {:ok, fold_events(events)}
    end
  end

  defp fold_events(events) do
    Enum.reduce(events, RDF.Graph.new(), fn
      %Event{operation: :replace, payload: payload}, _acc ->
        payload

      %Event{operation: :delete}, _acc ->
        RDF.Graph.new()

      %Event{operation: :patch, payload: %Patch{} = patch}, acc ->
        Patch.apply(acc, patch)
    end)
  end
end
```

- [ ] **Step 4: Update `RiptideWeb.Realtime.SseController`**

Replace `lib/riptide_web/realtime/sse_controller.ex` in full:

```elixir
defmodule RiptideWeb.Realtime.SseController do
  use Phoenix.Controller

  alias Riptide.Event
  alias Riptide.RDF.TurtleCodec
  alias Riptide.Stream.{StreamServer, StreamSupervisor}

  def subscribe(conn, %{"stream_id" => stream_id}) do
    case stream_id |> StreamSupervisor.ensure_ready() |> ensure_ready_status() do
      :ok ->
        Phoenix.PubSub.subscribe(Riptide.PubSub, "stream:" <> stream_id)
        cursor = last_event_id(conn)

        case StreamServer.get_since(stream_id, cursor) do
          {:gap, oldest} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(409, Jason.encode!(%{"oldestAvailable" => oldest}))

          {:ok, backlog} ->
            conn =
              conn
              |> put_resp_content_type("text/event-stream", nil)
              |> send_chunked(200)

            conn = Enum.reduce(backlog, conn, &write_event(&2, &1))
            loop(conn)
        end

      :error ->
        send_resp(conn, 503, "")
    end
  end

  @spec ensure_ready_status(:ok | {:error, term()}) :: :ok | :error
  def ensure_ready_status(:ok), do: :ok
  def ensure_ready_status({:error, _reason}), do: :error

  defp loop(conn) do
    receive do
      {:new_event, event} ->
        conn = write_event(conn, event)
        loop(conn)
    after
      1_000 -> conn
    end
  end

  defp write_event(conn, event) do
    {:ok, turtle} = TurtleCodec.encode(Event.wire_payload(event))
    frame = "id: #{event.sequence}\ndata: #{String.replace(turtle, "\n", "\ndata: ")}\n\n"
    {:ok, conn} = Plug.Conn.chunk(conn, frame)
    conn
  end

  defp last_event_id(conn) do
    case Plug.Conn.get_req_header(conn, "last-event-id") do
      [id] -> String.to_integer(id)
      [] -> nil
    end
  end
end
```

- [ ] **Step 5: Update `RiptideWeb.Realtime.ReplicationChannel`**

Replace `lib/riptide_web/realtime/replication_channel.ex` in full:

```elixir
defmodule RiptideWeb.Realtime.ReplicationChannel do
  @moduledoc """
  WebSocket replication transport for StreamLD's `binding-websocket` — joins
  `"replication:<stream_id>"` with an `"after"` cursor, replies with a backlog,
  and pushes further events as `"replication_frame"` messages. Mirrors the SSE
  controller's cursor/gap semantics over Phoenix Channels instead of SSE.
  """
  use Phoenix.Channel

  alias Riptide.Event
  alias Riptide.RDF.TurtleCodec
  alias Riptide.Stream.{StreamServer, StreamSupervisor}

  @impl true
  def join("replication:" <> stream_id, %{"after" => cursor}, socket) do
    case stream_id |> StreamSupervisor.ensure_ready() |> ensure_ready_status() do
      :ok ->
        Phoenix.PubSub.subscribe(Riptide.PubSub, "stream:" <> stream_id)

        case StreamServer.get_since(stream_id, cursor) do
          {:gap, oldest} ->
            {:error, %{"oldestAvailable" => oldest}}

          {:ok, events} ->
            socket = assign(socket, :stream_id, stream_id)
            {:ok, %{"backlog" => Enum.map(events, &frame/1)}, socket}
        end

      :error ->
        {:error, %{"reason" => "service_unavailable"}}
    end
  end

  @impl true
  def handle_info({:new_event, %Event{} = event}, socket) do
    push(socket, "replication_frame", frame(event))
    {:noreply, socket}
  end

  @spec ensure_ready_status(:ok | {:error, term()}) :: :ok | :error
  def ensure_ready_status(:ok), do: :ok
  def ensure_ready_status({:error, _reason}), do: :error

  defp frame(%Event{} = event) do
    {:ok, turtle} = TurtleCodec.encode(Event.wire_payload(event))

    %{
      "cursor" => event.sequence,
      "event" => %{
        "sequence" => event.sequence,
        "streamId" => event.stream_id,
        "isSnapshot" => Event.wire_snapshot?(event),
        "payload" => turtle
      }
    }
  end
end
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mix test test/riptide_web/ --trace`
Expected: PASS.

- [ ] **Step 7: Run the full suite**

Run: `mix test`
Expected: PASS, no regressions — every existing LDP/SSE/WebSocket test still passes unchanged (single-node test env, `node()` is always the only candidate, so `ensure_ready/1` always returns `:ok` exactly like `get_or_start/1` always succeeded before).

- [ ] **Step 8: Commit**

```bash
git add lib/riptide_web/ldp/resource_controller.ex lib/riptide_web/realtime/sse_controller.ex lib/riptide_web/realtime/replication_channel.ex test/riptide_web/ldp/resource_controller_test.exs test/riptide_web/realtime/sse_controller_test.exs test/riptide_web/realtime/replication_channel_test.exs
git commit -m "Wire LDP/SSE/WebSocket entry points through StreamSupervisor.ensure_ready/1"
```

---

### Task 4: Real multi-node proof — a non-member node serves a request correctly

**Files:**
- Create: `test/riptide_web/routing_cluster_test.exs`

**Interfaces:**
- Consumes: `Riptide.RaCluster.attempt_start_placement_cluster/1` (Phase 3c-i), `Riptide.Stream.Placement.start_link/1` (Task 4 of Phase 3c-ii), `Riptide.Stream.StreamSupervisor.ensure_ready/1` (Task 2 of this plan), `Riptide.Stream.StreamServer.append/2`/`get_since/2` (existing).
- Produces: nothing further downstream — this is the real proof that Tasks 1-3 work together across a node that genuinely isn't one of a stream's replicas, extending Phase 3c-ii's own proven `:peer`-based recipe (`test/riptide/stream/stream_placement_cluster_test.exs`) to 4 real nodes instead of 3.

- [ ] **Step 1: Write the test**

Create `test/riptide_web/routing_cluster_test.exs`:

```elixir
defmodule RiptideWeb.RoutingClusterTest do
  use ExUnit.Case, async: false

  @moduletag timeout: 60_000

  @peer_specs [
    {:riptide_routing0, "riptide-0", ~c"127.0.0.10"},
    {:riptide_routing1, "riptide-1", ~c"127.0.0.11"},
    {:riptide_routing2, "riptide-2", ~c"127.0.0.12"},
    {:riptide_routing3, "riptide-3", ~c"127.0.0.13"}
  ]

  setup_all do
    unless Node.alive?() do
      {:ok, _pid} = Node.start(:"routing_cluster_origin@127.0.0.1", :longnames)
    end

    :ok
  end

  test "a node that isn't one of a stream's 3 replicas still serves requests for it correctly" do
    pa_args = Enum.flat_map(:code.get_path(), fn p -> [~c"-pa", p] end)

    peers =
      for {alive_name, ordinal, host} <- @peer_specs do
        {:ok, pid, _not_yet_named} =
          :peer.start_link(%{
            connection: :standard_io,
            args: pa_args,
            env: [{~c"HOSTNAME", to_charlist(ordinal)}]
          })

        node = :"#{alive_name}@#{to_string(host)}"
        {:ok, _kernel_pid} = :peer.call(pid, :net_kernel, :start, [node, %{name_domain: :longnames}])
        assert :net_kernel.hidden_connect_node(node) == true

        {pid, node, ordinal}
      end

    on_exit(fn ->
      Enum.each(peers, fn {pid, _node, _ordinal} ->
        if Process.alive?(pid) do
          try do
            :peer.stop(pid)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      Enum.each(@peer_specs, fn {_alive_name, ordinal, _host} ->
        File.rm_rf!(Path.join(File.cwd!(), ordinal))
      end)
    end)

    [{module, bytecode}] = Code.compile_file(__ENV__.file)

    for {_pid, node, _ordinal} <- peers do
      assert {:module, ^module} =
               :erpc.call(node, :code, :load_binary, [module, ~c"routing_cluster_test.ex", bytecode])
    end

    nodes = Enum.map(peers, fn {_pid, node, _ordinal} -> node end)
    ordinal_to_node = Map.new(peers, fn {_pid, node, ordinal} -> {ordinal, node} end)
    resolve_fun = fn ordinal -> Map.fetch!(ordinal_to_node, ordinal) end

    for {_pid, node, _ordinal} <- peers do
      :erpc.call(node, Application, :put_env, [:riptide, :ordinal_resolver, resolve_fun])
    end

    for {n1, n2} <- unique_pairs(nodes) do
      assert :erpc.call(n1, :net_kernel, :connect_node, [n2]) == true
    end

    for {_pid, node, _ordinal} <- peers do
      {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:ra])
    end

    for {_pid, node, _ordinal} <- peers do
      case :erpc.call(node, :ra_system, :start, [:erpc.call(node, Riptide.RaCluster, :system_config, [])]) do
        {:ok, _pid} -> :ok
        {:ok, _pid, _info} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    # Only the first 3 :peer_specs are real placement-cluster ordinals
    # ("riptide-0/1/2", matching RaCluster.placement_ordinals/0) — the 4th
    # peer is deliberately extra fleet capacity, exactly like a real node
    # joining a growing cluster that ISN'T one of the 3 fixed placement
    # ordinals. It still needs :ra/PubSub bootstrapped (below) since it's a
    # real node any stream request could land on, just not a placement
    # metadata cluster member.
    placement_peers = Enum.take(peers, 3)

    results =
      Enum.map(placement_peers, fn {_pid, node, _ordinal} ->
        :erpc.call(node, Riptide.RaCluster, :attempt_start_placement_cluster, [resolve_fun])
      end)

    assert Enum.any?(results, &(&1 == :ok))

    for {_pid, node, _ordinal} <- peers do
      {:ok, _pid} = start_unlinked(node, Riptide.Stream.Placement, :start_link, [[]])
    end

    for {_pid, node, _ordinal} <- peers do
      {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:phoenix_pubsub])
      {:ok, _pid} = start_unlinked(node, Phoenix.PubSub.Supervisor, :start_link, [[name: Riptide.PubSub]])
    end

    {_pid, entry_node, _ordinal} = hd(peers)
    stream_id = "routing-cluster-" <> Uniq.UUID.uuid4()

    # RF=3 with 4 connected peers: propose_nodes/2 always puts the entry
    # (proposing) node first, then picks 2 more at random from the other 3
    # — so exactly one of the 4 peers is NOT assigned. Which one is random;
    # find out for real rather than assuming, so the assertions below always
    # target the actual non-member peer.
    assert :ok = :erpc.call(entry_node, Riptide.Stream.StreamSupervisor, :ensure_ready, [stream_id])
    server_ids = :erpc.call(entry_node, Riptide.Stream.Placement, :server_ids!, [stream_id])
    assert length(server_ids) == 3
    assigned_nodes = Enum.map(server_ids, fn {_name, node} -> node end)
    assert length(Enum.uniq(assigned_nodes)) == 3
    assert Enum.all?(assigned_nodes, &(&1 in nodes))

    [non_member_node] = nodes -- assigned_nodes

    graph = :erpc.call(entry_node, RDF.Graph, :new, [])
    event = :erpc.call(entry_node, Riptide.Event, :new, [stream_id, :replace, graph])
    stamped = :erpc.call(entry_node, Riptide.Stream.StreamServer, :append, [stream_id, event])
    assert stamped.sequence == 1

    # The real proof: the ONE peer that was never assigned as a replica —
    # never ran Riptide.Stream.Placement.ensure_started/2's formation
    # branch for this stream at all, has no local Ra process for it — still
    # correctly serves the same request path a member node would.
    assert :ok =
             :erpc.call(non_member_node, Riptide.Stream.StreamSupervisor, :ensure_ready, [stream_id])

    non_member_server_ids =
      :erpc.call(non_member_node, Riptide.Stream.Placement, :server_ids!, [stream_id])

    assert Enum.sort(non_member_server_ids) == Enum.sort(server_ids)

    {:ok, read_back} =
      :erpc.call(non_member_node, Riptide.Stream.StreamServer, :get_since, [stream_id, 0])

    assert [%{sequence: 1}] = read_back

    # Confirm no local Ra process for this stream's uid ever started on the
    # non-member node — it served the request purely via remote :ra
    # addressing, never local formation.
    uid = :erpc.call(non_member_node, Riptide.RaCluster, :uid_for, [stream_id])
    assert :erpc.call(non_member_node, Process, :whereis, [String.to_atom(uid)]) == nil
  end

  defp start_unlinked(node, mod, fun, args, timeout \\ 5_000) do
    parent = self()

    spawn(node, fn ->
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

  defp unique_pairs(list) do
    for {a, i} <- Enum.with_index(list),
        {b, j} <- Enum.with_index(list),
        i < j,
        do: {a, b}
  end
end
```

- [ ] **Step 2: Run it**

Run: `mix test test/riptide_web/routing_cluster_test.exs --trace`
Expected: PASS. Run it 3 times in a row to confirm no flakiness and clean cleanup (`ps aux | grep beam`, `epmd -names`, no leftover `riptide-*` directories in the repo root after each run).

- [ ] **Step 3: Run the full suite**

Run: `mix test`
Expected: PASS, no regressions.

- [ ] **Step 4: Commit**

```bash
git add test/riptide_web/routing_cluster_test.exs
git commit -m "Add real multi-node proof: a non-member node serves requests correctly"
```

---

### Task 5: Live proof against the existing Phase 3b StatefulSet

**Files:**
- No new files — this task operates against the real cluster using the existing `k8s/` manifests, deployed with a replica count greater than RF=3 (e.g. 5) so at least one pod is guaranteed non-member for some stream.

**Interfaces:**
- Consumes: the already-deployed `k8s/*.yaml` manifests, the built Docker image (now including this plan's Tasks 1-4).
- Produces: a written verification record (this task's own report) — no code.

**Note before starting:** deploying this live requires the operator's explicit go-ahead — ask before creating any real cluster resources. Build/push a throwaway-tagged image manually (e.g. `phase-3c-iii-proof`, never touching `:latest`), following the same working recipe as Phase 3c-i/3c-ii's own live proofs (`docker buildx build --network=host --push -t ghcr.io/openfaster-standard/riptide:phase-3c-iii-proof .`, `gh auth token | docker login ghcr.io -u <user> --password-stdin`).

- [ ] **Step 1: Build and push a fresh image, deploy to a disposable namespace with 5 replicas**

```bash
kubectl create namespace riptide-phase-3c-iii-proof
kubectl config set-context --current --namespace=riptide-phase-3c-iii-proof
```

Follow `k8s/README.md`'s Deploy steps, using both the throwaway image tag and a 5-replica override, piped through `kubectl apply -f -` (never edit the committed manifest):

```bash
sed -e 's|ghcr.io/openfaster-standard/riptide:latest|ghcr.io/openfaster-standard/riptide:phase-3c-iii-proof|' \
    -e 's|replicas: 3|replicas: 5|' \
    k8s/statefulset.yaml | kubectl apply -f -
```

If the ghcr.io package pull fails with `401 Unauthorized` (already hit twice before — private package), fix it the same way as before:

```bash
kubectl create secret docker-registry ghcr-pull-secret \
  --docker-server=ghcr.io \
  --docker-username=<your github username> \
  --docker-password="$(gh auth token)"
kubectl patch statefulset riptide --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/imagePullSecrets","value":[{"name":"ghcr-pull-secret"}]}]'
kubectl delete pod riptide-0 riptide-1 riptide-2 riptide-3 riptide-4 --wait=false
```

Run: `kubectl rollout status statefulset/riptide --timeout=180s`
Expected: all 5 pods reach `Ready`. Note: only `riptide-0`/`riptide-1`/`riptide-2` are placement-cluster ordinals (`RaCluster.placement_ordinals/0`); `riptide-3`/`riptide-4` are plain fleet capacity, matching Task 4's own peer split.

- [ ] **Step 2: Verify a genuinely new stream's assignment excludes at least one real pod**

```bash
kubectl exec riptide-0 -- bin/riptide rpc "IO.inspect(Riptide.Stream.StreamSupervisor.ensure_ready(\"live-routing-proof-stream\")); IO.inspect(Riptide.Stream.Placement.server_ids!(\"live-routing-proof-stream\"))"
```

Expected: `:ok`, then a 3-element list of `{name, node}` tuples. With 5 real pods and RF=3, at least 2 of the 5 real node identities are absent from this list — note which pod(s) are absent (their pod ordinal is derivable from the IP in the `node()` atom via `kubectl get pods -o wide`).

- [ ] **Step 3: Verify the excluded pod still serves the request correctly**

Pick one of the excluded pods from Step 2 (e.g. `riptide-3`):

```bash
kubectl exec riptide-3 -- bin/riptide rpc "IO.inspect(Riptide.Stream.StreamSupervisor.ensure_ready(\"live-routing-proof-stream\")); IO.inspect(Riptide.Stream.Placement.server_ids!(\"live-routing-proof-stream\"))"
kubectl exec riptide-0 -- bin/riptide rpc "IO.inspect(Riptide.Stream.StreamServer.append(\"live-routing-proof-stream\", Riptide.Event.new(\"live-routing-proof-stream\", :replace, RDF.Graph.new())))"
kubectl exec riptide-3 -- bin/riptide rpc "IO.inspect(Riptide.Stream.StreamServer.get_since(\"live-routing-proof-stream\", 0))"
```

Expected: `riptide-3`'s `ensure_ready` call returns `:ok` and its `server_ids!` matches the same 3-node set from Step 2 (confirming it resolved the existing assignment via the `:remote` branch, not formation); the `append` on `riptide-0` returns `sequence: 1`; the `get_since` on `riptide-3` (a real non-member pod) returns `{:ok, [%Riptide.Event{sequence: 1, ...}]}` — proving a genuinely non-member pod serves a real read correctly.

- [ ] **Step 4: Tear down**

```bash
kubectl delete namespace riptide-phase-3c-iii-proof
kubectl config set-context --current --namespace=default
```

Poll `kubectl get namespace riptide-phase-3c-iii-proof` until `NotFound`. Delete the throwaway image tag from ghcr.io (`gh api --method DELETE` on its package version) and the local docker image. Leave nothing behind.

- [ ] **Step 5: Record the results**

Write a short summary (for Task 6's `PROGRESS.md` update and the PR description) of what was directly observed at Steps 2-3 — the actual command output, not a paraphrased summary.

---

### Task 6: Full verification + PROGRESS.md + wrap-up

**Files:**
- Modify: `PROGRESS.md`

**Interfaces:**
- Consumes: everything from Tasks 1-5, including Task 5's recorded live-proof results.
- Produces: nothing further downstream — terminal task.

- [ ] **Step 1: Run the full test suite**

Run: `mix test`
Expected: PASS, 0 failures — including every test added in Tasks 1-4 and every pre-existing test (Phases 3a/3b/3c-i/3c-ii's suites) unaffected.

- [ ] **Step 2: Run Credo and formatter checks**

Run: `mix credo --strict && mix format --check-formatted`
Expected: both clean. Fix anything flagged and re-run.

- [ ] **Step 3: Update `PROGRESS.md`**

In the `## 3. Clustering / horizontal scale / HA` section's Phase 3c bullet, change the 3c-iii sub-bullet:

```markdown
  - **3c-iii — Request routing.** Wires the HTTP/SSE/WebSocket layer to consult 3c-i's store
    and serve requests correctly regardless of which node they land on. **Shipped 2026-08-25**
    — see `docs/superpowers/specs/2026-08-25-phase-3c-iii-request-routing-design.md`. No
    HTTP-level proxy layer needed — leans entirely on `:ra`'s and `Phoenix.PubSub`'s existing
    location-transparent/cluster-wide semantics. Live-proved against a real 5-pod GKE
    StatefulSet (RF=3): a pod that wasn't one of a stream's 3 replicas correctly served both
    a request that resolved the existing assignment and a real cross-pod read.
```

Change the `**Status**:` line from:

```markdown
**Status**: Phases 3a-3b shipped. Phase 3c-i and 3c-ii shipped. 3c-iii (request routing)
not yet started.
```

to:

```markdown
**Status**: Phases 3a-3b shipped. Phase 3c (3c-i/3c-ii/3c-iii) fully shipped.
```

- [ ] **Step 4: Commit**

```bash
git add PROGRESS.md
git commit -m "Mark Phase 3c-iii shipped in PROGRESS.md"
```

- [ ] **Step 5: Push and open a PR**

```bash
git push -u origin <branch-name>
gh pr create --title "Phase 3c-iii: request routing" --body "$(cat <<'EOF'
## Summary
- Implements the Phase 3c-iii design spec (docs/superpowers/specs/2026-08-25-phase-3c-iii-request-routing-design.md).
- No HTTP-level proxy layer — Riptide.Stream.Placement.ensure_started/2 gains a member/non-member branch so a non-member node resolving an existing assignment skips cluster formation entirely instead of always failing.
- StreamSupervisor.get_or_start/1 renamed to ensure_ready/1, calling Riptide.Stream.Placement.ensure_started/2 directly (bypassing StreamServer.start_link/1's local-pid requirement), returning :ok | {:error, term()}.
- All 3 request entry points (LDP HTTP, SSE, WebSocket replication) switch to ensure_ready/1 and map failure to a clean 503/error response.
- Includes [Task 5's live-proof results here — paste the recorded observations].

## Test plan
- [x] mix test — full suite passes, including the new Riptide.Stream.Placement/StreamSupervisor/web-controller tests and the new 4-peer real multi-node routing test
- [x] mix credo --strict
- [x] mix format --check-formatted
- [x] Live proof: a real pod that wasn't one of a stream's 3 replicas (RF=3, 5-pod StatefulSet) correctly resolved the existing assignment and served a real cross-pod read (see Task 5's recorded results)
EOF
)"
```

Report the PR URL and stop — do not merge without explicit human sign-off (ask via AskUserQuestion), matching this project's established practice for every prior PR.
