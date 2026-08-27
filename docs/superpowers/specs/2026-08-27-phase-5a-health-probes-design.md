# Phase 5a — Health & Readiness Probes

## Context & motivation

Phase 5a is the first phase of sub-project 5 (Observability & operability), the last sub-project
on Riptide's roadmap. Sub-project 5 bundles three independent concerns — health/readiness probes,
structured logging, and metrics — decomposed into phases the same way sub-projects 3 and 4 were,
rather than one monolithic spec. This phase covers only health/readiness probes, chosen first
because it's the smallest change with the most immediate operational safety benefit.

Today, `RiptideWeb.HealthController` (`lib/riptide_web/health_controller.ex`) exposes a single
`GET /health` that unconditionally returns `200 "ok"` — it checks nothing about the application's
actual state. `k8s/statefulset.yaml` points both `readinessProbe` and `livenessProbe` at this same
endpoint. In practice this means a node that can no longer reach the shared placement Ra cluster —
and therefore cannot correctly resolve stream placement for any LDP/SSE/WebSocket request — still
reports healthy and keeps receiving traffic.

## Scope

- Split the single `/health` route into `/health/live` and `/health/ready`, each backed by its own
  controller action.
- `/health/live`: unconditional `200 "ok"`, identical to today's behavior — deliberately checks
  nothing beyond "is Phoenix itself responsive," so a degraded downstream dependency never
  triggers a pod restart.
- `/health/ready`: performs one cheap, real query against the shared placement Ra cluster via
  `Riptide.Placement.lookup/1`. Returns `200` on success, `503` if the placement cluster is
  unreachable.
- Update `k8s/statefulset.yaml`'s `readinessProbe` to `/health/ready` and `livenessProbe` to
  `/health/live`.
- Update `config/prod.exs`'s `force_ssl` exclude paths from `["/health"]` to
  `["/health/live", "/health/ready"]`.
- Remove the old `/health` route outright — no alias is kept. Riptide's own example k8s manifests
  are the only real consumer of this path; there's no external contract to preserve.

## Out of scope

- Structured logging and metrics — Phases 5b and 5c respectively, not covered here.
- Checking libcluster peer connectivity or the OIDC JWKS cache as part of readiness — considered
  and deliberately deferred; placement-cluster reachability is the one dependency every request
  path actually needs, and covers the most common real failure mode (a node cut off from
  placement) without over-checking. Can be added to `/health/ready` in a later phase if a real gap
  surfaces.
- Any change to `Riptide.Application`'s supervision tree — this phase only adds controller actions
  and a routing/config change.
- A custom timeout wrapper around the readiness check — `:ra.consistent_query/2` (used internally
  by `Riptide.Placement.lookup/1`) already carries its own bounded timeout per ordinal attempt; see
  Architecture below for the worst-case latency this implies.

## Architecture

**`/health/live`** stays exactly as `RiptideWeb.HealthController`'s current `show/2` action
behaves today (unconditional `200`), just renamed/re-routed. No new logic.

**`/health/ready`** calls `Riptide.Placement.lookup/1` with a fixed sentinel stream ID (e.g.
`"__riptide_health_check__"`) that will never correspond to a real stream. This is the cheapest
real placement-cluster query already available: `lookup/1` performs an O(1) map lookup via
`PlacementMachine.get/2` under the hood, unlike `Riptide.Placement.list_all/1`, which returns the
*entire* streams map and would scale badly if called on every probe tick. A successful call —
even one that returns `nil` because the sentinel ID isn't a real stream — proves this node can
reach a live member of the placement Ra cluster, which is what actually matters for readiness.

`Riptide.Placement.lookup/1` (via its private `with_ordinal_fallback/2` helper, confirmed by
reading `lib/riptide/placement.ex:121-133`) tries each of the 3 fixed placement ordinals in turn
and only raises if all 3 fail. `/health/ready`'s action wraps this call in a `try/rescue`: a raised
exception (whether from a Ra-level error or a Ra-level timeout — both surface as a `RuntimeError`
from `RaCluster.consistent_query/2`) is caught and converted into a `503`, never an unhandled
crash.

**Worst-case latency**: each of the 3 ordinal attempts carries its own internal Ra timeout before
falling through to the next ordinal, so a fully-unreachable placement cluster means `/health/ready`
can take up to roughly 3× Ra's per-query timeout to respond with `503`. This phase does not add a
shorter custom timeout on top — Ra's own timeout is already a bounded, real number — but the
implementation plan should surface this as a concrete figure so `k8s/statefulset.yaml`'s
`readinessProbe.timeoutSeconds`/`periodSeconds` can be set sensibly relative to it, rather than
left at whatever default they currently have.

**Routing**: both new actions live in the same `RiptideWeb.HealthController`, added as two
top-level routes (`/health/live`, `/health/ready`) outside any tenant/auth/authz pipeline scope —
health checks are infrastructure-level and must never depend on authentication succeeding, matching
how `/health` is unscoped today.

## Testing

- `/health/live`: a request always returns `200` — there's no meaningful failure mode to exercise
  without killing the test's own BEAM, so this stays a simple happy-path assertion.
- `/health/ready`, success case: exercised against the test suite's existing shared placement
  cluster (already live for every test touching `Riptide.Stream.Placement`) — asserts `200`.
- `/health/ready`, failure case (`503`): not practically triggerable by tearing down the real
  shared placement cluster mid-suite-run, since other async tests depend on it staying up. Instead,
  force `Placement.lookup/1`'s 3-ordinal fallback (`with_ordinal_fallback/2`,
  `lib/riptide/placement.ex:121-133`) to exhaust and raise by temporarily overriding the existing
  `Application.put_env(:riptide, :ordinal_resolver, fn _ordinal -> :"nonexistent@nohost" end)` —
  the same config key `config/test.exs:33` already sets suite-wide (`fn _ordinal -> node() end`),
  and the same mechanism `RaCluster.default_ordinal_resolver/1` reads at call time. Pointing every
  ordinal at an unreachable node name makes each of the 3 attempts fail for real, without touching
  the actual shared placement cluster other tests depend on. Restore the original resolver in the
  test's own `on_exit`, matching the codebase's established setup/on_exit convention for scoped
  config overrides (e.g. `test/riptide/auth/verifier/oidc_test.exs`'s `oidc_issuer`/`oidc_audience`
  save-and-restore). This test module must be `async: false` — `:ordinal_resolver` is global
  `Application` state read by every other test touching `Riptide.Placement`/`RaCluster` across the
  suite, and `oidc_test.exs` sets the same precedent for its own global config keys.
