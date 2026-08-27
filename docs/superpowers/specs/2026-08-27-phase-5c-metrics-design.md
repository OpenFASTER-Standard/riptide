# Phase 5c — Metrics

## Context & motivation

Phase 5c is the third and final phase of sub-project 5 (Observability & operability), following
Phase 5a (health/readiness probes) and Phase 5b (structured logging), both shipped 2026-08-27. It
is also the last phase on Riptide's entire production-readiness roadmap.

Metrics are genuinely greenfield: `mix.lock` has no `telemetry_metrics`, `telemetry_poller`,
`prom_ex`, `prometheus`, `statsd`, or `live_dashboard` dependency, and there is exactly one
`:telemetry.attach` call anywhere in `lib/` — Phase 5b's own `Riptide.Telemetry.AccessLog`,
consuming Phoenix's built-in `[:phoenix, :endpoint, :stop]` event. Riptide emits zero
domain-specific telemetry events of its own.

Phoenix itself already emits several telemetry events for free (confirmed by grepping
`deps/phoenix/lib/` and `deps/plug/lib/`): `[:phoenix, :endpoint, :start/:stop]`,
`[:phoenix, :router_dispatch, :start/:stop/:exception]`, `[:phoenix, :socket_connected]`,
`[:phoenix, :channel_joined]`, `[:phoenix, :channel_handled_in]`, `[:phoenix, :error_rendered]`.
`:ra` (the Raft library every stream and the placement cluster are built on) emits none at all,
and neither does any of Riptide's own domain code — meaning the things that matter most
operationally for a Raft-backed event-streaming server (stream append latency/throughput, Ra
leader elections, replica-healer activity, placement-cluster health) currently have zero
visibility, and closing that gap requires adding genuinely new instrumentation, not just wiring up
a library.

## Scope

- `telemetry_metrics` + `telemetry_metrics_prometheus_core` (the lightweight combination — not the
  fuller, more batteries-included `PromEx` toolkit, matching this project's established pattern of
  minimal dependencies, e.g. Phase 5b's hand-rolled JSON formatter instead of a logging library).
- A second Plug-based listener, `RiptideWeb.MetricsEndpoint`, bound to port 9090, serving
  `GET /metrics` in Prometheus exposition format. This is a second listener in the same OTP
  application (an additional child in `Riptide.Application`'s supervision tree), not a separate
  deployment or process.
- `k8s/`'s example manifests gain a second, ClusterIP-only Service (or a second port on the
  existing `riptide` Service — see Architecture) for port 9090, with **no Ingress route** — the
  metrics endpoint is never reachable through Phase 4d's public Ingress/TLS path, only from inside
  the cluster (a Prometheus pod's own scrape).
- HTTP/WebSocket metrics attached directly to Phoenix's existing telemetry events — zero new
  `:telemetry.execute` calls needed for these.
- New `:telemetry.execute` calls added to 4 areas of Riptide's own domain code: stream
  append/read (`Riptide.Stream.StreamServer`), placement queries (`Riptide.Placement`), replica
  healing (`Riptide.Stream.ReplicaHealer`), and Ra placement-cluster leadership
  (`Riptide.RaCluster`), each detailed in Architecture below.
- All metrics avoid tagging by `stream_id` or `tenant_id` — see the Cardinality section, a binding
  constraint on every metric this phase adds.

## Out of scope

- **Grafana dashboards or Prometheus alerting rules.** An operator's own concern once metrics are
  exposed — the same boundary Phase 4d drew around not building the ingress controller itself.
- **BEAM VM metrics** (memory, scheduler utilization, GC, process/port counts).
  `:telemetry_poller`'s built-in `:vm.memory`/`:vm.total_run_queue_lengths` measurements would be a
  cheap, natural future addition, but they're generic-BEAM, not Riptide-specific, and adding them
  isn't necessary to close this phase's actual gap (domain visibility).
- **Per-tenant or per-stream metrics of any kind.** Ruled out entirely by the cardinality
  constraint below, not merely deferred.
- **Authorization-decision metrics** (allow/deny counts from `Riptide.Authz.evaluate/4`). No
  concrete operational need for this surfaced during brainstorming; can be added later the same
  way as any other domain event if one does.
- **A metrics-specific health/readiness check.** Phase 5a's `/health/ready` already covers
  placement-cluster reachability; this phase doesn't add a second, metrics-specific probe.

## Cardinality constraint (binding on every metric added in this phase)

Prometheus metrics must avoid unbounded label cardinality: each distinct combination of a metric
name and its tag values becomes its own stored time series. Unlike Phase 5b's `Logger` metadata
(where per-request `tenant_id`/`stream_id` context is exactly the point, and one log line's
metadata costs nothing extra), tagging a Prometheus metric by `stream_id` would create a separate
time series *per stream* — for a multi-tenant streaming server, that's potentially thousands of
series, a well-known way to degrade or crash a Prometheus server. No metric in this phase tags by
`stream_id` or `tenant_id`. Every tag used below is drawn from a small, fixed, known-in-advance set
(an HTTP method, a route pattern, a result atom like `:ok`/`:error`) — never from arbitrary
request-supplied data.

## Architecture

**Dependencies**: `{:telemetry_metrics, "~> 1.0"}`, `{:telemetry_poller, "~> 1.0"}`,
`{:telemetry_metrics_prometheus_core, "~> 1.0"}` added to `mix.exs`. `:telemetry` itself is already
present transitively (via Phoenix/Plug/libcluster).

**`Riptide.Telemetry`** (new module, a `Supervisor`) starts a
`{TelemetryMetricsPrometheus.Core, metrics: metrics()}` child and a `{:telemetry_poller, ...}`
child (for the one gauge metric — see below), and defines `metrics/0` returning the full list of
`Telemetry.Metrics` definitions. Started as a child of `Riptide.Application`'s supervision tree,
alongside (not replacing) Phase 5b's `Riptide.Telemetry.AccessLog.attach()` call — `:telemetry`
supports multiple independent handlers per event, so `AccessLog` (which logs) and this phase's
metrics handler (which counts/measures) both attach to `[:phoenix, :endpoint, :stop]`
independently, with no interaction or conflict.

**`RiptideWeb.MetricsEndpoint`** (new module) is a minimal `Plug.Router`-based (not a full
`Phoenix.Endpoint` — no need for the router/controller/socket machinery a second time) HTTP server
bound to port 9090, with a single route: `get "/metrics"` calling
`TelemetryMetricsPrometheus.Core.scrape/1` and returning the result as `text/plain`. Started as its
own child in `Riptide.Application`'s supervision tree via `Plug.Cowboy.child_spec/1` (the same
Cowboy adapter Phoenix itself already uses, so no new HTTP server dependency), bound explicitly to
port 9090 regardless of environment (no `config/prod.exs`-only gating — a self-hoster running a
single local instance for development still benefits from being able to curl its own metrics).

**Metric definitions** (`Riptide.Telemetry.metrics/0`):

HTTP/WS (attached to existing Phoenix events, zero new instrumentation):
- `phoenix.router_dispatch.duration` — distribution (ms), tags: `[:route, :method, :status]` (via
  `Telemetry.Metrics.distribution/2`, reading `route`/`conn.method`/`conn.status` from
  `[:phoenix, :router_dispatch, :stop]`'s metadata — `route` is the literal, compile-time
  router-DSL pattern string (e.g. `"/tenants/:tenant_id/resources/*path"`), a small fixed set;
  `conn.request_path` (the resolved, per-request path) is never used as a tag, since that would
  violate the Cardinality constraint below. This event only fires for requests that actually match
  a defined route; a request that matches no route simply never emits it, so it isn't counted).
- `phoenix.socket_connected.duration` — distribution (ms), from `[:phoenix, :socket_connected]`.
- `phoenix.channel_joined.duration` — distribution (ms), from `[:phoenix, :channel_joined]`.

Domain-specific (new `:telemetry.execute` calls):
- `riptide.stream.append.duration` — distribution (ms), no tags. New call in
  `Riptide.Stream.StreamServer.append/2` (`lib/riptide/stream/stream_server.ex:45`), wrapping the
  existing body with `:telemetry.span/3` (which handles start/stop/exception events and duration
  measurement automatically, rather than hand-rolling timing).
- `riptide.stream.get_since.duration` — distribution (ms), no tags; `riptide.stream.get_since.gap`
  — counter, no tags, incremented specifically on the `{:gap, oldest}` return branch. New calls in
  `Riptide.Stream.StreamServer.get_since/2` (`lib/riptide/stream/stream_server.ex:61`).
- `riptide.placement.lookup.duration` / `riptide.placement.assign.duration` — distributions (ms),
  tag: `[:result]` (`:ok`/`:error`, from whether the call raised — see Phase 4d/5a's own
  documentation of `Riptide.Placement.lookup/1`'s raise-on-total-failure behavior). New
  `:telemetry.span/3` wrapping in `Riptide.Placement.lookup/1` and `assign/2`
  (`lib/riptide/placement.ex:43,50`).
- `riptide.replica_healer.repairs` — counter, tag: `[:result]`; `riptide.replica_healer.dead_replicas_detected`
  — counter, no tags. New calls in `Riptide.Stream.ReplicaHealer`'s existing `repair/4`/`do_repair/6`
  private functions (`lib/riptide/stream/replica_healer.ex:72-115`) — placed alongside the
  Phase 5b `Logger` calls already there for the same outcomes, not replacing them.
- `riptide.ra.placement_leader` — last-value gauge (1 or 0), no tags. A new
  `:telemetry_poller` periodic measurement (interval matching `ReplicaHealer`'s own
  `@sweep_interval_ms`, 30 seconds) calling `Riptide.RaCluster.placement_leader?/0` and emitting
  `:telemetry.execute([:riptide, :ra, :placement_leader], %{value: if(leader?, do: 1, else: 0)})`
  — a gauge, not an event-driven counter, since leadership is standing state an operator wants to
  see as "currently true/false," not something with a meaningful "rate."

## Kubernetes manifests

`k8s/service.yaml` gains a second port entry (`metrics`, port 9090, ClusterIP — the existing
Service is already ClusterIP-scoped, so this reuses the same Service object rather than creating a
new one). `k8s/statefulset.yaml`'s container gains a second `containerPort: 9090` entry. Neither
`k8s/ingress.yaml` nor any Ingress-related manifest is touched — port 9090 is never routed through
the Ingress, matching the binding decision that metrics stay cluster-internal only. `README.md`'s
"Running via Kubernetes" section (added in Phase 4d) gains a short note on the metrics port and a
one-line example Prometheus scrape annotation
(`prometheus.io/scrape: "true"`, `prometheus.io/port: "9090"`) — actual Prometheus
installation/configuration remains the operator's own concern per Out of scope.

## Testing

- Domain instrumentation: for each new `:telemetry.execute`/`:telemetry.span` call site, a test
  using `:telemetry_test.attach_event_handlers/2` (the standard library helper for asserting a
  named process receives a given telemetry event) attaches a handler before invoking the
  instrumented function, then asserts the event fires with the expected event name and
  measurement/metadata shape — not by parsing Prometheus text output, which tests the wrong layer.
- One integration test making a real `GET http://localhost:9090/metrics` request (via `Req` or
  `:httpc` against the actually-running `RiptideWeb.MetricsEndpoint` child, started as part of the
  test app's own supervision tree) and asserting the response body contains at least one of the
  new metric names in valid Prometheus exposition format (a `metric_name{tags} value` line).
- No test asserts on exact histogram bucket boundaries or specific numeric values — these are
  inherently timing-dependent; tests assert a metric *exists and was recorded*, not its precise
  value.
