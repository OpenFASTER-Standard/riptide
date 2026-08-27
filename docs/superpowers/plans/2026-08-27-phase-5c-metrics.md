# Phase 5c (Metrics) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Riptide a Prometheus `/metrics` scrape endpoint covering both generic HTTP/WebSocket
traffic and the domain-specific signals that actually matter for a Raft-backed event-streaming
server (stream append/read latency, placement-cluster health, replica-healer activity, Ra
leadership) — the last phase on Riptide's entire production-readiness roadmap.

**Architecture:** `telemetry_metrics` + `telemetry_metrics_prometheus_core` (not the heavier
`PromEx`) aggregate `:telemetry` events into Prometheus format. A new `Riptide.Telemetry`
supervisor defines every metric and starts the Prometheus reporter plus a `:telemetry_poller` for
one gauge. A new, second Plug-based listener (`RiptideWeb.MetricsEndpoint`) serves `GET /metrics`
on port 9090 — a separate port, ClusterIP-only, never routed through Phase 4d's public Ingress.
HTTP/WebSocket metrics attach to telemetry events Phoenix already emits; domain metrics need new
`:telemetry.execute`/`:telemetry.span` calls added to Riptide's own stream/placement/replica-healer
code.

**Tech Stack:** `:telemetry`, `telemetry_metrics`, `telemetry_poller`, `telemetry_metrics_prometheus_core`, `Plug.Router`, `Plug.Cowboy`.

**Spec:** `docs/superpowers/specs/2026-08-27-phase-5c-metrics-design.md`

## Global Constraints

- **Cardinality (binding on every metric added in this phase):** no metric may tag by `stream_id`
  or `tenant_id` — Prometheus stores one time series per distinct tag-value combination, and
  either would create unbounded series for a multi-tenant streaming server. Every tag used in this
  plan is drawn from a small, fixed, known-in-advance set (an HTTP method, a *route pattern*
  string — not a resolved request path — a status code, a `:result` atom).
- **HTTP route tagging must use `[:phoenix, :router_dispatch, :stop]`'s `route` metadata key, NOT
  `conn.request_path`.** Confirmed by reading `deps/phoenix/lib/phoenix/router.ex:791-808`:
  `route` is the literal router-DSL pattern string (e.g. `"/tenants/:tenant_id/resources/*path"`),
  compiled once per route definition — a small, fixed set. `conn.request_path` is the resolved,
  per-request path (e.g. `/tenants/acme/resources/doc-1`) and would violate the cardinality
  constraint immediately if used as a tag.
- **Placement lookup/assign duration and error-count are tracked as two separate metrics, not one
  `:result`-tagged distribution.** `Riptide.Placement.lookup/1`/`assign/2` can raise (not return an
  `{:error, _}` tuple) on total placement-cluster failure — `:telemetry.span/3`'s exception path
  and its normal `:stop` path are different events, and relying on two `Telemetry.Metrics`
  definitions sharing one output name across different source events is an unconfirmed library
  behavior this plan avoids rather than assumes. Use `riptide.placement.lookup.duration`
  (distribution, `:stop` event, success-path latency only) and `riptide.placement.lookup.errors`
  (counter, `:exception` event) as two independently-named metrics. Same split for `assign`.
- `Riptide.Placement.lookup/1`'s existing raise-on-total-failure behavior (documented in Phase
  5a's own spec) must be preserved exactly — `:telemetry.span/3` re-raises automatically after
  emitting its `:exception` event, so wrapping it must not add any `rescue`/`catch` of its own.
- The metrics endpoint (port 9090) binds in every environment, not gated to `:prod` only — a
  self-hoster running one local instance should be able to `curl` its own metrics too.
- No Ingress manifest is touched — port 9090 is never reachable through Phase 4d's public
  Ingress/TLS path.
- The 4 existing Phase 5b `Logger` calls in `Riptide.Stream.ReplicaHealer` stay exactly as they
  are — new `:telemetry.execute` calls are added alongside them, not replacing them.

---

### Task 1: Add metrics dependencies

**Files:**
- Modify: `mix.exs`

**Interfaces:**
- Produces: `{:telemetry_metrics, ...}`, `{:telemetry_poller, ...}`,
  `{:telemetry_metrics_prometheus_core, ...}` as compiled dependencies — consumed by every later
  task in this plan.

- [ ] **Step 1: Confirm the current deps list**

Run: `grep -n "defp deps do" -A 20 mix.exs`
Expected (confirm this matches before editing):
```elixir
  defp deps do
    [
      {:phoenix, "~> 1.8"},
      {:plug_cowboy, "~> 2.7"},
      {:jason, "~> 1.4"},
      {:rdf, "~> 3.0"},
      {:json_ld, "~> 1.0"},
      {:uniq, "~> 0.6"},
      {:ra, "~> 2.15.0"},
      {:libcluster, "~> 3.3"},
      # Pinned below joken's own "~> 1.11.10" floor: jose 1.11.11+ uses the
      # `dynamic()` Erlang type in its typespecs, which only exists as a
      # built-in type from OTP 27 onward. This project is pinned to OTP 25
      # (see PROGRESS.md's :ra 2.15.0 rationale), so 1.11.11+ fails to
      # compile here with "type dynamic() undefined". 1.11.10 predates that
      # typespec change and satisfies joken's own requirement unchanged.
      {:jose, "== 1.11.10"},
      {:joken, "~> 2.6"},
      {:joken_jwks, "~> 1.7"},
      {:tesla, "~> 1.4"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
```

- [ ] **Step 2: Add the 3 new dependencies**

Change:
```elixir
      {:tesla, "~> 1.4"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
```
to:
```elixir
      {:tesla, "~> 1.4"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:telemetry_metrics_prometheus_core, "~> 1.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
```

`:telemetry` itself is already present transitively (via Phoenix/Plug/libcluster) — no explicit
entry needed.

- [ ] **Step 3: Fetch and compile**

Run: `mix deps.get`
Expected: resolves and fetches `telemetry_metrics`, `telemetry_poller`,
`telemetry_metrics_prometheus_core` (and `telemetry` if not already present), no errors.

Run: `mix compile`
Expected: compiles with no errors (pre-existing `:formats` warnings, unrelated to this change, are
fine).

- [ ] **Step 4: Run the full test suite**

Run: `mix test`
Expected: PASS — all tests green (this task only adds dependencies, no behavior change yet).

- [ ] **Step 5: Commit**

```bash
git add mix.exs mix.lock
git commit -m "Phase 5c: add telemetry_metrics, telemetry_poller, telemetry_metrics_prometheus_core"
```

---

### Task 2: `Riptide.Telemetry` + `RiptideWeb.MetricsEndpoint`

**Files:**
- Create: `lib/riptide/telemetry.ex`
- Create: `lib/riptide_web/metrics_endpoint.ex`
- Modify: `lib/riptide/application.ex`
- Test: `test/riptide_web/metrics_endpoint_test.exs`

**Interfaces:**
- Consumes: `Riptide.RaCluster.placement_leader?/0` (existing).
- Produces: `Riptide.Telemetry.metrics/0` (the full metric list, including domain metrics not yet
  emitted by Tasks 3-5 — `Telemetry.Metrics` definitions listen for an event name; nothing breaks
  if that event doesn't exist yet, it simply records nothing until a later task adds the
  `:telemetry.execute`/`:telemetry.span` call). `Riptide.Telemetry.measure_placement_leadership/0`
  — consumed by this same task's `:telemetry_poller` wiring, no other task depends on it.
  `RiptideWeb.MetricsEndpoint` — a `Plug.Router` module; no other task depends on its internals,
  only on port 9090 being reachable.

- [ ] **Step 1: Write the failing integration test**

Create `test/riptide_web/metrics_endpoint_test.exs`:

```elixir
defmodule RiptideWeb.MetricsEndpointTest do
  use ExUnit.Case, async: true

  @endpoint_url "http://localhost:9090/metrics"

  test "GET /metrics returns Prometheus exposition format with at least one known metric" do
    {:ok, {{_, 200, _}, _headers, body}} =
      :httpc.request(:get, {String.to_charlist(@endpoint_url), []}, [], [])

    body = to_string(body)

    # phoenix.router_dispatch.duration is guaranteed to have at least been
    # *registered* (Telemetry.Metrics exposes a metric's name in scrape
    # output once any matching event has fired at least once OR, for some
    # reporters, as soon as it's registered — assert on the broader
    # Prometheus format contract instead of requiring a specific metric to
    # already have data, since no HTTP request has necessarily happened yet
    # in this test's own process).
    assert body =~ "# TYPE"
    assert String.contains?(body, "riptide_") or String.contains?(body, "phoenix_")
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/riptide_web/metrics_endpoint_test.exs`
Expected: FAIL — connection refused (nothing listens on port 9090 yet).

- [ ] **Step 3: Write `Riptide.Telemetry`**

Create `lib/riptide/telemetry.ex`:

```elixir
defmodule Riptide.Telemetry do
  @moduledoc """
  Supervises Riptide's Prometheus metrics pipeline (Phase 5c): the
  `TelemetryMetricsPrometheus.Core` reporter (aggregates `:telemetry` events
  into Prometheus-formatted series, scraped by `RiptideWeb.MetricsEndpoint`
  on port 9090) and a `:telemetry_poller` for the one gauge metric that
  isn't event-driven (`riptide.ra.placement_leader` — standing state, not a
  discrete occurrence).

  No metric here tags by `stream_id`/`tenant_id` — see the Phase 5c design
  spec's Cardinality section: Prometheus stores one time series per
  distinct tag-value combination, so a per-stream or per-tenant tag would
  create unbounded series for a multi-tenant streaming server. HTTP route
  tagging uses `[:phoenix, :router_dispatch, :stop]`'s own `route` metadata
  key (the literal router-DSL pattern string, e.g.
  `"/tenants/:tenant_id/resources/*path"`, compiled once per route
  definition — a small, fixed set) rather than `conn.request_path` (the
  resolved, per-request path, which would violate the cardinality
  constraint immediately).
  """
  use Supervisor
  import Telemetry.Metrics

  @placement_leader_poll_interval_ms 30_000

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {TelemetryMetricsPrometheus.Core, metrics: metrics()},
      {:telemetry_poller,
       measurements: [{__MODULE__, :measure_placement_leadership, []}],
       period: @placement_leader_poll_interval_ms,
       name: Riptide.Telemetry.Poller}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Periodic measurement invoked by `:telemetry_poller` — emits
  `riptide.ra.placement_leader` as a 1/0 gauge.
  """
  @spec measure_placement_leadership() :: :ok
  def measure_placement_leadership do
    value = if Riptide.RaCluster.placement_leader?(), do: 1, else: 0
    :telemetry.execute([:riptide, :ra, :placement_leader], %{value: value}, %{})
  end

  @spec metrics() :: [Telemetry.Metrics.t()]
  def metrics do
    [
      # HTTP — [:phoenix, :router_dispatch, :stop] only fires for requests
      # that matched a defined route; its `route` metadata is the literal
      # router-DSL pattern, not the resolved request path (see moduledoc).
      distribution("phoenix.router_dispatch.duration",
        event_name: [:phoenix, :router_dispatch, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        tags: [:route, :method, :status],
        tag_values: &phoenix_router_dispatch_tag_values/1
      ),

      # WebSocket — Phoenix's own existing telemetry events, no new
      # instrumentation.
      distribution("phoenix.socket_connected.duration",
        event_name: [:phoenix, :socket_connected],
        measurement: :duration,
        unit: {:native, :millisecond}
      ),
      distribution("phoenix.channel_joined.duration",
        event_name: [:phoenix, :channel_joined],
        measurement: :duration,
        unit: {:native, :millisecond}
      ),

      # Stream — new :telemetry.span/3 calls added in Task 3
      # (Riptide.Stream.StreamServer).
      distribution("riptide.stream.append.duration",
        event_name: [:riptide, :stream, :append, :stop],
        measurement: :duration,
        unit: {:native, :millisecond}
      ),
      distribution("riptide.stream.get_since.duration",
        event_name: [:riptide, :stream, :get_since, :stop],
        measurement: :duration,
        unit: {:native, :millisecond}
      ),
      counter("riptide.stream.get_since.gap",
        event_name: [:riptide, :stream, :get_since, :gap]
      ),

      # Placement — new :telemetry.span/3 calls added in Task 4
      # (Riptide.Placement). Duration (success path) and errors (exception
      # path) are two separate metrics — see Global Constraints.
      distribution("riptide.placement.lookup.duration",
        event_name: [:riptide, :placement, :lookup, :stop],
        measurement: :duration,
        unit: {:native, :millisecond}
      ),
      counter("riptide.placement.lookup.errors",
        event_name: [:riptide, :placement, :lookup, :exception]
      ),
      distribution("riptide.placement.assign.duration",
        event_name: [:riptide, :placement, :assign, :stop],
        measurement: :duration,
        unit: {:native, :millisecond}
      ),
      counter("riptide.placement.assign.errors",
        event_name: [:riptide, :placement, :assign, :exception]
      ),

      # Replica healer — new :telemetry.execute calls added in Task 5
      # (Riptide.Stream.ReplicaHealer), alongside its existing Logger calls.
      counter("riptide.replica_healer.repairs",
        event_name: [:riptide, :replica_healer, :repair],
        tags: [:result]
      ),
      counter("riptide.replica_healer.dead_replicas_detected",
        event_name: [:riptide, :replica_healer, :dead_replica_detected]
      ),

      # Ra placement-cluster leadership — a gauge sampled by the
      # :telemetry_poller above, not event-driven.
      last_value("riptide.ra.placement_leader",
        event_name: [:riptide, :ra, :placement_leader],
        measurement: :value
      )
    ]
  end

  defp phoenix_router_dispatch_tag_values(%{route: route, conn: conn}) do
    %{route: route, method: conn.method, status: conn.status}
  end
end
```

- [ ] **Step 4: Write `RiptideWeb.MetricsEndpoint`**

Create `lib/riptide_web/metrics_endpoint.ex`:

```elixir
defmodule RiptideWeb.MetricsEndpoint do
  @moduledoc """
  A minimal `Plug.Router`-based HTTP server (not a full `Phoenix.Endpoint` —
  no router/controller/socket machinery needed a second time) serving
  `GET /metrics` in Prometheus exposition format, bound to port 9090.

  A separate port from `RiptideWeb.Endpoint` (4000), deliberately —
  Phase 4d's Ingress only routes port 4000 publicly; port 9090 is
  ClusterIP-only, reachable solely from inside the cluster (a Prometheus
  pod's own scrape), never through the public Ingress/TLS path. Binds in
  every environment, not gated to `:prod` — a self-hoster running one local
  instance should be able to `curl` its own metrics too.
  """
  use Plug.Router

  plug :match
  plug :dispatch

  get "/metrics" do
    body = TelemetryMetricsPrometheus.Core.scrape()

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, body)
  end

  match _ do
    send_resp(conn, 404, "")
  end
end
```

- [ ] **Step 5: Wire both into `Riptide.Application`**

Run: `grep -n "AccessLog.attach\|children =" lib/riptide/application.ex`
Expected (confirm this matches before editing):
```
    AccessLog.attach()

    children =
      [
        {Phoenix.PubSub, name: Riptide.PubSub},
        Riptide.Stream.Placement,
```

Change:
```elixir
    AccessLog.attach()

    children =
      [
        {Phoenix.PubSub, name: Riptide.PubSub},
        Riptide.Stream.Placement,
```
to:
```elixir
    AccessLog.attach()

    children =
      [
        {Phoenix.PubSub, name: Riptide.PubSub},
        Riptide.Telemetry,
        {Plug.Cowboy, scheme: :http, plug: RiptideWeb.MetricsEndpoint, options: [port: 9090]},
        Riptide.Stream.Placement,
```

- [ ] **Step 6: Run the integration test to verify it passes**

Run: `mix test test/riptide_web/metrics_endpoint_test.exs`
Expected: PASS — 1 test, 0 failures.

- [ ] **Step 7: Run the full test suite**

Run: `mix test`
Expected: PASS — all tests green.

- [ ] **Step 8: Commit**

```bash
git add lib/riptide/telemetry.ex lib/riptide_web/metrics_endpoint.ex lib/riptide/application.ex test/riptide_web/metrics_endpoint_test.exs
git commit -m "Phase 5c: add Riptide.Telemetry (Prometheus reporter) and RiptideWeb.MetricsEndpoint"
```

---

### Task 3: Stream instrumentation (`StreamServer.append/2`, `get_since/2`)

**Files:**
- Modify: `lib/riptide/stream/stream_server.ex`
- Test: `test/riptide/stream/stream_server_test.exs` (add to existing file — confirm it exists and
  tests this module first via `grep -n "defmodule" test/riptide/stream/stream_server_test.exs`)

**Interfaces:**
- Consumes: `:telemetry.span/3` (from the `:telemetry` dependency, already present).
- Produces: `[:riptide, :stream, :append, :start/:stop/:exception]`,
  `[:riptide, :stream, :get_since, :start/:stop/:exception]`,
  `[:riptide, :stream, :get_since, :gap]` telemetry events — consumed by Task 2's already-written
  `Riptide.Telemetry.metrics/0` (no changes needed there; those metric definitions already exist).

- [ ] **Step 1: Confirm current `append/2` and `get_since/2`**

Run: `grep -n "def append\|def get_since" -A 6 lib/riptide/stream/stream_server.ex`
Expected (confirm this matches before editing):
```elixir
  @spec append(String.t(), Event.t()) :: Event.t()
  def append(stream_id, %Event{} = event) do
    server_id = hd(Placement.server_ids!(stream_id))
    stamped = RaCluster.process_command(server_id, {:append, Event.encode(event)})
    Phoenix.PubSub.broadcast(Riptide.PubSub, "stream:" <> stream_id, {:new_event, stamped})
    stamped
  end
```
and
```elixir
  @spec get_since(String.t(), non_neg_integer() | nil) ::
          {:ok, [Event.t()]} | {:gap, pos_integer() | nil}
  def get_since(stream_id, cursor) do
    server_id = hd(Placement.server_ids!(stream_id))
    RaCluster.consistent_query(server_id, &RaMachine.get_since(&1, cursor))
  end
```

- [ ] **Step 2: Write the failing tests**

Add to `test/riptide/stream/stream_server_test.exs` (inside the existing module — check its
`alias`/`setup` blocks first and reuse whatever stream-creation helper the file already has, e.g.
`unique_stream_id/0` or similar, rather than inventing a new one):

```elixir
  test "append/2 emits a riptide.stream.append telemetry span" do
    stream_id = unique_stream_id()
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id) end)
    StreamServer.start_link(stream_id)

    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:riptide, :stream, :append, :start],
        [:riptide, :stream, :append, :stop]
      ])

    StreamServer.append(stream_id, Event.new(stream_id, :replace, RDF.Graph.new()))

    assert_received {[:riptide, :stream, :append, :start], ^ref, %{monotonic_time: _}, %{}}
    assert_received {[:riptide, :stream, :append, :stop], ^ref, %{duration: duration}, %{}}
    assert is_integer(duration)
  end

  test "get_since/2 emits a riptide.stream.get_since telemetry span" do
    stream_id = unique_stream_id()
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id) end)
    StreamServer.start_link(stream_id)

    ref =
      :telemetry_test.attach_event_handlers(self(), [[:riptide, :stream, :get_since, :stop]])

    StreamServer.get_since(stream_id, nil)

    assert_received {[:riptide, :stream, :get_since, :stop], ^ref, %{duration: duration}, %{}}
    assert is_integer(duration)
  end

  test "get_since/2 emits a gap event when the cursor has fallen out of retention" do
    stream_id = unique_stream_id()
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id) end)
    {:ok, _pid} = StreamServer.start_link({stream_id, retention: 1})

    StreamServer.append(stream_id, Event.new(stream_id, :replace, RDF.Graph.new()))
    StreamServer.append(stream_id, Event.new(stream_id, :replace, RDF.Graph.new()))

    ref = :telemetry_test.attach_event_handlers(self(), [[:riptide, :stream, :get_since, :gap]])

    assert {:gap, _oldest} = StreamServer.get_since(stream_id, 0)

    assert_received {[:riptide, :stream, :get_since, :gap], ^ref, %{}, %{}}
  end
```

If the existing test file doesn't already `alias Riptide.Stream.StreamServer` and
`alias Riptide.Event`, add those aliases. Use whatever exact `unique_stream_id/0`-equivalent helper
and `RDF.Graph.new()`-style event construction the existing tests in this file already use — read
the file's existing tests first and match their exact pattern rather than the illustrative code
above if it differs.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `mix test test/riptide/stream/stream_server_test.exs`
Expected: FAIL — the 3 new tests fail (no telemetry events fire yet); other existing tests in the
file still pass.

- [ ] **Step 4: Implement the instrumentation**

Change:
```elixir
  @spec append(String.t(), Event.t()) :: Event.t()
  def append(stream_id, %Event{} = event) do
    server_id = hd(Placement.server_ids!(stream_id))
    stamped = RaCluster.process_command(server_id, {:append, Event.encode(event)})
    Phoenix.PubSub.broadcast(Riptide.PubSub, "stream:" <> stream_id, {:new_event, stamped})
    stamped
  end
```
to:
```elixir
  @spec append(String.t(), Event.t()) :: Event.t()
  def append(stream_id, %Event{} = event) do
    :telemetry.span([:riptide, :stream, :append], %{}, fn ->
      server_id = hd(Placement.server_ids!(stream_id))
      stamped = RaCluster.process_command(server_id, {:append, Event.encode(event)})
      Phoenix.PubSub.broadcast(Riptide.PubSub, "stream:" <> stream_id, {:new_event, stamped})
      {stamped, %{}}
    end)
  end
```

Change:
```elixir
  @spec get_since(String.t(), non_neg_integer() | nil) ::
          {:ok, [Event.t()]} | {:gap, pos_integer() | nil}
  def get_since(stream_id, cursor) do
    server_id = hd(Placement.server_ids!(stream_id))
    RaCluster.consistent_query(server_id, &RaMachine.get_since(&1, cursor))
  end
```
to:
```elixir
  @spec get_since(String.t(), non_neg_integer() | nil) ::
          {:ok, [Event.t()]} | {:gap, pos_integer() | nil}
  def get_since(stream_id, cursor) do
    :telemetry.span([:riptide, :stream, :get_since], %{}, fn ->
      server_id = hd(Placement.server_ids!(stream_id))
      result = RaCluster.consistent_query(server_id, &RaMachine.get_since(&1, cursor))

      case result do
        {:gap, _oldest} -> :telemetry.execute([:riptide, :stream, :get_since, :gap], %{}, %{})
        _ -> :ok
      end

      {result, %{}}
    end)
  end
```

`:telemetry.span/3` requires its function to return `{result, stop_metadata}` — both wrapped
functions now return that 2-tuple instead of the bare value, and `:telemetry.span/3` itself
unwraps it back to just `result` for the caller, so `append/2`'s and `get_since/2`'s own external
return types (per their `@spec`s) are unchanged.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix test test/riptide/stream/stream_server_test.exs`
Expected: PASS — all tests in the file, 0 failures.

- [ ] **Step 6: Run the full test suite**

Run: `mix test`
Expected: PASS — all tests green.

- [ ] **Step 7: Commit**

```bash
git add lib/riptide/stream/stream_server.ex test/riptide/stream/stream_server_test.exs
git commit -m "Phase 5c: instrument StreamServer.append/2 and get_since/2 with telemetry spans"
```

---

### Task 4: Placement instrumentation (`lookup/1`, `assign/2`)

**Files:**
- Modify: `lib/riptide/placement.ex`
- Test: `test/riptide/placement_test.exs` (add to existing file)

**Interfaces:**
- Consumes: `:telemetry.span/3`.
- Produces: `[:riptide, :placement, :lookup, :start/:stop/:exception]`,
  `[:riptide, :placement, :assign, :start/:stop/:exception]` — consumed by Task 2's
  already-written `Riptide.Telemetry.metrics/0`.

- [ ] **Step 1: Confirm current `lookup/1` and `assign/2`**

Run: `grep -n "def lookup\|def assign" -A 6 lib/riptide/placement.ex`
Expected (confirm this matches before editing):
```elixir
  @spec assign(String.t(), [node()], (String.t() -> node())) :: [node()]
  def assign(stream_id, proposed_nodes, resolve_fun \\ &RaCluster.default_ordinal_resolver/1) do
    with_ordinal_fallback(resolve_fun, fn server_id ->
      RaCluster.process_command(server_id, {:assign, stream_id, proposed_nodes})
    end)
  end

  @spec lookup(String.t(), (String.t() -> node())) :: [node()] | nil
  def lookup(stream_id, resolve_fun \\ &RaCluster.default_ordinal_resolver/1) do
    with_ordinal_fallback(resolve_fun, fn server_id ->
      RaCluster.consistent_query(server_id, &PlacementMachine.get(&1, stream_id))
    end)
  end
```

- [ ] **Step 2: Write the failing tests**

Add to `test/riptide/placement_test.exs` (inside the existing module):

```elixir
  test "lookup/1 emits a riptide.placement.lookup telemetry span" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:riptide, :placement, :lookup, :stop]])

    Placement.lookup("some-nonexistent-stream-id")

    assert_received {[:riptide, :placement, :lookup, :stop], ^ref, %{duration: duration}, %{}}
    assert is_integer(duration)
  end

  test "lookup/1 emits an exception event when every ordinal fails" do
    failing_resolver = fn _ordinal -> :"nonexistent@nohost" end
    ref = :telemetry_test.attach_event_handlers(self(), [[:riptide, :placement, :lookup, :exception]])

    assert_raise RuntimeError, fn ->
      Placement.lookup("some-stream-id", failing_resolver)
    end

    assert_received {[:riptide, :placement, :lookup, :exception], ^ref, %{duration: _},
                      %{kind: :error}}
  end

  test "assign/2 emits a riptide.placement.assign telemetry span" do
    stream_id = "telemetry-assign-test-" <> Uniq.UUID.uuid4()
    ref = :telemetry_test.attach_event_handlers(self(), [[:riptide, :placement, :assign, :stop]])

    Placement.assign(stream_id, [node()])

    assert_received {[:riptide, :placement, :assign, :stop], ^ref, %{duration: duration}, %{}}
    assert is_integer(duration)
  end
```

The `failing_resolver`/`assert_raise` pattern mirrors Phase 5a's own health-probe test (see
`test/riptide_web/health_test.exs`'s `"returns 503 when the placement cluster is unreachable"`
test) — pointing every ordinal at an unreachable node name forces `with_ordinal_fallback/2` to
exhaust and raise for real, without touching the actual shared placement cluster other tests
depend on.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `mix test test/riptide/placement_test.exs`
Expected: FAIL — the 3 new tests fail (no telemetry events fire yet).

- [ ] **Step 4: Implement the instrumentation**

Change:
```elixir
  @spec assign(String.t(), [node()], (String.t() -> node())) :: [node()]
  def assign(stream_id, proposed_nodes, resolve_fun \\ &RaCluster.default_ordinal_resolver/1) do
    with_ordinal_fallback(resolve_fun, fn server_id ->
      RaCluster.process_command(server_id, {:assign, stream_id, proposed_nodes})
    end)
  end

  @spec lookup(String.t(), (String.t() -> node())) :: [node()] | nil
  def lookup(stream_id, resolve_fun \\ &RaCluster.default_ordinal_resolver/1) do
    with_ordinal_fallback(resolve_fun, fn server_id ->
      RaCluster.consistent_query(server_id, &PlacementMachine.get(&1, stream_id))
    end)
  end
```
to:
```elixir
  @spec assign(String.t(), [node()], (String.t() -> node())) :: [node()]
  def assign(stream_id, proposed_nodes, resolve_fun \\ &RaCluster.default_ordinal_resolver/1) do
    :telemetry.span([:riptide, :placement, :assign], %{}, fn ->
      result =
        with_ordinal_fallback(resolve_fun, fn server_id ->
          RaCluster.process_command(server_id, {:assign, stream_id, proposed_nodes})
        end)

      {result, %{}}
    end)
  end

  @spec lookup(String.t(), (String.t() -> node())) :: [node()] | nil
  def lookup(stream_id, resolve_fun \\ &RaCluster.default_ordinal_resolver/1) do
    :telemetry.span([:riptide, :placement, :lookup], %{}, fn ->
      result =
        with_ordinal_fallback(resolve_fun, fn server_id ->
          RaCluster.consistent_query(server_id, &PlacementMachine.get(&1, stream_id))
        end)

      {result, %{}}
    end)
  end
```

`:telemetry.span/3` re-raises automatically after emitting `[..., :exception]` on any exception
raised inside the wrapped function — `lookup/1`'s existing raise-on-total-failure behavior
(`with_ordinal_fallback/2`'s last-ordinal exception propagating uncaught) is preserved exactly; no
`rescue`/`catch` is added here.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix test test/riptide/placement_test.exs`
Expected: PASS — all tests in the file, 0 failures.

- [ ] **Step 6: Run the full test suite**

Run: `mix test`
Expected: PASS — all tests green.

- [ ] **Step 7: Commit**

```bash
git add lib/riptide/placement.ex test/riptide/placement_test.exs
git commit -m "Phase 5c: instrument Placement.lookup/1 and assign/2 with telemetry spans"
```

---

### Task 5: Replica-healer instrumentation

**Files:**
- Modify: `lib/riptide/stream/replica_healer.ex`
- Modify: `test/riptide/stream/replica_healer_cluster_test.exs` (add a telemetry assertion to its
  real-repair test — one of 3 files that exercise a real repair, per Step 2's own discovery; this
  task only touches this one, see Step 2 for why)

**Interfaces:**
- Consumes: `:telemetry.execute/3`.
- Produces: `[:riptide, :replica_healer, :repair]` (metadata `%{result: :ok | :error}`),
  `[:riptide, :replica_healer, :dead_replica_detected]` — consumed by Task 2's already-written
  `Riptide.Telemetry.metrics/0`.

- [ ] **Step 1: Confirm current `maybe_repair/1`, `repair/4`, `do_repair/6`**

Run: `grep -n "defp maybe_repair\|defp repair\|defp do_repair" -A 25 lib/riptide/stream/replica_healer.ex`
Expected (confirm this matches before editing):
```elixir
  defp maybe_repair({stream_id, nodes}) do
    uid = RaCluster.uid_for(stream_id)
    name = String.to_atom(uid)
    dead_nodes = Enum.reject(nodes, &RaCluster.member_alive?({name, &1}))

    case dead_nodes do
      [dead_node] -> repair(stream_id, uid, nodes, dead_node)
      _ -> :ok
    end
  end

  defp repair(stream_id, uid, nodes, dead_node) do
    survivor_nodes = nodes -- [dead_node]

    case pick_replacement(nodes) do
      nil ->
        :ok

      new_node ->
        case discover_retention(uid, survivor_nodes) do
          {:ok, retention} ->
            do_repair(stream_id, uid, survivor_nodes, dead_node, new_node, retention)

          :error ->
            Logger.warning(
              "ReplicaHealer could not discover #{stream_id}'s current retention from any " <>
                "survivor (#{inspect(survivor_nodes)}); skipping repair this tick",
              stream_id: stream_id,
              survivor_nodes: inspect(survivor_nodes)
            )
        end
    end
  end

  defp do_repair(stream_id, uid, survivor_nodes, dead_node, new_node, retention) do
    machine = {:module, RaMachine, %{retention: retention}}

    case RaCluster.replace_member(uid, survivor_nodes, dead_node, new_node, machine) do
      :ok ->
        new_nodes = Placement.replace_member(stream_id, dead_node, new_node)

        Phoenix.PubSub.broadcast(
          Riptide.PubSub,
          "stream_placement_changed",
          {:stream_placement_changed, stream_id, new_nodes}
        )

        Logger.info(
          "ReplicaHealer repaired #{stream_id}: replaced #{inspect(dead_node)} with #{inspect(new_node)}",
          stream_id: stream_id,
          dead_node: inspect(dead_node),
          new_node: inspect(new_node)
        )

      {:error, reason} ->
        Logger.warning(
          "ReplicaHealer failed to repair #{stream_id} (dead: #{inspect(dead_node)}): #{inspect(reason)}",
          stream_id: stream_id,
          dead_node: inspect(dead_node),
          reason: inspect(reason)
        )
    end
  end
```

- [ ] **Step 2: Add a telemetry assertion to one existing real repair test**

Confirmed by reading the actual test files (`grep -rl ":sweep\b" test/` — note this must search for
`:sweep` as an atom argument, not a literal `"ReplicaHealer.sweep"` substring: these tests call
`:erpc.call(node, Riptide.Stream.ReplicaHealer, :sweep, [])`, which splits the module and function
across separate arguments rather than a dotted call): 3 files exercise a real, successful repair —
`replica_healer_cluster_test.exs`, `replica_healer_retention_test.exs`, and
`replica_healer_leadership_gate_test.exs`. All 3 exercise the *same* underlying `do_repair/6`
success branch this task instruments — adding the identical telemetry-assertion pattern to all 3
would be redundant duplication of the same code path, not meaningfully broader coverage, so this
task adds it to only one: `test/riptide/stream/replica_healer_cluster_test.exs`'s
`"a stream's dead replica is automatically detected and repaired, with no data loss"` (the most
direct, single-repair scenario of the three). There is no existing test exercising a *failed*
repair at all; this task does not add one (inventing a new multi-node failure scenario is out of
scope — this successful-repair assertion is still meaningful coverage, and the gap should be noted
in the task report, not silently worked around).

**This test's `sweep/0` call runs on a remote `:peer` node** (`:erpc.call(node_a,
Riptide.Stream.ReplicaHealer, :sweep, [])`), not in the test's own process — `:telemetry` handlers
are node-local, so attaching one via plain `:telemetry_test.attach_event_handlers(self(), ...)` in
the test process would never see an event emitted on a different node. The handler must be
attached *on `node_a`* instead, via `:erpc.call`, with the test's own `self()` PID as the
destination — Erlang PIDs are location-transparent across already-connected distributed nodes (and
this test already connects all its peer nodes to each other earlier via `:net_kernel.connect_node`),
so the remote handler can message the origin test process directly.

In `test/riptide/stream/replica_healer_cluster_test.exs`, find this existing block (confirm via
`grep -n "assert eventually" test/riptide/stream/replica_healer_cluster_test.exs` first):

```elixir
    assert eventually(fn ->
             :erpc.call(node_a, Riptide.Stream.ReplicaHealer, :sweep, []) == :ok and
               Enum.sort(:erpc.call(node_a, Riptide.Placement, :lookup, [stream_id])) !=
                 Enum.sort(original_nodes)
           end)

    repaired_nodes = :erpc.call(node_a, Riptide.Placement, :lookup, [stream_id])
```

Change it to:

```elixir
    telemetry_ref =
      :erpc.call(node_a, :telemetry_test, :attach_event_handlers, [
        self(),
        [[:riptide, :replica_healer, :repair]]
      ])

    assert eventually(fn ->
             :erpc.call(node_a, Riptide.Stream.ReplicaHealer, :sweep, []) == :ok and
               Enum.sort(:erpc.call(node_a, Riptide.Placement, :lookup, [stream_id])) !=
                 Enum.sort(original_nodes)
           end)

    assert_received {[:riptide, :replica_healer, :repair], ^telemetry_ref, %{}, %{result: :ok}}

    repaired_nodes = :erpc.call(node_a, Riptide.Placement, :lookup, [stream_id])
```

The `eventually/1` retry loop may call `sweep/0` more than once before the repair actually
succeeds (per the existing test's own comment about needing a moment for the killed peer to be
observed as dead) — `assert_received` checks the whole mailbox for a matching message, not just
the most recent one, so this passes correctly regardless of how many attempts `eventually/1` took,
and any earlier `result: :error` events (if the repair genuinely failed on an early attempt for
unrelated timing reasons) are simply harmless unmatched messages left in the mailbox.

- [ ] **Step 3: Run the test to verify it fails**

Run: `mix test test/riptide/stream/replica_healer_cluster_test.exs`
Expected: FAIL — the new assertions fail (no telemetry events fire yet); other assertions in the
same tests still pass.

- [ ] **Step 4: Implement the instrumentation**

Change:
```elixir
  defp maybe_repair({stream_id, nodes}) do
    uid = RaCluster.uid_for(stream_id)
    name = String.to_atom(uid)
    dead_nodes = Enum.reject(nodes, &RaCluster.member_alive?({name, &1}))

    case dead_nodes do
      [dead_node] -> repair(stream_id, uid, nodes, dead_node)
      _ -> :ok
    end
  end
```
to:
```elixir
  defp maybe_repair({stream_id, nodes}) do
    uid = RaCluster.uid_for(stream_id)
    name = String.to_atom(uid)
    dead_nodes = Enum.reject(nodes, &RaCluster.member_alive?({name, &1}))

    case dead_nodes do
      [dead_node] ->
        :telemetry.execute([:riptide, :replica_healer, :dead_replica_detected], %{}, %{})
        repair(stream_id, uid, nodes, dead_node)

      _ ->
        :ok
    end
  end
```

Change the `do_repair/6` clause's `:ok ->` and `{:error, reason} ->` branches from:
```elixir
      :ok ->
        new_nodes = Placement.replace_member(stream_id, dead_node, new_node)

        Phoenix.PubSub.broadcast(
          Riptide.PubSub,
          "stream_placement_changed",
          {:stream_placement_changed, stream_id, new_nodes}
        )

        Logger.info(
          "ReplicaHealer repaired #{stream_id}: replaced #{inspect(dead_node)} with #{inspect(new_node)}",
          stream_id: stream_id,
          dead_node: inspect(dead_node),
          new_node: inspect(new_node)
        )

      {:error, reason} ->
        Logger.warning(
          "ReplicaHealer failed to repair #{stream_id} (dead: #{inspect(dead_node)}): #{inspect(reason)}",
          stream_id: stream_id,
          dead_node: inspect(dead_node),
          reason: inspect(reason)
        )
    end
  end
```
to:
```elixir
      :ok ->
        new_nodes = Placement.replace_member(stream_id, dead_node, new_node)

        Phoenix.PubSub.broadcast(
          Riptide.PubSub,
          "stream_placement_changed",
          {:stream_placement_changed, stream_id, new_nodes}
        )

        Logger.info(
          "ReplicaHealer repaired #{stream_id}: replaced #{inspect(dead_node)} with #{inspect(new_node)}",
          stream_id: stream_id,
          dead_node: inspect(dead_node),
          new_node: inspect(new_node)
        )

        :telemetry.execute([:riptide, :replica_healer, :repair], %{}, %{result: :ok})

      {:error, reason} ->
        Logger.warning(
          "ReplicaHealer failed to repair #{stream_id} (dead: #{inspect(dead_node)}): #{inspect(reason)}",
          stream_id: stream_id,
          dead_node: inspect(dead_node),
          reason: inspect(reason)
        )

        :telemetry.execute([:riptide, :replica_healer, :repair], %{}, %{result: :error})
    end
  end
```

Also, in `repair/4`'s own `:error -> Logger.warning(...)` branch (the "could not discover
retention" case — a *different* kind of failure than `do_repair/6`'s), add the same telemetry call
so a retention-discovery failure is also counted as a failed repair:

Change:
```elixir
          :error ->
            Logger.warning(
              "ReplicaHealer could not discover #{stream_id}'s current retention from any " <>
                "survivor (#{inspect(survivor_nodes)}); skipping repair this tick",
              stream_id: stream_id,
              survivor_nodes: inspect(survivor_nodes)
            )
        end
    end
  end
```
to:
```elixir
          :error ->
            Logger.warning(
              "ReplicaHealer could not discover #{stream_id}'s current retention from any " <>
                "survivor (#{inspect(survivor_nodes)}); skipping repair this tick",
              stream_id: stream_id,
              survivor_nodes: inspect(survivor_nodes)
            )

            :telemetry.execute([:riptide, :replica_healer, :repair], %{}, %{result: :error})
        end
    end
  end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `mix test test/riptide/stream/replica_healer_cluster_test.exs`
Expected: PASS — 1 test, 0 failures.

- [ ] **Step 6: Run the full test suite**

Run: `mix test`
Expected: PASS — all tests green (this also re-confirms
`test/riptide/stream/replica_healer_leadership_gate_test.exs`, which exercises `maybe_repair/1`'s
call path but wasn't modified in this task, still passes unaffected).

- [ ] **Step 7: Commit**

```bash
git add lib/riptide/stream/replica_healer.ex test/riptide/stream/replica_healer_cluster_test.exs
git commit -m "Phase 5c: instrument ReplicaHealer repairs with telemetry counters"
```

---

### Task 6: Kubernetes manifests + README

**Files:**
- Modify: `k8s/service.yaml`
- Modify: `k8s/statefulset.yaml`
- Modify: `README.md`

**Interfaces:**
- Consumes: port 9090 from Task 2 (the manifests only reference the port number, no code
  dependency).

- [ ] **Step 1: Confirm current `k8s/service.yaml`**

Run: `cat k8s/service.yaml`
Expected (confirm this matches before editing):
```yaml
apiVersion: v1
kind: Service
metadata:
  name: riptide
  labels:
    app: riptide
spec:
  type: ClusterIP
  selector:
    app: riptide
  ports:
    - name: http
      port: 4000
      targetPort: 4000
```

- [ ] **Step 2: Add the metrics port to the existing Service**

Change:
```yaml
  ports:
    - name: http
      port: 4000
      targetPort: 4000
```
to:
```yaml
  ports:
    - name: http
      port: 4000
      targetPort: 4000
    - name: metrics
      port: 9090
      targetPort: 9090
```

This reuses the existing `riptide` Service (already `ClusterIP`, never referenced by
`k8s/ingress.yaml`) rather than creating a second Service object — port 9090 is exposed the same
way port 4000 already is: cluster-internal only, with no Ingress route pointing at it.

- [ ] **Step 3: Add the metrics containerPort to the StatefulSet**

Run: `grep -n -A 4 "containerPort: 4000" k8s/statefulset.yaml`
Expected (confirm this matches before editing):
```
          ports:
            - name: http
              containerPort: 4000
          env:
```

Change:
```yaml
          ports:
            - name: http
              containerPort: 4000
          env:
```
to:
```yaml
          ports:
            - name: http
              containerPort: 4000
            - name: metrics
              containerPort: 9090
          env:
```

- [ ] **Step 4: Validate both files' YAML syntax**

Run: `python3 -c "import yaml; list(yaml.safe_load_all(open('k8s/service.yaml'))); list(yaml.safe_load_all(open('k8s/statefulset.yaml'))); print('OK')"`
Expected: `OK`

- [ ] **Step 5: Confirm the current README "Running via Kubernetes" section's end**

Run: `grep -n "^## \|^### " README.md`
Expected: shows `## Running via Kubernetes`, `### TLS`, and `## Releasing` (or similar) — confirm
where the TLS subsection ends and the next top-level `##` heading begins, so the new content lands
inside "Running via Kubernetes" but after the TLS subsection, not inside TLS itself or after
"Releasing".

- [ ] **Step 6: Add a metrics note to README**

Insert a new `### Metrics` subsection immediately after the TLS subsection's final paragraph (the
"Not covered by these manifests..." paragraph) and before the next top-level `##` heading:

```markdown
### Metrics

Riptide exposes Prometheus metrics on port 9090 (`GET /metrics`) — a separate port from the main
application (4000), reachable only from inside the cluster; `k8s/ingress.yaml` never routes to it.
If you run a Prometheus that auto-discovers scrape targets via pod annotations, add these to
`k8s/statefulset.yaml`'s pod template:

```yaml
metadata:
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "9090"
```

Setting up Prometheus itself (and any Grafana dashboards/alerting on top of it) is your own
deployment's concern — these manifests only expose the metrics, they don't install a scraper.
```

- [ ] **Step 7: Commit**

```bash
git add k8s/service.yaml k8s/statefulset.yaml README.md
git commit -m "Phase 5c: expose metrics port in k8s manifests and README"
```

---

### Task 7: Full verification + `PROGRESS.md`

**Files:**
- Modify: `PROGRESS.md`

**Interfaces:**
- Consumes: nothing new — this task verifies Tasks 1-6 together and documents completion.

- [ ] **Step 1: Run the full test suite one more time**

Run: `mix test`
Expected: PASS — all tests green (confirms all 6 prior tasks together introduced no regression).

- [ ] **Step 2: Run `mix format` and `mix credo --strict`**

Run: `mix format --check-formatted`
Expected: no output, exit code 0. If it reports unformatted files, run `mix format` and re-check.

Run: `mix credo --strict`
Expected: `found no issues` (or only issues that already existed before this plan — compare against
a `git stash`-free baseline if any appear; this project's CI gates on this check, per
`lib/riptide/../CLAUDE.md`'s standing rule to never end a turn with failing CI).

- [ ] **Step 3: Confirm the metrics endpoint shows real domain data end-to-end**

With the application running (`mix phx.server` in one terminal, or via
`iex -S mix` and manually triggering a stream append), run:
`curl -s http://localhost:9090/metrics | grep riptide_`
Expected: at least the metric *names* appear (e.g. `riptide_stream_append_duration_bucket`,
`riptide_placement_lookup_duration_bucket`, `riptide_ra_placement_leader`) — data for the counters/
distributions may show zero counts if nothing has been exercised yet in this manual session, but
`riptide_ra_placement_leader` should show a real 0 or 1 value within 30 seconds of boot (the
`:telemetry_poller`'s first tick).

- [ ] **Step 4: Update `PROGRESS.md`**

Find the section:

```markdown
- **Phase 5b — Structured logging.** **Shipped 2026-08-27** — see
```
...through...
```markdown
- **Phase 5c — Metrics.** Not yet designed.

**Status**: Phases 5a-5b shipped 2026-08-27. Phase 5c not yet designed.
```

Replace the `Phase 5c` and `Status` lines with:

```markdown
- **Phase 5c — Metrics.** **Shipped 2026-08-27** — see
  `docs/superpowers/specs/2026-08-27-phase-5c-metrics-design.md`. A Prometheus scrape endpoint
  (`GET /metrics` on port 9090, `RiptideWeb.MetricsEndpoint` — a separate, ClusterIP-only port
  never routed through Phase 4d's Ingress) exposes both HTTP/WebSocket metrics (attached directly
  to Phoenix's own existing telemetry events, e.g. `[:phoenix, :router_dispatch, :stop]`'s `route`
  metadata — the literal router-DSL pattern string, not the resolved per-request path, to avoid
  unbounded cardinality) and new domain instrumentation added to `Riptide.Stream.StreamServer`
  (append/read latency, gap-signal rate), `Riptide.Placement` (lookup/assign latency and error
  counts), and `Riptide.Stream.ReplicaHealer` (repair outcomes, dead-replica detection), plus a
  `:telemetry_poller`-driven gauge for Ra placement-cluster leadership. No metric tags by
  `stream_id`/`tenant_id` — see the design spec's Cardinality section. This closes sub-project 5
  (Observability & operability) and completes Riptide's entire production-readiness roadmap.

**Status**: Phases 5a-5c shipped 2026-08-27. Sub-project 5 (Observability & operability) complete.
Production-readiness roadmap complete.
```

Also find the sub-projects summary table near the top of the file:

```markdown
| 5 | Observability & operability (metrics, logging, health probes) | **Decomposed into phases 5a-5c** — see below |
```

Replace it with:

```markdown
| 5 | Observability & operability (metrics, logging, health probes) | **Shipped** (phases 5a-5c) — see below |
```

- [ ] **Step 5: Bump the file's "Last updated" date**

Confirm the actual current date via `date -u +%Y-%m-%d` and update the `**Last updated:**` line at
the top of `PROGRESS.md` to that value.

- [ ] **Step 6: Commit**

```bash
git add PROGRESS.md
git commit -m "Phase 5c: mark metrics shipped, sub-project 5 and roadmap complete"
```
