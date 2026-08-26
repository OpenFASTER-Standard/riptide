# Phase 4c — Authorization (ACP) — Design

**Status:** Approved 2026-08-26.

Sub-project 4 (Security & multi-tenancy) is decomposed into phases 4a-4d (see `PROGRESS.md`).
This is the third phase, following directly from Phase 4a (multi-tenancy data model) and Phase 4b
(pluggable authentication).

## 1. Context & motivation

Phases 4a and 4b established *who a request is for* (`conn.assigns.tenant_id`) and *who is asking*
(`conn.assigns.current_subject` — a verified claims map, or `nil` for anonymous). Neither enforces
anything: today, any caller who knows or guesses a `tenant_id` and a resource path can fully
read and write it, regardless of identity. This phase closes that gap.

Sub-project 4's own brainstorm already decided authorization uses ACP (Access Control Policy),
not WAC — ACP's policy/matcher model is more expressive than a flat ACL, in particular for the
core case a system like this actually needs: granting access to agents you haven't
pre-enumerated (e.g. "authenticated users can read, but only the creator can write"), and
"everyone except X"-style deny rules. A flat per-tenant ACL would close today's literal security
hole, but would re-invent a worse version of ACP's matcher model the moment either of those cases
came up — which is likely, given sharing data with not-yet-known agents is close to the point of
this kind of system.

This phase does **not** implement the full Solid ACP specification. Real ACP includes Access
Control Resources (ACRs) as their own discoverable, `Link`-header-advertised RDF resources,
matcher conditions on client application ID / verifiable credentials / issuer, and a separate
`Control` access mode. Riptide has no concept of client applications or verifiable credentials
today, and building ACRs as a whole second first-class resource type (with its own read/write
permission story) is significant scope with no current consumer. This phase instead borrows ACP's
core *shape* — Policies gated by Matchers, allow-and-deny with deny taking precedence, and
container-level inheritance — and drops everything else, revisiting fuller compliance only if
Solid-client interoperability becomes an actual goal.

## 2. Scope

- A policy model: `Riptide.Authz.Policy` (`effect: :allow | :deny`, `modes: [:read | :write]`,
  `matcher: :public | :authenticated | {:agent, subject}`), evaluated with container-level
  inheritance (a policy attached to a path prefix applies to everything under it) and
  deny-overrides-allow precedence.
- A pluggable storage behaviour (`Riptide.Authz.Store`), with a default implementation that
  extends the existing shared placement Ra cluster's state machine — not a new Ra cluster.
- A `RiptideWeb.Plugs.Authorize` plug enforcing the policy decision on every tenant-scoped LDP
  HTTP route.
- The equivalent enforcement for SSE and WebSocket subscriptions, via a new inverse
  `RiptideWeb.LDP.ResourceController.parse_stream_id/1` (recovering `tenant_id`/path from an
  opaque, client-supplied `stream_id`) feeding the same `Riptide.Authz.evaluate/4` decision point
  every transport calls.
- A bootstrapping mechanism so a brand-new, policy-less tenant isn't permanently locked out under
  default-deny: the first authenticated write to it atomically claims tenant-root ownership.
- A minimal policy management HTTP API (`POST`/`GET /tenants/:tenant_id/policies`), scoped to
  tenant-root policies only, so an owner can actually grant access to other agents — without this,
  the matcher expressiveness this phase exists to provide would be unreachable from outside the
  bootstrap owner.

## 3. Out of scope

- **Full Solid ACP compliance** — Access Control Resources as their own discoverable resources,
  `Link`-header discovery, and matcher conditions on client application / verifiable credential /
  issuer. See §1 for why. Nothing here precludes adding these later.
- **A `Control` access mode** — only `:read`/`:write` exist this phase. "Who can manage a
  tenant's policies" is gated by `:write` access at the tenant root (the same permission the
  bootstrap owner already holds), not a separate mode.
- **Sub-container policy management API** — `Riptide.Authz.evaluate/4`'s inheritance logic
  supports a policy at any path prefix, but this phase's HTTP management endpoints only expose
  the tenant root. Managing a policy on a specific sub-container has no API yet.
- **Policy revocation/deletion** — the management API is add-only this phase. A real, if narrow,
  gap: there is no way to remove a granted policy yet. Flagged here deliberately, not silently
  dropped — a natural fast-follow.
- **Tenant lifecycle beyond creation-via-first-write** — no rename, no delete, no listing all
  tenants. `tenant_id` remains "any resolvable string," per Phase 4a; this phase only adds that a
  tenant becomes "claimed" the first time an authenticated write succeeds against it.
- **TLS** (Phase 4d) — fully independent of this phase.

## 4. Architecture

A new `Riptide.Authz` namespace:

- **`Riptide.Authz.Policy`** — a struct: `%Policy{effect: :allow | :deny, modes: [:read | :write],
  matcher: :public | :authenticated | {:agent, subject :: String.t()}}`. `subject` is matched
  against `current_subject["sub"]` (the standard OIDC subject claim).
- **`Riptide.Authz.Store`** — a behaviour, selected via
  `Application.get_env(:riptide, :authz_store, Riptide.Authz.Store.Placement)` — the same
  config-driven swap pattern `Riptide.Auth.Verifier`/`Riptide.Tenancy.Resolver` already use:
  - `list_policies(tenant_id, path_prefix) :: [Policy.t()]`
  - `add_policy(tenant_id, path_prefix, Policy.t()) :: :ok`
  - `claim_tenant_if_unclaimed(tenant_id, subject) :: :claimed | :already_claimed`
- **`Riptide.Authz.Store.Placement`** — the default implementation. Rather than standing up a
  second Ra cluster, this adds new command types to the *existing*
  `Riptide.Placement.PlacementMachine` state machine — the same way Phase 3d-ii added
  `{:replace_member, ...}` alongside the original `{:assign, ...}` command without disturbing it.
  Policies become a second top-level key in the same already-hardened, already-bootstrapped
  cluster, rather than a second cold-boot-fragile cluster to operate and test.
- **`Riptide.Authz.evaluate(tenant_id, path_segments, current_subject, mode) :: :allow | :deny`**
  — the pure decision function. Storage-independent; trivially testable against a fake `Store`.
  Every transport (LDP HTTP, SSE, WebSocket) calls this one function — the same shape as Phase
  4b's `verifier.verify/1` being called from both `Authenticate` and `Socket.connect/3`.
- **`RiptideWeb.Plugs.Authorize`** — a new plug, the same shape as `ResolveTenant`/`Authenticate`:
  reads `conn.assigns.tenant_id`, `conn.assigns.current_subject`, and the request path/method
  (mapped to `:read` for GET, `:write` for POST/PUT/PATCH/DELETE), calls `evaluate/4`, and halts
  with `403` on deny. Wired into a new `:authz` pipeline applied after `:tenant` and `:auth` on
  every tenant-scoped LDP route.

## 5. Policy evaluation algorithm

Given `(tenant_id, path_segments, current_subject, mode)`:

1. Collect every policy attached to any prefix of `path_segments`, including the tenant root
   (`[]`) — every ancestor container's policies apply to a resource under it, not just policies on
   the resource's own exact path. This is the container-inheritance property carried over from
   ACP.
2. Filter to policies whose `matcher` matches `current_subject` — `:public` always matches;
   `:authenticated` matches iff `current_subject` is non-nil; `{:agent, s}` matches iff
   `current_subject["sub"] == s` — and whose `modes` include the requested `mode`.
3. If any matching policy has `effect: :deny` → **deny** (deny always overrides allow, regardless
   of which policy was added first or which container it's attached to).
4. Else if any matching policy has `effect: :allow` → **allow**.
5. Else (no matching policy at all) → **deny** — this is the default-deny posture — *unless* the
   bootstrap condition in §6 applies.

## 6. Bootstrapping: first authenticated write claims ownership

Default-deny with no existing tenant registry (Phase 4a explicitly deferred "does tenant
existence need its own registry" to whenever authorization needed something concrete to check
against — this is that moment) means a brand-new tenant would otherwise be permanently
inaccessible the instant this phase ships. Rather than introducing a separate tenant
creation/registry flow, ownership is established implicitly:

- A tenant is **unclaimed** if it has zero policies of any kind, anywhere in it.
- The first *authenticated* (`current_subject != nil`) *write* request against an unclaimed
  tenant atomically creates `%Policy{effect: :allow, modes: [:read, :write], matcher: {:agent,
  current_subject["sub"]}}` at the tenant root, then proceeds as allowed.
- This must be a single atomic operation, not a check-then-act pair of calls — a race between two
  different agents' first writes to the same brand-new tenant must resolve to exactly one owner,
  not both or neither. `claim_tenant_if_unclaimed/2` is implemented as one Ra command handled
  inside `PlacementMachine.apply/3`, giving this the same linearizable check-and-set semantics
  `:assign`'s own idempotent-race-safety already relies on (Phase 3c-i §4).
- Anonymous requests never bootstrap ownership — an unauthenticated write or any read (even
  authenticated) against an unclaimed tenant is denied outright, not treated as a claim attempt.
  This is deliberate: reads shouldn't be able to "look" their way into ownership, and allowing
  anonymous claims would let anyone squat an unclaimed `tenant_id` with no accountability at all.
- `RiptideWeb.Plugs.Authorize` calls `claim_tenant_if_unclaimed/2` whenever normal evaluation (§5)
  would deny *and* the request is an authenticated write — it does not separately pre-check
  whether the tenant is unclaimed, since that check is exactly what the atomic command itself
  performs. A `:claimed` result means ownership was just established by this request, which then
  proceeds as allowed; `:already_claimed` means the tenant already has policies (bootstrap doesn't
  apply here), so the original §5 denial stands.

## 7. SSE and WebSocket authorization

Both transports receive an opaque, client-supplied `stream_id` directly — as established in Phase
4a §5, neither reconstructs one from a path server-side. Before this phase, that opacity cost
nothing (nothing was secret); now, authorization needs to recover `(tenant_id, path_segments)`
from a bare `stream_id` string in order to call `evaluate/4`. Since
`RiptideWeb.LDP.ResourceController.stream_id_for/2`'s output format is a pure, deterministic,
reversible string (`"https://riptide.example/tenants/<tenant_id>/resources/<path>"`, no hashing
or randomness involved), the chosen approach is to parse it back apart rather than maintain a
separate `stream_id -> {tenant_id, path}` index as new persisted state:

- `stream_id_for/2` becomes public; a new inverse `parse_stream_id/1` (`{:ok, tenant_id,
  path_segments} | :error`) is added beside it in the same module, since that module already owns
  the addressing convention in both directions.
- `RiptideWeb.Realtime.SseController.subscribe/2` parses the incoming `stream_id`, then calls
  `Riptide.Authz.evaluate(tenant_id, path, current_subject, :read)` (subscribing is inherently a
  read) before calling `StreamSupervisor.ensure_ready/1` — denies with `403`.
- `RiptideWeb.Realtime.ReplicationChannel.join/3` does the same using `socket.assigns.
  current_subject` (established once at `connect/3` time, per Phase 4b) — denies with
  `{:error, %{"reason" => "unauthorized"}}`, matching the existing `service_unavailable` shape
  already used there for consistency.
- A `stream_id` that fails to parse (malformed, or predates tenant-scoped addressing) is treated
  as a deny, not a crash.

This does couple SSE/WebSocket authorization to `stream_id_for/2`'s exact current string format —
a round-trip test (`parse_stream_id(stream_id_for(t, p)) == {:ok, t, p}` for arbitrary `t`/`p`)
is required specifically to catch a future format change silently breaking this.

## 8. Policy management API

Bootstrapping alone only gets the owner access to their own tenant — nothing lets them share
access with anyone else, which would leave the matcher expressiveness this phase exists to
provide unreachable in practice. A minimal, tenant-root-only management API closes this:

- `POST /tenants/:tenant_id/policies` — body describes one `Policy` (`effect`, `modes`,
  `matcher`); appends it to the tenant's root policy list. Gated by `:write` access at the tenant
  root — i.e. the same permission the bootstrap owner (or anyone else later granted tenant-root
  write) already holds. No separate `Control` mode is needed since managing policies piggybacks
  on the same `:write` check as managing resources.
- `GET /tenants/:tenant_id/policies` — lists the tenant's root policies. Gated by `:read` at the
  tenant root.
- Both routes go through the same `:tenant`/`:auth`/`:authz` pipeline as the LDP resource routes,
  with `path_segments` fixed to `[]` (tenant root) for the `Authorize` plug's own evaluation.
- No `DELETE`/revoke endpoint this phase — see §3.

## 9. Testing

- `Riptide.Authz.evaluate/4` unit tests against a fake in-memory `Store` (no Ra cluster involved):
  each matcher kind, deny-overrides-allow when both an allow and a deny policy match, container
  inheritance (a parent-container policy applying to a child path), and default-deny when nothing
  matches.
- `PlacementMachine` tests for the new policy commands, including a concurrency test proving
  `claim_tenant_if_unclaimed/2` resolves a race between two simultaneous claims to exactly one
  winner.
- `RiptideWeb.Plugs.Authorize` plug tests using a config-injected fake `Authz`/`Store`, mirroring
  the existing `Authenticate`/`ResolveTenant` plug test pattern.
- End-to-end `ResourceController` tests: an anonymous (or authenticated, non-owner) read of an
  unclaimed tenant is denied (proving reads never bootstrap); the first authenticated write claims
  ownership and succeeds; the owner can then read/write freely; a different identity is denied
  until explicitly granted via the policy management API, after which it can read (or write, per
  whatever mode was granted) but nothing beyond that.
- SSE/WebSocket: the analogous authorized/denied pair for each transport, plus the
  `parse_stream_id/1` round-trip test from §7.
- Policy management API tests: a non-owner is denied `POST`/`GET`; the owner can add a policy and
  then list it back.
