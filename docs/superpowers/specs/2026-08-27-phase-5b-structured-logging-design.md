# Phase 5b — Structured Logging

## Context & motivation

Phase 5b is the second phase of sub-project 5 (Observability & operability), following Phase 5a
(health/readiness probes, shipped 2026-08-27). Today's logging is unstructured and disconnected
from Riptide's own domain concepts:

- `config/config.exs` uses Phoenix's default plain-text formatter
  (`"$time $metadata[$level] $message\n"`, `metadata: [:request_id]`).
- Only 4 `Logger` call sites exist in `lib/` (`replica_healer.ex` ×3, `placement.ex` ×1), all plain
  interpolated strings — values like `stream_id`/`dead_node` are baked into the message text, never
  attached as real `Logger` metadata.
- Zero explicit `Logger` calls exist anywhere in `lib/riptide_web/`. Phoenix's default request
  logging is nonetheless active — `Phoenix.Logger.install/0` is called automatically by the
  `:phoenix` OTP application itself (confirmed by reading `deps/phoenix/lib/phoenix.ex:26`), not by
  anything Riptide's own code does. But that default logging (confirmed by reading
  `deps/phoenix/lib/phoenix/logger.ex:240-263`) doesn't pass method/status/duration as `Logger`
  metadata at all — it bakes them into two separate plain-text messages ("`GET /path`" and
  "`Sent 200 in 5ms`"). JSON-wrapping that output as-is would still be unqueryable by status or
  duration.
- `config/config.exs`'s formatter already lists `metadata: [:request_id]`, but `Plug.RequestId` is
  never actually added to the endpoint — every request today has no correlation ID at all; that
  metadata key is always empty.

## Scope

- A hand-rolled JSON `Logger` formatter (`Jason` is already a dependency; no new dependency added),
  applied only in `config/prod.exs` — dev/test keep today's human-readable plain-text formatter.
- `Plug.RequestId` added to `RiptideWeb.Endpoint`, fixing the currently-dead `:request_id` metadata
  key.
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
- `config/prod.exs`'s `:logger, :default_formatter` config's `metadata:` list expands from
  `[:request_id]` to `[:request_id, :tenant_id, :subject]` so the formatter actually receives these
  keys — `Logger.metadata/1` calls that set a key not in this allowlist are silently dropped by
  Elixir's own `Logger` before formatting ever sees them.

**`RiptideWeb.Endpoint`** gains `plug Plug.RequestId` (placed before `Plug.Telemetry`, matching
`Plug.RequestId`'s own documented placement recommendation, so the ID is available to the access-log
handler below) and changes `plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]` to
`plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint], log: false` — the `log: false` option is
`Plug.Telemetry`'s own documented mechanism for suppressing `Phoenix.Logger`'s default two-line
text output per the moduledoc read in `deps/phoenix/lib/phoenix/logger.ex`, without needing to
touch Phoenix's own code.

**A new access-log `:telemetry` handler** (`Riptide.Telemetry.AccessLog`, attached once from
`Riptide.Application.start/2` via `:telemetry.attach/4` on `[:phoenix, :endpoint, :stop]`) reads
`conn.method`, `conn.request_path`, `conn.status`, and the event's `duration` measurement
(native time units, converted to milliseconds via `System.convert_time_unit/3`), then calls
`Logger.info("request completed", method: ..., path: ..., status: ..., duration_ms: ...)`. Since
`Logger.metadata/1` is process-scoped and this handler always runs in the same process that handled
the request (telemetry handlers execute synchronously in the emitting process for
`:telemetry.execute/3`, confirmed by `:telemetry`'s own documented execution model), the
already-set `request_id`/`tenant_id`/`subject` metadata is automatically included with zero extra
plumbing.

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

**Existing internal `Logger` calls** in `lib/riptide/stream/replica_healer.ex` and
`lib/riptide/placement.ex` keep their current human-readable messages but move the interpolated
values into a real metadata keyword list on each call (e.g.
`Logger.warning("ReplicaHealer failed to repair stream", stream_id: stream_id, dead_node: dead_node, reason: inspect(reason))`),
consistent with everything above.

## Testing

- `Riptide.Logger.JSONFormatter.format/4`: unit tests verifying the output is valid JSON (round-trips
  through `Jason.decode!/1`), contains the expected `timestamp`/`level`/`message` keys, includes
  arbitrary metadata keys passed to it, and correctly stringifies both binary and iodata messages.
- `Plug.RequestId` + the new access-log handler: an integration test using
  `ExUnit.CaptureLog.with_log/1` around a real request, asserting the captured output contains
  exactly one "request completed" line (not Phoenix's old two-line output) and that it mentions the
  right method/status/a numeric duration — via substring/regex assertions against the captured text,
  not by switching `config/test.exs` to the JSON formatter (which stays plain-text intentionally, so
  this test exercises the handler's logging call directly rather than the prod-only formatter).
- `ResolveTenant`/`Authenticate`/`SseController`/`Socket`/`ReplicationChannel`: for each, a test
  asserting `Logger.metadata()` contains the expected key/value after the relevant plug or
  connect/join callback runs, using `Logger.metadata/1`'s own getter (`Logger.metadata/0`) rather
  than parsing formatted log output — this tests the actual mechanism (metadata being set) directly
  rather than indirectly through string-matching a log line.
- The 4 converted internal `Logger` calls: existing tests covering `replica_healer.ex`/
  `placement.ex` behavior are unaffected (the message text and control flow don't change, only the
  metadata attached) — no new tests required for these beyond confirming (via `ExUnit.CaptureLog`
  where a relevant existing test already exercises the log call) that the expected metadata keys
  are present.
