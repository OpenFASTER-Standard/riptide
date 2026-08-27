# Phase 5b (Structured Logging) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Riptide structured, correlatable production logging — JSON output in prod, a real per-request access log with actual fields (not two lines of unstructured text), and `tenant_id`/`subject` context automatically attached to every log line for a given request/connection across all 3 transports (LDP HTTP, SSE, WebSocket).

**Architecture:** A hand-rolled `Logger.Formatter` callback (`Riptide.Logger.JSONFormatter`, using the already-present `Jason` dependency) replaces Phoenix's default two-line unstructured request logging with one `:telemetry`-driven structured access-log entry per request (`Riptide.Telemetry.AccessLog`). `Logger.metadata/1` calls in the request-processing plugs/callbacks of all 3 transports attach `tenant_id`/`subject` once, which then flows automatically into every subsequent log line in that same process — no parameter-threading required. Applied only in `config/prod.exs`; `config/dev.exs`/`config/test.exs` keep today's human-readable plain-text formatter unchanged.

**Tech Stack:** Elixir `Logger`/`Logger.Formatter`, `:telemetry`, `Jason` (already a dependency), `Plug`, `Phoenix.Socket`/`Phoenix.Channel`.

**Spec:** `docs/superpowers/specs/2026-08-27-phase-5b-structured-logging-design.md`

## Global Constraints

- No new dependencies — `Jason` (already present) is the only JSON library used.
- The JSON formatter applies ONLY in `config/prod.exs`. `config/config.exs`'s shared dev/test `:default_formatter` config (`format: "$time $metadata[$level] $message\n"`, `metadata: [:request_id]`) is left completely unchanged.
- `config/prod.exs`'s `:logger, :default_formatter` uses `metadata: :all` (a documented `Logger.Formatter` value meaning "every metadata key present"), NOT a hand-enumerated list — confirmed necessary because an explicit list would need a new entry added by hand for every future `Logger` call anywhere in the app that attaches a new custom key.
- `Riptide.Logger.JSONFormatter.format/4` MUST have a `rescue` fallback (to an `inspect/1`-based plain-text line) — with `metadata: :all`, Elixir's own automatically-attached metadata (e.g. `:pid`, `:mfa`) can include values with no `Jason.Encoder` implementation, and `Jason.encode!/1` would otherwise raise and crash the logging pipeline.
- `Plug.RequestId` already exists in `lib/riptide_web/endpoint.ex:36` and already populates `:request_id` in `Logger.metadata` on every request (confirmed by reading `deps/plug/lib/plug/request_id.ex`) — no task in this plan touches it or adds it again.
- The access-log handler's `Logger.info` call, and the 4 converted internal `Logger` calls, MUST bake their key values into the message string itself (not metadata-only) — dev/test's metadata allowlist stays `[:request_id]` only, so metadata-only values would be invisible in a developer's own console output.
- `tenant_id`/`subject` enrichment stays metadata-only (no message-string duplication) — their value is for production log correlation/querying across a whole request, not for a single dev-console line.
- `RiptideWeb.Plugs.Authenticate`'s and `RiptideWeb.Realtime.Socket.connect/3`'s `subject` metadata is set only `if sub = claims["sub"]` (guarded on truthiness) — Phase 4b's `Riptide.Auth.TokenConfig` does not require a `sub` claim, so a validly-authenticated token can still have `claims["sub"] == nil`; an absent metadata key and an explicit `nil` are indistinguishable in output, so both the anonymous case and this edge case leave `subject` genuinely unset.
- A test that mutates the global `Logger` level (via `Logger.configure/1`) or global `Application` config MUST be `async: false` and MUST restore the original value in `on_exit` — matching the established `:ordinal_resolver` pattern from Phase 5a.
- `ExUnit.CaptureLog`'s own `:level` option does NOT raise the real global `Logger.level/0` if that's already more restrictive (confirmed via its own documentation) — `config/test.exs` sets the real global level to `:warning`, so any test capturing an `:info`-level call must first save+override the real level via `Logger.configure(level: :info)`, not rely on `capture_log`'s `:level` option alone.
- `ReplicationChannel.join/3` must be tested by calling it **directly** as a plain function from the test process, not via `Phoenix.ChannelTest.join/4`/`subscribe_and_join/4` — those helpers run the channel callback in a separate, GenServer-spawned process (confirmed by reading `deps/phoenix/lib/phoenix/test/channel_test.ex:423`'s own docstring), so `Logger.metadata` set inside `join/3` via those helpers is invisible to `Logger.metadata()` read back in the test's own process.
- The 3 `Logger` call sites in `lib/riptide/stream/replica_healer.ex` do not get new dedicated tests in this phase — their only reachable path is through the existing multi-node `:peer`-based cluster test files' own complex setup; the message text and control flow are unchanged (only metadata is added), so the full suite passing unchanged is the correctness evidence for these 3 sites specifically.

---

### Task 1: `Riptide.Logger.JSONFormatter`

**Files:**
- Create: `lib/riptide/logger/json_formatter.ex`
- Test: `test/riptide/logger/json_formatter_test.exs`

**Interfaces:**
- Consumes: `Jason` (existing dependency).
- Produces: `Riptide.Logger.JSONFormatter.format/4` — consumed by Task 2's `config/prod.exs` wiring (`format: {Riptide.Logger.JSONFormatter, :format}`).

- [ ] **Step 1: Write the failing tests**

Create `test/riptide/logger/json_formatter_test.exs`:

```elixir
defmodule Riptide.Logger.JSONFormatterTest do
  use ExUnit.Case, async: true

  alias Riptide.Logger.JSONFormatter

  @timestamp {{2026, 8, 27}, {12, 34, 56, 789}}

  test "produces valid JSON with timestamp, level, and message" do
    output = JSONFormatter.format(:info, "hello", @timestamp, [])
    decoded = Jason.decode!(IO.iodata_to_binary(output))

    assert decoded["level"] == "info"
    assert decoded["message"] == "hello"
    assert decoded["timestamp"] == "2026-08-27T12:34:56.789Z"
  end

  test "includes metadata keys in the output" do
    output =
      JSONFormatter.format(:info, "hello", @timestamp, request_id: "abc123", tenant_id: "acme")

    decoded = Jason.decode!(IO.iodata_to_binary(output))

    assert decoded["request_id"] == "abc123"
    assert decoded["tenant_id"] == "acme"
  end

  test "normalizes an iodata message to a string" do
    output = JSONFormatter.format(:warning, ["parts ", "of ", "a ", "message"], @timestamp, [])
    decoded = Jason.decode!(IO.iodata_to_binary(output))

    assert decoded["message"] == "parts of a message"
  end

  test "falls back to inspect-based plain text instead of crashing on a non-JSON-encodable metadata value" do
    output = JSONFormatter.format(:info, "hello", @timestamp, pid: self())

    # Must not raise, and must still mention the message text somewhere in the fallback output.
    assert IO.iodata_to_binary(output) =~ "hello"
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/riptide/logger/json_formatter_test.exs`
Expected: FAIL — `Riptide.Logger.JSONFormatter` doesn't exist yet (`UndefinedFunctionError` or a compile error).

- [ ] **Step 3: Write the implementation**

Create `lib/riptide/logger/json_formatter.ex`:

```elixir
defmodule Riptide.Logger.JSONFormatter do
  @moduledoc """
  Custom `Logger.Formatter` callback (`format/4`) producing one JSON object per
  line, for production log aggregation. Wired in via
  `config :logger, :default_formatter, format: {__MODULE__, :format}, metadata: :all`
  in `config/prod.exs` only — `config/dev.exs`/`config/test.exs` keep Elixir's
  built-in plain-text formatter, unchanged.

  `metadata: :all` (rather than an explicit key list) means Elixir's own
  automatically-attached metadata (e.g. `:pid`, `:mfa`) can reach this
  function too — values with no `Jason.Encoder` implementation would make
  `Jason.encode!/1` raise, so the `rescue` clause below is load-bearing, not
  just defensive insurance.
  """

  @spec format(Logger.level(), Logger.message(), Logger.Formatter.date_time_ms(), keyword()) ::
          IO.chardata()
  def format(level, message, timestamp, metadata) do
    %{timestamp: format_timestamp(timestamp), level: level, message: format_message(message)}
    |> Map.merge(Map.new(metadata))
    |> Jason.encode!()
    |> Kernel.<>("\n")
  rescue
    _ -> "#{inspect({level, format_message(message), timestamp, metadata})}\n"
  end

  defp format_timestamp({date, {h, mi, s, ms}}) do
    {:ok, naive} = NaiveDateTime.from_erl({date, {h, mi, s}}, {ms * 1000, 3})
    NaiveDateTime.to_iso8601(naive) <> "Z"
  end

  defp format_message(message) when is_binary(message), do: message
  defp format_message(message) when is_list(message), do: IO.chardata_to_string(message)
  defp format_message(message), do: to_string(message)
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/riptide/logger/json_formatter_test.exs`
Expected: PASS — 4 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/riptide/logger/json_formatter.ex test/riptide/logger/json_formatter_test.exs
git commit -m "Phase 5b: add Riptide.Logger.JSONFormatter"
```

---

### Task 2: Wire the formatter into `config/prod.exs`, disable Phoenix's default request logging

**Files:**
- Modify: `config/prod.exs`
- Modify: `lib/riptide_web/endpoint.ex:37`

**Interfaces:**
- Consumes: `Riptide.Logger.JSONFormatter.format/4` (Task 1).
- Produces: nothing new consumed by later tasks — Task 3's access-log handler doesn't depend on this task's config wiring to be *implemented* first, only to be *correct* once both land.

- [ ] **Step 1: Confirm the current `config/prod.exs` content**

Run: `cat config/prod.exs`
Expected (confirm this matches before editing):
```elixir
import Config

# Force using SSL in production. This also sets the "strict-security-transport" header,
# known as HSTS. If you have a health check endpoint, you may want to exclude it below.
# Note `:force_ssl` is required to be set at compile-time.
config :riptide, RiptideWeb.Endpoint,
  force_ssl: [
    rewrite_on: [:x_forwarded_proto],
    exclude: [
      paths: ["/health/live", "/health/ready"],
      hosts: ["localhost", "127.0.0.1"]
    ]
  ]

# Do not print debug messages in production
config :logger, level: :info

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
```

If it doesn't match, STOP and re-read the file rather than guessing at insertion points.

- [ ] **Step 2: Add the JSON formatter config**

Insert the following block between the `force_ssl` config and the `# Do not print debug messages` comment:

```elixir
# Structured JSON logging for production log aggregation. dev/test keep
# config/config.exs's plain-text formatter and its narrower [:request_id]
# metadata list unchanged — this override applies to :prod only.
#
# metadata: :all (not an explicit key list) — an explicit list would need a
# new entry added by hand every time any future Logger call anywhere in the
# app attaches a new custom key, silently dropping anything not kept in
# sync. This also means Elixir's own automatically-attached metadata (e.g.
# :pid, :mfa) reaches Riptide.Logger.JSONFormatter.format/4 too, which is
# exactly why that module has its own rescue fallback for non-JSON-encodable
# values.
config :logger, :default_formatter,
  format: {Riptide.Logger.JSONFormatter, :format},
  metadata: :all
```

The full file should now read:

```elixir
import Config

# Force using SSL in production. This also sets the "strict-security-transport" header,
# known as HSTS. If you have a health check endpoint, you may want to exclude it below.
# Note `:force_ssl` is required to be set at compile-time.
config :riptide, RiptideWeb.Endpoint,
  force_ssl: [
    rewrite_on: [:x_forwarded_proto],
    exclude: [
      paths: ["/health/live", "/health/ready"],
      hosts: ["localhost", "127.0.0.1"]
    ]
  ]

# Structured JSON logging for production log aggregation. dev/test keep
# config/config.exs's plain-text formatter and its narrower [:request_id]
# metadata list unchanged — this override applies to :prod only.
#
# metadata: :all (not an explicit key list) — an explicit list would need a
# new entry added by hand every time any future Logger call anywhere in the
# app attaches a new custom key, silently dropping anything not kept in
# sync. This also means Elixir's own automatically-attached metadata (e.g.
# :pid, :mfa) reaches Riptide.Logger.JSONFormatter.format/4 too, which is
# exactly why that module has its own rescue fallback for non-JSON-encodable
# values.
config :logger, :default_formatter,
  format: {Riptide.Logger.JSONFormatter, :format},
  metadata: :all

# Do not print debug messages in production
config :logger, level: :info

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
```

- [ ] **Step 3: Verify `config/prod.exs` loads and parses correctly**

Plain `mix compile` does NOT load `config/prod.exs` (`config/config.exs`'s trailing
`import_config "#{config_env()}.exs"` only pulls in the file matching the current `Mix.env()`,
which defaults to `:dev` — this exact gap was already caught and documented in Phase 5a's plan).

Run: `MIX_ENV=prod mix compile --force`
Expected: compiles with no errors (pre-existing `:formats` warnings, unrelated to this change, are fine).

Then run: `SECRET_KEY_BASE=$(openssl rand -base64 48) MIX_ENV=prod mix run --no-start -e 'IO.inspect(Application.get_env(:logger, :default_formatter))'`
Expected output: `[format: {Riptide.Logger.JSONFormatter, :format}, metadata: :all]` — this confirms
the config value itself resolves correctly for `:prod`, overriding `config/config.exs`'s dev-level
default. (Verifying the full live-formatting behavior end-to-end would require a real release boot,
which is out of scope here — same "don't over-verify beyond what's reasonable in this environment"
precedent as Phase 4d's TLS phase not provisioning a live certificate.)

Then restore the default dev build: `MIX_ENV=dev mix compile --force`

- [ ] **Step 4: Confirm the current `Plug.Telemetry` line in the endpoint**

Run: `grep -n "Plug.Telemetry" lib/riptide_web/endpoint.ex`
Expected: `37:  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]`

- [ ] **Step 5: Disable Phoenix's default request logging**

In `lib/riptide_web/endpoint.ex`, change:

```elixir
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]
```

to:

```elixir
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint], log: false
```

Do NOT touch the `plug Plug.RequestId` line immediately above it — that plug already exists and
already works (see Global Constraints).

- [ ] **Step 6: Run the full test suite**

Run: `mix test`
Expected: PASS — all tests green. (No test currently asserts on Phoenix's default two-line request
log text, so disabling it should cause zero failures on its own — Task 3 is what actually replaces
the lost access-log behavior.)

- [ ] **Step 7: Commit**

```bash
git add config/prod.exs lib/riptide_web/endpoint.ex
git commit -m "Phase 5b: wire JSON formatter into prod, disable Phoenix's default request logging"
```

---

### Task 3: `Riptide.Telemetry.AccessLog` — structured, single-line request logging

**Files:**
- Create: `lib/riptide/telemetry/access_log.ex`
- Modify: `lib/riptide/application.ex`
- Test: `test/riptide/telemetry/access_log_test.exs`
- Test: `test/riptide_web/access_log_test.exs`

**Interfaces:**
- Consumes: `[:phoenix, :endpoint, :stop]` telemetry event (emitted by `Plug.Telemetry`, already present in the endpoint).
- Produces: `Riptide.Telemetry.AccessLog.attach/0` and `Riptide.Telemetry.AccessLog.handle_event/4` — `attach/0` is called from `Riptide.Application.start/2`; no other task depends on these names.

- [ ] **Step 1: Write the failing unit test**

Create `test/riptide/telemetry/access_log_test.exs`:

```elixir
defmodule Riptide.Telemetry.AccessLogTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Riptide.Telemetry.AccessLog

  # config/test.exs sets the real global Logger level to :warning, which
  # would silently suppress this handler's Logger.info calls entirely.
  # ExUnit.CaptureLog's own :level option does NOT help (it only filters
  # within a capture and does not override a stricter real Logger.level/0),
  # so the real global level must be lowered for the duration of this test.
  setup do
    original_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: original_level) end)
    :ok
  end

  test "logs method, path, status, and duration_ms from a fake conn" do
    conn = %Plug.Conn{method: "GET", request_path: "/health/live", status: 200}
    # Built via a round-trip conversion (not a literal native-unit guess) so
    # the assertion below is correct regardless of this VM's native time
    # unit resolution.
    duration = System.convert_time_unit(3, :millisecond, :native)

    log =
      capture_log(fn ->
        AccessLog.handle_event(
          [:phoenix, :endpoint, :stop],
          %{duration: duration},
          %{conn: conn},
          :ok
        )
      end)

    assert log =~ "GET /health/live 200 (3ms)"
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/riptide/telemetry/access_log_test.exs`
Expected: FAIL — `Riptide.Telemetry.AccessLog` doesn't exist yet.

- [ ] **Step 3: Write the implementation**

Create `lib/riptide/telemetry/access_log.ex`:

```elixir
defmodule Riptide.Telemetry.AccessLog do
  @moduledoc """
  Structured, single-line request access logging — replaces Phoenix's
  default two-line unstructured request logging, disabled via
  `plug Plug.Telemetry, ..., log: false` in `RiptideWeb.Endpoint`. Attached
  once, from `Riptide.Application.start/2`, to `[:phoenix, :endpoint, :stop]`.

  The log message bakes method/path/status/duration_ms directly into its own
  text (not metadata-only) so dev/test's plain-text formatter — whose
  metadata allowlist deliberately stays `[:request_id]`, unchanged from
  before this phase — still shows a useful line at the console. The same
  values are ALSO attached as metadata, picked up by production's JSON
  formatter (`metadata: :all` in `config/prod.exs`).
  """
  require Logger

  @doc "Attaches this module's handler. Called once from Riptide.Application.start/2."
  @spec attach() :: :ok | {:error, :already_exists}
  def attach do
    :telemetry.attach(
      "riptide-access-log",
      [:phoenix, :endpoint, :stop],
      &__MODULE__.handle_event/4,
      :ok
    )
  end

  @doc false
  @spec handle_event([atom()], map(), map(), term()) :: :ok
  def handle_event([:phoenix, :endpoint, :stop], %{duration: duration}, %{conn: conn}, _config) do
    duration_ms = System.convert_time_unit(duration, :native, :millisecond)

    Logger.info(
      "#{conn.method} #{conn.request_path} #{conn.status} (#{duration_ms}ms)",
      method: conn.method,
      path: conn.request_path,
      status: conn.status,
      duration_ms: duration_ms
    )

    :ok
  end
end
```

- [ ] **Step 4: Run the unit test to verify it passes**

Run: `mix test test/riptide/telemetry/access_log_test.exs`
Expected: PASS — 1 test, 0 failures.

- [ ] **Step 5: Write the failing integration test**

`Riptide.Telemetry.AccessLog` exists (Step 3) but isn't attached to the running application yet —
so a real request at this point produces ZERO log lines (Task 2 already disabled Phoenix's own
default logging, and nothing has replaced it yet). This step captures that failing state before
Step 6 wires up the fix.

Create `test/riptide_web/access_log_test.exs`:

```elixir
defmodule RiptideWeb.AccessLogTest do
  use ExUnit.Case, async: false
  use Plug.Test
  import ExUnit.CaptureLog

  @opts RiptideWeb.Endpoint.init([])

  # Same real-global-level override as Riptide.Telemetry.AccessLogTest —
  # see that file's own comment for why ExUnit.CaptureLog's :level option
  # alone does not suffice here.
  setup do
    original_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: original_level) end)
    :ok
  end

  test "a request produces exactly one structured access-log line, not Phoenix's default two" do
    log =
      capture_log(fn ->
        :get
        |> conn("/health/live")
        |> RiptideWeb.Endpoint.call(@opts)
      end)

    lines = log |> String.trim() |> String.split("\n") |> Enum.reject(&(&1 == ""))

    assert length(lines) == 1
    assert log =~ "GET /health/live 200"
  end
end
```

- [ ] **Step 6: Run the integration test to verify it fails**

Run: `mix test test/riptide_web/access_log_test.exs`
Expected: FAIL — `length(lines) == 1` fails because `lines` is empty (`0 != 1`): the handler exists
but isn't attached anywhere yet, so the request produces no access-log output at all.

- [ ] **Step 7: Attach the handler at application boot**

In `lib/riptide/application.ex`, change:

```elixir
  @impl true
  def start(_type, _args) do
    # Every fleet node — not just the 3 placement ordinals — can be picked
    # as a replica for a brand-new stream's real multi-member Ra cluster
    # (Phase 3c-ii/3c-iii), and forming that cluster requires this node's
    # own local `:ra` system to already be running by the time a sibling's
    # `:ra.start_cluster/2` call reaches it over RPC. Doing this here,
    # synchronously, before `Cluster.Supervisor`/libcluster even starts
    # connecting to peers, closes that startup race at its root (see Phase
    # 3d-i HA-proof spike, finding 1) rather than relying only on each
    # entry point's own lazy, on-demand call to the same idempotent
    # function.
    Riptide.RaCluster.ensure_system_started()

    children =
```

to:

```elixir
  @impl true
  def start(_type, _args) do
    # Every fleet node — not just the 3 placement ordinals — can be picked
    # as a replica for a brand-new stream's real multi-member Ra cluster
    # (Phase 3c-ii/3c-iii), and forming that cluster requires this node's
    # own local `:ra` system to already be running by the time a sibling's
    # `:ra.start_cluster/2` call reaches it over RPC. Doing this here,
    # synchronously, before `Cluster.Supervisor`/libcluster even starts
    # connecting to peers, closes that startup race at its root (see Phase
    # 3d-i HA-proof spike, finding 1) rather than relying only on each
    # entry point's own lazy, on-demand call to the same idempotent
    # function.
    Riptide.RaCluster.ensure_system_started()

    # Attached before the supervision tree (and therefore RiptideWeb.Endpoint)
    # starts, so no request can possibly arrive before this handler exists
    # (Phase 5b).
    Riptide.Telemetry.AccessLog.attach()

    children =
```

- [ ] **Step 8: Run the integration test to verify it passes**

Run: `mix test test/riptide_web/access_log_test.exs`
Expected: PASS — 1 test, 0 failures.

- [ ] **Step 9: Run the full test suite**

Run: `mix test`
Expected: PASS — all tests green.

- [ ] **Step 10: Commit**

```bash
git add lib/riptide/telemetry/access_log.ex lib/riptide/application.ex test/riptide/telemetry/access_log_test.exs test/riptide_web/access_log_test.exs
git commit -m "Phase 5b: add structured single-line access logging, replacing Phoenix's default"
```

---

### Task 4: `tenant_id`/`subject` enrichment for LDP HTTP (`ResolveTenant`, `Authenticate`)

**Files:**
- Modify: `lib/riptide_web/plugs/resolve_tenant.ex`
- Modify: `lib/riptide_web/plugs/authenticate.ex`
- Test: `test/riptide_web/plugs/resolve_tenant_test.exs` (add to existing file)
- Test: `test/riptide_web/plugs/authenticate_test.exs` (add to existing file)

**Interfaces:**
- Consumes: nothing new.
- Produces: nothing new consumed by later tasks — SSE/WebSocket enrichment in Task 5 is independent code, just following the same pattern.

- [ ] **Step 1: Write the failing tests**

In `test/riptide_web/plugs/resolve_tenant_test.exs`, add this test inside the existing module (after
the existing `"assigns tenant_id on success, using the default PathSegment resolver"` test):

```elixir
  test "sets tenant_id in Logger metadata on success" do
    %{conn(:get, "/tenants/acme/resources/foo") | params: %{"tenant_id" => "acme"}}
    |> ResolveTenant.call(ResolveTenant.init([]))

    assert Logger.metadata()[:tenant_id] == "acme"
  end
```

In `test/riptide_web/plugs/authenticate_test.exs`, first extend the existing `StubVerifier` module
to also handle a token whose claims omit `sub`:

```elixir
  defmodule StubVerifier do
    @behaviour Riptide.Auth.Verifier

    @impl true
    def verify("valid-token"), do: {:ok, %{"sub" => "user-1"}}
    def verify("no-sub-token"), do: {:ok, %{"other" => "claim"}}
    def verify(_token), do: {:error, :invalid_token}
  end
```

Then add these 3 tests inside the existing module:

```elixir
  test "sets subject in Logger metadata when a valid token has a sub claim" do
    :get
    |> conn("/resources/foo")
    |> put_req_header("authorization", "Bearer valid-token")
    |> Authenticate.call(Authenticate.init([]))

    assert Logger.metadata()[:subject] == "user-1"
  end

  test "does not set subject in Logger metadata for an anonymous request" do
    :get
    |> conn("/resources/foo")
    |> Authenticate.call(Authenticate.init([]))

    refute Keyword.has_key?(Logger.metadata(), :subject)
  end

  test "does not set subject in Logger metadata when claims lack a sub" do
    :get
    |> conn("/resources/foo")
    |> put_req_header("authorization", "Bearer no-sub-token")
    |> Authenticate.call(Authenticate.init([]))

    refute Keyword.has_key?(Logger.metadata(), :subject)
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/riptide_web/plugs/resolve_tenant_test.exs test/riptide_web/plugs/authenticate_test.exs`
Expected: FAIL — the new assertions fail since neither plug sets `Logger.metadata` yet.

- [ ] **Step 3: Implement `ResolveTenant`'s enrichment**

In `lib/riptide_web/plugs/resolve_tenant.ex`, change:

```elixir
  import Plug.Conn

  @behaviour Plug
```

to:

```elixir
  import Plug.Conn
  require Logger

  @behaviour Plug
```

and change:

```elixir
    case resolver.resolve(conn) do
      {:ok, tenant_id} ->
        if Regex.match?(@safe_tenant_id, tenant_id) do
          assign(conn, :tenant_id, tenant_id)
        else
          reject(conn)
        end
```

to:

```elixir
    case resolver.resolve(conn) do
      {:ok, tenant_id} ->
        if Regex.match?(@safe_tenant_id, tenant_id) do
          Logger.metadata(tenant_id: tenant_id)
          assign(conn, :tenant_id, tenant_id)
        else
          reject(conn)
        end
```

- [ ] **Step 4: Implement `Authenticate`'s enrichment**

In `lib/riptide_web/plugs/authenticate.ex`, change:

```elixir
  import Plug.Conn

  @behaviour Plug
```

to:

```elixir
  import Plug.Conn
  require Logger

  @behaviour Plug
```

and change:

```elixir
        case verifier.verify(token) do
          {:ok, claims} ->
            assign(conn, :current_subject, claims)
```

to:

```elixir
        case verifier.verify(token) do
          {:ok, claims} ->
            if sub = claims["sub"] do
              Logger.metadata(subject: sub)
            end

            assign(conn, :current_subject, claims)
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix test test/riptide_web/plugs/resolve_tenant_test.exs test/riptide_web/plugs/authenticate_test.exs`
Expected: PASS — all tests in both files, 0 failures.

- [ ] **Step 6: Run the full test suite**

Run: `mix test`
Expected: PASS — all tests green.

- [ ] **Step 7: Commit**

```bash
git add lib/riptide_web/plugs/resolve_tenant.ex lib/riptide_web/plugs/authenticate.ex test/riptide_web/plugs/resolve_tenant_test.exs test/riptide_web/plugs/authenticate_test.exs
git commit -m "Phase 5b: attach tenant_id/subject to Logger metadata in ResolveTenant/Authenticate"
```

---

### Task 5: `tenant_id`/`subject` enrichment for SSE and WebSocket

**Files:**
- Modify: `lib/riptide_web/realtime/sse_controller.ex`
- Modify: `lib/riptide_web/realtime/socket.ex`
- Modify: `lib/riptide_web/realtime/replication_channel.ex`
- Test: `test/riptide_web/realtime/sse_controller_test.exs` (add to existing file)
- Test: `test/riptide_web/realtime/replication_channel_test.exs` (add to existing file)

**Interfaces:**
- Consumes: `RiptideWeb.LDP.ResourceController.parse_stream_id/1` (existing), `Riptide.Authz.evaluate/4` (existing).
- Produces: nothing new consumed by later tasks.

- [ ] **Step 1: Write the failing SSE test**

In `test/riptide_web/realtime/sse_controller_test.exs`, add this test inside the existing
`describe "authorization"` block:

```elixir
    test "sets tenant_id in Logger metadata even when authorization denies the request" do
      tenant_id = "sse-authz-test-" <> Uniq.UUID.uuid4()
      stream_id = ResourceController.stream_id_for(tenant_id, ["doc"])

      conn =
        :get
        |> conn("/streams/#{URI.encode_www_form(stream_id)}/subscribe")
        |> RiptideWeb.Endpoint.call(@opts)

      assert conn.status == 403
      assert Logger.metadata()[:tenant_id] == tenant_id
    end
```

- [ ] **Step 2: Write the failing ReplicationChannel test**

In `test/riptide_web/realtime/replication_channel_test.exs`, add this test inside the existing
module (needs `require Logger` — check the top of the file first; if it's not already required in
this test module, add `require Logger` right after the `alias` lines):

```elixir
  test "sets tenant_id in Logger metadata after a successful join" do
    stream_id = unique_stream_id()
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id) end)
    StreamSupervisor.ensure_ready(stream_id)

    {:ok, socket} = connect(Socket, %{})

    # Calls join/3 DIRECTLY (not via Phoenix.ChannelTest.join/4 or
    # subscribe_and_join/4) — those helpers run the channel callback in a
    # separate, GenServer-spawned process, so Logger.metadata set inside it
    # would be invisible here. join/3 is a plain exported function; nothing
    # about its body is channel-process-specific.
    {:ok, _reply, _socket} =
      ReplicationChannel.join("replication:" <> stream_id, %{"after" => 0}, socket)

    assert Logger.metadata()[:tenant_id] == "ws-test-tenant"
  end
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `mix test test/riptide_web/realtime/sse_controller_test.exs test/riptide_web/realtime/replication_channel_test.exs`
Expected: FAIL — the new assertions fail since `tenant_id` isn't set in `Logger.metadata` yet by
either module.

- [ ] **Step 4: Implement `SseController`'s enrichment**

In `lib/riptide_web/realtime/sse_controller.ex`, change:

```elixir
defmodule RiptideWeb.Realtime.SseController do
  use Phoenix.Controller

  alias Riptide.Event
  alias Riptide.RDF.TurtleCodec
  alias Riptide.Stream.{StreamServer, StreamSupervisor}
  alias RiptideWeb.LDP.ResourceController

  def subscribe(conn, %{"stream_id" => stream_id}) do
    with {:ok, tenant_id, path_segments} <- ResourceController.parse_stream_id(stream_id),
         :allow <-
           Riptide.Authz.evaluate(tenant_id, path_segments, conn.assigns.current_subject, :read) do
      do_subscribe(conn, stream_id)
    else
      _ -> send_resp(conn, 403, "")
    end
  end
```

to:

```elixir
defmodule RiptideWeb.Realtime.SseController do
  use Phoenix.Controller
  require Logger

  alias Riptide.Event
  alias Riptide.RDF.TurtleCodec
  alias Riptide.Stream.{StreamServer, StreamSupervisor}
  alias RiptideWeb.LDP.ResourceController

  def subscribe(conn, %{"stream_id" => stream_id}) do
    with {:ok, tenant_id, path_segments} <- ResourceController.parse_stream_id(stream_id) do
      Logger.metadata(tenant_id: tenant_id)

      case Riptide.Authz.evaluate(tenant_id, path_segments, conn.assigns.current_subject, :read) do
        :allow -> do_subscribe(conn, stream_id)
        _ -> send_resp(conn, 403, "")
      end
    else
      _ -> send_resp(conn, 403, "")
    end
  end
```

This restructures the original single `with` (which chained the parse and the authz check as two
clauses) into a `with` for just the parse step, followed by a `case` for the authz check — so
`Logger.metadata(tenant_id: ...)` runs between them, before authorization is evaluated. The external
behavior (403 on either a parse failure or an authz denial) is unchanged.

- [ ] **Step 5: Implement `Socket`'s enrichment**

In `lib/riptide_web/realtime/socket.ex`, change:

```elixir
  use Phoenix.Socket

  channel "replication:*", RiptideWeb.Realtime.ReplicationChannel

  @impl true
  def connect(_params, socket, connect_info) do
    case Map.get(connect_info, :auth_token) do
      nil ->
        {:ok, assign(socket, :current_subject, nil)}

      token ->
        verifier = Application.get_env(:riptide, :auth_verifier, Riptide.Auth.Verifier.OIDC)

        case verifier.verify(token) do
          {:ok, claims} -> {:ok, assign(socket, :current_subject, claims)}
          {:error, reason} -> {:error, reason}
        end
    end
  end
```

to:

```elixir
  use Phoenix.Socket
  require Logger

  channel "replication:*", RiptideWeb.Realtime.ReplicationChannel

  @impl true
  def connect(_params, socket, connect_info) do
    case Map.get(connect_info, :auth_token) do
      nil ->
        {:ok, assign(socket, :current_subject, nil)}

      token ->
        verifier = Application.get_env(:riptide, :auth_verifier, Riptide.Auth.Verifier.OIDC)

        case verifier.verify(token) do
          {:ok, claims} ->
            if sub = claims["sub"] do
              Logger.metadata(subject: sub)
            end

            {:ok, assign(socket, :current_subject, claims)}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end
```

- [ ] **Step 6: Implement `ReplicationChannel`'s enrichment**

In `lib/riptide_web/realtime/replication_channel.ex`, change:

```elixir
  use Phoenix.Channel

  alias Riptide.Event
  alias Riptide.RDF.TurtleCodec
  alias Riptide.Stream.{StreamServer, StreamSupervisor}
  alias RiptideWeb.LDP.ResourceController

  @impl true
  def join("replication:" <> stream_id, %{"after" => cursor}, socket) do
    with {:ok, tenant_id, path_segments} <- ResourceController.parse_stream_id(stream_id),
         :allow <-
           Riptide.Authz.evaluate(tenant_id, path_segments, socket.assigns.current_subject, :read) do
      do_join(stream_id, cursor, socket)
    else
      _ -> {:error, %{"reason" => "unauthorized"}}
    end
  end
```

to:

```elixir
  use Phoenix.Channel
  require Logger

  alias Riptide.Event
  alias Riptide.RDF.TurtleCodec
  alias Riptide.Stream.{StreamServer, StreamSupervisor}
  alias RiptideWeb.LDP.ResourceController

  @impl true
  def join("replication:" <> stream_id, %{"after" => cursor}, socket) do
    with {:ok, tenant_id, path_segments} <- ResourceController.parse_stream_id(stream_id) do
      Logger.metadata(tenant_id: tenant_id)

      case Riptide.Authz.evaluate(tenant_id, path_segments, socket.assigns.current_subject, :read) do
        :allow -> do_join(stream_id, cursor, socket)
        _ -> {:error, %{"reason" => "unauthorized"}}
      end
    else
      _ -> {:error, %{"reason" => "unauthorized"}}
    end
  end
```

Same restructuring rationale as `SseController.subscribe/2` above — external behavior unchanged.

- [ ] **Step 7: Run the tests to verify they pass**

Run: `mix test test/riptide_web/realtime/sse_controller_test.exs test/riptide_web/realtime/replication_channel_test.exs`
Expected: PASS — all tests in both files, 0 failures.

- [ ] **Step 8: Run the full test suite**

Run: `mix test`
Expected: PASS — all tests green.

- [ ] **Step 9: Commit**

```bash
git add lib/riptide_web/realtime/sse_controller.ex lib/riptide_web/realtime/socket.ex lib/riptide_web/realtime/replication_channel.ex test/riptide_web/realtime/sse_controller_test.exs test/riptide_web/realtime/replication_channel_test.exs
git commit -m "Phase 5b: attach tenant_id/subject to Logger metadata for SSE and WebSocket"
```

---

### Task 6: Convert the 4 existing internal `Logger` calls to structured metadata

**Files:**
- Modify: `lib/riptide/stream/replica_healer.ex`
- Modify: `lib/riptide/stream/placement.ex`
- Test: `test/riptide/stream/placement_test.exs` (add to existing file — confirm this is the right
  test file for `Riptide.Stream.Placement` by running `grep -n "defmodule" test/riptide/stream/placement_test.exs`
  first; if it tests a different module, search for the correct existing test file for
  `Riptide.Stream.Placement` under `test/riptide/stream/` before adding to it)

**Interfaces:**
- Consumes: nothing new.
- Produces: nothing new consumed by later tasks.

- [ ] **Step 1: Confirm current `replica_healer.ex` Logger call sites**

Run: `grep -n "Logger\." lib/riptide/stream/replica_healer.ex`
Expected:
```
85:            Logger.warning(
106:        Logger.info(
111:        Logger.warning(
```

- [ ] **Step 2: Convert the 3 `replica_healer.ex` calls**

Change:

```elixir
          :error ->
            Logger.warning(
              "ReplicaHealer could not discover #{stream_id}'s current retention from any " <>
                "survivor (#{inspect(survivor_nodes)}); skipping repair this tick"
            )
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
```

Change:

```elixir
        Logger.info(
          "ReplicaHealer repaired #{stream_id}: replaced #{inspect(dead_node)} with #{inspect(new_node)}"
        )
```

to:

```elixir
        Logger.info(
          "ReplicaHealer repaired #{stream_id}: replaced #{inspect(dead_node)} with #{inspect(new_node)}",
          stream_id: stream_id,
          dead_node: inspect(dead_node),
          new_node: inspect(new_node)
        )
```

Change:

```elixir
      {:error, reason} ->
        Logger.warning(
          "ReplicaHealer failed to repair #{stream_id} (dead: #{inspect(dead_node)}): #{inspect(reason)}"
        )
```

to:

```elixir
      {:error, reason} ->
        Logger.warning(
          "ReplicaHealer failed to repair #{stream_id} (dead: #{inspect(dead_node)}): #{inspect(reason)}",
          stream_id: stream_id,
          dead_node: inspect(dead_node),
          reason: inspect(reason)
        )
```

- [ ] **Step 3: Write the failing test for `lib/riptide/stream/placement.ex`**

Run: `grep -n "defmodule" test/riptide/stream/placement_test.exs` first to confirm this file tests
`Riptide.Stream.Placement` (not a different module) — if it doesn't, find the correct existing test
file for this module under `test/riptide/stream/` (e.g. via `grep -rln "Riptide.Stream.Placement"
test/riptide/stream/`) and add the test there instead.

Add this test to whichever file actually tests `Riptide.Stream.Placement`. It asserts against
`Logger.metadata()` directly (not the formatted log text) — the message string already interpolates
`stream_id`/`new_nodes` today, before this task's change, so a text-matching assertion wouldn't
actually distinguish "old behavior" from "new behavior." Checking `Logger.metadata()` is what
genuinely exercises the new code:

```elixir
  test "attaches stream_id and new_nodes as Logger metadata when a broadcast value isn't a list" do
    Riptide.Stream.Placement.handle_info(
      {:stream_placement_changed, "some-stream", "not-a-list"},
      %{}
    )

    assert Logger.metadata()[:stream_id] == "some-stream"
    assert Logger.metadata()[:new_nodes] == inspect("not-a-list")
  end
```

- [ ] **Step 4: Run the new test to verify it fails**

Run: `mix test test/riptide/stream/placement_test.exs` (or whichever file Step 3 identified)
Expected: FAIL — `Logger.metadata()[:stream_id]` is `nil` since `handle_info/2` doesn't set any
metadata yet.

- [ ] **Step 5: Convert the `lib/riptide/stream/placement.ex` call**

Change:

```elixir
  def handle_info({:stream_placement_changed, stream_id, new_nodes}, state) do
    Logger.warning(
      "Riptide.Stream.Placement got a non-list stream_placement_changed broadcast for " <>
        "#{inspect(stream_id)} (#{inspect(new_nodes)}); skipping cache update"
    )

    {:noreply, state}
  end
```

to:

```elixir
  def handle_info({:stream_placement_changed, stream_id, new_nodes}, state) do
    Logger.warning(
      "Riptide.Stream.Placement got a non-list stream_placement_changed broadcast for " <>
        "#{inspect(stream_id)} (#{inspect(new_nodes)}); skipping cache update",
      stream_id: stream_id,
      new_nodes: inspect(new_nodes)
    )

    {:noreply, state}
  end
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `mix test test/riptide/stream/placement_test.exs` (or whichever file Step 3 identified)
Expected: PASS.

- [ ] **Step 7: Run the full test suite**

Run: `mix test`
Expected: PASS — all tests green, including the existing multi-node `replica_healer_cluster_test.exs`/
`replica_healer_retention_test.exs`/`replica_healer_leadership_gate_test.exs` files (unaffected —
their assertions check return values/PubSub broadcasts, not log message text, per the Global
Constraints note that no new tests are added for the 3 `replica_healer.ex` call sites specifically).

- [ ] **Step 8: Commit**

```bash
git add lib/riptide/stream/replica_healer.ex lib/riptide/stream/placement.ex test/riptide/stream/placement_test.exs
git commit -m "Phase 5b: attach structured metadata to the 4 existing internal Logger calls"
```

(Adjust the `git add` path in the command above if Step 3 identified a different test file.)

---

### Task 7: Full verification + `PROGRESS.md`

**Files:**
- Modify: `PROGRESS.md`

**Interfaces:**
- Consumes: nothing new — this task verifies Tasks 1-6 together and documents completion.

- [ ] **Step 1: Run the full test suite one more time**

Run: `mix test`
Expected: PASS — all tests green (confirms all 6 prior tasks together introduced no regression).

- [ ] **Step 2: Re-verify the prod config end to end**

Run: `MIX_ENV=prod mix compile --force`
Expected: compiles cleanly.

Then: `SECRET_KEY_BASE=$(openssl rand -base64 48) MIX_ENV=prod mix run --no-start -e 'IO.inspect(Application.get_env(:logger, :default_formatter))'`
Expected: `[format: {Riptide.Logger.JSONFormatter, :format}, metadata: :all]`

Then restore: `MIX_ENV=dev mix compile --force`

- [ ] **Step 3: Confirm no stray references to the old, unstructured logging pattern remain**

Run: `grep -rn "Logger\.\(info\|warning\)(\"" lib/ | grep -v "method}.*path}.*status}\|ReplicaHealer\|Riptide.Stream.Placement got"`
Expected: no matches other than what Task 6 already converted (the grep excludes those specific,
now-expected message prefixes) — if this finds an unexpected match, it means a `Logger` call
somewhere was missed; investigate before proceeding.

- [ ] **Step 4: Update `PROGRESS.md`**

Find the section:

```markdown
- **Phase 5a — Health & readiness probes.** **Shipped 2026-08-27** — see
  `docs/superpowers/specs/2026-08-27-phase-5a-health-probes-design.md`. The single, always-`200`
  `/health` route (which checked nothing) is replaced by `/health/live` (unconditional `200`, used
  for the StatefulSet's `livenessProbe`) and `/health/ready` (a real check — a cheap
  `Riptide.Placement.lookup/1` call against the shared placement Ra cluster, since every
  LDP/SSE/WebSocket request needs that cluster reachable to resolve stream placement; used for the
  `readinessProbe`). A node cut off from placement now stops receiving traffic instead of silently
  reporting healthy. No supervision-tree changes; the old route was removed outright with no alias.
- **Phase 5b — Structured logging.** Not yet designed.
- **Phase 5c — Metrics.** Not yet designed.

**Status**: Phase 5a shipped 2026-08-27. Phases 5b/5c not yet designed.
```

Replace the `Phase 5b` and `Status` lines with:

```markdown
- **Phase 5b — Structured logging.** **Shipped 2026-08-27** — see
  `docs/superpowers/specs/2026-08-27-phase-5b-structured-logging-design.md`. Production logging is
  now JSON (`Riptide.Logger.JSONFormatter`, `config/prod.exs`-only, `metadata: :all` rather than a
  hand-enumerated key list). Phoenix's default two-line unstructured request logging is replaced
  with one structured line per request (`Riptide.Telemetry.AccessLog`, a `:telemetry` handler on
  `[:phoenix, :endpoint, :stop]`). `tenant_id`/`subject` are attached to `Logger.metadata` once per
  request/connection across all 3 transports (`ResolveTenant`/`Authenticate` for LDP HTTP,
  `SseController.subscribe/2` for SSE, `Socket.connect/3`/`ReplicationChannel.join/3` for
  WebSocket) and then flow automatically into every subsequent log line in that process. `subject`
  is set only when a token's claims actually include a `sub` (Phase 4b's `TokenConfig` doesn't
  require one). dev/test keep today's plain-text formatter and narrower metadata list unchanged.
- **Phase 5c — Metrics.** Not yet designed.

**Status**: Phases 5a-5b shipped 2026-08-27. Phase 5c not yet designed.
```

- [ ] **Step 5: Commit**

```bash
git add PROGRESS.md
git commit -m "Phase 5b: mark structured logging shipped"
```
