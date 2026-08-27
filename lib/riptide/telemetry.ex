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
        tag_values: &phoenix_router_dispatch_tag_values/1,
        reporter_options: [buckets: [10, 25, 50, 100, 250, 500, 1000, 2500, 5000]]
      ),

      # WebSocket — Phoenix's own existing telemetry events, no new
      # instrumentation.
      distribution("phoenix.socket_connected.duration",
        event_name: [:phoenix, :socket_connected],
        measurement: :duration,
        unit: {:native, :millisecond},
        reporter_options: [buckets: [10, 25, 50, 100, 250, 500, 1000, 2500, 5000]]
      ),
      distribution("phoenix.channel_joined.duration",
        event_name: [:phoenix, :channel_joined],
        measurement: :duration,
        unit: {:native, :millisecond},
        reporter_options: [buckets: [10, 25, 50, 100, 250, 500, 1000, 2500, 5000]]
      ),

      # Stream — new :telemetry.span/3 calls added in Task 3
      # (Riptide.Stream.StreamServer).
      distribution("riptide.stream.append.duration",
        event_name: [:riptide, :stream, :append, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        reporter_options: [buckets: [10, 25, 50, 100, 250, 500, 1000, 2500, 5000]]
      ),
      distribution("riptide.stream.get_since.duration",
        event_name: [:riptide, :stream, :get_since, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        reporter_options: [buckets: [10, 25, 50, 100, 250, 500, 1000, 2500, 5000]]
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
        unit: {:native, :millisecond},
        reporter_options: [buckets: [10, 25, 50, 100, 250, 500, 1000, 2500, 5000]]
      ),
      counter("riptide.placement.lookup.errors",
        event_name: [:riptide, :placement, :lookup, :exception]
      ),
      distribution("riptide.placement.assign.duration",
        event_name: [:riptide, :placement, :assign, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        reporter_options: [buckets: [10, 25, 50, 100, 250, 500, 1000, 2500, 5000]]
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
