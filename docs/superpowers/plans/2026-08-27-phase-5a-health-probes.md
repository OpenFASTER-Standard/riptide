# Phase 5a (Health/Readiness Probes) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single, always-`200` `/health` endpoint with `/health/live` (unconditional, for liveness) and `/health/ready` (a real placement-cluster check, for readiness), so a Riptide node that can't reach the shared placement Ra cluster stops receiving traffic instead of silently reporting healthy.

**Architecture:** `RiptideWeb.HealthController` gains two actions (`live/2`, `ready/2`) replacing its current single `show/2`. `ready/2` calls `Riptide.Placement.lookup/1` with a fixed sentinel stream ID and rescues any raised exception into a `503` — no new modules, no supervision-tree changes.

**Tech Stack:** Elixir/Phoenix (`Phoenix.Controller`, `Phoenix.Router`), ExUnit, Kubernetes probe config (YAML).

**Spec:** `docs/superpowers/specs/2026-08-27-phase-5a-health-probes-design.md`

## Global Constraints

- `/health/live` must never depend on any external system (Ra, placement, auth) — unconditional `200 "ok"`, matching today's `show/2` behavior exactly.
- `/health/ready` must catch any exception raised while querying the placement cluster and return `503`, never let it crash into an unhandled `500` or hang past `:ra`'s own internal timeout.
- Both routes stay unscoped (`pipe_through :api` only) — never behind `:tenant`, `:auth`, or `:authz`. Health checks must never depend on authentication succeeding.
- The old `/health` route is removed outright — no alias, no backward-compatibility shim.
- No changes to `Riptide.Application`'s supervision tree.
- The `/health/ready` failure-case test must use `async: false` — it mutates the global `Application.get_env(:riptide, :ordinal_resolver)` key that other concurrently-running async tests also read, and must restore the original value in `on_exit`.

---

### Task 1: Split HealthController, update router, add tests

**Files:**
- Modify: `lib/riptide_web/health_controller.ex`
- Modify: `lib/riptide_web/router.ex:19-23` (the `/health` route's scope block)
- Modify: `test/riptide_web/health_test.exs` (full rewrite — the single existing test no longer applies)

**Interfaces:**
- Consumes: `Riptide.Placement.lookup/1` (existing, `lib/riptide/placement.ex:49-54`) — raises on total placement-cluster failure (all 3 ordinals exhausted via `with_ordinal_fallback/2`), returns `[node()] | nil` on success.
- Consumes: `Application.get_env(:riptide, :ordinal_resolver)` / `Application.put_env/3` (existing config key, already set in `config/test.exs:33`) — the test's mechanism for forcing a placement-cluster failure.
- Produces: `RiptideWeb.HealthController.live/2` and `RiptideWeb.HealthController.ready/2` — consumed by Task 2's router-adjacent config (no code dependency, just the same route paths).

- [ ] **Step 1: Write the failing tests**

Replace the full contents of `test/riptide_web/health_test.exs`:

```elixir
defmodule RiptideWeb.HealthTest do
  use ExUnit.Case, async: false
  use Plug.Test

  @opts RiptideWeb.Endpoint.init([])

  describe "GET /health/live" do
    test "returns 200 ok unconditionally" do
      conn =
        :get
        |> conn("/health/live")
        |> RiptideWeb.Endpoint.call(@opts)

      assert conn.status == 200
      assert conn.resp_body == "ok"
    end
  end

  describe "GET /health/ready" do
    test "returns 200 ok when the placement cluster is reachable" do
      conn =
        :get
        |> conn("/health/ready")
        |> RiptideWeb.Endpoint.call(@opts)

      assert conn.status == 200
      assert conn.resp_body == "ok"
    end

    # :ordinal_resolver is global Application state that every other test
    # touching Riptide.Placement/RaCluster also reads (config/test.exs:33
    # sets it suite-wide) — this test module is async: false specifically so
    # this override never races a concurrently-running async test.
    test "returns 503 when the placement cluster is unreachable" do
      original = Application.get_env(:riptide, :ordinal_resolver)
      Application.put_env(:riptide, :ordinal_resolver, fn _ordinal -> :"nonexistent@nohost" end)
      on_exit(fn -> Application.put_env(:riptide, :ordinal_resolver, original) end)

      conn =
        :get
        |> conn("/health/ready")
        |> RiptideWeb.Endpoint.call(@opts)

      assert conn.status == 503
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/riptide_web/health_test.exs`
Expected: FAIL — `/health/live` and `/health/ready` don't exist yet (the router still only has `/health`), so all 3 tests fail with a `Phoenix.Router.NoRouteError` (404).

- [ ] **Step 3: Rewrite the controller**

Replace the full contents of `lib/riptide_web/health_controller.ex`:

```elixir
defmodule RiptideWeb.HealthController do
  use Phoenix.Controller

  # Never a real stream — just needs to reach `PlacementMachine.get/2`'s O(1)
  # map lookup so `/health/ready` proves the placement Ra cluster answers,
  # without the cost of `Placement.list_all/1`'s full streams-map payload.
  @health_check_stream_id "__riptide_health_check__"

  # Deliberately checks nothing beyond "is Phoenix itself responsive" — a
  # degraded downstream dependency (e.g. an unreachable placement cluster)
  # must never trigger a pod restart, only a readiness failure (see ready/2).
  def live(conn, _params) do
    send_resp(conn, 200, "ok")
  end

  # Riptide.Placement.lookup/1 raises (via with_ordinal_fallback/2 exhausting
  # all 3 placement ordinals) when the shared placement Ra cluster is
  # unreachable — every LDP/SSE/WebSocket request needs this cluster to
  # resolve stream placement, so its reachability is what "ready" means here.
  def ready(conn, _params) do
    Riptide.Placement.lookup(@health_check_stream_id)
    send_resp(conn, 200, "ok")
  rescue
    _ -> send_resp(conn, 503, "not ready")
  end
end
```

- [ ] **Step 4: Update the router**

In `lib/riptide_web/router.ex`, replace:

```elixir
  scope "/" do
    pipe_through :api

    get "/health", RiptideWeb.HealthController, :show
  end
```

with:

```elixir
  scope "/" do
    pipe_through :api

    get "/health/live", RiptideWeb.HealthController, :live
    get "/health/ready", RiptideWeb.HealthController, :ready
  end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/riptide_web/health_test.exs`
Expected: PASS — 3 tests, 0 failures.

- [ ] **Step 6: Run the full suite to check for regressions**

Run: `mix test`
Expected: PASS — all tests green, including every other test file (no other file references `/health`, `HealthController.show`, or depends on the old route).

- [ ] **Step 7: Commit**

```bash
git add lib/riptide_web/health_controller.ex lib/riptide_web/router.ex test/riptide_web/health_test.exs
git commit -m "Phase 5a: split /health into /health/live and /health/ready"
```

---

### Task 2: Update k8s manifest and force_ssl config

**Files:**
- Modify: `k8s/statefulset.yaml:54-65` (the `readinessProbe`/`livenessProbe` blocks)
- Modify: `config/prod.exs:6-13` (the `force_ssl` `exclude.paths` list)

**Interfaces:**
- Consumes: `/health/live` and `/health/ready` from Task 1 — this task only points existing config at those paths, no new code.

- [ ] **Step 1: Confirm the exact current probe block**

Run: `grep -n -B2 -A6 'readinessProbe\|livenessProbe' k8s/statefulset.yaml`
Expected output (confirm this matches before editing — if it doesn't, stop and re-read the whole file rather than guessing at line numbers):
```
54:          readinessProbe:
55-            httpGet:
56-              path: /health
57-              port: 4000
58-            initialDelaySeconds: 5
59-            periodSeconds: 10
60:          livenessProbe:
61-            httpGet:
62-              path: /health
63-              port: 4000
64-            initialDelaySeconds: 10
65-            periodSeconds: 30
```

- [ ] **Step 2: Update the probe paths**

In `k8s/statefulset.yaml`, change:

```yaml
          readinessProbe:
            httpGet:
              path: /health
              port: 4000
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /health
              port: 4000
            initialDelaySeconds: 10
            periodSeconds: 30
```

to:

```yaml
          # readinessProbe calls Riptide.Placement.lookup/1, which retries
          # across all 3 placement ordinals on failure. Each attempt carries
          # :ra's own 5000ms default query timeout (deps/ra/src/ra.hrl's
          # DEFAULT_TIMEOUT), so a fully-unreachable placement cluster can
          # take up to ~15s to resolve to a 503. timeoutSeconds is set to 5s
          # (one ordinal attempt's worth) rather than k8s's 1s default, which
          # was already too short even for a single healthy attempt under
          # any real network latency or in-flight leader election.
          readinessProbe:
            httpGet:
              path: /health/ready
              port: 4000
            initialDelaySeconds: 5
            periodSeconds: 10
            timeoutSeconds: 5
          livenessProbe:
            httpGet:
              path: /health/live
              port: 4000
            initialDelaySeconds: 10
            periodSeconds: 30
```

- [ ] **Step 3: Validate YAML syntax**

Run: `python3 -c "import yaml, sys; list(yaml.safe_load_all(open('k8s/statefulset.yaml'))); print('OK')"`
Expected: `OK`

- [ ] **Step 4: Update config/prod.exs's force_ssl exclude paths**

In `config/prod.exs`, change:

```elixir
config :riptide, RiptideWeb.Endpoint,
  force_ssl: [
    rewrite_on: [:x_forwarded_proto],
    exclude: [
      paths: ["/health"],
      hosts: ["localhost", "127.0.0.1"]
    ]
  ]
```

to:

```elixir
config :riptide, RiptideWeb.Endpoint,
  force_ssl: [
    rewrite_on: [:x_forwarded_proto],
    exclude: [
      paths: ["/health/live", "/health/ready"],
      hosts: ["localhost", "127.0.0.1"]
    ]
  ]
```

- [ ] **Step 5: Verify config/prod.exs still loads and parses correctly**

Plain `mix compile` does NOT load `config/prod.exs` — `config/config.exs`'s trailing
`import_config "#{config_env()}.exs"` only pulls in the file matching the *current* `Mix.env()`,
which defaults to `:dev`. Confirm this yourself first if in doubt:
`mix run -e 'IO.inspect(Application.get_env(:riptide, RiptideWeb.Endpoint)[:force_ssl])'` prints
`nil` under plain `mix compile`/`mix run`, proving `prod.exs` was never touched. The actual
verification needs `MIX_ENV=prod`:

Run: `MIX_ENV=prod mix compile --force`
Expected: compiles with no errors (same pre-existing `:formats` warnings as any other compile are
fine — unrelated to this change). This loads and parses `config/prod.exs` for real, confirming the
edited `exclude.paths` list is valid Elixir/Config syntax, without needing `SECRET_KEY_BASE` or any
other release-time secret — that raise lives in `config/runtime.exs`, which only runs at release
boot, not during `mix compile`.

Then restore the default dev build so later tasks aren't left compiled against `:prod` config:
`MIX_ENV=dev mix compile --force`

- [ ] **Step 6: Commit**

```bash
git add k8s/statefulset.yaml config/prod.exs
git commit -m "Phase 5a: point k8s probes and force_ssl excludes at the new health paths"
```

---

### Task 3: Full verification + PROGRESS.md

**Files:**
- Modify: `PROGRESS.md` (sub-project 5's section and the sub-projects summary table)

**Interfaces:**
- Consumes: nothing new — this task verifies Tasks 1-2 together and documents completion.

- [ ] **Step 1: Run the full test suite one more time**

Run: `mix test`
Expected: PASS — all tests green (confirms Tasks 1 and 2 together didn't introduce any regression, e.g. from the `config/prod.exs` edit interacting with anything test-visible).

- [ ] **Step 2: Confirm the old route is fully gone**

Run: `grep -rn '"/health"' lib/ test/ k8s/ config/ README.md`
Expected: no matches (only `/health/live` and `/health/ready` should appear anywhere in the codebase now — this catches any leftover reference Tasks 1-2 might have missed, such as a stray mention in `README.md`'s "Running via Kubernetes" section from Phase 4d).

If the grep above finds a match in `README.md` (Phase 4d's "Running via Kubernetes" section doesn't reference `/health` directly today, but re-check since it's the most likely place a stray mention would live), update it to reference `/health/live`/`/health/ready` instead before proceeding.

- [ ] **Step 3: Update PROGRESS.md**

Find the section:

```markdown
## 5. Not yet started

Will be filled in as this sub-project reaches design.
```

Replace it with:

```markdown
## 5. Observability & operability — decomposed into phases

**Goal for this sub-project**: health/readiness probes, structured logging, and metrics — three
independent concerns, decomposed into phases the same way sub-projects 3 and 4 were, rather than
one monolithic spec.

**Phasing:**

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

Then find the sub-projects summary table near the top of the file:

```markdown
| 5 | Observability & operability (metrics, logging, health probes) | Not started |
```

Replace it with:

```markdown
| 5 | Observability & operability (metrics, logging, health probes) | **Decomposed into phases 5a-5c** — see below |
```

- [ ] **Step 4: Bump the file's "Last updated" date**

Change:
```markdown
**Last updated:** 2026-08-26
```
to:
```markdown
**Last updated:** 2026-08-27
```

(Confirm the actual current date via `date -u +%Y-%m-%d` before committing — use that value instead of the literal date above if the plan is executed on a later day.)

- [ ] **Step 5: Commit**

```bash
git add PROGRESS.md
git commit -m "Phase 5a: mark health/readiness probes shipped"
```
