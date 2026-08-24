# Riptide Docker Image & CI/CD Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Riptide a real, published, multi-arch Docker image on `ghcr.io`, a CI workflow that gates every change, a tag-triggered release workflow that builds/scans/publishes that image, and the branch-protection settings that make `main` trustworthy.

**Architecture:** A multi-stage `Dockerfile` builds a `mix release` on Elixir 1.18.4/OTP 25 (matching `:ra`'s pin) and runs it as a non-root user in a minimal `debian:bookworm-slim` runtime image, with the Ra data directory on a declared volume so container recreation doesn't silently lose durability. Two GitHub Actions workflows — `ci.yml` (every push/PR: tests, Credo, format check, a Dockerfile build-check) and `release.yml` (tag-triggered only: multi-arch build, SBOM/provenance attestation, Trivy scan, GitHub Release) — plus branch-protection settings on `main`.

**Tech Stack:** Elixir/Phoenix, Docker (Buildx, QEMU for multi-arch), GitHub Actions, GitHub Container Registry, Credo, Trivy.

**Spec:** `docs/superpowers/specs/2026-08-24-docker-cicd-design.md`

## Global Constraints

- Elixir `~> 1.17` (currently running 1.18.4 / OTP 25) — `mix.exs`. The Docker image and CI must
  use this exact Elixir/OTP combination, not a newer OTP: `:ra` is pinned to `~> 2.15.0`
  specifically because newer `:ra` versions require or break on a different OTP major line (see
  the persistence sub-project's design doc). This is load-bearing, not a style choice.
- Test command: `mix test`, run from `/work/riptide`.
- New deps use the existing house style: `{:name, "~> X.Y"}`, one per line, in `mix.exs`'s
  `deps/0`.
- The Ra data volume convention (`VOLUME ["/data"]` + `ENV RIPTIDE_RA_DATA_DIR=/data` in the
  Dockerfile) is what every later task's Docker/Compose/README examples build on — it must be
  established once, in Task 3, and referenced identically everywhere after.
- Registry: `ghcr.io`. Release trigger: `v*.*.*` git tags only, never a bare merge to `main`.
- Branch: work on a plain feature branch in the existing `/work/riptide` clone off `main` (this
  box's standing no-worktree rule — no `git worktree`).
- GitHub org/repo is `OpenFASTER-Standard/riptide` — note its name has mixed case, which matters
  for `ghcr.io` image naming (registries require lowercase; see Task 5).
- Out of scope, do not implement: deployment automation to any specific target
  (Kubernetes/Terraform/hosting provider), Dialyzer, native arm64 runners, automated
  changelog/semver tooling (conventional commits/semantic-release), and
  `mix compile --warnings-as-errors` (pre-existing disclosed warnings, deliberately deferred).

---

## File Structure

New files:
- `Dockerfile`, `.dockerignore`, `docker-compose.yml` — the image itself and a local-run example.
- `.credo.exs` — generated Credo config (`mix credo.gen.config`'s default output, not hand-edited).
- `.github/workflows/ci.yml` — test/lint/build-check, every push and PR.
- `.github/workflows/release.yml` — build/scan/publish/release, tag-triggered only.
- `scripts/configure-branch-protection.sh` — the one-time (re-runnable) branch-protection setup,
  captured as a script rather than a command typed once and forgotten.

Modified files:
- `mix.exs` — adds `releases/0` config and the `credo` dev/test dependency.
- `config/prod.exs` — excludes `/health` from the `force_ssl` redirect (a Docker `HEALTHCHECK`/
  orchestrator liveness probe shouldn't need TLS to succeed).
- `lib/riptide_web/realtime/socket.ex`, `lib/riptide_web/realtime/replication_channel.ex` — add
  missing `@moduledoc`s (a real, pre-existing Credo finding, not new code).
- `lib/riptide/ra_cluster.ex` — extract a `start_fresh_cluster/4` helper out of
  `start_or_restart/2` to fix a real, pre-existing Credo nesting-depth finding.
- `test/riptide_web/realtime/sse_controller_test.exs`,
  `test/riptide/stream/stream_supervisor_test.exs` — use already-aliased/newly-aliased module
  names instead of fully-qualified references (real, pre-existing Credo alias-usage findings).
- `README.md` — adds "Running via Docker" and "Releasing" sections.
- `PROGRESS.md` — status update once shipped (final task).

---

### Task 1: Mix release config + health-check SSL exclusion

**Files:**
- Modify: `mix.exs`
- Modify: `config/prod.exs`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: `_build/prod/rel/riptide/bin/riptide` (the release script) — Task 3's Dockerfile
  `COPY`s this directory directly. `GET /health` reachable over plain HTTP in `MIX_ENV=prod`
  (today it would 301/308-redirect to HTTPS, since `config/prod.exs`'s `force_ssl` currently only
  excludes specific hosts, not paths) — Task 3's Docker `HEALTHCHECK` depends on this.

- [ ] **Step 1: Add release config to `mix.exs`**

Add `releases: releases()` to the `project/0` keyword list (after `start_permanent`) and a new
private function:

```elixir
  def project do
    [
      app: :riptide,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      releases: releases(),
      deps: deps()
    ]
  end
```

```elixir
  defp releases do
    [
      riptide: [
        include_executables_for: [:unix],
        steps: [:assemble]
      ]
    ]
  end
```

Place `releases/0` near `elixirc_paths/1` (private function ordering doesn't matter, but keep
related config functions grouped).

- [ ] **Step 2: Exclude `/health` from the HTTPS redirect**

In `config/prod.exs`, the `force_ssl` config already has a commented-out hint for exactly this.
Uncomment and use it:

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

- [ ] **Step 3: Build the release and confirm it assembles**

Run: `MIX_ENV=prod mix release`
Expected: succeeds, creates `_build/prod/rel/riptide/bin/riptide`.

- [ ] **Step 4: Smoke-test the release actually boots and serves `/health` over plain HTTP**

```bash
SECRET_KEY_BASE=$(openssl rand -base64 48) \
PHX_SERVER=true \
PORT=4000 \
_build/prod/rel/riptide/bin/riptide start &
RELEASE_PID=$!
sleep 3
curl -f http://localhost:4000/health
echo "exit: $?"
_build/prod/rel/riptide/bin/riptide stop
wait $RELEASE_PID 2>/dev/null
```

Expected: `curl` prints `ok` and exits 0 (not a redirect, not a connection error).

- [ ] **Step 5: Run the full test suite to confirm nothing broke**

Run: `mix test`
Expected: unchanged pass count from before this task, 0 failures (this task only touches release
assembly and a prod-only config path — `config/test.exs` is untouched).

- [ ] **Step 6: Commit**

```bash
git add mix.exs config/prod.exs
git commit -m "Add mix release config; exclude /health from prod HTTPS redirect"
```

---

### Task 2: Add Credo, fix its findings against the current codebase

**Files:**
- Modify: `mix.exs`
- Create: `.credo.exs`
- Modify: `lib/riptide_web/realtime/socket.ex`
- Modify: `lib/riptide_web/realtime/replication_channel.ex`
- Modify: `lib/riptide/ra_cluster.ex`
- Modify: `test/riptide_web/realtime/sse_controller_test.exs`
- Modify: `test/riptide/stream/stream_supervisor_test.exs`

**Interfaces:**
- Consumes: nothing from Task 1 (independent).
- Produces: `mix credo --strict` exits 0 against the whole codebase — Task 4's `ci.yml` runs this
  command and expects a clean exit; if this task leaves any finding unfixed, CI will be red from
  its very first run.

- [ ] **Step 1: Add the Credo dependency**

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
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
```

Run: `mix deps.get`
Expected: fetches `credo` (locks to `1.7.19` as of this writing), plus its own deps `bunt` and
`file_system`.

- [ ] **Step 2: Generate the default Credo config**

Run: `mix credo.gen.config`
Expected: creates `.credo.exs` at the repo root. Do not hand-edit its contents — commit Credo's
own generated defaults as-is.

- [ ] **Step 3: Run Credo and confirm it reproduces these exact 9 pre-existing findings**

Run: `mix credo --strict`

Expected output (already verified against the current codebase while writing this plan — if your
run differs, the codebase has changed since this plan was written; investigate the diff rather
than assuming this list is stale):

- 2× missing `@moduledoc`: `lib/riptide_web/realtime/socket.ex`,
  `lib/riptide_web/realtime/replication_channel.ex`
- 5× "nested modules could be aliased": 3 in `test/riptide_web/realtime/sse_controller_test.exs`
  (lines ~37, 39, 44), 2 in `test/riptide/stream/stream_supervisor_test.exs` (lines ~33, 38) —
  all fully-qualified `Riptide.Stream.StreamServer.*` calls where a shorter alias already exists
  or should exist
- 2× function nested too deep: `Riptide.RaCluster.start_or_restart/2` (depth 4, max 2),
  `RiptideWeb.LDP.ResourceController.current_state/1` (depth 3, max 2)

Exit code: non-zero (14). This is expected — fix each finding in the steps below, don't suppress
them via `.credo.exs` config changes.

- [ ] **Step 4: Add `@moduledoc`s**

In `lib/riptide_web/realtime/socket.ex`, add after `defmodule RiptideWeb.Realtime.Socket do`:

```elixir
  @moduledoc """
  Phoenix Socket for StreamLD's WebSocket replication transport — mounts
  `ReplicationChannel` on the `replication:*` topic. Accepts every connection
  unconditionally (no socket-level auth yet) and assigns no socket id, since
  there's no per-connection session distinguishing one reader from another.
  """
```

In `lib/riptide_web/realtime/replication_channel.ex`, add after
`defmodule RiptideWeb.Realtime.ReplicationChannel do`:

```elixir
  @moduledoc """
  WebSocket replication transport for StreamLD's `binding-websocket` — joins
  `"replication:<stream_id>"` with an `"after"` cursor, replies with a backlog,
  and pushes further events as `"replication_frame"` messages. Mirrors the SSE
  controller's cursor/gap semantics over Phoenix Channels instead of SSE.
  """
```

- [ ] **Step 5: Fix the alias-usage findings in `sse_controller_test.exs`**

This file already has `alias Riptide.Event` and `alias Riptide.Stream.{StreamServer,
StreamSupervisor}` at the top — the findings are fully-qualified calls that should use those
existing aliases instead. In the test `"subscribing with a cursor older than the retention
window returns 409 with a gap signal"`, replace:

```elixir
    {:ok, _pid} = Riptide.Stream.StreamServer.start_link({stream_id, retention: 1})

    Riptide.Stream.StreamServer.append(
      stream_id,
      Riptide.Event.new(stream_id, :replace, RDF.Graph.new())
    )

    Riptide.Stream.StreamServer.append(
      stream_id,
      Riptide.Event.new(stream_id, :replace, RDF.Graph.new())
    )
```

with:

```elixir
    {:ok, _pid} = StreamServer.start_link({stream_id, retention: 1})

    StreamServer.append(
      stream_id,
      Event.new(stream_id, :replace, RDF.Graph.new())
    )

    StreamServer.append(
      stream_id,
      Event.new(stream_id, :replace, RDF.Graph.new())
    )
```

- [ ] **Step 6: Fix the alias-usage findings in `stream_supervisor_test.exs`**

This file only aliases `StreamSupervisor` today. Change its alias line from:

```elixir
  alias Riptide.Stream.StreamSupervisor
```

to:

```elixir
  alias Riptide.Event
  alias Riptide.Stream.{StreamServer, StreamSupervisor}
```

Then in the test `"get_or_start/1 isolates state between different streams"`, replace:

```elixir
    Riptide.Stream.StreamServer.append(
      stream_a,
      Riptide.Event.new(stream_a, :replace, RDF.Graph.new())
    )

    {:ok, events_b} = Riptide.Stream.StreamServer.get_since(stream_b, 0)
```

with:

```elixir
    StreamServer.append(
      stream_a,
      Event.new(stream_a, :replace, RDF.Graph.new())
    )

    {:ok, events_b} = StreamServer.get_since(stream_b, 0)
```

- [ ] **Step 7: Fix the nesting-depth finding in `ra_cluster.ex`**

Replace `start_or_restart/2`'s body (currently a `case` containing an `if/else` whose `else`
branch contains another `case` containing another `if/else` — 4 levels deep) by extracting the
inner "start a fresh cluster" branch into its own private function. Replace the full
`start_or_restart/2` function with:

```elixir
  @spec start_or_restart(String.t(), :ra_machine.machine()) :: :ra.server_id()
  def start_or_restart(stream_id, machine) do
    ensure_system_started()
    server_id = server_id(stream_id)
    {name, _node} = server_id

    case :ra.restart_server(@system, server_id) do
      :ok ->
        server_id

      {:error, _reason} ->
        # `:ra.restart_server/2` fails with a variety of shapes here — a clean
        # `{:error, {:already_started, pid}}` if it notices the server is
        # already up, but also a `{:error, {:shutdown, {:failed_to_start_child,
        # Name, {:already_started, pid}}}}` when it loses a race against Ra's
        # *own* automatic restart of a crashed server (the per-server
        # `ra_server_sup` supervises its `ra_server_proc` worker with a
        # restart strategy that already brings a merely-crashed process back
        # up on its own — confirmed empirically: killing the server's pid and
        # immediately calling this function reliably hits this branch with
        # the process already alive again under the same name, well before
        # any explicit restart/start_cluster call could have run). Matching
        # every error shape `:ra` might use for "it's already running" is
        # fragile, so instead we check the one thing that actually matters:
        # is a process registered under this server's name right now?
        if server_alive?(name) do
          server_id
        else
          start_fresh_cluster(stream_id, machine, server_id, name)
        end
    end
  end

  defp start_fresh_cluster(stream_id, machine, server_id, name) do
    cluster_name = uid_for(stream_id) <> "_cluster"

    case :ra.start_cluster(@system, cluster_name, machine, [server_id]) do
      {:ok, [_server_id], []} ->
        server_id

      {:error, reason} ->
        if server_alive?(name) do
          server_id
        else
          raise "Failed to start or restart Ra server #{inspect(server_id)}: #{inspect(reason)}"
        end
    end
  end
```

This is a pure extraction — identical behavior, just split across two functions so neither
exceeds nesting depth 2. `test/riptide/ra_cluster_test.exs` (from the persistence sub-project) is
the regression guard; it calls only the public `start_or_restart/2` and doesn't know or care that
the fresh-cluster path moved into a helper.

- [ ] **Step 8: Fix the nesting-depth finding in `resource_controller.ex`**

Replace `current_state/1` (currently a `case` whose `{:ok, events}` branch contains a `case`
whose `_` branch contains an `Enum.reduce/3` with a multi-clause anonymous function — 3 levels
deep) by extracting the event-folding logic into its own private function. Replace the full
`current_state/1` function with:

```elixir
  defp current_state(stream_id) do
    StreamSupervisor.get_or_start(stream_id)

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

  defp resolve_state(events) do
    case List.last(events) do
      %Event{operation: :delete} ->
        :not_found

      _ ->
        # An empty representation is not the same as not-found: only an
        # explicit DELETE reads as not-found. A PUT with an empty body
        # and a PATCH that removes the last remaining triple both leave
        # the resource visible as 200 with an empty body — the fold
        # below produces that empty graph either way.
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
```

Check the exact comment text already present in the current file around this function (it may
differ slightly in wording from what's shown above, since it was written in an earlier
sub-project) and preserve its intent rather than overwriting it with the abbreviated version
shown here — the important part is the 3-function split, not the exact comment wording.

- [ ] **Step 9: Confirm Credo is clean**

Run: `mix credo --strict`
Expected: `0 mods/funs, found no issues.` (or equivalent zero-issues output), exit code 0.

- [ ] **Step 10: Run the full test suite**

Run: `mix test`
Expected: same pass count as before this task, 0 failures — Steps 7-8 are pure refactors with no
behavior change, and `ra_cluster_test.exs` / `resource_controller_test.exs` are the regression
guards.

- [ ] **Step 11: Commit**

```bash
git add mix.exs mix.lock .credo.exs lib/riptide_web/realtime/socket.ex lib/riptide_web/realtime/replication_channel.ex lib/riptide/ra_cluster.ex test/riptide_web/realtime/sse_controller_test.exs test/riptide/stream/stream_supervisor_test.exs
git commit -m "Add Credo; fix its 9 findings against the current codebase"
```

---

### Task 3: Dockerfile, `.dockerignore`, `docker-compose.yml`

**Files:**
- Create: `Dockerfile`
- Create: `.dockerignore`
- Create: `docker-compose.yml`

**Interfaces:**
- Consumes: Task 1's `mix release` config and `/health`-over-plain-HTTP fix.
- Produces: the `VOLUME ["/data"]` + `RIPTIDE_RA_DATA_DIR=/data` convention that Task 5's
  release workflow builds the same way and Task 7's README documents — must not be renamed or
  restructured by any later task.

- [ ] **Step 1: Write the Dockerfile**

```dockerfile
# syntax=docker/dockerfile:1

# ---- Builder ----
FROM hexpm/elixir:1.18.4-erlang-25.3.2.21-debian-bookworm-20260803 AS builder

ENV MIX_ENV=prod

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mix deps.compile

COPY config config
COPY lib lib
COPY priv priv

RUN mix compile
RUN mix release

# ---- Runtime ----
FROM debian:bookworm-slim AS runtime

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
      libstdc++6 openssl libncurses6 locales ca-certificates curl && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

RUN groupadd --gid 1000 riptide && \
    useradd --uid 1000 --gid riptide --shell /bin/bash --create-home riptide

RUN mkdir -p /data && chown riptide:riptide /data

WORKDIR /app
RUN chown riptide:riptide /app

COPY --from=builder --chown=riptide:riptide /app/_build/prod/rel/riptide ./

USER riptide

ENV RIPTIDE_RA_DATA_DIR=/data
ENV PHX_SERVER=true
ENV PORT=4000

VOLUME ["/data"]
EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -f http://localhost:4000/health || exit 1

CMD ["bin/riptide", "start"]
```

The builder tag pins Elixir 1.18.4 with Erlang/OTP 25.3.2.21 on Debian bookworm — verified
against `hexpm/elixir`'s published tags on Docker Hub while writing this plan (the latest OTP
25.x patch available for this Elixir version at the time). If this tag has since been removed
(image registries occasionally prune very old tags), find its replacement by searching
`hexpm/elixir` tags for `1.18.4-erlang-25.` — do not silently jump to an OTP 26 tag, since that
breaks `:ra` (see Global Constraints).

- [ ] **Step 2: Write `.dockerignore`**

```
_build/
deps/
.git/
.gitignore
.github/
.superpowers/
docs/
test/
priv/ra_data/
priv/ra_data_test/
erl_crash.dump
*.md
.formatter.exs
.credo.exs
```

- [ ] **Step 3: Write `docker-compose.yml`**

```yaml
services:
  riptide:
    build: .
    image: ghcr.io/openfaster-standard/riptide:latest
    ports:
      - "4000:4000"
    environment:
      SECRET_KEY_BASE: ${SECRET_KEY_BASE:?Set SECRET_KEY_BASE, e.g. via: openssl rand -base64 48}
      PHX_HOST: ${PHX_HOST:-localhost}
    volumes:
      - riptide_data:/data

volumes:
  riptide_data:
```

- [ ] **Step 4: Build the image locally**

Run: `docker build -t riptide:local .`
Expected: succeeds (both stages). This is a single-arch (host-native) build for local testing —
multi-arch happens only in the release workflow (Task 5).

- [ ] **Step 5: Run it with a named volume and confirm `/health`**

```bash
docker volume create riptide-durability-test
docker run -d --name riptide-durability-test \
  -p 4000:4000 \
  -e SECRET_KEY_BASE="$(openssl rand -base64 48)" \
  -v riptide-durability-test:/data \
  riptide:local

sleep 3
curl -f http://localhost:4000/health
echo "health exit: $?"
```

Expected: `ok`, exit 0.

- [ ] **Step 6: Write data, then prove it survives a container restart**

```bash
curl -X PUT -H "Content-Type: text/turtle" \
  --data '<https://s> <https://p> <https://o> .' \
  http://localhost:4000/resources/durability-check

curl http://localhost:4000/resources/durability-check
# Expected: 200, body contains the triple above

docker restart riptide-durability-test
sleep 3

curl http://localhost:4000/resources/durability-check
# Expected: still 200, still contains the triple — same container, restarted
```

- [ ] **Step 7: Prove it survives full container recreation (the volume, not the container, is
what's durable)**

```bash
docker rm -f riptide-durability-test

docker run -d --name riptide-durability-test-2 \
  -p 4000:4000 \
  -e SECRET_KEY_BASE="$(openssl rand -base64 48)" \
  -v riptide-durability-test:/data \
  riptide:local

sleep 3
curl http://localhost:4000/resources/durability-check
# Expected: still 200, still contains the triple — a brand new container,
# same named volume, data survived
```

This is the step that matters most in this whole sub-project: it re-proves the persistence
sub-project's durability guarantee through the container boundary, using the actual published
volume convention, not just Ra's own internal tests.

- [ ] **Step 8: Clean up the test container and volume**

```bash
docker rm -f riptide-durability-test-2
docker volume rm riptide-durability-test
```

- [ ] **Step 9: Commit**

```bash
git add Dockerfile .dockerignore docker-compose.yml
git commit -m "Add multi-stage Dockerfile, .dockerignore, docker-compose.yml"
```

---

### Task 4: CI workflow (`ci.yml`)

**Files:**
- Create: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: Task 2's Credo setup (`mix credo --strict` must exit 0), Task 3's `Dockerfile`.
- Produces: a GitHub Actions check named `test` — Task 6's branch protection requires this exact
  job name as a required status check context. Do not rename the `test` job in a later task
  without also updating Task 6's script.

- [ ] **Step 1: Write `.github/workflows/ci.yml`**

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7

      - uses: erlef/setup-beam@v1
        with:
          elixir-version: "1.18.4"
          otp-version: "25.3.2.21"

      - name: Cache deps and _build
        uses: actions/cache@v6
        with:
          path: |
            deps
            _build
          key: ${{ runner.os }}-mix-${{ hashFiles('**/mix.lock') }}
          restore-keys: |
            ${{ runner.os }}-mix-

      - name: Install dependencies
        run: mix deps.get

      - name: Check formatting
        run: mix format --check-formatted

      - name: Run Credo
        run: mix credo --strict

      - name: Run tests
        run: mix test

  docker-build-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7

      - uses: docker/setup-buildx-action@v4

      - name: Build image (no push)
        uses: docker/build-push-action@v7
        with:
          context: .
          push: false
          platforms: linux/amd64
          tags: riptide:ci-build-check
```

Note the `test` job's OTP version (`25.3.2.21`) matches Task 3's Dockerfile builder image exactly
— CI is testing against the same toolchain the release actually ships.

- [ ] **Step 2: Push the branch and confirm the workflow runs for real**

```bash
git add .github/workflows/ci.yml
git commit -m "Add ci.yml: test + Dockerfile build-check on every push/PR"
git push -u origin HEAD
```

Run: `gh run list --branch "$(git branch --show-current)" --limit 5`

Wait for the run to appear, then: `gh run watch` (or `gh run view --log` on its ID once it
finishes).

Expected: both jobs (`test`, `docker-build-check`) complete successfully. If `test` fails on
something other than what Steps above already fixed, investigate — do not proceed to Task 6
(branch protection) with a workflow that doesn't actually pass.

---

### Task 5: Release workflow (`release.yml`)

**Files:**
- Create: `.github/workflows/release.yml`

**Interfaces:**
- Consumes: Task 3's `Dockerfile` and its `VOLUME`/`RIPTIDE_RA_DATA_DIR` convention.
- Produces: the actual release pipeline Task 8 exercises end-to-end with a real tag push.

- [ ] **Step 1: Write `.github/workflows/release.yml`**

```yaml
name: Release

on:
  push:
    tags:
      - "v*.*.*"

permissions:
  contents: write
  packages: write
  security-events: write

jobs:
  build-and-publish:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7

      # ghcr.io requires a lowercase image path; this org/repo
      # (OpenFASTER-Standard/riptide) has mixed case, so `github.repository`
      # can't be used directly here.
      - name: Lowercase image name
        run: echo "IMAGE_NAME=$(echo '${{ github.repository }}' | tr '[:upper:]' '[:lower:]')" >> "$GITHUB_ENV"

      - uses: docker/setup-qemu-action@v4

      - uses: docker/setup-buildx-action@v4

      - name: Log in to GHCR
        uses: docker/login-action@v4
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Derive image metadata
        id: meta
        uses: docker/metadata-action@v6
        with:
          images: ghcr.io/${{ env.IMAGE_NAME }}
          tags: |
            type=semver,pattern={{version}}
            type=semver,pattern={{major}}.{{minor}}
            type=raw,value=latest,enable=${{ !contains(github.ref_name, '-') }}

      - name: Build and push
        id: build
        uses: docker/build-push-action@v7
        with:
          context: .
          platforms: linux/amd64,linux/arm64
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          sbom: true
          provenance: true

      - name: Scan image for vulnerabilities (report all, non-blocking)
        uses: aquasecurity/trivy-action@0.36.0
        with:
          image-ref: ghcr.io/${{ env.IMAGE_NAME }}@${{ steps.build.outputs.digest }}
          format: sarif
          output: trivy-results.sarif
          severity: "CRITICAL,HIGH,MEDIUM"
          exit-code: "0"

      - name: Upload scan results to code scanning
        uses: github/codeql-action/upload-sarif@v4
        with:
          sarif_file: trivy-results.sarif

      - name: Fail release on CRITICAL vulnerabilities only
        uses: aquasecurity/trivy-action@0.36.0
        with:
          image-ref: ghcr.io/${{ env.IMAGE_NAME }}@${{ steps.build.outputs.digest }}
          format: table
          severity: "CRITICAL"
          exit-code: "1"

      - name: Create GitHub Release
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: gh release create "${{ github.ref_name }}" --generate-notes --title "${{ github.ref_name }}"
```

Two separate Trivy steps are deliberate, not redundant: the first scans everything and always
succeeds (`exit-code: "0"`) purely to produce the SARIF file for GitHub's code-scanning tab; the
second re-scans filtered to `CRITICAL` only and is the actual gate (`exit-code: "1"` fails the
job). This is what implements the spec's "surfaced but non-blocking below CRITICAL" policy using
Trivy's own filtering rather than custom scripting.

`sbom: true` / `provenance: true` on `docker/build-push-action` need the `docker-container`
buildx driver to produce real attestations — `docker/setup-buildx-action` creates that driver by
default (no extra config needed), but Task 8's end-to-end run is what actually confirms the
attestations show up rather than silently no-op-ing.

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "Add release.yml: tag-triggered multi-arch build, scan, SBOM, publish"
```

(This workflow can't be meaningfully tested by pushing to a feature branch — it only triggers on
`v*.*.*` tags. Real end-to-end verification happens deliberately in Task 8, after everything else
in this plan is confirmed working, since pushing a tag is a more consequential action than
pushing a branch.)

---

### Task 6: Branch protection on `main`

**Files:**
- Create: `scripts/configure-branch-protection.sh`

**Interfaces:**
- Consumes: Task 4's `ci.yml` — specifically its `test` job name, used as the required status
  check context. Requires that workflow to have actually run at least once (Task 4's Step 2) so
  GitHub recognizes the context name.

- [ ] **Step 1: Write the branch-protection script**

```bash
#!/usr/bin/env bash
set -euo pipefail

# Configures main's branch protection to match the Docker/CI/CD sub-project's
# design (docs/superpowers/specs/2026-08-24-docker-cicd-design.md §3.5):
# require the ci.yml `test` job, require a PR (no direct pushes), no mandatory
# approval count (effectively solo-maintained today; every PR already goes
# through this project's own AI-driven review process before merge).
#
# Re-runnable: safe to run again if these settings ever need to be reapplied.

REPO="OpenFASTER-Standard/riptide"

gh api \
  --method PUT \
  -H "Accept: application/vnd.github+json" \
  "repos/${REPO}/branches/main/protection" \
  --input - <<'EOF'
{
  "required_status_checks": {
    "strict": true,
    "checks": [{"context": "test"}]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "required_approving_review_count": 0
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
EOF

echo "Branch protection applied to ${REPO}#main."
```

- [ ] **Step 2: Make it executable and run it for real**

```bash
chmod +x scripts/configure-branch-protection.sh
./scripts/configure-branch-protection.sh
```

Expected: the `gh api` call succeeds (HTTP 200). If it errors on
`required_pull_request_reviews.required_approving_review_count: 0` (some GitHub API versions may
reject 0 and require ≥1), that's a live API detail this plan couldn't verify without actually
calling it — adjust the script to the smallest change that achieves "require a PR, no mandatory
approval count" (check the error message and GitHub's current branch-protection API docs), fix
it, and rerun before proceeding.

- [ ] **Step 3: Verify the actual settings, not just that the script ran**

Run: `gh api "repos/OpenFASTER-Standard/riptide/branches/main/protection" | jq '{required_status_checks, enforce_admins, required_pull_request_reviews, allow_force_pushes, allow_deletions}'`

Expected: output matches what Step 1's payload requested — `required_status_checks.checks`
contains `{"context": "test"}`, `allow_force_pushes: false`, `allow_deletions: false`.

- [ ] **Step 4: Commit**

```bash
git add scripts/configure-branch-protection.sh
git commit -m "Add and apply branch-protection script for main"
```

---

### Task 7: README updates

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: Task 3's `docker-compose.yml`/volume convention, Task 5's `v*.*.*` tag convention.

- [ ] **Step 1: Add a "Running via Docker" section**

Add after the existing "How the pieces fit together" section:

```markdown
## Running via Docker

A published image is available at `ghcr.io/openfaster-standard/riptide` — see the
[Releases](https://github.com/OpenFASTER-Standard/riptide/releases) page for available tags.

Riptide's durability model (see `PROGRESS.md`) depends on its Ra data directory surviving
container restarts — always mount a volume at `/data`, or you'll silently lose every stream on
container recreation:

```bash
docker volume create riptide_data
docker run -d \
  -p 4000:4000 \
  -e SECRET_KEY_BASE="$(openssl rand -base64 48)" \
  -v riptide_data:/data \
  ghcr.io/openfaster-standard/riptide:latest
```

Or with `docker-compose.yml` (included in this repo):

```bash
export SECRET_KEY_BASE=$(openssl rand -base64 48)
docker compose up
```

`SECRET_KEY_BASE` is required (Phoenix uses it to sign/encrypt cookies and tokens); generate one
with `openssl rand -base64 48` or `mix phx.gen.secret`. `PHX_HOST` defaults to `localhost` in the
compose file — set it to your real hostname for anything beyond local testing.
```

- [ ] **Step 2: Add a "Releasing" section**

Add after the new "Running via Docker" section:

```markdown
## Releasing

Riptide uses plain [semver](https://semver.org/) tags (`vMAJOR.MINOR.PATCH`, optionally with a
`-rc1`-style pre-release suffix). Pushing a tag matching `v*.*.*` to `main` triggers
`.github/workflows/release.yml`, which builds and publishes a multi-arch
(`linux/amd64`/`linux/arm64`) image to `ghcr.io/openfaster-standard/riptide`, scans it for
vulnerabilities, attaches an SBOM, and creates a GitHub Release with auto-generated notes.

Version bumps are a judgment call made when tagging, not automated:
- **major** — breaking StreamLD protocol or LDP API changes
- **minor** — new capability, backward-compatible
- **patch** — fixes, no behavior change

A "clean" tag (`v0.2.0`) also gets the `latest` image tag; a pre-release tag (`v0.2.0-rc1`) does
not.
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "Document Docker usage and the release process in README"
```

---

### Task 8: End-to-end verification and wrap-up

**Files:**
- Modify: `PROGRESS.md`

**Interfaces:**
- Consumes: everything from Tasks 1-7. This is the task that actually proves the whole
  sub-project works, not just that each piece compiles/lints/builds in isolation.

- [ ] **Step 1: Merge this branch's work so `release.yml` can run from `main`**

`release.yml` only triggers on tags, and tags are conventionally cut from `main`. Push this
branch, open a PR, and get it merged (following this project's established review process)
before continuing — Steps 2+ below need the release workflow to exist on `main`.

- [ ] **Step 2: Push a throwaway pre-release tag**

```bash
git checkout main && git pull
git tag v0.0.0-test1
git push origin v0.0.0-test1
```

(Using a `-test1` pre-release suffix is deliberate: per Task 5, pre-release tags don't get the
`latest` tag, so this can't accidentally become what `docker pull ...:latest` resolves to.)

- [ ] **Step 3: Watch the release run for real**

Run: `gh run list --workflow=release.yml --limit 3`, then `gh run watch <run-id>`

Expected: the `build-and-publish` job completes successfully end to end (lowercase image name
derivation, QEMU/Buildx setup, GHCR login, multi-arch build+push, both Trivy steps, SARIF
upload, GitHub Release creation).

- [ ] **Step 4: Confirm the image actually exists and is multi-arch**

```bash
docker buildx imagetools inspect ghcr.io/openfaster-standard/riptide:0.0.0-test1
```

Expected: lists both `linux/amd64` and `linux/arm64` manifests.

- [ ] **Step 5: Pull and run the *published* image (not a local build) and re-prove durability**

```bash
docker volume create riptide-e2e-test
docker run -d --name riptide-e2e-test \
  -p 4000:4000 \
  -e SECRET_KEY_BASE="$(openssl rand -base64 48)" \
  -v riptide-e2e-test:/data \
  ghcr.io/openfaster-standard/riptide:0.0.0-test1

sleep 3
curl -f http://localhost:4000/health

curl -X PUT -H "Content-Type: text/turtle" \
  --data '<https://s> <https://p> <https://o> .' \
  http://localhost:4000/resources/e2e-durability-check

docker rm -f riptide-e2e-test
docker run -d --name riptide-e2e-test-2 \
  -p 4000:4000 \
  -e SECRET_KEY_BASE="$(openssl rand -base64 48)" \
  -v riptide-e2e-test:/data \
  ghcr.io/openfaster-standard/riptide:0.0.0-test1

sleep 3
curl http://localhost:4000/resources/e2e-durability-check
# Expected: 200, still contains the triple — the actual published image,
# actually pulled from ghcr.io, actually preserves data across recreation.
```

- [ ] **Step 6: Confirm the SBOM and vulnerability scan produced real output**

```bash
docker buildx imagetools inspect ghcr.io/openfaster-standard/riptide:0.0.0-test1 --format '{{json .SBOM}}' | head -c 500
```

Expected: real SBOM JSON content, not empty/null.

Run: `gh api "repos/OpenFASTER-Standard/riptide/code-scanning/alerts" --jq '. | length'`

Expected: a number ≥ 0 (some may be 0 if Trivy found nothing at HIGH/CRITICAL/MEDIUM — that's a
valid outcome; what matters is the API call succeeds, confirming SARIF upload worked, not that
alerts exist). Cross-check against the `Scan image for vulnerabilities` step's own log output in
`gh run view <run-id> --log` for the actual finding count Trivy reported.

- [ ] **Step 7: Clean up every throwaway artifact from this verification**

```bash
docker rm -f riptide-e2e-test-2
docker volume rm riptide-e2e-test

git tag -d v0.0.0-test1
git push origin :refs/tags/v0.0.0-test1

gh release delete v0.0.0-test1 --yes --repo OpenFASTER-Standard/riptide
```

Then delete the test image version from the registry: `gh api
"/orgs/OpenFASTER-Standard/packages/container/riptide/versions" --jq '.[] | select(.metadata.container.tags[]? == "0.0.0-test1") | .id'`
to find its version ID, then `gh api --method DELETE
"/orgs/OpenFASTER-Standard/packages/container/riptide/versions/<id>"`.

Expected: no `v0.0.0-test1` tag, release, or package version left in the repo/registry
afterward — confirm with `gh release list --repo OpenFASTER-Standard/riptide` and `git tag -l`.

- [ ] **Step 8: Update `PROGRESS.md`**

Change sub-project 2's row from `**In design** — see below` to `**Shipped** — see below`. Update
the `## 2. Docker image + CI/CD` section's Status line to point at the PR that merged this work
(fill in the real PR number/URL once known) instead of "design doc written and committed;
approved; moving to implementation plan."

- [ ] **Step 9: Commit and push**

```bash
git add PROGRESS.md
git commit -m "Update PROGRESS.md: Docker image + CI/CD sub-project shipped"
git push
```

---

## Self-Review Notes

- **Spec coverage**: §3.1 Dockerfile → Task 3. §3.2 Ra data volume → Task 3 Steps 1/3, re-proven
  in Task 8 Step 5. §3.3 `ci.yml` → Task 4. §3.4 `release.yml` → Task 5. §3.5 branch protection →
  Task 6. §3.6 versioning convention → Task 7 Step 2. §4 Testing → Task 8 in full (multi-arch,
  `/health`, durability-through-recreation, SBOM/scan output, cleanup). §5 Dependencies (Credo) →
  Task 2. §6 Deferred work — verified no task attempts any of the listed out-of-scope items.
- **Pre-existing findings folded in, not new scope creep**: Task 2's Credo fixes and Task 1's
  `force_ssl` fix are real, mechanical corrections to code that already exists — same pattern as
  the persistence sub-project folding its own pre-existing PR #1 gaps into that plan rather than
  tracking them separately.
- **Type/interface consistency checked**: the `VOLUME ["/data"]` / `RIPTIDE_RA_DATA_DIR=/data`
  convention established in Task 3 is referenced identically (not renamed/restructured) in Task 5
  (implicitly, since it builds the same Dockerfile), Task 7 (README examples), and Task 8
  (end-to-end verification). The `test` job name from Task 4 is referenced identically in Task
  6's branch-protection script. `ghcr.io/openfaster-standard/riptide` (lowercased) is used
  consistently across Task 3's `docker-compose.yml`, Task 5's workflow, Task 7's README, and Task
  8's verification commands.
- **Placeholder scan**: no TBD/TODO left in any task. The one deliberately-not-hardcoded value
  (the exact `hexpm/elixir` tag, if it's been pruned by the time this plan executes) has a
  concrete fallback instruction (search for `1.18.4-erlang-25.` tags, never jump to OTP 26),
  which is guidance for a real contingency, not a vague placeholder.
