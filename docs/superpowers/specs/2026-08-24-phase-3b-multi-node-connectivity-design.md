# Phase 3b — Real Multi-Node Connectivity — Design

**Status:** Approved 2026-08-24.

Sub-project 3 (Clustering / horizontal scale / HA) is decomposed into four phases (see
`PROGRESS.md`, § "3. Clustering / horizontal scale / HA"). Phase 3a (schema-versioning envelope)
shipped 2026-08-24. This is Phase 3b: re-enable real distributed Erlang, solve the stable-node-
identity problem for real, wire up Kubernetes-based peer discovery, and prove N nodes actually
connect and stay connected. Foundational for Phase 3c (sharded per-stream placement + real
multi-member Ra clusters) and Phase 3d (HA proof + operator tooling) — testable in isolation from
both, since this phase creates no multi-member Ra clusters itself.

## 1. Context and motivation

Riptide currently runs with `RELEASE_DISTRIBUTION=none` (`Dockerfile:64`), which fixes `node()`
to the constant `nonode@nohost` on every boot. The Dockerfile's own comment explains why: `:ra`
namespaces its on-disk data under a per-node subdirectory keyed by `node()`
(`ra_env:data_dir/0`, confirmed in `deps/ra/src/ra_env.erl:18-27` — `node()` is unconditionally
appended as the final path segment, with no override at the application-env level). Since `mix
release`'s default `sname` distribution derives the node name from the container's hostname,
and a Kubernetes pod's hostname changes on every recreation, real distributed Erlang would have
silently broken `:ra`'s durability guarantee for a recreated pod — until now, disabling
distribution entirely was the simplest way to sidestep that.

Re-enabling distributed Erlang for real surfaces the same tension in a different form:
Kubernetes pod IPs are not stable across restarts even for `StatefulSet` pods (only the pod's
*DNS hostname* is stable — its IP is reassigned by the CNI on every recreation). `libcluster`'s
`Cluster.Strategy.Kubernetes.DNS` strategy — the natural fit for Kubernetes-based discovery,
confirmed against its real hexdocs page — connects peers using `<application_name>@<resolved-
pod-IP>`, i.e. it needs each node's own distribution identity (`RELEASE_NODE`) to be IP-based to
be reachable. So a stable, FQDN-based `RELEASE_NODE` (the first, rejected approach explored
during brainstorming — see design history) would not actually work with the standard, documented
discovery strategy without a hand-rolled replacement.

The resolution, verified by reading the vendored `:ra` 2.15.4 source directly rather than
assuming: `:ra`'s node-level data directory *is* overridable, just not through an application-env
knob. `ra_system:start/1` accepts a caller-constructed config map with its own `data_dir` key
(`ra_system.erl:32-34`, the `config()` type) and — unlike `ra_system:start_default/0` /
`ra:start_in/1`, both of which still re-derive the directory through `ra_env:data_dir/0` and
append `node()` regardless — `ra_system:start/1` hands that `data_dir` straight through to
`ra_systems_sup:start_system/1` (`ra_systems_sup.erl:26-35`) with no `node()` involvement
anywhere downstream. This is a system-level analog to the per-*stream* directory override
`Riptide.RaCluster` already performs via `log_init_args: %{uid: uid}`
(`ra_cluster.ex:57-64`) — the same pattern, one level up the stack.

That decoupling is what makes this phase's design possible: Erlang distribution identity
(`RELEASE_NODE`) can be IP-based, satisfying `libcluster`'s discovery mechanism, while `:ra`'s
on-disk data directory is pinned to something else entirely — a Kubernetes `StatefulSet` pod's
stable ordinal hostname — so durability no longer depends on distribution identity being stable
at all.

## 2. Kubernetes topology

A `StatefulSet` named `riptide`, 3 replicas (matching the replication factor anticipated for
Phase 3c's sharded Ra clusters — this phase does not create multi-member Ra clusters itself, just
proves connectivity at that scale), plus a headless `Service` (`clusterIP: None`) named
`riptide-headless` fronting it — this is what gives each pod its stable ordinal identity
(`riptide-0`, `riptide-1`, `riptide-2`) and, via `volumeClaimTemplates`, a persistent volume that
follows that ordinal across restarts and rescheduling. A separate, regular `Service` (`ClusterIP`)
remains the actual client-facing entry point for HTTP/SSE traffic — unrelated to clustering,
unchanged in shape from what a single-node deployment would use.

## 3. `:ra`'s data-directory decoupling

`Riptide.RaCluster.ensure_system_started/0` (currently `ra_cluster.ex:167-174`) changes from
calling `:ra_system.start_default/0` to constructing its own config and calling
`:ra_system.start/1`:

```elixir
defp ensure_system_started do
  config =
    :ra_system.default_config()
    |> Map.put(:data_dir, data_dir())

  case :ra_system.start(config) do
    {:ok, _pid} -> :ok
    {:ok, _pid, _info} -> :ok
    {:error, {:already_started, _pid}} -> :ok
    {:error, reason} -> raise "Failed to start the default Ra system: #{inspect(reason)}"
  end
end

# Stable across pod restarts/rescheduling even though Erlang distribution identity
# (node()) is now IP-based and NOT stable — see Phase 3b design spec §1/§3. Kubernetes
# sets a StatefulSet pod's HOSTNAME to its stable pod name (e.g. "riptide-0"); outside
# Kubernetes (local dev, docker-compose, tests) HOSTNAME still resolves to something
# stable per-container/per-host, so this doesn't regress non-clustered environments.
defp data_dir do
  {:ok, cwd} = File.cwd()
  base = Application.get_env(:ra, :data_dir, cwd)
  Path.join(base, System.get_env("HOSTNAME", "nonode"))
end
```

(Exact `ra_system.default_config()` field shape and any additional required keys confirmed
against the pinned `:ra` version during implementation — same verify-against-live-source
discipline used throughout this project's `:ra` integration work.)

## 4. Distributed Erlang identity & `libcluster`

- `RELEASE_DISTRIBUTION=name` (long names — required since the node name will contain dots)
  replaces the current `RELEASE_DISTRIBUTION=none` in the `k8s/` deployment path. `Dockerfile`'s
  own default stays `RELEASE_DISTRIBUTION=none` for the single-node/`docker-compose` path (see
  §7) — the `StatefulSet` manifest overrides it via its pod spec's `env`.
- `RELEASE_NODE=riptide@${POD_IP}`, computed in a new `rel/env.sh.eex` release boot script from a
  `POD_IP` environment variable populated via the Kubernetes Downward API (`status.podIP`) in the
  `StatefulSet`'s pod spec.
- `RELEASE_COOKIE` supplied via a Kubernetes `Secret` (generated once operator-side; the same
  value mounted into every pod). `k8s/secret.example.yaml` ships as a template — the real value
  is never committed.
- New dependency `{:libcluster, "~> 3.3"}` (exact version confirmed against hex at
  implementation time). Configuration:

  ```elixir
  config :libcluster,
    topologies: [
      riptide: [
        strategy: Cluster.Strategy.Kubernetes.DNS,
        config: [
          service: "riptide-headless",
          application_name: "riptide",
          polling_interval: 5_000
        ]
      ]
    ]
  ```

- `Riptide.Application`'s supervision tree gains
  `{Cluster.Supervisor, [Application.get_env(:libcluster, :topologies, []), [name:
  Riptide.ClusterSupervisor]]}`. Outside Kubernetes, `:libcluster, :topologies` is simply unset
  (defaults to `[]`), so `Cluster.Supervisor` starts with nothing to do — local dev,
  `docker-compose`, and the test suite are all unaffected by this addition.
- No RBAC/`ServiceAccount` changes needed: `Cluster.Strategy.Kubernetes.DNS` only performs DNS
  lookups against the headless `Service` — unlike an API-watch-based libcluster strategy, it
  never touches the Kubernetes API, keeping this phase's security footprint minimal.

## 5. Testing / proof strategy

`Cluster.Strategy.Kubernetes.DNS` fundamentally cannot be exercised outside real Kubernetes DNS,
so this phase proves two different things at two different levels:

- **Local automated test** (ExUnit, using OTP 25's `:peer` module to spawn several real, separate
  Erlang nodes in-process — already available, since the `Dockerfile`'s builder targets
  Erlang/OTP 25): connects N nodes directly via `Node.connect/1` (bypassing `libcluster`'s
  Kubernetes-specific discovery, which isn't what's under test here) and proves (a) real
  distributed-Erlang connectivity holds across a polling window, not just a one-shot connect, and
  (b) `:ra`'s new `HOSTNAME`-derived data-directory override correctly isolates each node's
  on-disk data under IP-shaped node names — the actual correctness-sensitive part of this phase,
  and the part a live cluster can't cheaply regression-test on every CI run.
- **Live GKE proof** (manual, using this box's live cluster access): deploy the real `k8s/`
  manifests (not a hand-rolled equivalent) to a new, disposable namespace, confirm all 3 pods'
  `Node.list()` (via a remote shell / `:erpc`) shows the other two, confirm
  `Cluster.Strategy.Kubernetes.DNS` discovery specifically works end-to-end (the one thing the
  local test can't cover), and confirm survival across killing and rescheduling one pod. This is
  the phase's actual "prove it" deliverable per `PROGRESS.md`'s own wording, and it directly
  validates what ships in the repo rather than a stand-in.

## 6. Manifest location

New `k8s/` directory in the Riptide repo (open-source, reference-implementation project — these
manifests are reusable artifacts for any operator, not this org's private infrastructure):

- `k8s/statefulset.yaml` — the `riptide` `StatefulSet`, including `POD_IP` Downward API wiring,
  `RELEASE_DISTRIBUTION`/`RELEASE_NODE` env, `RELEASE_COOKIE` from the Secret, and
  `volumeClaimTemplates`.
- `k8s/headless-service.yaml` — `riptide-headless`, `clusterIP: None`.
- `k8s/service.yaml` — the regular client-facing `Service`.
- `k8s/secret.example.yaml` — a template for `RELEASE_COOKIE`; not a real secret.
- `k8s/README.md` — how to deploy: generate a real cookie, apply the manifests, verify pods
  connect.

## 7. Out of scope

- Real multi-member Ra clusters — streams still run as single-node Ra clusters, unchanged. Ra
  cluster membership across the now-connected nodes is Phase 3c.
- Sharded/placement logic — Phase 3c.
- Auto-rebalancing or manual grow/shrink tooling — Phase 3d.
- `docker-compose.yml` and the `Dockerfile`'s own default (`RELEASE_DISTRIBUTION=none`) are
  unchanged — the new distributed-Erlang path only activates under the `k8s/` manifests' pod
  spec, which overrides the env var. Local dev stays single-node.
- Migration path for data written under the old `nonode@nohost`-keyed directory — no real
  persisted data exists in any environment yet (confirmed with the operator, same as Phase 3a).
