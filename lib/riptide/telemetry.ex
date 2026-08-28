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

      # A raised/exited controller action is a SEPARATE event from :stop
      # (Phoenix never emits both for the same request) — Riptide's own
      # placement layer is documented as deliberately raise-on-total-failure
      # (see Riptide.Placement's moduledoc), so a full placement-cluster
      # outage would otherwise be completely invisible in Prometheus (only
      # the readiness probe would hint at it), with request-level failure
      # volume/rate dark. `route`/`method` are the same small, fixed-set
      # tags :stop already uses — `status` isn't meaningful here since no
      # response was ever produced.
      counter("riptide.http.exceptions",
        event_name: [:phoenix, :router_dispatch, :exception],
        tags: [:route, :method],
        tag_values: &phoenix_router_dispatch_exception_tag_values/1
      ),

      # Total HTTP request volume, including requests that never matched a
      # route at all (:router_dispatch never fires for those — see this
      # module's own moduledoc) — [:phoenix, :endpoint, :stop] fires for
      # every request regardless of route match (it's the same event Phase
      # 5b's AccessLog already consumes). Tagged only by :status (a small,
      # fixed set) — not :route, since an unmatched request has none.
      counter("phoenix.endpoint.requests",
        event_name: [:phoenix, :endpoint, :stop],
        tags: [:status],
        tag_values: &phoenix_endpoint_stop_tag_values/1
      ),

      # WebSocket — Phoenix's own existing telemetry events, no new
      # instrumentation. Tagged by :result (:ok/:error — Phoenix already
      # attaches this to both events for free) so an auth-failure or
      # authorization-denial spike on this transport is distinguishable
      # from ordinary latency, the same way the HTTP metric above
      # distinguishes by :status.
      distribution("phoenix.socket_connected.duration",
        event_name: [:phoenix, :socket_connected],
        measurement: :duration,
        unit: {:native, :millisecond},
        tags: [:result],
        tag_values: &result_tag_value/1,
        reporter_options: [buckets: [10, 25, 50, 100, 250, 500, 1000, 2500, 5000]]
      ),
      distribution("phoenix.channel_joined.duration",
        event_name: [:phoenix, :channel_joined],
        measurement: :duration,
        unit: {:native, :millisecond},
        tags: [:result],
        tag_values: &result_tag_value/1,
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

      # Falling back past one placement-cluster member to the next —
      # previously silent (rescued with no log/metric), so a persistently
      # unreachable (but not yet totally-down) member had no visibility
      # beyond a subtle latency increase in the aggregate duration
      # distributions above.
      counter("riptide.placement.member_fallback",
        event_name: [:riptide, :placement, :member_fallback]
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

      # A stream's own Ra cluster exhausting its bounded formation retries —
      # previously silent; surfaces as a bare 503 to the caller with nothing
      # in Riptide's own logs/metrics explaining why.
      counter("riptide.stream.formation_failures",
        event_name: [:riptide, :stream, :formation_failure]
      ),

      # A committed event that failed to decode (e.g. a future wire version
      # from a rolling upgrade) — see Riptide.Stream.RaMachine's own comment
      # on why this is dropped rather than crashing the replica.
      counter("riptide.stream.poison_commands",
        event_name: [:riptide, :stream, :poison_command]
      ),

      # A tenant hit its per-tenant live-stream quota — see
      # Riptide.Stream.Placement's own comment on the resource-exhaustion
      # this bounds.
      counter("riptide.stream.quota_exceeded",
        event_name: [:riptide, :stream, :quota_exceeded]
      ),

      # Authorization decisions — :effect/:mode are both small, fixed sets
      # (2 values each), safe to tag. Without this, a systemic authz failure
      # (e.g. the policy store starts returning empty for an unrelated
      # reason, so evaluate/4's own default-deny applies to everything) is
      # invisible on any dashboard.
      counter("riptide.authz.decisions",
        event_name: [:riptide, :authz, :decision],
        tags: [:effect, :mode]
      ),

      # The placement cluster's own boot-time cluster-formation retry loop
      # failing — previously silent; an operator saw only "pod NotReady"
      # with no explanation in Riptide's own logs/metrics.
      counter("riptide.ra.placement_cluster_formation_attempts",
        event_name: [:riptide, :ra, :placement_cluster_formation_attempts],
        tags: [:result]
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

  defp phoenix_router_dispatch_exception_tag_values(%{route: route, conn: conn}) do
    %{route: route, method: conn.method}
  end

  defp phoenix_endpoint_stop_tag_values(%{conn: conn}) do
    %{status: conn.status}
  end

  defp result_tag_value(%{result: result}) do
    %{result: result}
  end
end
