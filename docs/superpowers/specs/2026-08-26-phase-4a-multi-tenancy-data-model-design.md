# Phase 4a — Multi-Tenancy Data Model — Design

**Status:** Approved 2026-08-26.

Sub-project 4 (Security & multi-tenancy) is decomposed into phases 4a-4d (see `PROGRESS.md`).
This phase is the first: nothing else in sub-project 4 can be meaningfully scoped without a
tenant concept existing first.

## 1. Context & motivation

Riptide has zero tenancy concept today. A `stream_id` is a raw URL-derived string with no owner
(`RiptideWeb.LDP.ResourceController.stream_id_for/1` builds it directly from a hardcoded fixed
prefix, `"https://riptide.example/resources/"`, plus the request path) — every resource in a
deployment lives in one flat, unscoped namespace. The router has no auth plug at all
(`RiptideWeb.Router`'s `:api` pipeline only does `plug :accepts`), and the WebSocket layer's own
module doc states outright that it "accepts every connection unconditionally (no socket-level
auth yet)."

Multi-tenancy is a confirmed near-term requirement (not aspirational), with **logical isolation**
as the chosen model: tenants share the same underlying infrastructure (the same fleet, the same
kind of `:ra` clusters per stream) rather than each getting dedicated resources — isolation is
enforced in software (namespacing + authorization), not by physically separating infrastructure
per tenant. This keeps operating cost and complexity from multiplying per tenant, matching this
project's existing "fleet grows, individual `:ra` groups stay small and sharded" philosophy from
sub-project 3.

This phase is scoped narrowly and deliberately: it introduces tenant-scoped *addressing* only.
No authentication (Phase 4b) or authorization/enforcement (Phase 4c) exists yet — this phase's
job is to make every resource nameable per-tenant, the seam every later phase in this sub-project
builds on, the same way Phase 3c-i's placement store shipped before 3c-iii's real routing
consumed it.

## 2. Scope

- A pluggable tenant-resolution mechanism: extract a `tenant_id` from an incoming request, via
  either a URL path segment or a subdomain, selected by configuration (both must be supported,
  not just one with the other deferred).
- Tenant-scoped resource/stream addressing: every stream's identity incorporates its resolved
  `tenant_id`, so two tenants requesting what looks like "the same" resource path get genuinely
  different, fully isolated underlying `:ra` clusters.
- Wiring tenant resolution into all three request entry points (LDP HTTP, SSE, WebSocket
  replication channel).

## 3. Out of scope

- **Any authentication** — establishing *who* is making a request is Phase 4b's job. This phase
  only resolves a `tenant_id` string from the request itself (a path segment or subdomain); it
  makes no claim about whether the caller is entitled to act as that tenant.
- **Any authorization/enforcement** — Phase 4c's job. After this phase, a caller who knows or
  guesses a `tenant_id` can still address that tenant's resources; nothing yet checks that they
  should be allowed to. This is a deliberately incremental, not-yet-secure intermediate state,
  consistent with how earlier sub-project phases have shipped structural pieces before the
  consuming/enforcing piece existed.
- **A tenant registry or tenant lifecycle** (create/list/delete tenants) — `tenant_id` is any
  resolvable string for this phase; nothing validates that a tenant "exists" in some durable
  sense. Whether tenant existence needs its own registry is a question for Phase 4b/4c, once
  identity and authorization are being designed and need something concrete to check against.
- **TLS** (Phase 4d) — fully independent of this phase.
- **Migrating existing data** — nothing is in production yet, so no migration path is needed.

## 4. Architecture

A new `Riptide.Tenancy` namespace:

- **`Riptide.Tenancy.Resolver`** — a behaviour with one callback:
  `resolve(Plug.Conn.t()) :: {:ok, tenant_id :: String.t()} | {:error, term()}`.
- **`Riptide.Tenancy.Resolver.PathSegment`** — extracts `tenant_id` from a URL path segment (the
  router gains a `/tenants/:tenant_id/...` prefix ahead of the existing `resources`/`streams`
  routes).
- **`Riptide.Tenancy.Resolver.Subdomain`** — extracts `tenant_id` from `conn.host` (e.g.
  `acme.riptide.example`).
- Selected via `Application.get_env(:riptide, :tenancy_resolver, Riptide.Tenancy.Resolver.PathSegment)`
  — the same config-driven swap pattern `RaCluster.default_ordinal_resolver/1` already uses
  (Phase 3c-i), so a deployment picks one resolution strategy for all its traffic, and tests can
  inject a stub the same way `config/test.exs` already overrides the ordinal resolver.
- A new plug, `RiptideWeb.Plugs.ResolveTenant`, runs early in the router's `:api` pipeline (before
  any resource logic), calls the configured resolver, and on success assigns
  `conn.assigns.tenant_id`. On failure (no resolvable tenant — e.g. a path missing the tenant
  segment, or a host that isn't a recognized subdomain shape) it halts the connection with `400`
  before any resource logic runs.

## 5. Tenant-scoped resource addressing

`RiptideWeb.LDP.ResourceController.stream_id_for/1` changes from:

```elixir
"https://riptide.example/resources/" <> path
```

to:

```elixir
"https://riptide.example/tenants/#{conn.assigns.tenant_id}/resources/" <> path
```

Since `RaCluster.uid_for/1` hashes the *entire* stream_id opaquely (SHA-256 over the full string),
this namespaces every stream's underlying `:ra` cluster by tenant automatically — two tenants
addressing what looks like the same resource path end up with completely different, non-colliding
`stream_id`s and therefore completely different `:ra` clusters, with no data ever comingled.
Critically, this requires **zero changes** below the web layer: `Riptide.Stream.Placement`,
`Riptide.RaCluster`, and `Riptide.Stream.ReplicaHealer` all already treat `stream_id` as an opaque
string and have no tenant-awareness to add.

`RiptideWeb.Realtime.SseController` and `RiptideWeb.Realtime.ReplicationChannel` resolve
`tenant_id` the same way (SSE via the same `ResolveTenant` plug on its own route; the WebSocket
channel via an equivalent resolution step against its own connect params/topic, since channel
joins don't flow through the same plug pipeline as HTTP requests) and build the matching
tenant-scoped stream_id before subscribing to or joining a stream.

## 6. Testing

- Unit tests for both resolvers: correct extraction on a well-formed path/host, and `{:error, _}`
  on a malformed or missing tenant segment/subdomain.
- `ResolveTenant` plug tests: `400` on an unresolvable tenant, correct `conn.assigns.tenant_id` on
  success, using both resolvers via config override.
- `ResourceController` tests confirming two different `tenant_id`s requesting the identically-named
  resource path produce two different `stream_id`s (and, by extension, two fully isolated `:ra`
  clusters) — the core isolation property this phase exists to establish.
- SSE/WebSocket tests confirming their own tenant resolution produces the same stream_id a
  matching HTTP request for the same tenant/path would.
