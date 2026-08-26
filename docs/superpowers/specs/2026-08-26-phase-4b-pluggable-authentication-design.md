# Phase 4b — Pluggable Authentication — Design

**Status:** Approved 2026-08-26.

Sub-project 4 (Security & multi-tenancy) is decomposed into phases 4a-4d (see `PROGRESS.md`).
This is the second phase, following directly from Phase 4a (multi-tenancy data model).

## 1. Context & motivation

Riptide has zero authentication anywhere today. The router's `:api` pipeline only does content
negotiation; `RiptideWeb.Realtime.Socket.connect/3` accepts every WebSocket connection
unconditionally (its own module doc says so outright); the SSE route doesn't even run Phase 4a's
`:tenant` pipeline. Phase 4a established *who a request is for* (tenant-scoped addressing) but
nothing establishes *who is asking*. This phase closes that gap: verifying a bearer token and
exposing the resulting identity to the rest of the request pipeline, so a later phase (4c) has
something to authorize against.

Three decisions carried over from Phase 4a's own brainstorm constrain this phase: authentication
must be pluggable from the start (starting with standard OIDC/OAuth2, not the narrower
Solid-ecosystem WebID-OIDC convention); the isolation model is logical, not physical; and
authorization itself is explicitly Phase 4c's job, not this one's.

No OIDC/JWT library, JWKS handling, or identity-provider integration exists anywhere in this
project yet — this phase introduces all of it from scratch, including a real (if disposable, for
proof purposes) external identity provider dependency.

## 2. Scope

- A pluggable `Riptide.Auth.Verifier` behaviour, with a standard OIDC/JWT implementation as the
  first (and initial default) concrete verifier.
- A plug (`RiptideWeb.Plugs.Authenticate`) that extracts a bearer token from a request, verifies
  it via the configured verifier, and exposes the resulting claims to the rest of the request.
- Applying this uniformly across all 3 request transports (LDP HTTP, SSE, WebSocket) — leaving one
  transport unauthenticated while another requires a token would be an inconsistent, easily-missed
  gap.
- Authentication is optional at this layer: a request with no token proceeds as anonymous; a
  request with a token that fails verification is rejected. Nothing yet *requires* a token to
  access a resource — that's Phase 4c's job, once it exists to make that decision meaningfully.

## 3. Out of scope

- **Authorization/enforcement** (Phase 4c) — this phase only establishes identity; nothing checks
  whether the resulting `current_subject` may act on a given tenant or resource.
- **Closing SSE's separate tenant-scoping gap** — the SSE route still sits outside Phase 4a's
  `:tenant` pipeline. Pre-existing, not this phase's job to fix.
- **User provisioning/lookup** — this phase exposes a verified JWT's own claims verbatim; mapping
  a `sub` claim to a richer internal user record, roles, or profile is deferred.
- **Token refresh/session management** — this is a stateless bearer-token verification layer.
  Issuing, refreshing, or revoking tokens is the identity provider's job, not Riptide's.
- **TLS** (Phase 4d) — unrelated, independent phase.

## 4. Architecture

New `Riptide.Auth` namespace, mirroring Phase 4a's `Riptide.Tenancy` pattern:

- **`Riptide.Auth.Verifier`** — a behaviour: `verify(token :: String.t()) :: {:ok, claims :: map()} | {:error, term()}`.
- **`Riptide.Auth.Verifier.OIDC`** — the first concrete implementation, using `joken` +
  `joken_jwks` to verify a JWT's signature against the configured provider's JWKS endpoint and
  check standard claims (`exp`, `iss`, `aud`). Neither library exists in this project yet; both
  are added as new dependencies.
- Selected via `Application.get_env(:riptide, :auth_verifier, Riptide.Auth.Verifier.OIDC)` — the
  same config-driven swap pattern already used for `:tenancy_resolver` (Phase 4a) and
  `:ordinal_resolver` (Phase 3c-i), so a different mechanism (API keys, WebID-OIDC) can replace
  this one later without touching the pipeline that consumes it.
- **`RiptideWeb.Plugs.Authenticate`** — extracts a bearer token (see §5), calls the configured
  verifier, and assigns `conn.assigns.current_subject` to the decoded claims map on success,
  `nil` on no token present, and halts with `401` only if a token *was* presented but failed
  verification.
- Wired as its own pipeline, independent of Phase 4a's `:tenant` pipeline — applied to all 3
  transports' entry points regardless of whether that specific route is also tenant-scoped. This
  deliberately does not fold authentication into tenant resolution, and deliberately does not fix
  SSE's separate pre-existing gap of sitting outside `:tenant` (see §3) — those are different
  concerns that happen to currently live in the same file.
- **WebSocket**: `RiptideWeb.Realtime.Socket.connect/3` verifies a token once, at connect time,
  assigning `socket.assigns.current_subject` for the lifetime of the connection. A channel
  `join/3` never re-verifies — the socket-level identity already applies to every channel joined
  on it. See the correction in §5 for exactly how the token reaches `connect/3` — it is not the
  raw `Authorization` header.

## 5. Token extraction per transport

- **HTTP** (LDP resource routes): standard `Authorization: Bearer <token>` header.
- **SSE**: header if present, else a `?token=<token>` query parameter — browsers' native
  `EventSource` API cannot set custom headers, so a query-param fallback is a well-known, accepted
  pattern for this specific transport. If both are somehow present, the header takes precedence,
  to avoid ambiguity about which one is authoritative.
- **WebSocket**: **Correction from an earlier draft of this section, caught during implementation
  planning**: a raw `Authorization` header is NOT readable in `connect/3` — Phoenix deliberately
  withholds arbitrary request headers from `Phoenix.Socket.connect/3` (documented in
  `Phoenix.Endpoint`'s own "Where are my headers?" note: a WebSocket handshake is cross-origin, so
  a malicious page could otherwise ride a victim's browser-managed `Authorization`/cookie headers
  straight into the socket). The original assumption that "a WebSocket client can always set
  connection headers" doesn't hold for the same reason browsers' native `EventSource` can't — a
  browser's native `WebSocket` API can't set arbitrary upgrade-request headers either. Phoenix
  ships a purpose-built mechanism for exactly this instead: the `socket/3` macro's `auth_token:
  true` option, which accepts a token from the client via the `Sec-WebSocket-Protocol` header
  (prefixed `"base64url.bearer.phx."`, standard-base64-decoded server-side — see
  `deps/phoenix/lib/phoenix/transports/websocket.ex`) and surfaces it to `connect/3` as
  `connect_info.auth_token`, with no extra `connect_info:` wiring needed (`auth_token: true` alone
  makes `Phoenix.Socket.Transport.load_config/1` inject it). This is used instead of a
  query-param fallback.

## 6. Error handling

- No token at all → `current_subject` is `nil` (HTTP: `conn.assigns`; WebSocket:
  `socket.assigns`), request proceeds as anonymous.
- Token present but fails verification (bad signature, expired, wrong issuer/audience, or the
  JWKS endpoint itself is unreachable) → `401` for HTTP/SSE; a rejection tuple for the WebSocket
  `connect/3`, mirroring the existing `{:error, %{"reason" => "service_unavailable"}}` shape
  `RiptideWeb.Realtime.ReplicationChannel.join/3` already uses elsewhere in this codebase for
  consistency (e.g. `{:error, %{"reason" => "unauthorized"}}`).
- A JWKS fetch failure is treated as a verification failure — fails closed, never silently
  degrades an unverifiable token into an anonymous request. A token that can't be checked is never
  treated as though it had passed.

## 7. Testing & live proof

- Unit tests for `Verifier.OIDC` against a disposable test JWKS setup (a throwaway keypair
  generated in-test) — no network dependency for this layer's own unit tests.
- `Authenticate` plug tests: valid token → claims assigned; no token → anonymous, request
  proceeds; expired/bad-signature/wrong-issuer token → `401`; SSE-specific query-param extraction
  and header-takes-precedence-when-both-present behavior.
- WebSocket `connect/3` tests covering the same valid/absent/invalid matrix, using this project's
  established `:peer`-based or direct-conn test patterns.
- **Live proof**: stand up a disposable, throwaway OIDC/JWKS provider (e.g. a Docker-based mock
  OIDC server) for one end-to-end pass proving a real token from a real (if disposable) identity
  provider is verified correctly against a running Riptide instance — torn down afterward,
  matching this project's established "disposable, no lasting infrastructure" pattern for live
  proofs. This is not a commitment to any specific production identity provider; it only proves
  the mechanism works against a real OIDC-compliant issuer, not a hand-rolled stub.
