# Phase 3b — Real Multi-Node Connectivity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-enable real distributed Erlang for Riptide, with a stable-identity scheme that actually holds under Kubernetes, and prove N nodes connect and stay connected — both locally (automated) and on a real cluster (live proof).

**Architecture:** `:ra`'s on-disk data directory is decoupled from Erlang's distribution identity (`node()`) via an explicit `ra_system:start/1` config override keyed on the pod's stable `HOSTNAME` instead. Erlang distribution identity itself becomes IP-based (`RELEASE_NODE=riptide@$POD_IP`), which is what `libcluster`'s `Cluster.Strategy.Kubernetes.DNS` strategy actually connects to. A `StatefulSet` + headless `Service` give each pod both the stable `HOSTNAME` (for `:ra`'s directory) and the DNS surface `libcluster` queries (for peer discovery).

**Tech Stack:** Elixir, `:ra` 2.15.4 (data-dir override only, no new API surface), `libcluster` ~> 3.3 (new dependency), OTP 25's `:peer` module (test-only), Kubernetes (`StatefulSet`, headless `Service`).

**Spec:** `docs/superpowers/specs/2026-08-24-phase-3b-multi-node-connectivity-design.md`

## Global Constraints

- `:ra`'s data directory is overridden via `ra_system:default_config() |> Map.put(:data_dir, dir) |> Map.put(:wal_data_dir, dir)` passed to `ra_system:start/1` — NOT `ra_system:start_default/0` or `ra:start_in/1`, both of which still re-derive the directory through `node()` regardless of any app-env override (confirmed against the vendored `:ra` 2.15.4 source).
- `dir` is derived from `System.get_env("HOSTNAME", "nonode")`, joined onto the existing `Application.get_env(:ra, :data_dir, cwd)` base (already set via `RIPTIDE_RA_DATA_DIR` in `config/runtime.exs` — this plan adds a layer under that existing base, it does not replace it).
- `libcluster` topologies are configured ONLY when `POD_IP` is present in the environment (set exclusively by the `k8s/statefulset.yaml` pod spec's Downward API wiring) — everywhere else (local dev, `docker-compose`, tests, `Dockerfile`'s own defaults) this stays inert.
- `RELEASE_DISTRIBUTION=none` remains the `Dockerfile`'s own baked default; the `k8s/statefulset.yaml` manifest overrides it via `rel/env.sh.eex`, not by changing the `Dockerfile`.
- No RBAC/`ServiceAccount` changes — `Cluster.Strategy.Kubernetes.DNS` only performs DNS lookups, never touches the Kubernetes API.
- `k8s/` manifests live in the Riptide repo itself (open-source, reusable by any operator), not a private infra repo.
- No real multi-member Ra clusters, sharding, or rebalancing in this phase — Phase 3c/3d.

---

### Task 1: `:ra`'s data-directory decoupling

**Files:**
- Modify: `lib/riptide/ra_cluster.ex`
- Modify: `test/riptide/ra_cluster_test.exs`
- Create: `test/riptide/ra_cluster_data_dir_test.exs`

**Interfaces:**
- Consumes: nothing new.
- Produces: `RaCluster.data_dir/0 :: String.t()` — a new public function. Task 2's local proof test calls this indirectly (via each peer's own `:ra_system.fetch(:default)` after starting a stream there) to confirm per-node isolation.

- [ ] **Step 1: Write the failing tests**

Create `test/riptide/ra_cluster_data_dir_test.exs` (separate file, `async: false`, since it mutates the process-wide `HOSTNAME` OS environment variable — the existing `ra_cluster_test.exs` is `async: true` and must not race against env-var mutation):

```elixir
defmodule Riptide.RaClusterDataDirTest do
  use ExUnit.Case, async: false

  alias Riptide.RaCluster

  test "data_dir/0 derives the directory name from HOSTNAME" do
    original = System.get_env("HOSTNAME")
    System.put_env("HOSTNAME", "riptide-2")

    try do
      assert Path.basename(RaCluster.data_dir()) == "riptide-2"
    after
      if original, do: System.put_env("HOSTNAME", original), else: System.delete_env("HOSTNAME")
    end
  end

  test "data_dir/0 falls back to \"nonode\" when HOSTNAME is unset" do
    original = System.get_env("HOSTNAME")
    System.delete_env("HOSTNAME")

    try do
      assert Path.basename(RaCluster.data_dir()) == "nonode"
    after
      if original, do: System.put_env("HOSTNAME", original)
    end
  end
end
```

Add to `test/riptide/ra_cluster_test.exs` (existing `async: true` file — this test does NOT mutate `HOSTNAME`, only reads it, so it's safe here; add inside the existing `describe`-less module body, using the existing `setup` block's `stream_id`):

```elixir
  test "the started Ra system's data_dir and wal_data_dir are HOSTNAME-derived, not node()-derived",
       %{stream_id: stream_id} do
    machine = {:module, EchoMachine, %{}}
    RaCluster.start_or_restart(stream_id, machine)

    config = :ra_system.fetch(:default)
    expected = RaCluster.data_dir()

    assert config.data_dir == expected
    assert config.wal_data_dir == expected
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/riptide/ra_cluster_data_dir_test.exs test/riptide/ra_cluster_test.exs`
Expected: FAIL — `RaCluster.data_dir/0 is undefined or private`

- [ ] **Step 3: Implement the data-directory override**

In `lib/riptide/ra_cluster.ex`, replace the `ensure_system_started/0` function:

```elixir
  @spec ensure_system_started() :: :ok
  defp ensure_system_started do
    dir = data_dir()

    config =
      :ra_system.default_config()
      |> Map.put(:data_dir, dir)
      |> Map.put(:wal_data_dir, dir)

    case :ra_system.start(config) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> raise "Failed to start the default Ra system: #{inspect(reason)}"
    end
  end

  # Stable across pod restarts/rescheduling even though Erlang distribution identity
  # (node()) is now IP-based and NOT stable — see Phase 3b design spec §1/§3.
  # Kubernetes sets a StatefulSet pod's HOSTNAME to its stable pod name (e.g.
  # "riptide-0"); outside Kubernetes (local dev, docker-compose, tests) HOSTNAME
  # still resolves to something stable per-container/per-host, so this doesn't
  # regress non-clustered environments. Both `data_dir` and `wal_data_dir` are
  # pinned here — `:ra`'s own `default_config/0` would otherwise leave
  # `wal_data_dir` defaulted to the OLD node()-derived directory
  # (`ra_system.erl`'s `WalDataDir = application:get_env(ra, wal_data_dir,
  # DataDir)`), silently splitting a stream's WAL from the rest of its data
  # across two different, inconsistently-keyed directories.
  #
  # `to_string/1` on the configured base handles both shapes `:ra, :data_dir`
  # can arrive in: a plain binary (the `File.cwd!()` fallback) or a charlist
  # (config/runtime.exs stores `RIPTIDE_RA_DATA_DIR` as a charlist, since it's
  # passed straight into Erlang code that expects `file:filename()`) — `Path.join/2`
  # raises on a charlist, unlike Erlang's more permissive `filename:join/2`.
  @spec data_dir() :: String.t()
  def data_dir do
    base = Application.get_env(:ra, :data_dir, File.cwd!()) |> to_string()
    Path.join(base, System.get_env("HOSTNAME", "nonode"))
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/riptide/ra_cluster_data_dir_test.exs test/riptide/ra_cluster_test.exs`
Expected: PASS (all tests in both files)

- [ ] **Step 5: Run the full test suite to confirm no regression**

Run: `mix test`
Expected: PASS, 0 failures. This is the first change to `ensure_system_started/0` since it was written — confirm every other Ra-touching test (cold-restart, issue #8, retention/compaction) still passes with the new config-map-based start path.

- [ ] **Step 6: Commit**

```bash
git add lib/riptide/ra_cluster.ex test/riptide/ra_cluster_test.exs test/riptide/ra_cluster_data_dir_test.exs
git commit -m "Decouple Ra's data directory from node() via an explicit ra_system config"
```

---

### Task 2: Local multi-node connectivity + data-directory proof test

**Files:**
- Create: `test/riptide/multi_node_connectivity_test.exs`

**Interfaces:**
- Consumes: `RaCluster.start_or_restart/2` (Task 1, unchanged signature, called on each peer) — validates the resulting Ra system config (which Task 1's `data_dir/0` override determines) directly via `:ra_system.fetch/1`, comparing against each peer's own known `HOSTNAME`. `Riptide.Test.EchoMachine` (existing test-support module, `test/support/echo_machine.ex`).
- Produces: nothing consumed elsewhere — this task's deliverable is the passing test itself, as evidence Task 1's data-dir override holds under real distributed-Erlang node identities, not just in a single-node test process.

**Context this task's implementer needs, verified empirically against this exact codebase before writing this plan (do not re-derive from general OTP knowledge — this environment has real gotchas):**
- `epmd` (Erlang Port Mapper Daemon) registers nodes by **alive-name only** (the part before `@`), shared across every node running on this one machine — NOT by the full `name@host`. Three simulated peers all named `riptide` (even bound to different loopback IPs like `127.0.0.1`/`127.0.0.2`/`127.0.0.3`) collide on this box's single shared `epmd` and time out starting the second one. In real Kubernetes each pod has its *own* `epmd`, so this collision cannot happen there — it's a local-simulation-only artifact. Use distinct alive-names locally (`riptide0`, `riptide1`, `riptide2`), all on `127.0.0.1`.
- `:peer.call/4` returned `{:error, :noconnection}` in this environment even for a successfully-started, reachable peer. Use `:erpc.call/4` instead (standard distributed-Erlang RPC) — verified working reliably here.
- `:peer.start_link/1`'s `args` option needs each flag/value as a **separate charlist** element (e.g. `[~c"-pa", ~c"/some/path"]`, not a joined string) — passing binaries raises `{:invalid_arg, "-pa"}`.
- Peers do **not** auto-connect to each other (only to the node that spawned them) — connect every pair explicitly via `:net_kernel.connect_node/1`, mirroring what `libcluster`'s discovery strategy does for real peers in production.
- Passing the *full*, unfiltered `:code.get_path()` as `-pa` args (not a hand-filtered subset) is what makes the compiled `Riptide.*` and `Riptide.Test.*` modules callable on a peer — confirmed working end-to-end, including calling `Riptide.RaCluster.uid_for/1` remotely via `:erpc.call/4`.
- `:peer.start_link/1`'s `env` option (`env: [{~c"HOSTNAME", to_charlist(value)}]`) sets an OS environment variable in the spawned peer's own process — confirmed each peer can read back its own distinct `HOSTNAME` via `System.get_env/1`.
- The origin (test-runner) node must be distributed before spawning named peers — `Node.start(:"some_name@127.0.0.1", :longnames)` if `Node.alive?()` is false.
- Each peer also needs `:ra`'s OTP application actually started (not just its code loadable) before `RaCluster.start_or_restart/2` will work there, since that function starts a supervision subtree (`ra_systems_sup`) that lives inside `:ra`'s own application supervisor — call `Application.ensure_all_started(:ra)` on each peer first.

- [ ] **Step 1: Write the test**

Create `test/riptide/multi_node_connectivity_test.exs`:

```elixir
defmodule Riptide.MultiNodeConnectivityTest do
  use ExUnit.Case, async: false

  @moduletag timeout: 60_000

  @peers [{:riptide0, "riptide-0"}, {:riptide1, "riptide-1"}, {:riptide2, "riptide-2"}]

  setup_all do
    unless Node.alive?() do
      {:ok, _pid} = Node.start(:"multi_node_connectivity_origin@127.0.0.1", :longnames)
    end

    :ok
  end

  test "N real distributed Erlang nodes connect and stay connected, each with its own HOSTNAME-derived Ra data directory" do
    pa_args = Enum.flat_map(:code.get_path(), fn p -> [~c"-pa", p] end)

    peers =
      for {alive_name, hostname} <- @peers do
        {:ok, pid, node} =
          :peer.start_link(%{
            name: alive_name,
            host: ~c"127.0.0.1",
            longnames: true,
            args: pa_args,
            env: [{~c"HOSTNAME", to_charlist(hostname)}]
          })

        {pid, node, hostname}
      end

    on_exit(fn -> Enum.each(peers, fn {pid, _node, _hostname} -> :peer.stop(pid) end) end)

    nodes = Enum.map(peers, fn {_pid, node, _hostname} -> node end)

    # Peers don't auto-connect to each other — connect every pair explicitly,
    # mirroring what libcluster's discovery strategy does in production.
    for {n1, n2} <- unique_pairs(nodes) do
      assert :erpc.call(n1, :net_kernel, :connect_node, [n2]) == true
    end

    # Real connectivity, not just a one-shot connect: poll several times.
    for _ <- 1..5 do
      for {_pid, node, _hostname} <- peers do
        seen = node |> then(&:erpc.call(&1, Node, :list, [])) |> MapSet.new()
        expected = nodes |> List.delete(node) |> MapSet.new()
        assert MapSet.subset?(expected, seen)
      end

      Process.sleep(100)
    end

    # :ra's data-directory decoupling (Task 1) holds under real distributed node
    # identities: each peer's own Ra system uses its own HOSTNAME-derived
    # directory, isolated from the others' — even though all three are now real,
    # independently-addressable Erlang nodes rather than one test process.
    stream_id = "multi-node-test-" <> Uniq.UUID.uuid4()

    for {_pid, node, hostname} <- peers do
      {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:ra])

      :erpc.call(node, Riptide.RaCluster, :start_or_restart, [
        stream_id,
        {:module, Riptide.Test.EchoMachine, %{}}
      ])

      config = :erpc.call(node, :ra_system, :fetch, [:default])

      assert Path.basename(config.data_dir) == hostname
      assert Path.basename(config.wal_data_dir) == hostname
    end
  end

  defp unique_pairs(list) do
    for {a, i} <- Enum.with_index(list),
        {b, j} <- Enum.with_index(list),
        i < j,
        do: {a, b}
  end
end
```

- [ ] **Step 2: Run the test**

Run: `mix test test/riptide/multi_node_connectivity_test.exs --trace`
Expected: PASS. If it fails, check against the verified gotchas listed above before assuming the test's approach is wrong — every one of them was hit and resolved empirically while designing this plan. If a *new* failure mode shows up (e.g. `:ra` not starting cleanly on a peer, a timing-sensitive `Node.list()` assertion), treat it as real signal about Task 1's implementation or this test's polling window, not as a reason to weaken the assertions.

- [ ] **Step 3: Run the full test suite to confirm no regression**

Run: `mix test`
Expected: PASS, 0 failures. This test spawns real OS-level BEAM processes — confirm it doesn't leave orphaned peer processes behind (check `ps aux | grep beam` shows nothing new lingering after the run) and doesn't destabilize other tests run in the same suite.

- [ ] **Step 4: Commit**

```bash
git add test/riptide/multi_node_connectivity_test.exs
git commit -m "Add local multi-node connectivity + data-directory isolation proof test"
```

---

### Task 3: Distributed Erlang identity & libcluster wiring

**Files:**
- Modify: `mix.exs`
- Modify: `config/runtime.exs`
- Modify: `lib/riptide/application.ex`
- Create: `rel/env.sh.eex`
- Create: `test/riptide/application_test.exs`

**Interfaces:**
- Consumes: nothing from Task 1/2 — this task is independent code (release config + supervision tree), though it composes with Task 1 in production (both activate together under real Kubernetes deployment).
- Produces: `Riptide.ClusterSupervisor` (a named process in the supervision tree) — nothing else in this plan consumes it directly; it exists for `libcluster` itself to manage.

- [ ] **Step 1: Write the failing test**

Create `test/riptide/application_test.exs`:

```elixir
defmodule Riptide.ApplicationTest do
  use ExUnit.Case, async: true

  test "Riptide.ClusterSupervisor starts as part of the application" do
    assert Process.whereis(Riptide.ClusterSupervisor) |> is_pid()
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/riptide/application_test.exs`
Expected: FAIL — `Process.whereis(Riptide.ClusterSupervisor)` returns `nil`, so `is_pid(nil)` fails

- [ ] **Step 3: Add the `libcluster` dependency**

In `mix.exs`, add to the `deps/0` list (after `{:ra, "~> 2.15.0"}`):

```elixir
      {:libcluster, "~> 3.3"},
```

Run: `mix deps.get`

- [ ] **Step 4: Wire `Cluster.Supervisor` into the application's supervision tree**

In `lib/riptide/application.ex`, replace the `children` list:

```elixir
    children = [
      {Phoenix.PubSub, name: Riptide.PubSub},
      {Cluster.Supervisor,
       [Application.get_env(:libcluster, :topologies, []), [name: Riptide.ClusterSupervisor]]},
      # Start a worker by calling: Riptide.Worker.start_link(arg)
      # {Riptide.Worker, arg},
      # Start to serve requests, typically the last entry
      RiptideWeb.Endpoint
    ]
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `mix test test/riptide/application_test.exs`
Expected: PASS

- [ ] **Step 6: Add the Kubernetes-only `libcluster` topology config**

In `config/runtime.exs`, add (after the existing `:ra, :data_dir` block, before the `if config_env() == :prod do` block):

```elixir
# Only present when the k8s/statefulset.yaml pod spec's Downward API sets it —
# everywhere else (local dev, docker-compose, tests) libcluster stays configured
# with an empty topology list, making Cluster.Supervisor an inert no-op (see
# Riptide.Application). See Phase 3b design spec §4.
if System.get_env("POD_IP") do
  config :libcluster,
    topologies: [
      riptide: [
        strategy: Cluster.Strategy.Kubernetes.DNS,
        config: [
          service: System.get_env("RIPTIDE_HEADLESS_SERVICE", "riptide-headless"),
          application_name: "riptide",
          polling_interval: 5_000
        ]
      ]
    ]
end
```

- [ ] **Step 7: Add the release boot script for distribution identity**

Create `rel/env.sh.eex`:

```bash
#!/bin/sh

# Only overrides the Dockerfile's baked-in RELEASE_DISTRIBUTION=none when POD_IP
# is present — i.e. only under the k8s/statefulset.yaml deployment path. Local
# dev and docker-compose are untouched. See Phase 3b design spec §4.
if [ -n "$POD_IP" ]; then
  export RELEASE_DISTRIBUTION="name"
  export RELEASE_NODE="riptide@${POD_IP}"
fi
```

- [ ] **Step 8: Run the full test suite to confirm no regression**

Run: `mix test`
Expected: PASS, 0 failures. `POD_IP` is unset in the test environment, so both the `config/runtime.exs` gate and `rel/env.sh.eex` (which only applies to actual `mix release` builds, not `mix test`) stay inert.

- [ ] **Step 9: Build a release locally to confirm `rel/env.sh.eex` is picked up and the app still boots**

Run: `MIX_ENV=prod mix release --overwrite`
Expected: release builds successfully, output confirms `rel/env.sh.eex` was included (check `_build/prod/rel/riptide/releases/0.1.0/env.sh` exists and matches the source file).

Run: `SECRET_KEY_BASE=$(mix phx.gen.secret) PHX_SERVER=true _build/prod/rel/riptide/bin/riptide eval "IO.puts(Node.self())"`
Expected: prints `nonode@nohost` (since `POD_IP` isn't set here) — confirms the boot script's conditional correctly leaves the non-Kubernetes path unchanged.

- [ ] **Step 10: Commit**

```bash
git add mix.exs mix.lock config/runtime.exs lib/riptide/application.ex rel/env.sh.eex test/riptide/application_test.exs
git commit -m "Wire libcluster + Kubernetes-conditional distributed Erlang identity"
```

---

### Task 4: Kubernetes manifests

**Files:**
- Create: `k8s/statefulset.yaml`
- Create: `k8s/headless-service.yaml`
- Create: `k8s/service.yaml`
- Create: `k8s/secret.example.yaml`
- Create: `k8s/README.md`

**Interfaces:**
- Consumes: `POD_IP`/`RELEASE_DISTRIBUTION`/`RELEASE_NODE` wiring from Task 3's `rel/env.sh.eex`; `RIPTIDE_HEADLESS_SERVICE`/service-name conventions from Task 3's `config/runtime.exs`.
- Produces: the manifest set Task 5's live proof deploys verbatim.

- [ ] **Step 1: Write the headless Service**

Create `k8s/headless-service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: riptide-headless
  labels:
    app: riptide
spec:
  clusterIP: None
  selector:
    app: riptide
  ports:
    - name: http
      port: 4000
      targetPort: 4000
```

- [ ] **Step 2: Write the client-facing Service**

Create `k8s/service.yaml`:

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

- [ ] **Step 3: Write the Secret template**

Create `k8s/secret.example.yaml`:

```yaml
# Copy to secret.yaml (git-ignored — never commit real values), fill in real
# values, then `kubectl apply -f secret.yaml`.
#
# RELEASE_COOKIE: any random string, e.g. `openssl rand -base64 48`. Must be
# identical across every pod in the StatefulSet — distributed Erlang nodes
# only trust peers presenting the same cookie.
# SECRET_KEY_BASE: `mix phx.gen.secret` (run from a Riptide checkout).
apiVersion: v1
kind: Secret
metadata:
  name: riptide-secrets
type: Opaque
stringData:
  RELEASE_COOKIE: "REPLACE_ME"
  SECRET_KEY_BASE: "REPLACE_ME"
```

- [ ] **Step 4: Write the StatefulSet**

Create `k8s/statefulset.yaml`:

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: riptide
  labels:
    app: riptide
spec:
  serviceName: riptide-headless
  replicas: 3
  selector:
    matchLabels:
      app: riptide
  template:
    metadata:
      labels:
        app: riptide
    spec:
      containers:
        - name: riptide
          image: ghcr.io/openfaster-standard/riptide:latest
          ports:
            - name: http
              containerPort: 4000
          env:
            - name: POD_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.podIP
            - name: PHX_SERVER
              value: "true"
            - name: PHX_HOST
              value: "riptide-headless"
            - name: RELEASE_COOKIE
              valueFrom:
                secretKeyRef:
                  name: riptide-secrets
                  key: RELEASE_COOKIE
            - name: SECRET_KEY_BASE
              valueFrom:
                secretKeyRef:
                  name: riptide-secrets
                  key: SECRET_KEY_BASE
          volumeMounts:
            - name: data
              mountPath: /data
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
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 1Gi
```

- [ ] **Step 5: Write the deployment README**

Create `k8s/README.md`:

```markdown
# Deploying Riptide to Kubernetes

Phase 3b's multi-node connectivity manifests: a 3-replica `StatefulSet`, a headless
`Service` for peer discovery, a regular `Service` for client traffic, and a `Secret`
template.

## Deploy

1. Copy the secret template and fill in real values:

   ```bash
   cp secret.example.yaml secret.yaml
   # RELEASE_COOKIE: openssl rand -base64 48
   # SECRET_KEY_BASE: mix phx.gen.secret (run from a Riptide checkout)
   ```

2. Apply everything:

   ```bash
   kubectl apply -f secret.yaml
   kubectl apply -f headless-service.yaml
   kubectl apply -f service.yaml
   kubectl apply -f statefulset.yaml
   ```

3. Wait for all 3 pods to become ready:

   ```bash
   kubectl rollout status statefulset/riptide
   ```

## Verify nodes are connected

```bash
kubectl exec -it riptide-0 -- bin/riptide remote
```

Then, in the remote IEx shell:

```elixir
Node.list()
# => [:"riptide@10.x.x.x", :"riptide@10.x.x.x"]  (the other two pods' IPs)
```

Repeat against `riptide-1`/`riptide-2` to confirm all three see the other two.

## Teardown

```bash
kubectl delete -f statefulset.yaml -f service.yaml -f headless-service.yaml -f secret.yaml
```

`secret.yaml` is git-ignored (see the repo's `.gitignore`) — never commit real
`RELEASE_COOKIE`/`SECRET_KEY_BASE` values.
```

- [ ] **Step 6: Add `k8s/secret.yaml` to `.gitignore`**

Add to `.gitignore` (create the file if it doesn't already have a `k8s/` section):

```
k8s/secret.yaml
```

- [ ] **Step 7: Validate the manifests against a real Kubernetes API (dry-run, no changes applied)**

Run: `kubectl apply --dry-run=server -f k8s/headless-service.yaml -f k8s/service.yaml -f k8s/statefulset.yaml`
Expected: all three resources pass server-side validation (no output other than each resource name suffixed `(dry run)`), confirming the YAML is well-formed and schema-valid against a real cluster's API before Task 5's actual live deployment. (`k8s/secret.example.yaml` is a template, not meant to be applied directly — skip it here.)

- [ ] **Step 8: Commit**

```bash
git add k8s/ .gitignore
git commit -m "Add Kubernetes manifests for Phase 3b's multi-node connectivity proof"
```

---

### Task 5: Live GKE proof

**Files:**
- No new files — this task operates against the real cluster using Task 4's manifests verbatim.

**Interfaces:**
- Consumes: `k8s/*.yaml` (Task 4), the built Docker image (existing CI/CD pipeline from sub-project 2).
- Produces: a written verification record (this task's own report, once executed) — no code.

- [ ] **Step 1: Build and push a fresh image**

Confirm the current `main`/branch HEAD's image is available at `ghcr.io/openfaster-standard/riptide:latest` (or build/push one via the existing CI/CD pipeline from sub-project 2 if the latest commit isn't built yet). Do not hand-build a one-off image — use the same pipeline every other deployment goes through, so this proof validates the real artifact.

- [ ] **Step 2: Create a disposable namespace**

```bash
kubectl create namespace riptide-phase-3b-proof
kubectl config set-context --current --namespace=riptide-phase-3b-proof
```

- [ ] **Step 3: Deploy**

Follow `k8s/README.md`'s Deploy steps exactly (generate a real cookie + secret key base, `kubectl apply` all four manifests in the documented order) against this namespace.

Run: `kubectl rollout status statefulset/riptide --timeout=120s`
Expected: all 3 pods reach `Ready`.

- [ ] **Step 4: Verify all 3 pods see each other**

For each of `riptide-0`, `riptide-1`, `riptide-2`:

```bash
kubectl exec riptide-<N> -- bin/riptide rpc "IO.inspect(Node.list())"
```

Expected: each pod's output lists the other two pods' `riptide@<pod-ip>` node names — 3 pods, each seeing exactly 2 others.

- [ ] **Step 5: Verify survival across a pod kill/reschedule**

```bash
kubectl delete pod riptide-1
kubectl rollout status statefulset/riptide --timeout=120s
```

Wait for `riptide-1` to come back up, then re-run Step 4's check on all 3 pods again. Expected: connectivity re-establishes — every pod again sees the other two, including the recreated `riptide-1` (now with a new `POD_IP`, since pod IPs are not stable across recreation — confirming `libcluster`'s DNS-based re-discovery, not a one-time static connection, is what's actually keeping the cluster connected).

- [ ] **Step 6: Verify `:ra` data-directory stability across that same pod recreation**

Before Step 5's delete, note `riptide-1`'s `:ra` data directory:

```bash
kubectl exec riptide-1 -- bin/riptide rpc "IO.inspect(Riptide.RaCluster.data_dir())"
```

After Step 5's pod comes back, re-run the same command against the recreated `riptide-1`. Expected: identical directory path both times (derived from the stable `HOSTNAME=riptide-1`, unaffected by the pod's new IP) — confirming the PVC (bound to the StatefulSet ordinal, not the pod's ephemeral identity) and Ra's on-disk data survived the recreation.

- [ ] **Step 7: Tear down**

```bash
kubectl delete namespace riptide-phase-3b-proof
kubectl config set-context --current --namespace=default
```

Confirm deletion completed: `kubectl get namespace riptide-phase-3b-proof` returns `NotFound` (poll if needed — namespace deletion is asynchronous).

- [ ] **Step 8: Record the results**

Write a short summary (for Task 6's PROGRESS.md update and the eventual PR description) of what was directly observed at each step above — the actual `Node.list()` output, the actual data-directory paths before/after recreation, and the rollout timings. This is the phase's real "prove it" evidence; a claim of success without this record doesn't count as verification.

---

### Task 6: Full verification + PROGRESS.md + wrap-up

**Files:**
- Modify: `PROGRESS.md`
- No new source files.

**Interfaces:**
- Consumes: everything from Tasks 1-5, including Task 5's recorded live-proof results.
- Produces: nothing further downstream — terminal task.

- [ ] **Step 1: Run the full test suite**

Run: `mix test`
Expected: PASS, 0 failures — including Task 1's new tests, Task 2's multi-node connectivity test, Task 3's application test, and every pre-existing test (issue #6, issue #8, Phase 3a's encode/decode tests) unaffected.

- [ ] **Step 2: Run Credo and formatter checks**

Run: `mix credo --strict && mix format --check-formatted`
Expected: both clean. Fix anything flagged and re-run.

- [ ] **Step 3: Update `PROGRESS.md`**

In the `## 3. Clustering / horizontal scale / HA — decomposed into phases` section, change the Phase 3b bullet's trailing `**Not yet designed.**` to:

```markdown
  other. Foundational for 3c/3d, testable in isolation. **Shipped 2026-08-24** — see
  `docs/superpowers/specs/2026-08-24-phase-3b-multi-node-connectivity-design.md`.
```

Change the `**Status**:` line from:

```markdown
**Status**: Phase 3a shipped. Phase 3b (real multi-node connectivity) not yet started.
```

to:

```markdown
**Status**: Phases 3a-3b shipped. Phase 3c (sharded per-stream placement + real
multi-member Ra clusters) not yet started.
```

- [ ] **Step 4: Commit**

```bash
git add PROGRESS.md
git commit -m "Mark Phase 3b shipped in PROGRESS.md"
```

- [ ] **Step 5: Push and open a PR**

```bash
git push -u origin <branch-name>
gh pr create --title "Phase 3b: real multi-node connectivity" --body "$(cat <<'EOF'
## Summary
- Implements the Phase 3b design spec (docs/superpowers/specs/2026-08-24-phase-3b-multi-node-connectivity-design.md).
- Decouples :ra's on-disk data directory from Erlang distribution identity via an explicit ra_system:start/1 config override keyed on HOSTNAME (RaCluster.data_dir/0).
- Adds libcluster + Cluster.Strategy.Kubernetes.DNS, gated on POD_IP so it's inert outside Kubernetes.
- Adds k8s/ manifests (StatefulSet, headless Service, client Service, Secret template) as reusable deployment artifacts.
- Includes [Task 5's live-proof results here — paste the recorded observations].

## Test plan
- [x] mix test — full suite passes, including the new local multi-node connectivity/data-directory test and every pre-existing regression test
- [x] mix credo --strict
- [x] mix format --check-formatted
- [x] Live GKE proof: 3 pods connected via libcluster's Kubernetes.DNS discovery, survived a pod kill/reschedule, :ra data directory stable across that recreation (see Task 5's recorded results)
EOF
)"
```

Report the PR URL and stop — do not merge without explicit human sign-off (ask via AskUserQuestion), matching this project's established practice for every prior PR this session.
