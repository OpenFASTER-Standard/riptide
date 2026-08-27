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

Example manifests live in `k8s/` — a 3-replica `StatefulSet` (`k8s/statefulset.yaml`), a
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
