# Riptide — Production Readiness Roadmap

**Last updated:** 2026-08-24

This tracks Riptide's path from "working reference implementation" (shipped: see
[PR #1](https://github.com/OpenFASTER-Standard/riptide/pull/1)) to "production-grade centerpiece
of an organization's data architecture." Kept proactively up to date as work lands — this is the
first place to check for current status, not a historical log.

## Sub-projects

| # | Sub-project | Status |
|---|---|---|
| 1 | Persistence & durability | **Shipped** — see below |
| 2 | Docker image + CI/CD | **Shipped** — see below |
| 3 | Clustering / horizontal scale / HA | Not started (multi-node `Ra` replication belongs here — see §1) |
| 4 | Security & multi-tenancy (auth, WAC/ACP, TLS) | Not started |
| 5 | Observability & operability (metrics, logging, health probes) | Not started |

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
server process within the same live BEAM node rather than exercising a real cold restart. Tracked
as [OpenFASTER-Standard/riptide#6](https://github.com/OpenFASTER-Standard/riptide/issues/6); not
yet fixed.

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
[PR #4](https://github.com/OpenFASTER-Standard/riptide/pull/4) (invalid `trivy-action` tag pin)
and [PR #5](https://github.com/OpenFASTER-Standard/riptide/pull/5) (QEMU-under-JIT segfaults on
arm64 → native `ubuntu-24.04-arm` runners; a digest-merge `printf` bug; the CRITICAL gate missing
`ignore-unfixed`; a missing `checkout` step; OCI labels/annotations dropped by the job
restructuring). Final verification against `main` itself (commit `5801afe`) confirmed a clean,
first-try, no-fixes-needed release run with everything above genuinely present on the published
`ghcr.io` image. See §1's caveat above for one durability finding from that same verification
pass — real, but in sub-project 1's code, not this sub-project's own deliverables.

## 3-5. Not yet started

Will be filled in as each sub-project reaches design.
