# Phase 4a: Multi-Tenancy Data Model Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introduce tenant-scoped resource addressing so two tenants requesting what looks like the same resource path get genuinely different, fully isolated underlying `:ra` clusters — no authentication or enforcement yet, just the namespacing seam every later phase in this sub-project builds on.

**Architecture:** A pluggable `Riptide.Tenancy.Resolver` behaviour (path-segment and subdomain implementations), selected via application config — the same config-driven swap pattern `RaCluster.default_ordinal_resolver/1` already uses. A new `RiptideWeb.Plugs.ResolveTenant` plug runs in a new router pipeline ahead of the LDP resource routes (now under `/tenants/:tenant_id/resources/*path`), assigning `conn.assigns.tenant_id`. `ResourceController.stream_id_for/2` incorporates `tenant_id` into every stream_id it builds; since `RaCluster.uid_for/1` already hashes the full stream_id opaquely, this namespaces every stream's underlying `:ra` cluster by tenant with zero changes below the web layer. SSE and the WebSocket replication channel need no changes — they already take a fully-qualified, client-supplied `stream_id` directly, never constructing one from a path server-side.

**Tech Stack:** Elixir/Phoenix, Plug, ExUnit.

**Spec:** `docs/superpowers/specs/2026-08-26-phase-4a-multi-tenancy-data-model-design.md`

## Global Constraints

- No authentication or authorization/enforcement in this phase — a caller who knows or guesses a `tenant_id` can still address that tenant's resources; nothing checks whether they should be allowed to. This is a deliberately incremental, not-yet-secure intermediate state.
- No tenant registry or lifecycle — `tenant_id` is any resolvable string; nothing validates a tenant "exists."
- Both the path-segment and subdomain resolvers must be fully implemented (not one now, one deferred) — the resolver is selected by configuration, not hardcoded to one strategy.
- `RiptideWeb.Realtime.SseController` and `RiptideWeb.Realtime.ReplicationChannel` need **no code or route changes** in this phase (see spec §5's correction) — they already take an opaque, fully-qualified `stream_id` directly from the client.

---

### Task 1: `Riptide.Tenancy.Resolver` behaviour + `PathSegment` implementation

**Files:**
- Create: `lib/riptide/tenancy/resolver.ex`
- Create: `lib/riptide/tenancy/resolver/path_segment.ex`
- Test: `test/riptide/tenancy/resolver/path_segment_test.exs`

**Interfaces:**
- Consumes: nothing new — pure Plug.Conn inspection.
- Produces: the `Riptide.Tenancy.Resolver` behaviour (`@callback resolve(Plug.Conn.t()) :: {:ok, String.t()} | {:error, term()}`) and `Riptide.Tenancy.Resolver.PathSegment.resolve/1`. Consumed by Task 3's plug and Task 4's router/config wiring.

- [ ] **Step 1: Write the failing test**

Create `test/riptide/tenancy/resolver/path_segment_test.exs`:

```elixir
defmodule Riptide.Tenancy.Resolver.PathSegmentTest do
  use ExUnit.Case, async: true
  use Plug.Test

  alias Riptide.Tenancy.Resolver.PathSegment

  test "resolves tenant_id from a conn whose route already bound a :tenant_id param" do
    conn = %{conn(:get, "/tenants/acme/resources/foo") | params: %{"tenant_id" => "acme"}}

    assert PathSegment.resolve(conn) == {:ok, "acme"}
  end

  test "returns an error when no tenant_id param is present" do
    conn = conn(:get, "/resources/foo")

    assert {:error, _reason} = PathSegment.resolve(conn)
  end

  test "returns an error when tenant_id is present but empty" do
    conn = %{conn(:get, "/tenants//resources/foo") | params: %{"tenant_id" => ""}}

    assert {:error, _reason} = PathSegment.resolve(conn)
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/riptide/tenancy/resolver/path_segment_test.exs --trace`
Expected: FAIL — `Riptide.Tenancy.Resolver.PathSegment` doesn't exist yet.

- [ ] **Step 3: Implement the behaviour and the resolver**

Create `lib/riptide/tenancy/resolver.ex`:

```elixir
defmodule Riptide.Tenancy.Resolver do
  @moduledoc """
  Behaviour for extracting a tenant_id from an incoming request. Selected via
  `Application.get_env(:riptide, :tenancy_resolver, Riptide.Tenancy.Resolver.PathSegment)`
  — the same config-driven swap `Riptide.RaCluster.default_ordinal_resolver/1`
  already uses (Phase 3c-i) for picking a resolution strategy per deployment.
  """

  @callback resolve(Plug.Conn.t()) :: {:ok, String.t()} | {:error, term()}
end
```

Create `lib/riptide/tenancy/resolver/path_segment.ex`:

```elixir
defmodule Riptide.Tenancy.Resolver.PathSegment do
  @moduledoc """
  Extracts tenant_id from a `:tenant_id` path parameter — i.e. a router scope
  shaped `/tenants/:tenant_id/...`. Reads `conn.params["tenant_id"]` rather
  than parsing `conn.path_info` directly: Phoenix binds a matched route's path
  params before running that route's `pipe_through` pipeline, so by the time
  any plug in the pipeline runs, `conn.params` already has `tenant_id` set for
  any route under such a scope.
  """
  @behaviour Riptide.Tenancy.Resolver

  @impl true
  def resolve(%Plug.Conn{params: %{"tenant_id" => tenant_id}}) when tenant_id != "" do
    {:ok, tenant_id}
  end

  def resolve(%Plug.Conn{}) do
    {:error, :no_tenant_segment}
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/riptide/tenancy/resolver/path_segment_test.exs --trace`
Expected: PASS, all 3 tests.

- [ ] **Step 5: Commit**

```bash
git add lib/riptide/tenancy/resolver.ex lib/riptide/tenancy/resolver/path_segment.ex test/riptide/tenancy/resolver/path_segment_test.exs
git commit -m "Add Riptide.Tenancy.Resolver behaviour + PathSegment implementation"
```

---

### Task 2: `Riptide.Tenancy.Resolver.Subdomain` implementation

**Files:**
- Create: `lib/riptide/tenancy/resolver/subdomain.ex`
- Test: `test/riptide/tenancy/resolver/subdomain_test.exs`

**Interfaces:**
- Consumes: `Riptide.Tenancy.Resolver` behaviour (Task 1).
- Produces: `Riptide.Tenancy.Resolver.Subdomain.resolve/1`. Consumed by Task 4's config wiring (as an alternative to `PathSegment`, demonstrated via a config override in its own test).

- [ ] **Step 1: Write the failing test**

Create `test/riptide/tenancy/resolver/subdomain_test.exs`:

```elixir
defmodule Riptide.Tenancy.Resolver.SubdomainTest do
  use ExUnit.Case, async: true
  use Plug.Test

  alias Riptide.Tenancy.Resolver.Subdomain

  test "resolves tenant_id from the leading subdomain label" do
    conn = %{conn(:get, "/resources/foo") | host: "acme.riptide.example"}

    assert Subdomain.resolve(conn) == {:ok, "acme"}
  end

  test "returns an error when the host has no tenant subdomain (bare base domain)" do
    conn = %{conn(:get, "/resources/foo") | host: "riptide.example"}

    assert {:error, _reason} = Subdomain.resolve(conn)
  end

  test "returns an error when the host is a bare single label" do
    conn = %{conn(:get, "/resources/foo") | host: "localhost"}

    assert {:error, _reason} = Subdomain.resolve(conn)
  end

  test "resolves correctly even with a multi-label base domain" do
    conn = %{conn(:get, "/resources/foo") | host: "acme.riptide.example.com"}

    assert Subdomain.resolve(conn) == {:ok, "acme"}
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/riptide/tenancy/resolver/subdomain_test.exs --trace`
Expected: FAIL — `Riptide.Tenancy.Resolver.Subdomain` doesn't exist yet.

- [ ] **Step 3: Implement the resolver**

Create `lib/riptide/tenancy/resolver/subdomain.ex`:

```elixir
defmodule Riptide.Tenancy.Resolver.Subdomain do
  @moduledoc """
  Extracts tenant_id from `conn.host`'s leading subdomain label, e.g.
  `"acme.riptide.example"` -> `"acme"`. Requires at least 3 total labels (a
  tenant subdomain plus a base domain of at least 2 labels) so a bare base
  domain like `"riptide.example"` — with no tenant subdomain at all — isn't
  misread as tenant_id `"riptide"`.
  """
  @behaviour Riptide.Tenancy.Resolver

  @impl true
  def resolve(%Plug.Conn{host: host}) do
    case String.split(host, ".") do
      [tenant_id | rest] when tenant_id != "" and length(rest) >= 2 ->
        {:ok, tenant_id}

      _ ->
        {:error, :no_tenant_subdomain}
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/riptide/tenancy/resolver/subdomain_test.exs --trace`
Expected: PASS, all 4 tests.

- [ ] **Step 5: Commit**

```bash
git add lib/riptide/tenancy/resolver/subdomain.ex test/riptide/tenancy/resolver/subdomain_test.exs
git commit -m "Add Riptide.Tenancy.Resolver.Subdomain implementation"
```

---

### Task 3: `RiptideWeb.Plugs.ResolveTenant`

**Files:**
- Create: `lib/riptide_web/plugs/resolve_tenant.ex`
- Test: `test/riptide_web/plugs/resolve_tenant_test.exs`

**Interfaces:**
- Consumes: `Riptide.Tenancy.Resolver` implementations (Tasks 1-2), `Application.get_env(:riptide, :tenancy_resolver, Riptide.Tenancy.Resolver.PathSegment)`.
- Produces: `RiptideWeb.Plugs.ResolveTenant` (a standard `Plug` — `init/1` + `call/2`), assigning `conn.assigns.tenant_id` on success or halting with `400` on failure. Consumed by Task 4's router wiring.

- [ ] **Step 1: Write the failing tests**

Create `test/riptide_web/plugs/resolve_tenant_test.exs`:

```elixir
defmodule RiptideWeb.Plugs.ResolveTenantTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias RiptideWeb.Plugs.ResolveTenant

  setup do
    original = Application.get_env(:riptide, :tenancy_resolver)
    on_exit(fn -> Application.put_env(:riptide, :tenancy_resolver, original) end)
    :ok
  end

  test "assigns tenant_id on success, using the default PathSegment resolver" do
    conn =
      %{conn(:get, "/tenants/acme/resources/foo") | params: %{"tenant_id" => "acme"}}
      |> ResolveTenant.call(ResolveTenant.init([]))

    assert conn.assigns.tenant_id == "acme"
    refute conn.halted
  end

  test "halts with 400 when no tenant_id can be resolved" do
    conn =
      :get
      |> conn("/resources/foo")
      |> ResolveTenant.call(ResolveTenant.init([]))

    assert conn.halted
    assert conn.status == 400
  end

  test "uses whichever resolver is configured, not always PathSegment" do
    Application.put_env(:riptide, :tenancy_resolver, Riptide.Tenancy.Resolver.Subdomain)

    conn =
      %{conn(:get, "/resources/foo") | host: "acme.riptide.example"}
      |> ResolveTenant.call(ResolveTenant.init([]))

    assert conn.assigns.tenant_id == "acme"
    refute conn.halted
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/riptide_web/plugs/resolve_tenant_test.exs --trace`
Expected: FAIL — `RiptideWeb.Plugs.ResolveTenant` doesn't exist yet.

- [ ] **Step 3: Implement the plug**

Create `lib/riptide_web/plugs/resolve_tenant.ex`:

```elixir
defmodule RiptideWeb.Plugs.ResolveTenant do
  @moduledoc """
  Resolves `conn.assigns.tenant_id` via the configured
  `Riptide.Tenancy.Resolver` implementation
  (`Application.get_env(:riptide, :tenancy_resolver)`, defaulting to
  `Riptide.Tenancy.Resolver.PathSegment`) — mirrors
  `Riptide.RaCluster.default_ordinal_resolver/1`'s config-driven resolver
  swap (Phase 3c-i). Halts with `400` if no tenant_id can be resolved; no
  resource logic should ever run without a resolved tenant.
  """
  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    resolver =
      Application.get_env(:riptide, :tenancy_resolver, Riptide.Tenancy.Resolver.PathSegment)

    case resolver.resolve(conn) do
      {:ok, tenant_id} ->
        assign(conn, :tenant_id, tenant_id)

      {:error, _reason} ->
        conn
        |> send_resp(400, "")
        |> halt()
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/riptide_web/plugs/resolve_tenant_test.exs --trace`
Expected: PASS, all 3 tests.

- [ ] **Step 5: Commit**

```bash
git add lib/riptide_web/plugs/resolve_tenant.ex test/riptide_web/plugs/resolve_tenant_test.exs
git commit -m "Add RiptideWeb.Plugs.ResolveTenant"
```

---

### Task 4: Wire tenant resolution into the router and `ResourceController`

**Files:**
- Modify: `lib/riptide_web/router.ex`
- Modify: `lib/riptide_web/ldp/resource_controller.ex`
- Test: `test/riptide_web/ldp/resource_controller_test.exs`

**Interfaces:**
- Consumes: `RiptideWeb.Plugs.ResolveTenant` (Task 3).
- Produces: every LDP resource route now lives under `/tenants/:tenant_id/resources/*path`; `ResourceController.stream_id_for/2` (arity changes from 1 to 2) takes `(tenant_id, path_segments)`. No other task depends on this one.

- [ ] **Step 1: Update the failing tests first — existing tests move to tenant-scoped paths, plus a new isolation test**

Modify `test/riptide_web/ldp/resource_controller_test.exs` — replace lines 9-16 (the `unique_path/0` and `stream_id_for/1` helpers) with:

```elixir
  defp unique_path,
    do: "/tenants/test-tenant/resources/test-#{System.unique_integer([:positive])}"

  # Mirrors RiptideWeb.LDP.ResourceController.stream_id_for/2 so tests can
  # clean up the same Ra-backed stream the controller actually wrote to.
  defp stream_id_for(path) do
    segments = path |> String.trim_leading("/tenants/test-tenant/resources/") |> String.split("/")
    "https://riptide.example/tenants/test-tenant/resources/" <> Enum.join(segments, "/")
  end
```

Every existing test in this file builds its request path via `unique_path()`/`stream_id_for/1`, so this one change moves the whole file's existing coverage onto tenant-scoped routes with no other edits needed to those tests.

Add this new test at the end of the file, before the closing `end` of the module (after the `"ensure_ready_status/1 maps :ok and {:error, _} correctly"` test):

```elixir
  test "two different tenants requesting the identically-named resource path get fully isolated resources" do
    path_suffix = "shared-name-#{System.unique_integer([:positive])}"
    tenant_a_path = "/tenants/tenant-a/resources/" <> path_suffix
    tenant_b_path = "/tenants/tenant-b/resources/" <> path_suffix

    on_exit(fn ->
      Riptide.RaTestHelpers.cleanup_stream(
        "https://riptide.example/tenants/tenant-a/resources/" <> path_suffix
      )

      Riptide.RaTestHelpers.cleanup_stream(
        "https://riptide.example/tenants/tenant-b/resources/" <> path_suffix
      )
    end)

    :put
    |> conn(tenant_a_path, "<https://pod.example/x> <https://pod.example/y> \"a\" .\n")
    |> put_req_header("content-type", "text/turtle")
    |> RiptideWeb.Endpoint.call(@opts)

    get_b_conn = :get |> conn(tenant_b_path) |> RiptideWeb.Endpoint.call(@opts)
    assert get_b_conn.status == 404

    get_a_conn = :get |> conn(tenant_a_path) |> RiptideWeb.Endpoint.call(@opts)
    assert get_a_conn.status == 200
    assert get_a_conn.resp_body =~ "\"a\""
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/riptide_web/ldp/resource_controller_test.exs --trace`
Expected: FAIL — every test 404s (no route currently matches `/tenants/...`), since the router hasn't changed yet.

- [ ] **Step 3: Update the router**

Replace the full contents of `lib/riptide_web/router.ex`:

```elixir
defmodule RiptideWeb.Router do
  use Phoenix.Router

  pipeline :api do
    plug :accepts, ["json", "turtle", "ld+json"]
  end

  pipeline :tenant do
    plug RiptideWeb.Plugs.ResolveTenant
  end

  scope "/" do
    pipe_through :api

    get "/health", RiptideWeb.HealthController, :show
    get "/streams/:stream_id/subscribe", RiptideWeb.Realtime.SseController, :subscribe
  end

  scope "/tenants/:tenant_id" do
    pipe_through [:api, :tenant]

    get "/resources/*path", RiptideWeb.LDP.ResourceController, :show
    post "/resources/*path", RiptideWeb.LDP.ResourceController, :create_child
    put "/resources/*path", RiptideWeb.LDP.ResourceController, :replace
    delete "/resources/*path", RiptideWeb.LDP.ResourceController, :delete
    patch "/resources/*path", RiptideWeb.LDP.ResourceController, :patch
  end
end
```

`/health` and the SSE subscribe route are deliberately left outside the `/tenants/:tenant_id` scope and untouched — see this plan's Global Constraints and the spec's §5 correction for why SSE needs no changes.

- [ ] **Step 4: Update `ResourceController`**

Replace the full contents of `lib/riptide_web/ldp/resource_controller.ex`:

```elixir
defmodule RiptideWeb.LDP.ResourceController do
  use Phoenix.Controller

  alias Riptide.Event
  alias Riptide.RDF.{Patch, TurtleCodec}
  alias Riptide.Stream.{StreamServer, StreamSupervisor}

  @ldp_contains RDF.iri("http://www.w3.org/ns/ldp#contains")

  def show(conn, %{"path" => path_segments}) do
    stream_id = stream_id_for(conn.assigns.tenant_id, path_segments)

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
    stream_id = stream_id_for(conn.assigns.tenant_id, path_segments)
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
    stream_id = stream_id_for(conn.assigns.tenant_id, path_segments)

    case stream_id |> StreamSupervisor.ensure_ready() |> ensure_ready_status() do
      :ok ->
        StreamServer.append(stream_id, Event.new(stream_id, :delete, RDF.Graph.new()))
        send_resp(conn, 204, "")

      :error ->
        send_resp(conn, 503, "")
    end
  end

  def patch(conn, %{"path" => path_segments} = params) do
    stream_id = stream_id_for(conn.assigns.tenant_id, path_segments)

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
    tenant_id = conn.assigns.tenant_id
    container_stream_id = stream_id_for(tenant_id, path_segments)
    {:ok, body, conn} = Plug.Conn.read_body(conn)

    case TurtleCodec.decode(body) do
      {:ok, child_graph} ->
        child_id = Uniq.UUID.uuid4()
        child_stream_id = container_stream_id <> "/" <> child_id

        with :ok <- child_stream_id |> StreamSupervisor.ensure_ready() |> ensure_ready_status(),
             :ok <-
               container_stream_id |> StreamSupervisor.ensure_ready() |> ensure_ready_status() do
          StreamServer.append(child_stream_id, Event.new(child_stream_id, :replace, child_graph))

          containment_triple =
            {RDF.iri(container_stream_id), @ldp_contains, RDF.iri(child_stream_id)}

          containment_patch = %Patch{additions: [containment_triple], removals: []}

          StreamServer.append(
            container_stream_id,
            Event.new(container_stream_id, :patch, containment_patch)
          )

          location =
            "/tenants/#{tenant_id}/resources/" <> Enum.join(path_segments, "/") <> "/" <> child_id

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

  defp stream_id_for(tenant_id, path_segments) do
    "https://riptide.example/tenants/#{tenant_id}/resources/" <> Enum.join(path_segments, "/")
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

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix test test/riptide_web/ldp/resource_controller_test.exs --trace`
Expected: PASS, all tests including the new isolation test.

- [ ] **Step 6: Run the full suite**

Run: `mix test`
Expected: PASS, 0 failures — no other test file references the old `/resources/*path` (untenanted) route or `stream_id_for/1`'s old arity.

- [ ] **Step 7: Run Credo and formatter checks**

Run: `mix credo --strict && mix format --check-formatted`
Expected: both clean. Fix anything flagged and re-run.

- [ ] **Step 8: Commit**

```bash
git add lib/riptide_web/router.ex lib/riptide_web/ldp/resource_controller.ex test/riptide_web/ldp/resource_controller_test.exs
git commit -m "Wire tenant resolution into the router and ResourceController"
```

---

### Task 5: Full verification + `PROGRESS.md` + wrap-up

**Files:**
- Modify: `PROGRESS.md`

**Interfaces:**
- Consumes: everything from Tasks 1-4.
- Produces: nothing further downstream — terminal task.

- [ ] **Step 1: Run the full test suite**

Run: `mix test`
Expected: PASS, 0 failures.

- [ ] **Step 2: Run Credo and formatter checks**

Run: `mix credo --strict && mix format --check-formatted`
Expected: both clean.

- [ ] **Step 3: Update the sub-projects summary table**

In the `## Sub-projects` table near the top of `PROGRESS.md`, change the row:

```markdown
| 4 | Security & multi-tenancy (auth, WAC/ACP, TLS) | Not started |
```

to:

```markdown
| 4 | Security & multi-tenancy (auth, ACP, TLS) | **Decomposed into phases 4a-4d** — see below |
```

(dropping "WAC" from the parenthetical — Phase 4a's own design decided ACP over WAC; see Task 5's next step for the full rationale written into the sub-project's own section).

- [ ] **Step 4: Update the `## 4-5. Not yet started` section**

Find the `## 4-5. Not yet started` section (currently reading `Will be filled in as each sub-project reaches design.`) and replace it with:

```markdown
## 4. Security & multi-tenancy — decomposed into phases

**Goal for this sub-project**: authentication (who is making a request), authorization (what can
they do), multi-tenancy (data isolation between tenants sharing one deployment), and TLS
(transport security) — bundled under one roadmap line originally, but these are independent
concerns, each getting its own brainstorm → spec → plan → implementation cycle, the same way
sub-project 3 was decomposed into phases 3a-3d.

**Key decisions made:**

- **Isolation model**: logical, not physical — tenants share the same fleet and the same kind of
  `:ra` clusters per stream; isolation is enforced in software (namespacing + authorization), not
  by giving each tenant dedicated infrastructure. Keeps operating cost from multiplying per tenant.
- **Authentication**: pluggable from the start, starting with standard OIDC/OAuth2 (not the
  narrower Solid-ecosystem WebID-OIDC convention the original StreamLD design doc's naming came
  from) — a request's identity mechanism should be swappable without redesigning the request
  pipeline, so a Solid-specific or API-key mechanism can be added later without a rewrite.
- **Authorization**: ACP (Access Control Policy), not WAC (Web Access Control) — ACP is the newer
  Solid-ecosystem standard, more expressive (policy/condition-based rather than a flat ACL
  resource), and fixes known WAC expressiveness gaps.
- **TLS**: terminated at the Kubernetes ingress/load balancer, not in-app — keeps this out of
  Riptide's own codebase entirely; the phase is mostly infrastructure (Ingress manifest +
  cert-manager), not Elixir code.

**Phasing:**

- **Phase 4a — Multi-tenancy data model.** Tenant-scoped resource addressing only — no auth or
  enforcement yet. **Shipped 2026-08-26** — see
  `docs/superpowers/specs/2026-08-26-phase-4a-multi-tenancy-data-model-design.md`. A pluggable
  `Riptide.Tenancy.Resolver` behaviour (path-segment and subdomain implementations, config-selected)
  feeds a new `RiptideWeb.Plugs.ResolveTenant` plug; every LDP resource route now lives under
  `/tenants/:tenant_id/resources/*path`, and `ResourceController.stream_id_for/2` incorporates
  `tenant_id` into every stream_id it builds. Since `RaCluster.uid_for/1` already hashes the full
  stream_id opaquely, this namespaces every stream's underlying `:ra` cluster by tenant with zero
  changes below the web layer. SSE and the WebSocket replication channel needed no changes — they
  already take a fully-qualified, client-supplied `stream_id` directly, never constructing one
  from a path server-side.
- **Phase 4b — Pluggable authentication.** Not yet designed.
- **Phase 4c — Authorization (ACP).** Not yet designed.
- **Phase 4d — TLS.** Not yet designed.

**Status**: Phase 4a shipped 2026-08-26. Phases 4b-4d not yet designed.

## 5. Not yet started

Will be filled in as this sub-project reaches design.
```

- [ ] **Step 5: Commit**

```bash
git add PROGRESS.md
git commit -m "Mark Phase 4a shipped in PROGRESS.md"
```
