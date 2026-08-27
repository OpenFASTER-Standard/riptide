# Riptide — Production Readiness Roadmap

**Last updated:** 2026-08-27

This tracks Riptide's path from "working reference implementation" (shipped: see
[PR #1](https://github.com/OpenFASTER-Standard/riptide/pull/1)) to "production-grade centerpiece
of an organization's data architecture." Kept proactively up to date as work lands — this is the
first place to check for current status, not a historical log.

## Sub-projects

| # | Sub-project | Status |
|---|---|---|
| 1 | Persistence & durability | **Shipped** — see below |
| 2 | Docker image + CI/CD | **Shipped** — see below |
| 3 | Clustering / horizontal scale / HA | **Decomposed into phases 3a-3d** — see below |
| 4 | Security & multi-tenancy (auth, ACP, TLS) | **Shipped** (phases 4a-4d) — see below |
| 5 | Observability & operability (metrics, logging, health probes) | **Decomposed into phases 5a-5c** — see below |

Sequencing rationale: persistence first, since clustering/HA are meaningless without durable
storage to replicate, and every other sub-project assumes data actually survives a restart.

## 1. Persistence & durability — shipped

**Scope for this sub-project**: a single-node `Ra`-replicated (cluster size 1) durable log per
stream, replacing the current in-memory `state.events` list in `Riptide.Stream.StreamServer`.
Solves the most urgent gap: a crash today loses all data and silently resets sequence numbers
from 1, which can break a reconnecting subscriber's `Last-Event-ID` resumption without even
signaling a gap.

**Key decisions made (with rationale — see chat history / eventual design doc for full research
citations):**

- **Durability model**: majority-commit over a `Ra`-replicated (Raft) write-ahead log — same
  model RabbitMQ quorum queues use in production. Resolves the fsync-vs-replication tension
  (Kafka's replication-only model vs. EventStoreDB's fsync-first model) by getting both at once,
  rather than picking one.
- **Storage medium**: local segment-log now; hybrid tiering to object storage for cold retention
  (Kafka KIP-405 pattern) is real production precedent but deferred as additive, not a Phase-1
  requirement.
- **Ordering guarantee**: StreamLD's single monotonic sequence-number-per-stream guarantee is
  preserved, not sacrificed for throughput (a deliberate choice — Kafka's own per-partition
  model was the recommended alternative and was explicitly turned down).
- **Horizontal throughput beyond one `Ra` group**: not being pursued. **Revised 2026-08-23** —
  the earlier "Kafka-scale from the start" ambition is walked back in favor of a simple system
  that is efficient and actually works: a single `Ra` group (the same model RabbitMQ quorum
  queues run in production) comfortably handles tens of thousands of msgs/sec per stream, well
  above real workload needs, with none of the unproven-coordinator risk a multi-shard sequencer
  would add. Not scoped as future work at all — only revisited if a real, measured stream ever
  actually hits that ceiling.
- **Khepri (RabbitMQ's `Ra`-based Mnesia replacement) is NOT the storage engine** — it keeps the
  entire dataset in memory as well as on disk, a hard ceiling below multi-TB/PB retention. `Ra`
  itself (the underlying Raft library) is the right substrate; Riptide builds its own segment-log
  storage on top of it rather than routing through Khepri's tree abstraction.

**Known operational risk to design around from day one**: a shared `Ra` WAL under disk
contention can collapse throughput by orders of magnitude (RabbitMQ's own published numbers:
13k→6k→300 msg/s as contention increased). High-volume streams need real disk isolation, not
just "add more Ra groups on the same disk."

**Honest limits (see design doc §6 for the full list):**

- **Durability is real, before ack.** `Ra` fsyncs its WAL (`datasync`, `default` write strategy)
  *before* acknowledging a write, so an acknowledged append survives a genuine process/host crash.
  One subtlety worth knowing: `get_since/2` is a fast, possibly-stale local read, so in the brief
  window right after a server restart it can momentarily reflect a not-yet-fully-re-applied log —
  a read-freshness window, not data loss (the data is on disk and committed the whole time; use
  `RaCluster.consistent_query/2` for a linearizable read). This was the root cause of the
  crash-recovery test's earlier ~1-in-12 flake, now fixed by asserting durability via a consistent
  read.
- **No schema-versioning envelope on persisted `Event`/`Patch` terms.** `Ra` stores raw Erlang
  terms; a future `Event` struct-shape change (like this sub-project's own `is_snapshot?` →
  `operation` change) would make previously-persisted data unreadable. Fine today (no deployment
  has data across such a change), but needs a versioned envelope + migration path before Riptide
  runs somewhere with existing persisted data. Deferred deliberately.

**Status**: shipped — see
[PR #2](https://github.com/OpenFASTER-Standard/riptide/pull/2) (implementation) and
[`docs/superpowers/specs/2026-08-23-persistence-durability-design.md`](docs/superpowers/specs/2026-08-23-persistence-durability-design.md)
(design). Companion regression test in the spec repo:
[OpenFASTER-Standard/spec#3](https://github.com/OpenFASTER-Standard/spec/pull/3).

**Caveat added 2026-08-24, discovered during sub-project 2's Task 8 end-to-end verification**:
the "durable before ack" claim above (and in the design doc's §6) holds for the write's own WAL
entry, but *not* unconditionally for the whole system — a genuine process/host crash landing
shortly after a stream's first write in a fresh process lifetime can leave that entry orphaned
and unreachable (the data is still on disk, but the Ra server registration needed to find it
again after a cold restart isn't durably flushed on the same timeline as the WAL fsync). Confirmed
live and 100%-reproducible under tight timing against the real published `ghcr.io` image; not
caught by the existing `ra_cluster_test.exs` crash-recovery test because that test kills the Ra
server process within the same live BEAM node rather than exercising a real cold restart. Fixed —
see [OpenFASTER-Standard/riptide#6](https://github.com/OpenFASTER-Standard/riptide/issues/6) (now
closed) for the full root-cause/verification writeup; `RaCluster.start_or_restart/2` now always
uses an explicit, deterministic Ra server UID instead of depending on `:ra`'s crash-fragile
registry to decide "restart vs. start fresh." Verifying this fix against a real container surfaced
a separate, narrower, pre-existing characteristic — `GET /resources/:id` can see a transient,
self-healing (not data-loss) staleness window on the very first read after a stream's first cold
boot, because it reads via `RaCluster.local_query/2` rather than `consistent_query/2` — tracked
separately, unrelated to and unaffected by this fix, as
[OpenFASTER-Standard/riptide#8](https://github.com/OpenFASTER-Standard/riptide/issues/8).

## 2. Docker image + CI/CD — shipped

**Scope for this sub-project**: a real, published `ghcr.io` Docker image (multi-stage `mix
release` build, multi-arch amd64/arm64, non-root, SBOM + provenance attestations), a `ci.yml`
workflow gating every push/PR (tests, Credo, format check, a Dockerfile build-check), a
tag-triggered `release.yml` (build/scan/publish/GitHub Release), and branch-protection settings
on `main`.

**Key decisions made (with rationale — see design doc for full detail):**

- **Registry**: GitHub Container Registry, not Docker Hub — reuses the auto-provisioned
  `GITHUB_TOKEN`, no separate account/secret to manage.
- **Release trigger**: tag-triggered semver (`v*.*.*`), not every merge to `main` — a release is
  a deliberate action, not an automatic side effect of merging.
- **Branch model**: trunk-based + branch protection (continuing what this project already does),
  not GitFlow — `develop`/`release`/`hotfix` branches would be pure ceremony at this project's
  size.
- **Static analysis**: Credo + `mix format --check-formatted` in CI now; Dialyzer deliberately
  deferred (real value, but its PLT build is slow and a first run tends to surface a wave of
  pre-existing findings to triage — a separate follow-up, not bundled here).
- **The Ra data volume is the one part of this sub-project with real correctness stakes**: the
  image declares `VOLUME ["/data"]` + `RIPTIDE_RA_DATA_DIR=/data` by default, documented with a
  `docker run -v` / `docker-compose.yml` example. Without this, a naive `docker run` would
  silently throw away every stream's durable log on container recreation — reintroducing, at the
  infrastructure layer, exactly the bug sub-project 1 fixed in the application layer.
- **OTP version in the image is load-bearing, not a style choice**: the builder/runtime images
  must use Erlang/OTP 25, matching `:ra`'s `~> 2.15.0` pin from sub-project 1 (newer `:ra`
  requires/breaks on a different OTP line — see that sub-project's honest-limits note above).
- **Vulnerability scan gate**: Trivy scan on every release, but only fails the build on
  CRITICAL-severity findings — HIGH-and-below are surfaced (GitHub code scanning) but
  non-blocking, so releases aren't held hostage to unfixable upstream base-image CVEs.
- **No automated changelog/semver tooling** (no conventional-commits/semantic-release) —
  `gh release create --generate-notes` is enough; the git tag itself is already the deliberate
  release decision.

**Status**: shipped — see
[PR #3](https://github.com/OpenFASTER-Standard/riptide/pull/3) (main implementation: Dockerfile,
`ci.yml`, `release.yml`, branch protection, README) and
[`docs/superpowers/specs/2026-08-24-docker-cicd-design.md`](docs/superpowers/specs/2026-08-24-docker-cicd-design.md)
(design, revised — see the design doc's own revision note for the QEMU→native-arm64 and
CRITICAL-gate `ignore-unfixed` changes). End-to-end verification against real tag-triggered
release runs (multi-arch build, OCI labels/annotations, SBOM, vulnerability scan, GitHub Release
automation, durability-through-container-recreation) surfaced real bugs, fixed in
[PR #4](https://github.com/OpenFASTER-Standard/riptide/pull/4) (invalid `trivy-action` tag pin —
shows as "Closed" rather than "Merged" on GitHub because a transient API error interrupted the
merge response after the squash commit had already landed on `main`; the content is genuinely
there, only the PR's own state label is misleading)
and [PR #5](https://github.com/OpenFASTER-Standard/riptide/pull/5) (QEMU-under-JIT segfaults on
arm64 → native `ubuntu-24.04-arm` runners; a digest-merge `printf` bug; the CRITICAL gate missing
`ignore-unfixed`; a missing `checkout` step; OCI labels/annotations dropped by the job
restructuring). Final verification against `main` itself (commit `5801afe`) confirmed a clean,
first-try, no-fixes-needed release run with everything above genuinely present on the published
`ghcr.io` image. See §1's caveat above for one durability finding from that same verification
pass — real, but in sub-project 1's code, not this sub-project's own deliverables.

## 3. Clustering / horizontal scale / HA — decomposed into phases

**Goal for this sub-project**: both halves of the name, deliberately combined — surviving a node
failure without losing data or availability (HA), and handling more streams/throughput by adding
nodes (horizontal scale). Chosen together because the natural solution covers both at once: a
per-stream replica *placement* decision determines which nodes host a stream (enabling scale as
the fleet grows) and how many (enabling HA), the same way RabbitMQ's quorum queues — the closest
real precedent, sharing Riptide's exact "one Ra cluster per unit of data" architecture and the
same underlying `:ra` library — already do it.

**Key research findings driving the phasing (see chat history / eventual phase specs for full
detail):**

- `:ra` itself provides only low-level membership primitives (`add_member`/`remove_member`) —
  zero built-in policy for when/how to grow a cluster. Any placement/rebalancing logic is
  Riptide's own to build, same as RabbitMQ built theirs in the `rabbit` app, not in `:ra`.
- RabbitMQ's real precedent at scale: each queue's Ra cluster is a *subset* of the fleet (default
  3 nodes), not full N-way replication — confirms sharded placement, not "every stream on every
  node," is the right model once the fleet is expected to grow past a handful of nodes.
- RabbitMQ's own automatic rebalancing is deliberately conservative (manual CLI-driven grow/
  shrink is the primary mechanism; automatic reconciliation is slow-interval and only reacts to
  an operator-*confirmed* permanent node removal, never a merely-offline node) — informs Phase 3d
  leaning manual-first rather than building a continuous rebalancing allocator up front.
- Real distributed Erlang needs to be genuinely re-enabled (`RELEASE_DISTRIBUTION=none` is
  currently set as a workaround for a different bug — see §1's honest-limits note) with a
  properly stable node identity this time, not just flipping the flag back.
- Target deployment: Kubernetes (matches this box's own environment) — node discovery via
  `libcluster`'s Kubernetes DNS strategy against a headless Service.
- Target fleet size: large and growing (10+ nodes over time), not a small fixed set — this is
  what makes sharded placement worth the complexity rather than "just replicate everywhere."

**Phasing** (each phase gets its own brainstorm → spec → plan → implementation cycle, same as
sub-projects 1 and 2 did internally):

- **Phase 3a — Schema-versioning envelope.** A versioned wrapper around persisted `Event`/`Patch`
  terms so a future struct change doesn't break reading old data. Originally deferred in
  sub-project 1's design doc §6; pulled forward here because multi-node rolling deploys turn this
  from a someday-risk into a live one (nodes can briefly run different code versions mid-deploy).
  Fully self-contained — doesn't depend on anything else in this sub-project. **Shipped
  2026-08-24** — see `docs/superpowers/specs/2026-08-24-phase-3a-schema-versioning-envelope-design.md`.
- **Phase 3b — Real multi-node connectivity.** Re-enable distributed Erlang properly (not
  `RELEASE_DISTRIBUTION=none`), solve the stable-node-identity problem for real this time,
  `libcluster` + Kubernetes DNS discovery, prove N nodes actually see and stay connected to each
  other. Foundational for 3c/3d, testable in isolation. **Shipped 2026-08-24** — see
  `docs/superpowers/specs/2026-08-24-phase-3b-multi-node-connectivity-design.md`.
- **Phase 3c — Sharded per-stream placement + real multi-member Ra clusters — decomposed
  into sub-phases.** The core clustering work: replication factor (almost certainly 3), which
  subset of the fleet a given stream's replicas land on, actually creating multi-member Ra
  clusters instead of always-size-1. Decomposed into:
  - **3c-i — Placement metadata store.** A small, dedicated `:ra` cluster (fixed 3 members,
    decoupled from total fleet size) durably recording `stream_id → [replica nodes]`.
    Foundational — nothing else in 3c can be built without it. **Shipped 2026-08-25** — see
    `docs/superpowers/specs/2026-08-25-phase-3c-i-placement-metadata-design.md`. Live-proved
    against a real 3-pod GKE StatefulSet (real assignment written on one pod, correctly
    replicated to the other two via Raft); that proof also surfaced and fixed a real,
    pre-existing gap in `k8s/statefulset.yaml` (missing `fsGroup`, which blocked any real
    `:ra` data persistence to `/data` for the non-root container user).
  - **3c-ii — Real multi-member Ra cluster formation.** Consumes 3c-i's stored assignment to
    actually start an N-member Ra cluster for a stream, replacing the old hardcoded
    single-member `initial_members: [server_id]`. **Shipped 2026-08-25** — see
    `docs/superpowers/specs/2026-08-25-phase-3c-ii-multi-member-ra-clusters-design.md`.
    Live-proved against a real 3-pod GKE StatefulSet: a genuinely new stream formed a real
    3-member cluster spanning all 3 pods, and a write on one pod replicated to the other two.
    Along the way, closed a real liveness gap in `StreamServer`'s restart path exposed by
    `Riptide.Stream.Placement`'s new cache-hit shortcut, and fixed a pre-existing test-suite
    flake in the shared placement cluster's node-identity bootstrap.
  - **3c-iii — Request routing.** Wires the HTTP/SSE/WebSocket layer to consult 3c-i's store
    and serve requests correctly regardless of which node they land on. **Shipped 2026-08-25**
    — see `docs/superpowers/specs/2026-08-25-phase-3c-iii-request-routing-design.md`. No
    HTTP-level proxy layer needed — leans entirely on `:ra`'s and `Phoenix.PubSub`'s existing
    location-transparent/cluster-wide semantics. `Riptide.Stream.Placement` gained a
    member/non-member branch so a non-member node skips cluster formation entirely;
    `StreamSupervisor.get_or_start/1` was renamed to `ensure_ready/1`, dropping the
    local-pid contract that never made sense once a node's replicas could live elsewhere.
    Live-proved against a real 5-pod GKE StatefulSet (RF=3): a pod that wasn't one of a
    stream's 3 replicas correctly served both a request that resolved the existing
    assignment and a real cross-pod read.
- **Phase 3d — HA proof + operator tooling.** Actually kill a node and prove streams keep
  working. **Scope correction (2026-08-25, ahead of 3d-ii design):** the placement cluster's own
  membership is a solved problem (see 3d-i finding 3) — this phase's remaining, still-fully-open
  job is repairing a *stream's own* replica set after a member's node identity drifts. That drift
  isn't a rare failure mode: every pod restart (routine deploy included) gets a fresh IP-based
  `node()` identity (Phase 3b), so it's the normal steady state of running this fleet, not an
  edge case. Manual/on-demand operator tooling for something this frequent doesn't scale — 3d-ii
  is scoped as a **fully automatic background self-healing process** (detect drift, pick a
  replacement, repair — zero operator/human involvement in the steady-state case), not a
  RabbitMQ-style manual-first CLI tool as originally sketched. This is a deliberate reversal of
  the sub-project's earlier "manual grow/shrink first" framing for this specific piece.
  - **3d-i — HA proof spike.** Live GKE spike (5-pod StatefulSet, RF=3): force-killed placement-
    cluster pods and a stream replica pod to observe real failure/recovery behavior. **Investigated
    and fixed 2026-08-25.** Found and fixed 2 real bugs, corrected a stale design-doc claim:
    1. A fresh, non-placement-ordinal fleet node could lose a startup race and silently never
       start its replica of a brand-new stream's cluster — `RaCluster.start_or_join_replicated/3`
       blindly trusted `:ra.start_cluster/2`'s reply even when its `NotStarted` list was
       non-empty. Fixed: `Riptide.Application.start/2` now starts every node's local `:ra` system
       unconditionally at boot (closing the race at its root), and `start_or_join_replicated/3`
       now treats a genuinely-not-alive `NotStarted` member as a retriable error instead of
       silent partial success — routing through `Riptide.Stream.Placement`'s existing bounded
       retry loop.
    2. `Riptide.Placement.assign/2,3`/`lookup/1,2` hardcoded addressing the metadata cluster via
       only `riptide-0`, no fallback — a de-facto single point of failure for the whole placement
       layer on every restart of that one pod, even though the underlying 3-member Raft cluster
       stayed healthy via its other members. Fixed: both now try each placement ordinal in turn.
    3. Not a bug: confirmed (live + reproduced via a controlled multi-node test + direct `:ra`
       source reading) that the placement cluster's own membership self-heals automatically after
       genuine quorum loss, with zero data loss — contradicting 3c-i's own design spec, which was
       corrected. This holds structurally as long as the placement cluster never snapshots
       (`PlacementMachine.apply/3` never emits `release_cursor`); a tripwire regression test
       (`test/riptide/placement_snapshot_recovery_test.exs`) guards against that assumption
       silently breaking in the future.
  - **3d-ii — Automatic stream replica healing.** A stream with exactly one dead replica (of
    RF=3) is now detected and repaired automatically, with zero operator action — see
    `docs/superpowers/specs/2026-08-25-phase-3d-ii-replica-healing-design.md`. **Shipped
    2026-08-25.** `Riptide.Stream.ReplicaHealer` sweeps every known stream on a timer, gated to
    only the placement cluster's current Raft leader (reusing its existing leader election for
    single-writer safety, no new coordination mechanism), and on finding a dead member: joins a
    live replacement into the stream's real `:ra` cluster (`RaCluster.replace_member/5`),
    updates the durable placement assignment, and broadcasts a PubSub invalidation so no node's
    cache keeps routing to the dead replica. Live-proved against a real 5-pod GKE StatefulSet
    (RF=3): a killed replica pod was automatically replaced with no operator action and no data
    loss.

**Status**: Phases 3a-3b shipped. Phase 3c (3c-i/3c-ii/3c-iii) fully shipped. Phase 3d-i (HA
proof spike + fixes) shipped 2026-08-25. Phase 3d-ii (automatic stream replica healing) shipped 2026-08-25.

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
- **Phase 4b — Pluggable authentication.** **Shipped 2026-08-26** — see
  `docs/superpowers/specs/2026-08-26-phase-4b-pluggable-authentication-design.md`. A pluggable
  `Riptide.Auth.Verifier` behaviour (config-selected, defaulting to `Riptide.Auth.Verifier.OIDC` —
  standard OIDC/JWT via `joken`+`joken_jwks`) feeds a new `RiptideWeb.Plugs.Authenticate` plug,
  applied to all 3 request transports (LDP HTTP, SSE, WebSocket). Authentication is optional at
  this layer — no token proceeds as anonymous (`current_subject: nil`); a present-but-invalid
  token is rejected (`401` for HTTP/SSE, connection refused for WebSocket). WebSocket auth uses
  Phoenix's purpose-built `auth_token`/`Sec-WebSocket-Protocol` mechanism rather than a header,
  since Phoenix deliberately doesn't expose the raw `Authorization` header to `Socket.connect/3`.
  Live-proved end-to-end against a real, disposable `oidc-provider`-based OIDC issuer. No
  authorization/enforcement yet — that's Phase 4c.
- **Phase 4c — Authorization (ACP).** **Shipped 2026-08-26** — see
  `docs/superpowers/specs/2026-08-26-phase-4c-authorization-design.md`. An ACP-inspired policy
  model (`Riptide.Authz.Policy`: `effect: :allow | :deny`, `modes: [:read | :write]`, `matcher:
  :public | :authenticated | {:agent, subject}`), evaluated with container-level inheritance and
  deny-overrides-allow, enforced across all 3 transports (a new `RiptideWeb.Plugs.Authorize` for
  LDP HTTP; direct `Riptide.Authz.evaluate/4` calls from SSE and the WebSocket channel after
  recovering tenant/path from an opaque `stream_id` via a new `parse_stream_id/1`). Default-deny,
  with an implicit bootstrap: the first authenticated write to a policy-less tenant atomically
  claims tenant-root ownership (`Riptide.Authz.Store.claim_tenant_if_unclaimed/2`), so no separate
  tenant registry is needed. Policies persist via the *existing* shared placement Ra cluster
  (`Riptide.Placement.PlacementMachine` gained `policies` state alongside its original `streams`
  state) rather than a second Ra cluster to operate. A minimal, tenant-root-only policy management
  API (`POST`/`GET /tenants/:tenant_id/policies`) lets an owner grant other agents access. Not
  full Solid ACP compliance — no Access Control Resources as discoverable resources, no
  client/VC/issuer matchers, no `Control` mode, no policy revocation yet; see the design spec §3
  for the complete list of deliberate omissions.
- **Phase 4d — TLS.** **Shipped 2026-08-26** — see
  `docs/superpowers/specs/2026-08-26-phase-4d-tls-design.md`. TLS terminates at the Kubernetes
  ingress, not in-app — no Elixir changes, confirmed by reading (not assuming) that
  `config/prod.exs`'s `force_ssl` and `config/runtime.exs`'s `url: [scheme: "https"]` already
  anticipate this. New example manifests: `k8s/ingress.yaml` (ingress-nginx, with
  `proxy-buffering: "off"` and a 3600s `proxy-read-timeout` for Riptide's long-lived SSE/WebSocket
  connections) and `k8s/cluster-issuer.yaml` (Let's Encrypt via ACME HTTP-01, staging + prod).
  Wildcard/DNS-01 certs for the subdomain tenancy resolver are deliberately out of scope — see the
  design spec's Out of scope section. Verified via `kubectl apply --dry-run=server` against a
  scratch namespace on a live cluster (schema-valid), not a live-issued certificate — real ACME
  issuance needs public DNS + a reachable ingress IP, which this phase does not provision.

**Status**: Phases 4a-4d shipped 2026-08-26. Sub-project 4 (Security & multi-tenancy) complete.

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
