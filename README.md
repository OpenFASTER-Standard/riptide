# Riptide

Riptide is the reference implementation of **StreamLD**, a clean-slate, professional-grade
standard for real-time-capable Linked Data event streaming — incubating within the
[OpenFASTER](https://openfaster.org) ecosystem.

Riptide is an Elixir/Phoenix server that speaks enough Solid/LDP to act as a usable pod
server, backed natively by a StreamLD event log instead of a request/response pipeline —
an event-driven alternative to [Community Solid Server](https://github.com/CommunitySolidServer/CommunitySolidServer).

Design status: implemented and tested (unit + controller/channel tests passing). See
`docs/superpowers/specs/2026-08-22-streamld-riptide-design.md` for the full design and its
rationale.

The StreamLD specification itself lives in a separate repo:
[`OpenFASTER-Standard/spec`](https://github.com/OpenFASTER-Standard/spec).

## How the pieces fit together

At the core of Riptide is a per-stream, sequence-numbered event log:
`Riptide.Stream.StreamServer` is a thin client (no GenServer of its own) over a single-node
`Ra`-replicated (Raft) cluster, one per stream, dynamically started/restarted on demand via
`Riptide.RaCluster` — the only module that talks to `:ra` directly. Each stream's log is a
`Riptide.Stream.RaMachine`, a pure `:ra_machine` that assigns each appended event the next
sequence number and applies retention trimming, with events committed durably to disk through
Ra's write-ahead log instead of living only in process memory, so a stream survives a crash or
restart with its data and sequence numbers intact. Every append also broadcasts the new event
over `Phoenix.PubSub` on the `"stream:<stream_id>"` topic — this is the internal fan-out
mechanism that both realtime surfaces below subscribe to, decoupling the write path from however
many readers are currently attached.

Riptide exposes that event log through three HTTP/WS surfaces:

- **LDP CRUD** (`RiptideWeb.LDP.ResourceController`) — `GET`/`PUT`/`PATCH`/`DELETE`/`POST` on
  `/resources/*path`. `GET` folds a stream's events into its current RDF graph; `PUT`/`DELETE`
  append snapshot events; `PATCH` appends a delta event from a JSON body's `additions`/
  `removals` Turtle fields; `POST` to a container path creates a child resource and records an
  `ldp:contains` triple back on the container.
- **SSE subscription** (`RiptideWeb.Realtime.SseController`) — `GET
  /streams/:stream_id/subscribe`, with `Last-Event-ID` support for resuming a dropped
  connection. Replies with a backlog of events since the given cursor, then streams further
  `Phoenix.PubSub` broadcasts as they arrive; if the requested cursor has already fallen out of
  the stream's retention window, responds `409` with `{"oldestAvailable": <seq>}` instead.
- **WebSocket replication** (`RiptideWeb.Realtime.ReplicationChannel`) — joins the
  `replication:<stream_id>` topic on the `/replication` socket with an `"after"` cursor,
  analogous to the SSE endpoint but over Phoenix Channels: join replies with a backlog, and
  subsequent events are pushed as `"replication_frame"` messages. A cursor outside the
  retention window is rejected at join time with `{"oldestAvailable": <seq>}`, matching the SSE
  gap-signal shape.

## Running locally for development

`mix phx.server` just works — no `HOSTNAME`, no special config. The placement cluster
self-forms as a single-node cluster automatically (Phase 3e): every node's `Riptide.
PlacementMembership` controller checks for an existing cluster, finds none, and forms one from
whatever's actually connected (just this one process, locally).

```bash
mix deps.get
mix phx.server
```

Wait for `curl http://localhost:4000/health/ready` to return `200` (the placement cluster forms in
the background at boot; this can take a few seconds) before making any LDP request — every read
and write depends on it being ready.

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

## Running via Kubernetes

Example manifests live in `k8s/` — a `StatefulSet` (`k8s/statefulset.yaml`, defaulting to 3
replicas — this is just a starting point now, not a hard requirement; see Phase 3e), a
`ClusterIP` Service for client traffic (`k8s/service.yaml`), a headless Service for internal Ra/
Erlang-distribution peer discovery (`k8s/headless-service.yaml`), and a Secret template for the
two required env vars (`k8s/secret.example.yaml`). These assume a Kubernetes cluster and `kubectl`
access already exist — copy `k8s/secret.example.yaml` to `secret.yaml` (git-ignored), fill in real
values per its own comments, then:

```bash
kubectl apply -f k8s/secret.yaml
kubectl apply -f k8s/headless-service.yaml -f k8s/service.yaml -f k8s/statefulset.yaml
```

### TLS

`k8s/ingress.yaml` and `k8s/cluster-issuer.yaml` add TLS termination at the ingress, per this
project's design (see `docs/superpowers/specs/2026-08-26-phase-4d-tls-design.md`) — Riptide itself
never holds a certificate or speaks TLS directly. This requires
[ingress-nginx](https://kubernetes.github.io/ingress-nginx/deploy/) and
[cert-manager](https://cert-manager.io/docs/installation/) already installed on your cluster.

Let's Encrypt's production endpoint has strict per-hostname rate limits that a first attempt can
easily exceed while debugging DNS/ingress setup, so the steps below have you verify against the
`letsencrypt-staging` issuer first — staging certs aren't trusted by browsers, but they prove the
HTTP-01 challenge mechanics work before you spend a production issuance attempt on it.

1. Edit `k8s/cluster-issuer.yaml`: replace both `REPLACE_ME@example.com` placeholders with a real
   email address (Let's Encrypt uses this for expiry/problem notifications, not for
   authentication), then `kubectl apply -f k8s/cluster-issuer.yaml`.
2. Edit `k8s/ingress.yaml`: replace both `riptide.example.com` placeholders with your real
   hostname, and change the `cert-manager.io/cluster-issuer` annotation from `letsencrypt-prod` to
   `letsencrypt-staging` — then `kubectl apply -f k8s/ingress.yaml`.
3. Point that hostname's DNS at your ingress controller's external IP
   (`kubectl get svc -n <ingress-nginx-namespace> ingress-nginx-controller`).
4. Update `k8s/statefulset.yaml`'s `PHX_HOST` value to the same hostname (see the comment above
   that field) and re-apply the StatefulSet.
5. Verify staging works: `kubectl describe certificate riptide-tls` should reach `Ready: True`
   once cert-manager completes the ACME HTTP-01 challenge against the staging endpoint.
6. Switch to production: edit `k8s/ingress.yaml` again, changing the annotation from
   `letsencrypt-staging` to `letsencrypt-prod`, then re-apply and re-check
   `kubectl describe certificate riptide-tls` for `Ready: True` against the real Let's Encrypt
   endpoint.

**Not covered by these manifests:** the subdomain-based tenancy resolver (see
`docs/superpowers/specs/2026-08-26-phase-4a-multi-tenancy-data-model-design.md`) routes tenants by
hostname (`tenant.riptide.example.com`), which needs a *wildcard* certificate — HTTP-01 (used
above) cannot issue wildcards. If you're using that resolver, switch to a DNS-01 solver instead
(provider-specific; see
[cert-manager's ACME DNS-01 provider docs](https://cert-manager.io/docs/configuration/acme/dns01/))
and request `*.riptide.example.com` in `k8s/ingress.yaml`'s `tls.hosts` instead of a single
hostname.

### Metrics

Riptide exposes Prometheus metrics on port 9090 (`GET /metrics`) — a separate port from the main
application (4000), reachable only from inside the cluster; `k8s/ingress.yaml` never routes to it.
If you run a Prometheus that auto-discovers scrape targets via pod annotations, add these to
`k8s/statefulset.yaml`'s pod template:

```yaml
metadata:
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "9090"
```

Setting up Prometheus itself (and any Grafana dashboards/alerting on top of it) is your own
deployment's concern — these manifests only expose the metrics, they don't install a scraper.

## Running on Fly.io

`fly.toml` (included in this repo) deploys Riptide as a single Fly Machine with a persistent Fly
Volume mounted at `/data` — the same single-node model as `docker-compose.yml` above, just on
Fly's infrastructure instead of your own. This needs `flyctl` and an authenticated Fly.io org.

```bash
fly apps create <your-app-name>          # update fly.toml's `app` and `PHX_HOST` to match
fly volumes create riptide_data --region <region> --size 1 -a <your-app-name>
fly secrets set -a <your-app-name> \
  SECRET_KEY_BASE="$(openssl rand -base64 48)" \
  RELEASE_DISTRIBUTION=name \
  RELEASE_NODE=riptide@127.0.0.1 \
  RELEASE_COOKIE="$(openssl rand -hex 16)"
fly deploy -a <your-app-name>
```

`RELEASE_DISTRIBUTION`/`RELEASE_NODE`/`RELEASE_COOKIE` enable Erlang distribution scoped to
loopback only (`127.0.0.1` — not reachable from outside the machine), solely so `bin/riptide rpc`
can attach for one-off administrative calls (see "Seeding data" below) — this is the Fly
equivalent of `iex -S mix phx.server`'s attached shell in local dev.

**Why `RELEASE_NODE=riptide@127.0.0.1`, not `@localhost`:** Erlang's longname distribution mode
(`RELEASE_DISTRIBUTION=name`) requires the host part to be a real IP or fully-qualified hostname —
`localhost` is rejected outright ("Hostname localhost is illegal"). This mirrors
`rel/env.sh.eex`'s own `riptide@$POD_IP` choice for the Kubernetes path, just with the loopback
address in place of a pod IP.

`fly.toml` also sets `RIPTIDE_PLACEMENT_TARGET_SIZE=1` — a single-machine deployment (Fly, plain
`docker run`, `docker-compose`) only ever has one node to form a placement cluster from, so the
target size needs to match; see the comment above `placement_target_size` in `config/runtime.exs`
for why. This isn't strictly required (the default target size of 3 still gracefully collapses to
whatever's actually present), but leaving it unset means the ambient join loop keeps periodically
probing for 2 more nodes that will never appear.

### Seeding data

There's no HTTP endpoint for tenant/policy administration (deliberately — it's an Elixir-native,
operator-only action, same as local dev's `setup.exs`). Attach via `bin/riptide rpc`, not
`bin/riptide remote`: the latter's `--remsh` silently falls back to a disconnected local session
over a non-tty connection (exactly what `fly ssh console -C "..."` gives you), which looks like it
worked but never touches the running app. `rpc` doesn't need a tty:

```bash
fly ssh console -a <your-app-name> -C \
  "/app/bin/riptide rpc 'Code.eval_string(Base.decode64!(\"$(base64 -w0 examples/live-story/setup.exs)\"))'"
```

(Base64-encoding the script sidesteps quoting a multi-line Elixir expression through two layers of
shell — `fly ssh console -C` and the SSH session itself.) For a one-off tenant policy without the
full live-story seed, pass a shorter expression the same way — `rpc` accepts any single Elixir
expression.

### Verified

Setup → deploy → seed → verify (health check, `PATCH` a line, confirm it via `GET` and over SSE) →
complete teardown (`fly apps destroy <app> --yes`), run 3 times end-to-end with no manual
intervention between runs, 2026-08-27.

## Performance

Measured 2026-08-27 against the code at this point in `main`. Every number below is from a real
run on this exact machine, not an estimate — see [Methodology](#methodology) for exactly how to
reproduce it and what its limitations are.

### Core primitives (Elixir-level, `Benchee`)

Micro-benchmarks of the operations everything else is built on: RDF/Turtle codec, patch
application, and the three Ra-backed primitives (stream append, stream read, placement lookup)
and the in-memory authorization check.

| Operation | Throughput | Mean latency | Median | p99 |
|---|---:|---:|---:|---:|
| `Patch.apply/2` (1 addition + 1 removal) | 599.5K/s | 1.67 μs | 1.19 μs | 2.85 μs |
| `Placement.lookup/1` (cached cluster, hot path) | 179.8K/s | 5.56 μs | 4.68 μs | 12.93 μs |
| `StreamServer.get_since/2` (10-event history, full read) | 121.7K/s | 8.21 μs | 6.98 μs | 16.58 μs |
| `TurtleCodec.encode/1` (1 triple) | 112.3K/s | 8.91 μs | 7.82 μs | 31.65 μs |
| `Authz.evaluate/4` (1 `:public` policy, depth-1 path) | 112.0K/s | 8.93 μs | 7.59 μs | 19.89 μs |
| `StreamServer.get_since/2` (1000-event history, tail read) | 54.4K/s | 18.37 μs | 17.47 μs | 36.82 μs |
| `StreamServer.get_since/2` (100-event history, full read) | 29.0K/s | 34.46 μs | 31.06 μs | 59.04 μs |
| `TurtleCodec.decode/1` (1 triple) | 21.8K/s | 45.92 μs | 43.41 μs | 70.47 μs |
| `TurtleCodec.encode/1` (50 triples) | 4.8K/s | 207.95 μs | 204.21 μs | 277.24 μs |
| `StreamServer.get_since/2` (1000-event history, full read) | 3.1K/s | 327.12 μs | 280.63 μs | 523.68 μs |
| `TurtleCodec.decode/1` (50 triples) | 1.2K/s | 872.37 μs | 847.23 μs | 1141.85 μs |
| `StreamServer.append/2` (`:replace`, empty graph) | 316/s | 3.16 ms | 3.12 ms | 4.14 ms |

Two things stand out. First, `append/2` is roughly 1000x slower than everything above it in this
table — that's the cost of a real Raft commit with an fsync'd write-ahead log on every single
append, not something the implementation is failing to optimize; it's the actual price of the
durability guarantee this table is really measuring. Second, `get_since/2`'s full-history cost
grows with the stream's total history size (scanning/decoding every stored event), while its
tail-read cost (a fresh cursor near the end) stays cheap regardless of history size — read cost is
about how much of the log a given cursor needs to replay, not how long the stream has existed.

### HTTP (`wrk`, single node)

| Scenario | Concurrency | Throughput | p50 | p90 | p99 |
|---|---|---:|---:|---:|---:|
| `GET /health/live` | 4 threads / 32 conns | 19,343 req/s | — | — | — |
| `GET` LDP resource (10-triple body) | 1 thread / 1 conn | 3,004 req/s | 0.32 ms | 0.40 ms | 0.51 ms |
| `GET` LDP resource | 4 threads / 32 conns | 9,643 req/s | — | — | — |
| `GET` LDP resource | 8 threads / 128 conns | 11,094 req/s | 8.4 ms | 36.5 ms | 48.8 ms |
| `GET` LDP resource | 8 threads / 256 conns | 11,670 req/s | 16.8 ms | 49.4 ms | 61.4 ms |
| `PUT` (write) same resource repeatedly | 1 thread / 1 conn | 372 req/s | 2.55 ms | 2.90 ms | 11.92 ms |
| `PUT` same resource repeatedly | 4 threads / 32 conns | 1,293 req/s | 19.5 ms | 69.6 ms | 392.5 ms |
| `PUT` same resource repeatedly | 8 threads / 128 conns | 764 req/s | 168.5 ms | 242.1 ms | 280.9 ms |
| `PUT` spread across 500 resources | 4 threads / 32 conns | 3,014 req/s | 6.1 ms | 39.7 ms | 56.0 ms |
| `PUT` spread across 500 resources | 8 threads / 128 conns | 4,865 req/s | 17.2 ms | 60.8 ms | 68.6 ms |

The `PUT` rows are the most important ones to read carefully, and they tell a real architectural
story, not just a number: **hammering one resource with concurrent writes doesn't scale, and
shouldn't** — throughput actually *drops* from 1,293 to 764 req/s going from 32 to 128 connections,
because every write to the same resource serializes through that resource's own single-writer Ra
log (by design — see "How the pieces fit together" above). Concurrent writers to the *same*
resource just queue up and their latency grows; there is no amount of added concurrency that helps
that case, and this benchmark demonstrates it rather than papering over it. Spreading writes across
many different resources (the realistic multi-tenant/multi-resource shape) scales the way you'd
expect instead: 3,014 → 4,865 req/s from 32 to 128 connections, each resource's writes still fully
serialized and durable, but different resources' Ra clusters make progress independently.

### Methodology

- **Hardware**: 16-core Intel Xeon Platinum 8581C @ 2.10GHz, 62.8 GB RAM. Elixir 1.18.4, Erlang/OTP
  25.2.3 (JIT enabled).
- **Single node, not a 3-replica HA cluster.** Every stream (and the placement metadata cluster
  itself) runs with a real Ra log and a real fsync'd WAL, but with a replication factor of 1 —
  these numbers do not include cross-node Raft replication latency, which Phase 3's own HA design
  spec already establishes adds a real, separate cost (a leader must hear back from a quorum of
  replicas before committing). Benchmarking the 3-replica case needs a real multi-node
  cluster and is a natural next benchmarking pass, not something this single-machine run
  attempts to simulate.
- **Client and server share this same 16-core machine** — `wrk` itself consumes real CPU that
  would otherwise go to Riptide, so the HTTP throughput numbers above are a lower bound on what a
  dedicated load-generator-on-a-separate-host setup would show, not an upper bound.
- **Build**: a `:test`-config build (`mix test`'s own app boot, `code_reloader`/`debug_errors`
  explicitly disabled), not a full `:prod` release — see `test/bench/http_server_test.exs`'s own
  comment for exactly why (`force_ssl` is compile-time-locked to `:prod` only, and standing up a
  real 3-ordinal-DNS-resolved placement cluster just for a single-node benchmark isn't worth a
  permanent config escape hatch). `:phoenix, :plug_init_mode` also stays `:runtime` (dev/test's
  faster-recompile setting) rather than `:prod`'s `:compile` — a real production release's plug
  pipeline has one less layer of per-request overhead than what's measured here.
- **Not measured in this pass**: SSE/WebSocket live-delivery (append-to-subscriber) latency, and
  authenticated (OIDC) request overhead (every request above is anonymous, matched against a
  `:public` policy — real JWT verification adds its own cost on top of `Authz.evaluate/4`'s number
  above). Both are reasonable candidates for a follow-up benchmarking pass, not silently assumed to
  be free.

Reproduce it yourself:

```bash
# Core primitives (Elixir-level Benchee benchmarks)
mix test test/bench/core_bench_test.exs --include benchmark --trace

# HTTP server for wrk/curl/etc. — run this in one terminal, drive it from another
mix test test/bench/http_server_test.exs --include benchmark --trace
wrk -t8 -c128 -d10s --latency http://127.0.0.1:4000/tenants/http-bench-tenant/resources/bench-read-doc
wrk -t8 -c128 -d10s --latency -s bench/wrk-put-many-resources.lua http://127.0.0.1:4000
```

See `bench/README.md` for what each script does and why it's structured the way it is.

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
