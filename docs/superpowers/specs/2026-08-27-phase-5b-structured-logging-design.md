# Phase 5b — Structured Logging

## Context & motivation

Phase 5b is the second phase of sub-project 5 (Observability & operability), following Phase 5a
(health/readiness probes, shipped 2026-08-27). Today's logging is unstructured and disconnected
from Riptide's own domain concepts:

- `config/config.exs` uses Phoenix's default plain-text formatter
  (`"$time $metadata[$level] $message\n"`, `metadata: [:request_id]`).
- Only 4 `Logger` call sites exist in `lib/` (`lib/riptide/stream/replica_healer.ex` ×3,
  `lib/riptide/stream/placement.ex` ×1), all plain interpolated strings — values like
  `stream_id`/`dead_node` are baked into the message text, never attached as real `Logger` metadata.
- Zero explicit `Logger` calls exist anywhere in `lib/riptide_web/`. Phoenix's default request
  logging is nonetheless active — `Phoenix.Logger.install/0` is called automatically by the
  `:phoenix` OTP application itself (confirmed by reading `deps/phoenix/lib/phoenix.ex:26`), not by
  anything Riptide's own code does. But that default logging (confirmed by reading
  `deps/phoenix/lib/phoenix/logger.ex:240-263`) doesn't pass method/status/duration as `Logger`
  metadata at all — it bakes them into two separate plain-text messages ("`GET /path`" and
  "`Sent 200 in 5ms`"). JSON-wrapping that output as-is would still be unqueryable by status or
  duration.
- **Correction, caught during plan-writing:** an earlier draft of this spec claimed
  `Plug.RequestId` was never added to the endpoint and that `:request_id` was always empty. That
  was wrong — `lib/riptide_web/endpoint.ex:36` already has `plug Plug.RequestId` (present since the
  very first commit of that file, 2026-08-22), and `Plug.RequestId`'s own source
  (`deps/plug/lib/plug/request_id.ex`) confirms it already calls
  `Logger.metadata([{:request_id, request_id}])` on every request. Request correlation already
  works today; this was a research error (an unverified claim), not a real gap. No task in this
  phase adds `Plug.RequestId` — it's already exactly where it needs to be, ahead of
  `Plug.Telemetry`.

## Scope

- A hand-rolled JSON `Logger` formatter (`Jason` is already a dependency; no new dependency added),
  applied only in `config/prod.exs` — dev/test keep today's human-readable plain-text formatter.
- Phoenix's default two-line, unstructured request logging disabled
  (`plug Plug.Telemetry, ..., log: false`), replaced with one `:telemetry` handler on
  `[:phoenix, :endpoint, :stop]` emitting a single structured log entry per request with real
  fields: `method`, `path`, `status`, `duration_ms`.
- `tenant_id` and `subject` context enrichment via `Logger.metadata/1`, wired into all 3 request
  transports (not just the LDP HTTP path) so every log line for a given request/connection
  automatically carries them:
  - **LDP HTTP**: `RiptideWeb.Plugs.ResolveTenant` sets `tenant_id`; `RiptideWeb.Plugs.Authenticate`
    sets `subject` (when present) — both already run once per request in the same process the
    access-log handler and any controller logging execute in.
  - **SSE**: `RiptideWeb.Plugs.Authenticate` already runs on this route (sets `subject`
    automatically, same process for the whole long-lived connection), but `ResolveTenant` does not
    (tenant is derived later from the stream_id) — `RiptideWeb.Realtime.SseController.subscribe/2`
    sets `tenant_id` explicitly right after `ResourceController.parse_stream_id/1` resolves it.
  - **WebSocket**: runs through neither plug — `subject` is set in
    `RiptideWeb.Realtime.Socket.connect/3` right after token verification (or `nil` for anonymous);
    `tenant_id` is set in `RiptideWeb.Realtime.ReplicationChannel.join/3` right after
    `parse_stream_id/1` resolves it, since one socket can join multiple topics/tenants over its
    lifetime and each `join/3` runs in that channel's own process (nothing carries over from
    `connect/3`'s process automatically).
- The existing 4 internal `Logger` calls (`replica_healer.ex`, `placement.ex`) converted to real
  metadata fields (`stream_id`, `dead_node`, `new_node`, etc.) alongside a still-readable message.

## Out of scope

- Any external log-shipping/aggregation setup (Fluentd, Vector, a specific cloud logging backend)
  — this phase produces structured JSON on stdout; what an operator does with that stream is
  already the deployment's own concern (same boundary Phase 5a drew around ingress/cert-manager
  being the operator's own installed infrastructure).
- A dedicated JSON-logging library (`logger_json` or similar) — a ~30-line hand-rolled formatter
  using the already-present `Jason` dependency covers this phase's actual needs without adding a
  new dependency.
- Metrics/telemetry dashboards — Phase 5c's job, not this phase's.
- Log level tuning beyond what already exists (`config/prod.exs`'s `:info`, `config/test.exs`'s
  `:warning`) — no new log levels or per-module level overrides are introduced.
- Redacting specific claim fields from `subject` — `subject` is set to the JWT's `sub` claim
  specifically (a string identifier), not the full claims map, which already avoids logging
  arbitrary token contents; no further PII scrubbing is in scope.

## Architecture

**`Riptide.Logger.JSONFormatter`** (new module) implements the `format/4` callback
(`level, message, timestamp, metadata`), used only in `config/prod.exs`:
- Converts the timestamp Logger actually passes in (an Erlang `{date, {h, mi, s, ms}}` tuple) to
  ISO8601 via `NaiveDateTime.from_erl/2` + `NaiveDateTime.to_iso8601/1` — using the real event
  timestamp rather than `DateTime.utc_now()` at format time, so a log line's timestamp stays
  correct even if formatting is briefly delayed under backpressure.
- Normalizes `message` (which Logger allows to be a string, `iodata`, or a struct implementing
  `String.Chars`) to a plain string via `to_string/1`.
- Builds a flat map (`timestamp`, `level`, `message`, plus every metadata key present) and
  `Jason.encode!/1`'s it, followed by `"\n"`.
- `config/prod.exs`'s `:logger, :default_formatter` config sets `metadata: :all` (a documented
  `Logger.Formatter` value — confirmed at
  `/usr/local/lib/elixir/lib/logger/lib/logger/formatter.ex:122,213` — meaning "pass every metadata
  key present," not an enumerated list). An explicit list was considered and rejected: it would
  need a new entry added by hand every time any future `Logger` call anywhere in the app attaches a
  new custom key, silently dropping anything not kept in sync — the opposite of what structured
  logging is for. `config/config.exs`'s dev/test list stays the narrower, explicit `[:request_id]`,
  unchanged — dev/test intentionally keeps today's minimal, deliberate console output.
- **This makes the `rescue` clause above load-bearing, not just defensive insurance.** With
  `metadata: :all`, Elixir's own automatically-attached metadata (e.g. `:pid`, `:mfa` — a
  `{module, function, arity}` tuple, present on log events routed through `:logger`'s standard
  translators) flows through too, and neither a raw PID nor a bare tuple has a `Jason.Encoder`
  implementation — `Jason.encode!/1` would raise for such a value. The formatter's `rescue` falls
  back to an `inspect/1`-based plain-text line in that case, so a JSON-unsafe metadata value
  degrades a single log line's format rather than crashing the logging pipeline outright.

**`RiptideWeb.Endpoint`** changes `plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]` to
`plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint], log: false` — the `log: false` option is
`Plug.Telemetry`'s own documented mechanism for suppressing `Phoenix.Logger`'s default two-line
text output per the moduledoc read in `deps/phoenix/lib/phoenix/logger.ex`, without needing to
touch Phoenix's own code. `Plug.RequestId` (line 36, already present ahead of `Plug.Telemetry`) is
untouched — see the Context correction above.

**Wiring the custom formatter** uses `Logger.Formatter`'s documented `{module, function}` tuple
form (confirmed via `/usr/local/lib/elixir/lib/logger/lib/logger/formatter.ex`'s own moduledoc):
`config :logger, :default_formatter, format: {Riptide.Logger.JSONFormatter, :format}, metadata: [...]`
— not a bare module reference. This form still applies `Logger.Formatter`'s own `metadata:`
allowlist filtering *before* calling the custom function, which is why the metadata keys must be
listed explicitly (see below) for `Logger.metadata/1`-set keys to ever reach `format/4` at all.

**A new access-log `:telemetry` handler** (`Riptide.Telemetry.AccessLog`, attached once from
`Riptide.Application.start/2` via `:telemetry.attach/4` on `[:phoenix, :endpoint, :stop]`) reads
`conn.method`, `conn.request_path`, `conn.status`, and the event's `duration` measurement (native
time units, converted to milliseconds via `System.convert_time_unit/3`), then calls
`Logger.info("#{method} #{path} #{status} (#{duration_ms}ms)", method: ..., path: ..., status: ..., duration_ms: ...)`.
Since `Logger.metadata/1` is process-scoped and this handler always runs in the same process that
handled the request (telemetry handlers execute synchronously in the emitting process for
`:telemetry.execute/3`, confirmed by `:telemetry`'s own documented execution model), the
already-set `request_id`/`tenant_id`/`subject` metadata is automatically included with zero extra
plumbing.

**Why the access-log message still bakes in `method`/`path`/`status`/`duration_ms` even though prod
uses `metadata: :all`:** `config/config.exs`'s shared dev/test metadata list stays the narrow,
explicit `[:request_id]`, unchanged — `metadata: :all` is a prod-only override. Under dev/test's
plain-text formatter, an unlisted metadata key is still silently dropped from the `$metadata`
placeholder, so `method`/`path`/`status`/`duration_ms` would otherwise be invisible in a
developer's own `mix phx.server` console. Baking them into the message string itself (which
`$message` always prints, regardless of any metadata allowlist) keeps local dev output at least as
useful as Phoenix's old two-line default. The same reasoning applies to the 4 existing internal
`Logger` calls below: their interpolated values move into real metadata (for prod's structured
`:all` output) but ALSO stay in the message text (for dev/test console readability) — unlike
`tenant_id`/`subject`, which stay metadata-only, since their value is specifically for production
log correlation/querying across a whole request, not for a human reading one line at a dev console.

**`RiptideWeb.Plugs.ResolveTenant`** adds one line after the existing `assign(conn, :tenant_id,
tenant_id)`: `Logger.metadata(tenant_id: tenant_id)`.

**`RiptideWeb.Plugs.Authenticate`** adds `Logger.metadata(subject: sub)` in the `{:ok, claims} ->`
branch, but only `if sub = claims["sub"]` — Phase 4b's `Riptide.Auth.TokenConfig` only requires
`exp`/`iss`/`aud` to be present, not `sub`, so a validly-authenticated token can still have
`claims["sub"] == nil`. Guarding on truthiness means both the anonymous branch and this edge case
leave `subject` genuinely absent from metadata rather than present-but-`nil` — an absent key and an
explicit `nil` are indistinguishable in the JSON output anyway, so consistently omitting it avoids
a `"subject": null` field cluttering every such request's log line for no informational gain.

**`RiptideWeb.Realtime.SseController.subscribe/2`** adds `Logger.metadata(tenant_id: tenant_id)`
right after the `with` clause's `{:ok, tenant_id, path_segments} <- ...` match succeeds, before
authorization is checked — so even a 403-denied SSE attempt's log line (if one is ever added later)
would carry the right tenant context; `subject` is already covered by the `:auth` pipeline's
`Authenticate` plug running earlier in the same request.

**`RiptideWeb.Realtime.Socket.connect/3`** adds the same guarded `Logger.metadata(subject: sub)`
(only `if sub = claims["sub"]`) in its `{:ok, claims} -> ...` branch, mirroring `Authenticate`'s
plug-level handling and the same nil-vs-absent reasoning above.

**`RiptideWeb.Realtime.ReplicationChannel.join/3`** adds `Logger.metadata(tenant_id: tenant_id)`
right after `parse_stream_id/1` resolves it, mirroring the SSE controller's placement.

**Existing internal `Logger` calls** in `lib/riptide/stream/replica_healer.ex` (3 call sites, module
`Riptide.Stream.ReplicaHealer`) and `lib/riptide/stream/placement.ex` (1 call site, module
`Riptide.Stream.Placement` — corrected from an earlier draft's wrong path/module name,
`lib/riptide/placement.ex`/`Riptide.Placement`, a different, unrelated module) keep their current
human-readable, value-interpolated messages (so dev/test console output is unchanged) but ALSO
attach the same values as a real metadata keyword list on each call, e.g.
`Logger.warning("ReplicaHealer failed to repair #{stream_id} (dead: #{inspect(dead_node)}): #{inspect(reason)}", stream_id: stream_id, dead_node: inspect(dead_node), reason: inspect(reason))`
— consistent with the access-log handler's own "message keeps the human string, metadata carries
the same values separately" approach above.

## Testing

- `Riptide.Logger.JSONFormatter.format/4`: unit tests verifying the output is valid JSON (round-trips
  through `Jason.decode!/1`), contains the expected `timestamp`/`level`/`message` keys, includes
  arbitrary metadata keys passed to it, and correctly stringifies both binary and iodata messages.
- The new access-log handler: an integration test using `ExUnit.CaptureLog.capture_log/1` around a
  real request, asserting the captured output contains exactly one line (not Phoenix's old two-line
  output) mentioning the right method/status/a numeric duration — via substring assertions against
  the captured text, not by switching `config/test.exs` to the JSON formatter (which stays
  plain-text intentionally, so this test exercises the handler's logging call directly rather than
  the prod-only formatter). `config/test.exs` sets the global `Logger` level to `:warning`, which
  would silently suppress this handler's `Logger.info` calls entirely —
  `ExUnit.CaptureLog`'s own `:level` option does NOT help here (confirmed via its own
  documentation: it only filters within a capture and explicitly does not override the real
  `Logger.level/0` if that's already more restrictive), so the test must save `Logger.level()`,
  call `Logger.configure(level: :info)` before capturing, and restore the original value in
  `on_exit` — the same global-mutation-with-restore pattern already established for
  `:ordinal_resolver` (Phase 5a), including `async: false` for the same reason.
- `ResolveTenant`/`Authenticate`/`SseController`/`Socket`/`ReplicationChannel`: for each, a test
  asserting `Logger.metadata()` contains the expected key/value after the relevant plug or
  connect/join callback runs, using `Logger.metadata/1`'s own getter (`Logger.metadata/0`) rather
  than parsing formatted log output — this tests the actual mechanism (metadata being set) directly
  rather than indirectly through string-matching a log line.
  **`ReplicationChannel.join/3` needs a specific test-construction caveat**, confirmed by reading
  `deps/phoenix/lib/phoenix/test/channel_test.ex:423`'s own docstring: "the given channel is joined
  in a **separate process** which is linked to the test process." A test using the normal
  `Phoenix.ChannelTest.join/4`/`subscribe_and_join/4` helpers would set `Logger.metadata` inside
  that separate spawned process, invisible to `Logger.metadata()` read back in the test's own
  process. The metadata test must instead call `ReplicationChannel.join/3` **directly** (it's a
  plain, exported function — nothing about its body is channel-process-specific) from the test
  process itself, bypassing the channel-spawning helper for this one assertion. (`Socket.connect/3`
  does not have this problem: `Phoenix.ChannelTest.connect/3`'s own `__connect__/4`, confirmed by
  reading the same file's lines 326-347, calls `handler.connect/1` synchronously via a plain `with`
  in the calling process — no separate process involved.)
- The 4 converted internal `Logger` calls: `lib/riptide/stream/placement.ex`'s single call site is
  directly, cheaply testable — `Riptide.Stream.Placement.handle_info/2`'s non-list-broadcast clause
  is a plain exported function, callable directly with a crafted message
  (`{:stream_placement_changed, "some-id", "not-a-list"}`) without needing the module's own running
  GenServer state; wrap the call in `ExUnit.CaptureLog.capture_log/1` (no `Logger.configure`
  override needed here — `Logger.warning` is already above `config/test.exs`'s `:warning`
  threshold) and assert the captured text mentions both interpolated values. The 3 call sites in
  `lib/riptide/stream/replica_healer.ex` are reachable only through `repair/4`'s private,
  multi-branch call chain (retention discovery, real `RaCluster.replace_member/5` calls), whose
  setup is already owned by the existing multi-node, `:peer`-based cluster test files
  (`replica_healer_cluster_test.exs`, `replica_healer_retention_test.exs`,
  `replica_healer_leadership_gate_test.exs`) — retrofitting `CaptureLog` assertions into those is
  out of scope for this phase given that setup complexity, and unnecessary for correctness: the
  message text and control flow are unchanged, only metadata is added, so the full suite passing
  unchanged is sufficient evidence these 3 call sites didn't regress.
