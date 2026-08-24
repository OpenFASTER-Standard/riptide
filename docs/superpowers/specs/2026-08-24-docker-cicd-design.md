# Riptide Docker Image & CI/CD — Design

**Status:** Approved 2026-08-24. Sub-project 2 of Riptide's production-readiness roadmap (see
`PROGRESS.md`).

**Revised 2026-08-24**: §2's "Multi-arch strategy" decision (Buildx + QEMU emulation) and §3.4's
`release.yml` description are now factually wrong and superseded — see the notes inline in both
sections. Task 8 end-to-end verification found that QEMU user-mode emulation of `linux/arm64`
reproducibly segfaults while cross-building this image (`mix deps.compile` crashes with `qemu:
uncaught target signal 11`), because BEAM's JIT generates native machine code at compile/runtime
and QEMU's user-mode emulation of freshly-generated, self-modifying target-arch code is a known
weak spot for JIT/compiled-language toolchains — not a QEMU version quirk to pin around. The
pipeline now builds each platform **natively** instead: `linux/amd64` on `ubuntu-latest`,
`linux/arm64` on `ubuntu-24.04-arm` (a free GitHub-hosted runner for public repos), merged into
one multi-arch manifest list via `docker buildx imagetools create` — Docker's own documented
"distribute build across multiple runners" pattern for exactly this scenario. §6's "Native arm64
runners" deferred-work bullet is removed accordingly: it's implemented now, not deferred.

## 1. Context and motivation

Riptide has no Dockerfile, no CI, and no repo-specific `CLAUDE.md` today — every `mix test` run
and every merge to `main` happens by hand, with no automated gate and no way to actually run the
server outside a local `mix phx.server`. Sub-project 1 (Persistence & durability) shipped real
durability guarantees inside the app; this sub-project is what makes that reachable outside a
developer's checkout — a real, published container image, plus the CI/CD and branch-protection
scaffolding to build and ship it safely and repeatably.

Scope for this sub-project: a production-grade Docker image, a CI workflow that gates every
change, a tag-triggered release workflow that builds/scans/publishes that image, and the
branch-protection settings that make `main` trustworthy. It does not cover deployment
automation to any specific target (Kubernetes manifests, Terraform, a hosting provider) — that's
implicitly a later concern once there's an image worth deploying.

## 2. Decisions made (with rationale)

- **CI provider: GitHub Actions.** Riptide lives on `github.com/OpenFASTER-Standard`; Actions
  needs no separate account/credential setup and is the default expectation for a GitHub-hosted
  project.
- **Registry: GitHub Container Registry (`ghcr.io`).** Authenticates with the same
  auto-provisioned `GITHUB_TOKEN` Actions already has — no separate account, no stored
  long-lived token to rotate, and images sit next to the code and PRs that produced them.
- **Release trigger: tag-triggered semver, not every merge to `main`.** Pushing a `v*.*.*` tag is
  a deliberate, reviewable release action. Publishing an image on every merge would make every
  merge implicitly a release with no clean version number attached.
- **Branch model: trunk-based + branch protection, not GitFlow.** `main` stays always-releasable,
  short-lived feature branches merge via PR — continuing exactly what this project has already
  been doing. `develop`/`release`/`hotfix` branches would be pure ceremony for a project with
  essentially one active line of work.
- **Scope depth: essentials + vulnerability scanning + SBOM + multi-arch (amd64/arm64).** The
  full "top notch industry best practices" ask, not a trimmed-down version.
- **Static analysis: Credo + `mix format --check-formatted` in CI, not Dialyzer.** Credo is
  fast and near-zero-setup; Dialyzer's PLT build is slow and its first run tends to surface a
  wave of pre-existing findings to triage — real value, but a separate, deliberate future
  addition rather than bundled into this sub-project.
- **Release build method: `mix release` + a hand-rolled multi-stage Dockerfile**, based on
  Phoenix's own `mix phx.gen.release` pattern — standard, transparent, and immediately
  recognizable to anyone who's shipped a production Phoenix app. Buildpacks and Nix-based builds
  were considered and declined: less transparent (buildpacks) or too much tooling investment for
  this project's current size (Nix).
- **Workflow structure: two files, `ci.yml` and `release.yml`**, not one workflow with
  conditional jobs — clean separation between "is this change good" (every push/PR) and "ship a
  release" (tag-triggered only).
- **Multi-arch strategy: native per-platform runners, merged via `docker buildx imagetools
  create`.** *(Revised 2026-08-24 — originally specified as Buildx + QEMU emulation; see the
  revision note at the top of this doc.)* `linux/amd64` builds on `ubuntu-latest`, `linux/arm64`
  builds on `ubuntu-24.04-arm` (a free GitHub-hosted runner for public repos, so no dependency on
  paid runner minutes), each pushed by digest, then merged into one multi-arch manifest list.
  QEMU emulation was the original default on the reasoning that it's "portable,
  dependency-free" and native runners were "worth revisiting later if release build times become
  a real problem" — that framing assumed the only downside was speed. In practice, QEMU
  user-mode emulation of `linux/arm64` reproducibly segfaults while compiling this app (BEAM's
  JIT generates native machine code at runtime; QEMU's emulation of freshly-generated, target-arch
  machine code is a known weak spot for JIT/compiled-language toolchains) — not a "someday"
  performance concern but an outright correctness failure discovered the first time the pipeline
  was actually run end to end (Task 8). Native runners aren't just faster here, they're the only
  approach that works.
- **No automated changelog/semver tooling.** Releases use `gh release create --generate-notes`
  (auto-generated from merged PRs) rather than a hand-maintained `CHANGELOG.md` or a
  conventional-commits-driven semantic-release tool. Both were considered; both are ceremony this
  project doesn't need while releases are cut manually and infrequently — the tag itself already
  *is* the deliberate release decision.
- **Vulnerability scan gate: fail only on CRITICAL severity with an available fix
  (`ignore-unfixed: true`).** HIGH-and-below findings are surfaced (uploaded to GitHub code
  scanning) but non-blocking. A hard fail on any HIGH finding would make releases hostage to
  upstream base-image CVEs with no available fix — and the same reasoning turned out to apply one
  level up too: Task 8 end-to-end verification hit exactly this at CRITICAL severity (a
  Debian-`will_not_fix` `zlib1g` CVE with no fix ever coming), which without `ignore-unfixed`
  would have permanently blocked every release. `ignore-unfixed` is scoped to the blocking gate
  only; the non-blocking report-everything scan still surfaces unfixed findings for visibility.
- **Branch protection: require passing CI + PR-before-merge; no mandatory approval count.** This
  is effectively a solo-maintainer project today, and every PR already goes through this
  project's own AI-driven code-review process before merge. A required-external-reviewer setting
  would lock the maintainer out of merging their own already-reviewed work. Revisit if/when a
  second human maintainer joins.

## 3. Architecture

### 3.1 Dockerfile (multi-stage)

- **Builder stage**: `hexpm/elixir` pinned to Elixir 1.18.4 / **Erlang/OTP 25** — the exact patch
  tag is verified against what's actually published at implementation time, not guessed here.
  OTP 25 is load-bearing, not a style choice: `:ra` is pinned to `~> 2.15.0` in `mix.lock`
  specifically because newer `:ra` versions require or break on a different OTP line (see
  sub-project 1's persistence design doc). The image has to match the toolchain the code was
  actually built and tested against. Runs `mix deps.get --only prod`, `mix compile`,
  `mix release`.
- **Runtime stage**: `debian:bookworm-slim` (matches the builder's glibc so the release's BEAM
  binaries/NIFs work unmodified), minimal runtime packages (`libstdc++6`, `openssl`, `ncurses`,
  `locales`, `ca-certificates`), a dedicated non-root `riptide` user, the built release copied
  in, `HEALTHCHECK` calling the existing `GET /health` endpoint
  (`lib/riptide_web/health_controller.ex` — already returns `200 "ok"`, no new code needed).
- **`.dockerignore`**: excludes `_build/`, `deps/`, `.git/`, `docs/`, `test/`, `priv/ra_data*/`,
  `erl_crash.dump`.
- **OCI labels** (`org.opencontainers.image.source`, `.revision`, `.version`, etc.),
  auto-populated by `docker/metadata-action` in the release workflow rather than hand-maintained.

### 3.2 The Ra data volume

The Dockerfile declares `VOLUME ["/data"]` and sets `ENV RIPTIDE_RA_DATA_DIR=/data` — already a
supported override from sub-project 1's config (`config/config.exs` reads
`System.get_env("RIPTIDE_RA_DATA_DIR", "priv/ra_data")`; no code changes needed here). This is
the one part of this sub-project with real correctness stakes, not boilerplate: without an
explicit volume, a naive `docker run` silently discards every stream's durable log on container
recreation — reintroducing, at the infrastructure layer, exactly the bug sub-project 1 fixed in
the application layer. The README's Docker section documents `docker run -v riptide_data:/data
...` and a `docker-compose.yml` example so a mounted volume is the obvious, documented default,
not a footgun discovered in production.

### 3.3 CI workflow (`ci.yml`)

Runs on every push and pull request. Uses `erlef/setup-beam` pinned to the same Elixir
1.18.4/OTP 25 combination as the Dockerfile — a single version, not a matrix. Testing against a
newer OTP would give false confidence, since `:ra` is pinned specifically because it's broken
there.

- **`test` job**: `mix deps.get`, `mix format --check-formatted`, `mix credo --strict`,
  `mix test`. Dependency and `_build` caching keyed on `mix.lock`'s hash.
- **`docker-build-check` job**: builds the Dockerfile (single-arch `amd64`, no push) on every
  PR/push, catching a broken release build before a release tag is ever cut.

Deliberately not included: `mix compile --warnings-as-errors`. A few pre-existing, disclosed
`:formats`-option warnings already exist in some controllers (surfaced during earlier reviews);
turning this on now would fail CI on unrelated pre-existing noise. A one-line follow-up cleanup
task, not bundled into this sub-project.

### 3.4 Release workflow (`release.yml`)

*(Revised 2026-08-24 — originally specified as a single `build-and-publish` job using Buildx +
QEMU emulation; see the revision note at the top of this doc. QEMU emulation of `linux/arm64`
reproducibly segfaulted during `mix deps.compile`, so this now builds each platform natively and
merges the result, which needs multiple jobs to fan out across two differently-architected
runners.)*

Triggers only on tags matching `v*.*.*`. Three jobs:

1. **`meta`**: lowercases the image name (`ghcr.io` requires it; this org/repo has mixed case)
   and runs `docker/metadata-action` once, up front, deriving tags from the git tag — the exact
   semver (e.g. `0.2.0`) plus `latest`, but `latest` only for a clean tag like `v0.2.0`, never a
   pre-release tag like `v0.2.0-rc1` (standard `metadata-action` semver-pattern behavior) — plus
   the OCI `labels`/`annotations` values, exposed as job outputs so both jobs below can reuse
   them without re-deriving.
2. **`build`** (matrix: `linux/amd64` on `ubuntu-latest`, `linux/arm64` on `ubuntu-24.04-arm`):
   each leg logs into `ghcr.io`, then `docker/build-push-action` builds and pushes *that
   platform only*, by digest (`push-by-digest=true`), with `labels:` from `meta` baked into that
   platform's image config and BuildKit's native SBOM/provenance attestations enabled (`sbom:
   true`, `provenance: true` — a first-class Buildx feature, not a separate tool). Each leg
   uploads its digest as a build artifact for the next job to pick up.
3. **`publish`**: downloads both digests, merges them into one multi-arch manifest list via
   `docker buildx imagetools create` (tagged with `meta`'s tags, annotated at the index level
   with `meta`'s OCI annotations — `imagetools create` doesn't inherit per-platform image-config
   labels, so the same `org.opencontainers.image.*` values are re-attached here as manifest-list
   annotations instead). Then: `aquasecurity/trivy-action` scans the merged image, results upload
   to GitHub's code-scanning tab, and the job fails only on CRITICAL-severity findings with an
   available fix (`ignore-unfixed: true` — HIGH-and-below are surfaced non-blocking, and a
   CRITICAL finding with no fix available, e.g. Debian-`will_not_fix` CVEs, is surfaced but
   doesn't block; see §2's blocking-gate rationale). Finally, `gh release create
   --generate-notes` creates a GitHub Release from the tag, with auto-generated notes from merged
   PRs since the last tag.

### 3.5 Branch protection (repo setting, not a workflow file)

Configured via `gh api` against `main`: require the `ci.yml` test job to pass before merging,
require pull requests (no direct pushes), block force-pushes and branch deletion on `main`. No
mandatory minimum-approval count (see §2 rationale).

### 3.6 Versioning convention

Plain semver (`vMAJOR.MINOR.PATCH`, optional `-rc1`-style pre-release suffixes), tagged manually
on `main` when a release is deliberately cut — no automation decides version numbers. A short
`## Releasing` section in the README documents the convention and a bump rule of thumb: breaking
StreamLD/API changes → major, new capability → minor, fixes → patch.

## 4. Testing

Once implemented, the pipeline needs to be exercised end-to-end for real, not just trusted:

- Push a throwaway pre-release tag (e.g. `v0.0.0-test`) or use `workflow_dispatch` for a dry run.
- Confirm the image builds for both `amd64` and `arm64`.
- Confirm the built image runs and `GET /health` responds `200`.
- Confirm a stream survives a container restart when the data volume is mounted — this directly
  re-proves sub-project 1's durability guarantee through the container boundary, which is the
  one thing in this whole sub-project that would be a real regression if silently broken.
- Confirm the vulnerability scan and SBOM attestation actually produce output rather than
  silently no-op-ing.
- Delete the throwaway test tag/image from the registry afterward — no leftover fake releases.

## 5. Dependencies

- New dev dependency: `{:credo, "~> 1.7", only: [:dev, :test], runtime: false}` (exact version
  verified against `mix hex.info credo` at implementation time).
- No new runtime/production dependencies — the Docker/CI tooling (`docker/*` actions,
  `aquasecurity/trivy-action`, `erlef/setup-beam`) lives entirely in GitHub Actions workflow
  files, not in `mix.exs`.

## 6. Deferred work and honest limits

- **Deployment automation to a specific target** (Kubernetes manifests, Terraform, a hosting
  provider) is out of scope — this sub-project produces a real, published, runnable image; where
  it actually runs in production is a separate, later concern.
- **Dialyzer** is a real, valuable addition, deliberately not bundled here (see §2) — a good
  candidate for its own small follow-up once there's bandwidth to triage its first-run findings.
- **Automated semver/changelog tooling** (conventional commits, semantic-release) — deliberately
  declined for now (see §2); revisit only if manual tagging becomes a real bottleneck.
