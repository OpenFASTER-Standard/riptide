# Riptide — Production Readiness Roadmap

**Last updated:** 2026-08-29

This tracks Riptide's path from "working reference implementation" (shipped: see
[PR #1](https://github.com/OpenFASTER-Standard/riptide/pull/1)) to "production-grade centerpiece
of an organization's data architecture." Kept proactively up to date as work lands — this is the
first place to check for current status, not a historical log.

## Sub-projects

| # | Sub-project | Status |
|---|---|---|
| 1 | Persistence & durability | **Shipped** — see below |
| 2 | Docker image + CI/CD | **Shipped** — see below |
| 3 | Clustering / horizontal scale / HA | **Shipped** (phases 3a-3e) — see below |
| 4 | Security & multi-tenancy (auth, ACP, TLS) | **Shipped** (phases 4a-4d) — see below |
| 5 | Observability & operability (metrics, logging, health probes) | **Shipped** (phases 5a-5c) — see below |
| 6 | Derivation and execution layer | **6c-i-a, 6c-i-b, 6b-i, 6d-i, 6e-i, 6e-ii, 6e-iii, 6f, 6g-i, 6a, 6b-ii, 6h-i, 6h-ii shipped** (Rule/Signature representation and parser; fact-pattern matching and joins; WASI execution substrate; mechanical wiring; anti-unification algorithm; Generalization Fidelity replay harness; DedupGate orchestration; LLM fallback loop; exact/keyword Discovery; bitemporal fact shape; supervised long-running process primitive; Pattern Hub threat model; Pattern Hub deployment) — 8 phases remaining, see `docs/superpowers/specs/2026-08-27-derivation-and-execution-layer-design.md` |

Sequencing rationale: persistence first, since clustering/HA are meaningless without durable
storage to replicate, and every other sub-project assumes data actually survives a restart.
Sub-project 6 is the first thing built on top of 1-5's now-complete foundation, not a parallel
effort — see that spec's own §1.

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
- **No schema-versioning envelope on persisted `Event`/`Patch` terms** — true when this sub-project
  shipped, deliberately deferred at the time. **Resolved by Phase 3a** (shipped 2026-08-24, see
  §3 below): a versioned wrapper around persisted `Event`/`Patch` terms now exists specifically so
  a struct-shape change like this doesn't break reading previously-persisted data.

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
- **Phase 3e — Elastic placement-cluster membership.** Every other piece of clustering was
  already elastic (general fleet connectivity, per-stream replica placement) — the ONE place
  that genuinely assumed a fixed node count was the placement/metadata cluster's own membership,
  hardcoded to exactly 3 fixed ordinals (`riptide-0`/`riptide-1`/`riptide-2`). **Shipped
  2026-08-28** — see `docs/superpowers/specs/2026-08-27-phase-3e-elastic-placement-membership-design.md`.
  Replaced with self-forming genesis (any node finding no existing placement cluster
  deterministically computes and forms one from whoever's actually connected, after a short
  settle window), discovery-based addressing (an ETS-cached fast path kept current via PubSub,
  falling back to a fleet-wide probe — no more fixed ordinal names anywhere in
  `Riptide.Placement`), and automatic reconciliation to a configurable `RIPTIDE_PLACEMENT_TARGET_SIZE`
  (default 3, validated as a positive odd integer): ambient join when under target, leader-only
  shrink/dead-member-repair when over target or a member is confirmed dead. Also added graceful
  drain — a node proactively removes itself from the placement cluster on supervised shutdown.
  Verified via a new `:peer`-based multi-node test suite (genesis convergence, grow, shrink,
  dead-member replacement, graceful drain) and the full existing suite; unlike 3c-i/3c-ii/3c-iii/
  3d-i/3d-ii, **not yet live-proved against a real GKE StatefulSet** — a reasonable follow-up,
  not silently assumed equivalent to those phases' live-fire proof.

**Status**: Phases 3a-3b shipped. Phase 3c (3c-i/3c-ii/3c-iii) fully shipped. Phase 3d-i (HA
proof spike + fixes) shipped 2026-08-25. Phase 3d-ii (automatic stream replica healing) shipped
2026-08-25. Phase 3e (elastic placement-cluster membership) shipped 2026-08-28.

## 4. Security & multi-tenancy — decomposed into phases

**Goal for this sub-project**: authentication (who is making a request), authorization (what can
they do), multi-tenancy (data isolation between tenants sharing one deployment), and TLS
(transport security) — bundled under one roadmap line originally, but these are independent
concerns, each getting its own brainstorm → spec → plan → implementation cycle, the same way
sub-project 3 was decomposed into phases 3a-3e.

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
- **Post-4d hardening (PR #32) — full-repo audit remediation, not just atom exhaustion.** A
  7-pass audit (correctness, security, concurrency, error handling, resource management, data
  integrity, observability) found and fixed, with every finding independently re-verified against
  real code/library source before being fixed:
  - **Unbounded atom creation via read-only requests.** Found during a deep repo-health
    investigation, 2026-08-28: `RaCluster.server_id/1` mints a permanent, never-freed BEAM atom for
    any `stream_id` it's asked about, and `RiptideWeb.LDP.ResourceController`'s `GET` action,
    `SseController`'s subscribe, and `ReplicationChannel`'s join all called
    `StreamSupervisor.ensure_ready/1` (which mints that atom) unconditionally — including for a
    resource nobody had ever written to. An authenticated user with ordinary read access to their
    own tenant could loop distinct never-created paths to exhaust the BEAM's atom table and crash
    the shared node for every tenant; `Riptide.Stream.Placement`'s existing 10,000-streams-per-tenant
    quota only partially bounded this (unlimited free, write-free atom creation via reads was still
    possible). Fixed: the `GET` path now checks `Riptide.Placement.lookup/1` (a cheap, atom-free
    existence query) before calling `ensure_ready/1` — 404 immediately if unassigned, no atom ever
    minted. SSE subscribe and WS replication join must keep allowing "subscribe before first
    write," so creation there is instead rate-limited per subject (`Riptide.NewStreamRateLimit`,
    Hammer-backed) rather than refused outright.
  - **Turtle-parsing memory bomb.** A per-process heap cap was added after confirming empirically
    that a ~3MB deeply-nested Turtle body drives ~863MB/~19s in the decoding process — the same
    resource-exhaustion class as the atom issue above, from a different angle (untrusted input
    driving unbounded resource use), and the concrete precedent motivating the Derivation and
    Execution Layer spec's WASI fuel/memory-metering requirement for Capabilities
    (`docs/superpowers/specs/2026-08-27-derivation-and-execution-layer-design.md` §4).
  - **Security**: closed a tenant-hijack path (sub-less JWTs sharing a bootstrapped owner policy);
    scoped the `?token=` auth fallback to SSE only.
  - **Concurrency/data-integrity**: fenced `ReplicaHealer`'s repair through the placement Ra
    cluster's own consensus (new `{:claim_repair, ...}`/`{:release_repair, ...}` commands) instead
    of trusting an unfenced leader check — closes a dual-leader race that could permanently orphan
    a Ra member; made `RaCluster.replace_member/5`'s `remove_member` step fully idempotent.
  - **Correctness**: `StreamServer.append/2`/`get_since/2` now fall back across all of a stream's
    replicas (previously a de-facto SPOF on the first one); fixed `create_child`'s orphaned-child
    risk on partial failure.
  - **Error handling**: `RaMachine.apply/3` no longer crash-loops a replica forever on an
    undecodable committed event; `RaCluster`'s core Ra wrappers now catch `:exit` uniformly;
    placement-cluster-down now maps to 503 everywhere (`Authorize`, `PolicyController`, SSE, WS),
    not a generic 500.
  - **Resource management**: per-tenant live-stream quota (bounds unbounded Ra-cluster creation via
    a POST loop), JWKS fetch timeout, policy-list dedup/cap, k8s resource limits + hardened
    securityContext.
  - **Observability**: new telemetry for authz decisions, HTTP exceptions, WS connect/join results,
    ordinal fallback, placement-cluster formation attempts, stream formation failures, dropped
    poison commands, quota rejections; logging added for previously-silent failure paths.

  **Flake fixed 2026-08-28 (previously tolerated as "known," now root-caused and resolved):**
  `SseControllerTest`/`ReplicationChannelTest`'s "subscribing/joining more distinct brand-new
  streams than the configured limit is rejected" tests occasionally observed one extra `:allow`
  where a `:deny` was expected (e.g. `[200, 200, 200]` instead of `[200, 200, 429]`). Root cause,
  confirmed via a dedicated reproduction test (`NewStreamRateLimitTest`) that deliberately times a
  burst to straddle a window boundary rather than waiting on rare CI timing to surface it:
  `Riptide.NewStreamRateLimit` used Hammer's default `:fix_window` algorithm, which anchors every
  key's window to the same globally-synchronized wall-clock boundary (multiples of `scale_ms`
  since the Unix epoch) rather than to when that subject's own activity began — a same-subject
  burst can straddle that global boundary purely by chance of what real time it is when the burst
  happens, resetting the count mid-burst. This was a real bug, not just a test artifact: the same
  under-counting could let a real subject briefly exceed the configured limit in production, not
  only in tests. Fixed by switching to Hammer's `:fix_window_per_key` algorithm, which anchors
  each key's window to that key's own first hit instead — verified via 10 consecutive clean runs
  of the affected test files with no failures (previously ~40% locally reproducible once the
  underlying algorithm bug was isolated).

**Status**: Phases 4a-4d shipped 2026-08-26. Sub-project 4 (Security & multi-tenancy) complete.
Post-4d hardening fix shipped 2026-08-28.

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
  require one). dev/test keep today's plain-text formatter; `config/config.exs`'s shared
  `metadata: :all` (widened from `[:request_id]` during CI fix-up, since `mix credo --strict`'s
  `Warning.MissingLoggerMetadataKeys` check flags any custom key not declared in *some* env's
  Logger config, and `:all` costs nothing extra on lines that don't set those keys) means any of
  the new metadata keys also show at the dev console when present, not just in prod's JSON output.
- **Phase 5c — Metrics.** **Shipped 2026-08-27** — see
  `docs/superpowers/specs/2026-08-27-phase-5c-metrics-design.md`. A Prometheus scrape endpoint
  (`GET /metrics` on port 9090, `RiptideWeb.MetricsEndpoint` — a separate, ClusterIP-only port
  never routed through Phase 4d's Ingress) exposes both HTTP/WebSocket metrics (attached directly
  to Phoenix's own existing telemetry events, e.g. `[:phoenix, :router_dispatch, :stop]`'s `route`
  metadata — the literal router-DSL pattern string, not the resolved per-request path, to avoid
  unbounded cardinality) and new domain instrumentation added to `Riptide.Stream.StreamServer`
  (append/read latency, gap-signal rate), `Riptide.Placement` (lookup/assign latency and error
  counts), and `Riptide.Stream.ReplicaHealer` (repair outcomes, dead-replica detection), plus a
  `:telemetry_poller`-driven gauge for Ra placement-cluster leadership. No metric tags by
  `stream_id`/`tenant_id` — see the design spec's Cardinality section. This closes sub-project 5
  (Observability & operability) and completes Riptide's entire production-readiness roadmap.

**Status**: Phases 5a-5c shipped 2026-08-27. Sub-project 5 (Observability & operability) complete.
Production-readiness roadmap complete as of 2026-08-27 — see sub-projects 3 and 4 above for
hardening work (Phase 3e, the post-4d atom-exhaustion fix) that continued to land afterward.

## 6. Derivation and execution layer — decomposed into phases

**Goal for this sub-project**: the first thing built on top of sub-projects 1-5's now-complete
foundation, not a parallel effort — see
`docs/superpowers/specs/2026-08-27-derivation-and-execution-layer-design.md` §1. Riptide today is
an event-sourced fact store with one hardcoded derivation; this sub-project adds a general
derivation and execution engine so that "answer a question about the facts" and "cause an effect
in the world" become two interpretations of the same declarative object, evaluated by one engine,
sharing Riptide's Fact store and running in the same OS process as its existing LDP surface.
Decomposed into 21 phases (one shared foundation, one primary spine, three parallel tracks, after
a full pairwise dependency/leverage review) — see the design spec's §7 for the full breakdown.

### 6c-i-a — Rule/Signature representation and parser

Foundation-track phase (§7 of the design spec), the single highest-leverage phase in the
Sub-project 6 roadmap. **Shipped 2026-08-28** — see
`docs/superpowers/specs/2026-08-28-rule-signature-representation-design.md`.

`Riptide.Derivation.Rule`/`Signature`/`Var`/`Literal.{FactPattern,CapabilityReference,RuleReference}`
represent a parsed Rule; `Riptide.Derivation.Parser.decode/1` parses the Soufflé-shaped Datalog-
clause concrete syntax into that structure (NimbleParsec, with the same untrusted-input heap-cap
guard `Riptide.RDF.TurtleCodec.decode/1` already carries). `Riptide.Derivation.RuleRDFCodec.
to_rdf/1`/`from_rdf/2` reify a Rule as RDF triples ("Rules are Facts" — SPIN's `sp:` vocabulary for
fact-pattern literals, new `urn:riptide:vocab:` terms for capability-reference/rule-reference
literals) and read it back, asserted through the existing `Event`/`StreamServer` mechanism with no
new persistence path. `linkml-datalog` re-checked 2026-08-28: still dormant (last pushed
2024-02-14) — unchanged from the design spec's prior checks.

**Status**: Phase 6c-i-a shipped 2026-08-28. 20 phases remaining across the primary spine and the
three parallel tracks — see the design spec's §7 for the full roadmap.

### 6c-i-b — Fact-pattern matching and joins

Second link in the walking skeleton (`6b-i → 6c-i-a → 6c-i-b → 6d-i → ...`), following
6c-i-a's Rule/Signature representation. **Shipped 2026-08-28** — see
`docs/superpowers/specs/2026-08-28-phase-6c-i-b-fact-pattern-matching-design.md`.

`Riptide.Derivation.Matcher.bindings/2`/`evaluate/2` evaluate the fact-pattern-only fragment of
QueryInterpretation: joins across a Rule's Body against a caller-supplied `RDF.Graph.t()`, then
concludes the Head. Built as a thin adapter over `RDF.Query`/`RDF.Query.BGP` (already available
transitively via the `rdf` hex dependency, no new dependency) rather than a hand-rolled join
algorithm. Closes a real unbounded-atom-creation risk found during design: `RDF.Query.BGP`'s
matcher requires atom-based variables, so Body variables are translated through a small, fixed,
compile-time-created pool of placeholder atoms rather than `String.to_atom/1` on untrusted
variable-name text. Also enforces Datalog rule safety (every Head variable must appear in the
Body) and rejects Bodies containing capability-reference/rule-reference literals (out of scope
until 6b-i's WASI substrate exists).

**Status**: Phase 6c-i-b shipped 2026-08-28. 19 phases remaining across the primary spine and the
three parallel tracks — see the design spec's §7 for the full roadmap.

### 6b-i — WASI execution substrate

Foundation-track phase (§7 of the design spec), independent of every other Sub-project 6
phase. **Shipped 2026-08-29** — see
`docs/superpowers/specs/2026-08-28-phase-6b-i-wasi-execution-substrate-design.md` (Revision 2).

`Riptide.Capability.authorized?/3`/`invoke/4` authorize and invoke a tenant-scoped WASI
Preview 2 component. Authorization reuses the existing `Riptide.Authz` ACP machinery via a
synthetic `["capabilities", name]` path and a new `:invoke` mode, rather than a parallel grant
mechanism. Invocation shells out to the `wasmtime` CLI as a separate OS process — not `wasmex`,
which was proven during design to be unable to bound a WASI Preview 2 component's execution
time at all (its Components API's fuel accounting operates on a different native resource type
than its Components store, and its `call_function/4` timeout is checked only before/after
execution, never during; a real infinite-loop fixture component demonstrated the Elixir process
can be killed while the native computation keeps consuming CPU indefinitely). The external
`wasmtime` CLI's own `-W fuel=`/`-W timeout=`/`-W max-memory-size=` flags all verified to trap
deterministically, with OS-process-level resource reclaim on exit. WASIX (subprocess spawning)
is dropped entirely — it's a Wasmer-specific technology with no path on the wasmtime-based stack
this project uses, and no current Capability needs it.

**Status**: Phase 6b-i shipped 2026-08-29. 18 phases remaining across the primary spine and the
three parallel tracks — see the design spec's §7 for the full roadmap.

### 6d-i — Mechanical wiring

Third link in the walking skeleton (`6b-i → 6c-i-a → 6c-i-b → 6d-i → 6e-i → ...`), the
first phase exercising 6b-i's `Riptide.Capability.invoke/4` and 6c-i-b's
`Riptide.Derivation.Matcher` together in one real end-to-end path. **Shipped 2026-08-29**
— see `docs/superpowers/specs/2026-08-29-phase-6d-i-mechanical-wiring-design.md`.

`Riptide.Derivation.ExecuteInterpreter.call_template/3` is a direct generalization of
`Matcher.evaluate/2`: a Rule's Body resolves left-to-right, with maximal runs of
`FactPattern` literals resolved via a new `Matcher.bindings/3` (a backward-compatible
seeded-join extension) and `CapabilityReference`/`RuleReference` literals invoked once per
active branch — a `RuleReference` backtracks over its (possibly multiple) nested Outcomes,
a `CapabilityReference` never does, since `Capability.invoke/4` is always single-valued.
`NativeTemplate`/`Template` stay pure structural predicates over `Rule`, not new types, per
the parent spec's own framing. A real inconsistency found during design between the parent
spec's original worked example and the 2-arity Head invariant (established later, during
6c-i-a's own implementation) was resolved by scoping `RuleReference` to exactly one input
argument for this phase — documented explicitly, not silently papered over.

**Status**: Phase 6d-i shipped 2026-08-29. 17 phases remaining across the primary spine and
the three parallel tracks — see the design spec's §7 for the full roadmap.

### 6e-i — Anti-unification algorithm

Fourth link in the walking skeleton (`6b-i → 6c-i-a → 6c-i-b → 6d-i → 6e-i → 6e-ii → ...`),
unblocked by 6c-i-a alone. **Shipped 2026-08-29** — see
`docs/superpowers/specs/2026-08-29-phase-6e-i-anti-unification-design.md`.

`Riptide.Derivation.AntiUnifier.generalize/2` computes a Rule × Rule least-general-
generalization (Plotkin 1970) plus the two recovering substitutions, operating purely over
6c-i-a's in-memory representation — no execution substrate, no real Capability. A Rule's
Body is a logical conjunction, so anti-unifying two Bodies is a search over which literal in
one corresponds to which in the other (an alignment), pruned by the existing structural
constraint that `FactPattern.predicate`/`CapabilityReference.capability`/`RuleReference.rule`
are always fixed IRIs, never `Var.t()` — two literals can only pair if they share the same
identifying IRI, kind, and arity. Multiple mutually-incomparable alignments are arbitrated
via bottom-clause-style bounding, concretely read as: keep only the candidates introducing
the fewest fresh variables, returning all ties (`generalize/2`'s own return type is a list
for exactly this reason) rather than collapsing to one answer — a still-tied result is
DedupGate's (6e-iii) concern, not this phase's. A real correctness point found during design,
not obvious from Plotkin's classical statement: a `Var.t()` never short-circuits the
"already the same" fast path via string-name equality, since two different Rules' same-named
variables are unrelated (variable names are rule-local and arbitrary) — every `Var.t()`
comparison goes through the shared, injective memo map unconditionally. Generalization safety
(a Head variable absent from a possibly-shrunk Body) is deliberately not checked here — it's
free from `Matcher.evaluate/2`'s existing `check_safety/2` for whoever evaluates a
generalization later, most plausibly 6e-ii.

**Status**: Phase 6e-i shipped 2026-08-29. 16 phases remaining across the primary spine and
the three parallel tracks — see the design spec's §7 for the full roadmap.

### 6e-ii — Generalization Fidelity replay harness

Fifth link in the walking skeleton (`6b-i → 6c-i-a → 6c-i-b → 6d-i → 6e-i → 6e-ii → ...`),
unblocked by 6e-i (needs a Generalization to test against) and 6b-i (needs the WASI sandbox
to replay into). **Shipped 2026-08-29** — see
`docs/superpowers/specs/2026-08-29-phase-6e-ii-generalization-fidelity-design.md`.

`Riptide.Derivation.GeneralizationFidelity.check/3` checks whether a ground Trace (a
`Rule.t()` whose Signature has no free parameters, per parent spec §5) replays faithfully.
The key insight: a ground Trace's `CapabilityReference.result` field, once ground, already
*is* that invocation's recorded output — no new Provenance/recording type was needed, and
the harness never touches `AntiUnifier`/Generalization/substitution at all, reusing
`ExecuteInterpreter.Context` and the real, unmodified `Capability.invoke/4` as-is. Replay is
a straight-line recursive walk over the Body (no join search — everything's already
concrete): FactPattern literals check graph membership via `RDF.Graph.include?/2`;
`:effect`-kind Capabilities are re-invoked (real `wasmtime`) and compared against the
recorded result; `:observe`-kind Capabilities are always trusted from the recorded result and
never invoked, matching parent spec §4's literal wording that the external world isn't
expected to be frozen between runs; `RuleReference` literals recurse through
`context.rules`, reusing the same map `ExecuteInterpreter` already uses for live execution,
with a nested fidelity failure wrapped as `{:nested, iri, inner_reason}` while a nested
structural error propagates unwrapped (matching `ExecuteInterpreter`'s own convention). A
pre-existing quirk was documented, not fixed: `ExecuteInterpreter.bind_result/3` binds a
Capability's raw invoke output as a plain Elixir string rather than an `RDF.Term.t()`, as its
declared type implies — fixing it would mean touching already-shipped, tested 6d-i code, and
both sides of the fidelity check's `==` comparison come from the same `Capability.invoke/4`
path regardless, so they stay mutually consistent. A round-trip integration test composes
`AntiUnifier.generalize/2` → reconstruct each candidate via its own recovering substitution →
`check/3` on each reconstructed Trace, satisfying the exit criterion's literal wording ("given
a Generalization and its source Traces...") end-to-end via test composition rather than the
module's own signature.

**Status**: Phase 6e-ii shipped 2026-08-29. 15 phases remaining across the primary spine and
the three parallel tracks — see the design spec's §7 for the full roadmap.

### 6e-iii — DedupGate orchestration

Sixth link in the walking skeleton (`6b-i → 6c-i-a → 6c-i-b → 6d-i → 6e-i → 6e-ii → 6e-iii →
{6f, 6g-i}`), unblocked by 6e-i (#78), 6e-ii (#79), and 6d-i (#64). **Shipped 2026-08-29** —
see `docs/superpowers/specs/2026-08-29-phase-6e-iii-dedupgate-orchestration-design.md`.

Two new modules: `Riptide.Derivation.Catalog` (storage) and `Riptide.Derivation.DedupGate`
(the `Reject`/`Merge`/`Admit` decision plus the human review workflow), scope-parameterized
`Tenant`/`Hub` from the start. The key insight: a `CatalogEntry ⊑ Rule` is just more RDF
Facts, so Catalog needed no new persistence subsystem — it reuses `StreamServer`/`Event`/
`Patch`/`RuleRDFCodec`/`Matcher` exactly as `RiptideWeb.LDP.ResourceController` already does
for LDP resources, as one more resource-stream namespace. `Merge` reuses
`AntiUnifier.generalize/2` a second time (candidate × existing entry) instead of inventing a
graph-merge algorithm; `Reject` vs. `Merge` reduces to a mechanical check on the recovering
substitution's own values (`entry_unchanged? = Enum.all?(Map.values(sub_entry),
&match?(%Var{}, &1))`) — no alpha-equivalence checker needed. `supersede_entry/2` and
`resolve_pending_review/3` both retag rather than delete (a 2-triple patch swapping one
`rdf:type`), avoiding a transitive-closure graph-deletion problem discovered while grounding
the implementation plan and fixed in the spec before any code was written.
`AntiUnifier.substitute/2` was promoted from a helper duplicated in 6e-i's and 6e-ii's own
test files into real production code, since `DedupGate` needed it for real for the first
time. One real finding surfaced only by testing: two "tied" candidate generalizations from
`AntiUnifier.generalize/2` are not guaranteed to be alpha-equivalent to each other (a
symmetric literal swap happens to produce isomorphic ones; an asymmetric one does not) —
verified directly rather than assumed, after an initial proof attempt turned out to be wrong.

**Status**: Phase 6e-iii shipped 2026-08-29. 14 phases remaining across the primary spine and
the three parallel tracks — see the design spec's §7 for the full roadmap.

### 6f — LLM fallback loop

Seventh link in the walking skeleton (`6b-i → 6c-i-a → 6c-i-b → 6d-i → 6e-i → 6e-ii → 6e-iii →
{6f, 6g-i}`), unblocked by 6e-iii (#66). **Shipped 2026-08-29** — see
`docs/superpowers/specs/2026-08-29-phase-6f-llm-fallback-loop-design.md`.

`Riptide.Derivation.LLMFallback.run/3`: Task with no Catalog match → LLM-guided Capability
invocation → ground Trace. The LLM authors Rule text directly, reusing `Parser.decode/1`
completely unmodified — `Matcher`'s and `Parser`'s own doc comments already called Rule Body
text "untrusted/LLM-authorable" before this phase existed. `ExecuteInterpreter` gained one
small, purely additive `resolve_bindings/3`, exposing the bindings a live run needs to become
a ground Trace via `AntiUnifier.substitute/2` (its fourth real production caller) — zero risk
to `call_template/3`'s own shipped, tested behavior. The LLM call itself is Elixir-level
platform infrastructure — a small injectable `Client` behaviour (real Anthropic-backed
implementation + fake for tests), configured via `Application.get_env/3` exactly like
`Riptide.Authz`'s own `authz_store` pattern. Investigated and ruled out modeling it as a
Capability instead (conceptual mismatch — Riptide's own reasoning step, not a tenant-granted
external-system integration — plus `Capability.invoke/4` hardcodes `-S inherit-network=n`
today, so no Capability can reach the network at all yet). The capstone test — two
`LLMFallback.run/3` calls → `AntiUnifier.generalize/2` → `DedupGate.propose/4` →
`approve_review/2` → live in `Catalog.list_entries/1` — is the first test in this whole
sub-project to exercise the entire walking skeleton end-to-end in one place.

**Status**: Phase 6f shipped 2026-08-29. 13 phases remaining across the primary spine and the
three parallel tracks — see the design spec's §7 for the full roadmap.

### 6g-i — Exact/keyword Discovery

Eighth link in the walking skeleton, and its own final step (`6b-i → 6c-i-a → 6c-i-b → 6d-i →
6e-i → 6e-ii → 6e-iii → {6f, 6g-i}`), unblocked by 6e-iii (#66). **Shipped 2026-08-29** — see
`docs/superpowers/specs/2026-08-29-phase-6g-i-exact-keyword-discovery-design.md`.

`Riptide.Derivation.Discovery.find/2`: exact/keyword lookup over CatalogEntry. Tokenizes the
query and each found entry's predicate local name (camelCase-aware), ranks word-set-equal
entries above any partial-overlap keyword match, and breaks ties within either tier by
specificity (free-variable count) — the same idea 6e-i/6e-iii already established for
anti-unification scoring. `recency` and `StabilityClass` conflict-resolution tiers were both
investigated and explicitly deferred, for two different concrete reasons: `recency` isn't
actually free (`Catalog.list_entries/1` folds the event log into an unordered `RDF.Graph`,
discarding admission order — a blank-node-counter proxy was considered and rejected as unsound
for a distributed, Ra-replicated system); `StabilityClass` doesn't exist as a field anywhere in
shipped code and would mean retrofitting `Capability.Definition` for something issue #68 never
asked for. `ExecuteInterpreter.call_template/4` — an already-implemented private clause used
internally by `invoke_rule/4` — became public (pure visibility widening, zero behavior change),
letting a caller seed a found template's free variables against a new Task's own concrete
arguments. The capstone test closes the walking skeleton's own `{6f, 6g-i}` branch end-to-end
for the first time with **zero** LLM calls: two `LLMFallback.run/3` calls admit a CatalogEntry
via the full `AntiUnifier.generalize/2` → `DedupGate.propose/4` → `approve_review/2` path, a
third task is found by `Discovery.find/2`'s keyword tier, and invoked directly via
`ExecuteInterpreter.call_template/4`.

**Status**: Phase 6g-i shipped 2026-08-29. 12 phases remaining across the primary spine and the
three parallel tracks — see the design spec's §7 for the full roadmap.

### 6a — Bitemporal fact shape

Foundation-track phase (§7 of the design spec, `depends on: nothing`), independent of every
other Sub-project 6 phase. **Shipped 2026-08-29** — see
`docs/superpowers/specs/2026-08-29-phase-6a-bitemporal-fact-shape-design.md`.

Lets a Fact carry a ValidTime interval (RDF-star `validFrom`/`validTo` annotations, simple
`xsd:dateTime` literal values) distinct from its TransactionTime, via the existing LDP write
path's Turtle body (annotation-sugar syntax `s p o {| pred obj |}`) — no new write API. Two
findings, both verified empirically rather than assumed, collapsed this phase's scope well
below the parent spec's own framing: (1) the vendored `rdf` dependency's `RDF.Query.BGP` engine
already treats RDF-star quoted-triple patterns as first-class, variable-bindable pattern
elements — no duplication into a parallel plain-triple form is needed for the derivation layer
to reason over ValidTime, contrary to the parent spec's §8.4 assumption; that duplication
concern becomes 6c-iii-b's (much smaller than assumed) job of widening `FactPattern.args` to
admit quoted-triple patterns, not a storage-layer mechanism. (2) The existing write/read/storage
path — `TurtleCodec`, `RiptideWeb.LDP.ResourceController`, `Event`/`Patch`'s `%{v: 1, ...}`
envelope, and real Ra-backed `StreamServer` persistence — already round-trips RDF-star content
correctly with **zero** code changes beyond widening `Patch.triple`'s Dialyzer type (a
type-only change; runtime behavior needed no fix). Also found and documented: Turtle-star's bare
`<<s p o>> pred obj .` form only asserts the annotation triple, not the base fact — the
annotation-sugar form `s p o {| pred obj |}` is the one this phase's spec designates as correct,
asserting both. Full OWL-Time reified `Instant`/`Interval` individuals were considered and ruled
out in favor of simple literal-valued annotations, since nothing implements Allen-relation
comparison yet; the Allen-relation vocabulary subset (`before`/`after`/`meets`/`overlaps`/
`during`/`starts`/`finishes`/`equals`) is named in the spec for a future querying phase to
implement against, not built here.

**Status**: Phase 6a shipped 2026-08-29. 11 phases remaining across the primary spine, the
Foundation track, and the parallel tracks — see the design spec's §7 for the full roadmap.

### 6b-ii — Supervised long-running process primitive

Foundation-track phase (§7 of the design spec, `depends on: nothing`), independent of every
other Sub-project 6 phase. **Shipped 2026-08-29** — see
`docs/superpowers/specs/2026-08-29-phase-6b-ii-supervised-process-design.md`.

`Riptide.SupervisedProcess` — a reusable `DynamicSupervisor` + `Registry` primitive, typed for
the revocable/restartable adaptation-safety property from session types with runtime adaptation
(Di Giusto & Pérez, arXiv:1312.2699), that a future blob store (6j) and persistent Capability
grant would be built from. The parent spec's own claim that `Riptide.Stream.StreamServer`'s
supervision-tree shape was "a real, citable bridge to OTP semantics" turned out not to hold up —
verified directly that `StreamServer` isn't a `GenServer` at all (Ra owns that process opaquely),
and no `Supervisor`/`DynamicSupervisor`/`Registry` existed anywhere in Riptide's own code before
this phase. Splits the adaptation-safety property into two honestly-distinct mechanisms rather
than conflating them: voluntary restart/revoke gating (`request_restart/1`/`request_revoke/1`,
refused via `{:error, :session_active}` when a session is active — a crash cannot be "refused,"
by definition, so this is deliberately scoped to in-band, evaluable requests only) and
crash-session legibility (`Riptide.SupervisedProcess.SessionTracker`, an ETS-backed detection
mechanism — no resumption logic, just a legible trace instead of silent data loss). The
session-active check runs inside the target process's own serialized mailbox
(`handle_stop_if_idle/4`), closing a real race a design sketch checking from outside the process
(`:sys.get_state/1` then a separate stop call) would have had. Restart and revoke share one
supervisor mechanism (`:transient` restart type, differing only in exit reason — abnormal vs.
`:normal`) rather than needing special-cased logic.

**Status**: Phase 6b-ii shipped 2026-08-29. 10 phases remaining across the primary spine, the
Foundation track, and the parallel tracks — see the design spec's §7 for the full roadmap.

### 6h-i — Pattern Hub threat model

Foundation-track phase (§7 of the design spec, `depends on: nothing`), independent of every
other Sub-project 6 phase. **Shipped 2026-08-29** — see
`docs/superpowers/specs/2026-08-29-phase-6h-i-pattern-hub-threat-model-design.md`. Unlike every
other Sub-project 6 phase, this one's deliverable *is* the design document — its exit criterion
("a written auth/rate-limit threat model exists and is reviewed") has no code component.

Brainstorming this phase found and corrected a real gap in the parent design spec itself: every
prior revision described Pattern Hub curation as "Riptide-internal," but no design work had ever
concretely defined who that was. Corrected first, separately, in the parent spec's own eleventh
revision: **Tenant is the sovereign unit** — any Tenant may publish/share content, reviewed
through that Tenant's own already-shipped DedupGate authority (6e-iii), never a separate
third-party reviewer; sharing is designed to work identically whether the receiving Tenant is on
the same Riptide deployment or a different, independently-operated one (federation, a stated
design goal with cross-instance trust verification explicitly deferred). Once grounded against
the corrected model, 6h-i's own threat model simplified substantially: every write action on the
Hub surface (propose, approve/decline-review, install, Crosswalk-propose) is always performed as
some real, already-existing Tenant using its own already-shipped `Authz.evaluate/4` — no new
authorization primitive needed anywhere, and two threats from an earlier draft (privilege
escalation on a central review gate; a structural mismatch in `Authz.evaluate/4`'s signature)
were retired as no longer applicable rather than silently dropped. The most important residual
risk became tenant-data leakage via incomplete generalization (anti-unification only turns a
position into a variable where source Traces actually disagreed, so a literal constant across
every Trace a Tenant has seen so far can ship into a publicly-installable Pattern verbatim) —
with no central reviewer as a safety net, a Tenant's own mandatory human review before
`Admit`/`Merge` is the sole line of defense, called out explicitly rather than assumed safe.

**Status**: Phase 6h-i shipped 2026-08-29. 9 phases remaining across the primary spine, the
Foundation track, and the parallel tracks — see the design spec's §7 for the full roadmap.

### 6h-ii — Pattern Hub deployment

Consumes 6h-i's threat model plus 6e-iii's DedupGate and 6g-i's Discovery; unblocks 6i. **Shipped
2026-08-29** — see `docs/superpowers/specs/2026-08-29-phase-6h-ii-pattern-hub-deployment-design.md`.
Stands up the Pattern Hub as a real, network-publicly-reachable HTTP surface for the first time.

Route topology splits by shape rather than by a single top-level namespace: tenant-less reads
(`GET /hub/search`, `GET /hub/entries/:node_id`, optional auth via the existing `Authenticate`
plug unmodified) and tenant-scoped writes (`POST /tenants/:tenant_id/hub/propose`,
`.../pending-reviews/:node_id/approve`, `.../decline`), the latter reusing the exact existing
`[:api, :tenant, :auth, :authz]` pipeline unchanged — zero new auth-plug logic anywhere, matching
6h-i's own requirement. `DedupGate.propose/4`/`approve_review/2` widened to `propose/5`/
`approve_review/3`, splitting the single `scope` argument into `target_scope` (which Catalog to
classify/admit against) and `review_scope` (whose pending-review stream owns the review) — a
pure, backward-compatible signature widening; every pre-existing caller has
`target_scope == review_scope`. Publishing to Hub is the *same* `propose/5` call as a Tenant's
own Tenant-scope proposal, made at the same moment with the same fresh candidates
(`target_scope: :hub`, `review_scope: {:tenant, tenant_id}`) — not a later "share my already-
admitted entry" action, which would have needed retaining substitutions `PendingReview` doesn't
carry. `decline_review/2`'s own signature stayed unchanged (it only ever touched the review
scope, never the Catalog target). `ProposeController` is scoped to fact-pattern-only candidates
(no `CapabilityReference`/`RuleReference` literals) — a real, previously-unaddressed gap surfaced
during design: no Capability registry exists anywhere in the project, so `DedupGate`'s fidelity
replay-testing has no safe way to resolve `context.capabilities` from a network request (a
caller-supplied `Capability.Definition.component` would be an arbitrary-file-execution risk).
Full Install (Crosswalk-aware field binding) stays explicitly deferred to 6i, per the exit
criterion's own literal wording.

Three real, pre-existing bugs found and fixed along the way, all invisible until this phase made
`:hub` a genuinely long-lived, repeatedly-read/written stream for the first time (every prior use
of `:hub` — including 6e-iii's own Catalog tests — created and destroyed it within one isolated
test, never exercising it the way a real, growing Hub Catalog behaves):

1. `Riptide.RaTestHelpers.cleanup_stream/1` (`RaCluster.force_delete/1`) force-deletes the entire
   underlying Ra server for a stream_id — safe for a `unique_tenant()`-scoped stream nobody else
   touches, but confirmed live to race a subsequent write against the *same* stream_id (a
   `:noproc` before the lazily-recreated server catches up) when called on `:hub`, which is
   shared and non-unique. Fixed by no longer force-deleting `:hub` from any test (it already
   tolerates accumulation — that's why `catalog_test.exs`'s own "Hub vs. Tenant scope isolation"
   test asserts via `Enum.any?`/`refute Enum.any?` rather than an exact list).
2. `Riptide.RaCluster.process_command/2`/`consistent_query/2`/`local_query/2` raised immediately
   on any transient failure — a gap the code's own comment had flagged as needed "once the
   Clustering/HA sub-project adds multi-node membership" (already shipped, phase 3c) but never
   implemented. Fixed with a bounded retry (50 attempts, 100ms backoff, matching this file's own
   `retry_cluster_change/2` precedent) on `{:error, :noproc}`/`:nodedown`/`:shutdown`, the
   already-flagged `{:timeout, _}`, and the raw `:exit` `catch` clause; any other, non-transient
   `{:error, reason}` still raises immediately, unretried. General `RaCluster` fix, not
   Hub-specific — protects every caller of these three functions.

3. A third, deeper bug the retry above did *not* fix on its own: `:ra` 2.15.4's own
   `apply_consistent_queries_effects/2` (`true = LastApplied >= ReadCommitIndex`) can fail its
   internal assertion and crash the *entire* `gen_statem` process backing a stream's Ra server —
   root-caused precisely via the actual crash reports in a failing CI run's log
   (`gen_statem ... terminating`, `** (stop) {:EXIT, {{:badmatch, false}, ...}}`), confirmed to
   happen asynchronously inside `ra_server_proc`'s own leader-loop processing, independent of any
   specific caller — not something a caller-side retry, however large, can ride out. Once that
   happens, nothing else recovers it on its own: `Riptide.Stream.Placement`'s cache
   (`server_ids!/1`) is a pure ETS read, never invalidated, so every subsequent caller keeps being
   handed the now-dead registration; `Riptide.Stream.ReplicaHealer`'s repair is replace-based
   (swap a dead member for a *different* live node) and `pick_replacement/2` always excludes the
   dead member's own node from candidacy, so it's a no-op for a single-member (`RF=1`, this test
   environment's `:hub`) cluster's own only member dying — there's no spare node to promote.
   Fixed with a new `RaCluster.restart_server/1` (`:ra.restart_server/2` — recovers a crashed
   server in place from its own durable log, unlike `start_or_join_replicated/3` which forms a
   brand-new cluster or `replace_member/5` which needs surviving *other* members to agree to a
   membership change) wired into `StreamServer`'s existing last-replica fallback: once every
   replica in a stream's list has been tried and the last one's failure survives
   `RaCluster`'s own transient retry, attempt a same-node restart-in-place once, then retry the
   original call once more (itself get its own full retry budget, covering the brief window a
   freshly-restarted server needs to re-elect itself leader) before finally letting a genuine
   failure propagate uncaught. Not Hub-specific — every stream was exposed to this crash class,
   `:hub` just made it visible first by being the first stream kept alive and repeatedly
   read/written across a whole realistic session (every prior use of `:hub`, and every other
   stream in the existing suite, was always short-lived/isolated per test, so a mid-session server
   crash had no chance to matter before). Evidence: reproduced live via 2 of 3 consecutive CI runs
   on this PR failing with exactly this crash before the fix, then 3 consecutive full local-suite
   runs with zero Hub-related failures after it (the only failures across those 3 runs were
   different, already-flaky, unrelated pre-existing tests — `SseControllerTest`/
   `ReplicationChannelTest`'s own documented rate-limit boundary flake, and one `ResourceControllerTest`
   placement-assignment flake).

**Status**: Phase 6h-ii shipped 2026-08-29. 8 phases remaining across the primary spine, the
Foundation track, and the parallel tracks — see the design spec's §7 for the full roadmap.
