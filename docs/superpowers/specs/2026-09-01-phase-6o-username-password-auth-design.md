# Phase 6o — Username/Password Authentication

## 1. Context and motivation

Sub-project 6 (Derivation and execution layer) is being built phase-by-phase against
`docs/superpowers/specs/2026-08-27-derivation-and-execution-layer-design.md`. This phase — like 6j,
6k, 6l, 6d-ii, 6m, and 6n before it — emerged from real need rather than the original 21-phase
breakdown, and gets its own letter continuing that same sequence.

**Direct origin.** While brainstorming the Sub-project 6 demo (6n's own spec named it "6o,
provisionally"), the demo's own bootstrap step — an unauthenticated browser page needing to prove an
identity against a genuinely fresh, real Riptide instance — surfaced a gap: Riptide's only existing
identity mechanism is `Riptide.Auth.Verifier.OIDC`, which delegates all credential management to an
external OIDC provider. That's a reasonable default for a real deployment, but it means nobody can log
into a fresh Riptide instance at all without first standing up (or already having) their own identity
provider — a hard requirement this project cannot assume of every person who wants to try Riptide.
Because a real, general-purpose authentication mechanism is independently useful for any Riptide
deployment — not just this demo — it gets its own phase (6o) rather than being folded into the demo's
own scope; the demo itself is pushed back one more letter, to 6p.

## 2. Scope

- A new `Riptide.Auth.Verifier.Password` — verifies Riptide's own self-issued JWTs (signed with
  Riptide's own key, not fetched from an external JWKS endpoint), reusing `Riptide.Auth.TokenConfig`'s
  existing required-claims shape (`exp`/`iss`/`aud`/`sub`) (§4.5).
- A composite verifier dispatch so a request can be authenticated by either mechanism — an
  OIDC-issued token or a Riptide-issued one — without changing `RiptideWeb.Plugs.Authenticate`'s own
  contract (§4.5).
- Two new, deliberately anonymous routes: `POST /auth/signup` and `POST /auth/login` (§4.2, §4.3).
- Accounts as ordinary, individually-addressable Tenant-scoped resources — no new storage engine, no
  new query mechanism, no global cross-tenant "system" entity (§4.1).
- Rate-limiting on both new routes, reusing the existing `Hammer`-based pattern
  `Riptide.HubRateLimit`/`Riptide.NewStreamRateLimit` already establish (§4.6).

## 3. Non-goals

- **Email verification.** Signup is username/password only, no email collection. A real recovery
  channel is valuable future work but is separate scope (mail delivery, verification-token issuance,
  an unverified-account state) — deliberately deferred so this phase stays focused on "a random person
  with no other infrastructure can get an account."
- **Password reset/recovery.** With no email on file (above), there is no recovery channel this phase
  can build. A forgotten password means creating a new tenant/account, same as today with no username/
  password auth at all. Real recovery is follow-up work, gated on email verification landing first.
- **Server-side password re-hashing.** The client hashes the password (SHA-256, native
  `crypto.subtle`) before it ever leaves the browser; the server stores that hash as-is, with no
  additional server-side hash step. This is a deliberate, informed tradeoff — see §6 for the concrete
  risk being accepted, and why it doesn't get closed here.
- **Renaming/changing a username or moving an account between tenants.** Not built; not needed for
  this phase's own exit criterion.
- **The demo itself** — 6p (provisionally), built on top of this phase, 6m, and 6n together.

## 4. Detailed design

### 4.1 Data model: accounts are ordinary Tenant-scoped resources, not a new concept

An account is not a new storage abstraction — it's exactly the same kind of thing every other piece of
Tenant-scoped data already is: one independently-addressable stream. `accounts` is a path-prefix
convention under a Tenant's own resource tree, the same way `jobs` and `catalog` already are (moved
under `/resources/*path` by 6m and 6n respectively) — **not** a single shared stream holding many
records the way the Hub Capability/Crosswalk catalogs work (§4.3 of the 6n design spec). Each account
is its own stream:

```elixir
ResourceController.stream_id_for({:tenant, tenant_id}, ["accounts", username])
# => "https://riptide.example/tenants/<tenant_id>/resources/accounts/<username>"
```

This directly gives every account the same portability story any other Tenant resource already has (or
will have, once real cross-instance migration tooling exists) — no new cross-tenant exception, unlike
a global "system" tenant would be (rejected during brainstorming — see the design rationale below).

**Why not a global cross-tenant accounts store.** The obvious alternative — one shared `{:tenant,
"system"}` (or similar reserved) tenant holding every account across the whole instance — was
considered and rejected. Investigation confirmed Riptide's "a Tenant should be trivially movable to a
different instance, no structural ties" principle does not fully hold today (the placement Ra cluster
comingles every Tenant's Authz policies in one instance-wide structure; Hub is explicitly,
deliberately instance-scoped per the master design doc, with federation named and deferred; blob
replication and stream-replica placement are fleet-wide with no live migration tooling). A global
accounts tenant would not be the first crack in that principle, but it would be a *worse kind* of
exception than the existing ones: Hub content is genuinely meant to be shared, and the placement
cluster's per-tenant data can in principle still be sliced out and exported later even though it's
comingled today. A single global accounts stream holding every user's login credential, comingled, is
much harder to cleanly carve one Tenant's slice out of — and it's specifically the ability to *log in
at all*, not just some non-critical data, that would be left behind on the origin instance. Scoping
accounts per-Tenant avoids introducing this new failure mode entirely.

**Multi-user Tenants are a natural consequence, not a special case.** Because an account is just an
ordinary resource under its own Tenant's tree, a Tenant can have as many accounts as it wants — adding
a second account to an *already-claimed* Tenant needs **zero new code**: it's performed by an
already-authenticated existing member (the owner, or anyone already granted `write` on that path
prefix via the existing `Authz.Store.add_policy/3`) as an ordinary write through the existing generic
`PUT /tenants/:tenant_id/resources/accounts/:username` route `ResourceController.replace/2` already
provides — `PUT`, not `POST`, since `create_child/2` mints its own random child ID rather than
accepting the caller-chosen username the account's own deterministic address (§4.1 above) requires.
Having an account this way is a separate concern from being authorized to use it on that Tenant's own
resources — see §5's worked example for the explicit policy-grant step this implies. Only the *first*
account for a brand-new, not-yet-claimed Tenant needs new code (§4.2), because that caller isn't
authenticated yet — the same bootstrap problem
`RiptideWeb.Plugs.Authorize.maybe_bootstrap/4` already solves for an *already-authenticated* caller
claiming a brand-new Tenant (confirmed by reading it directly: it requires a non-nil
`current_subject["sub"]`, i.e. an already-verified token) — signup needs its own, simpler bootstrap
because there is no token yet at all.

**Account RDF shape** (new module, mirrors `CapabilityCatalogRDFCodec`'s own shape):

```elixir
@riptide_account RDF.iri("urn:riptide:vocab:Account")
@riptide_username RDF.iri("urn:riptide:vocab:username")
@riptide_password_hash_sha256 RDF.iri("urn:riptide:vocab:passwordHashSha256")
@riptide_account_subject RDF.iri("urn:riptide:vocab:accountSubject")
```

`accountSubject` is a freshly-generated UUID (`Uniq.UUID.uuid4()`, already a dependency — used
elsewhere in tests) minted once at account-creation time and used as the issued JWT's `sub` claim —
deliberately decoupled from both `username` and `tenant_id` so identity remains stable independent of
either (consistent with how an OIDC `sub` is already treated as an opaque identifier with no assumed
structure).

### 4.2 `POST /auth/signup` — anonymous, creates a Tenant and its first account together

Request: `{"tenant_id": "guild-a", "username": "alice", "password_hash": "<sha256 hex, client-computed>"}`

This is the one place genuinely new server logic is required, because the caller has no token at all
yet — it cannot go through `RiptideWeb.Plugs.Authenticate`/`Authorize`'s normal pipeline (chicken-and-egg:
those plugs exist to check a token that doesn't exist until signup succeeds). The handler:

1. Validates `tenant_id`/`username` are non-empty and contain no `/` (stream_id path segments split on
   `/` — see §6) and that `password_hash` looks like a 64-character hex SHA-256 digest.
2. Calls `Riptide.Authz.Store.Placement.claim_tenant_if_unclaimed(tenant_id, subject)` **directly** —
   the same underlying primitive `Authorize.maybe_bootstrap/4` already calls, just invoked directly
   from the signup controller rather than through the generic write pipeline, mirroring how
   `Riptide.Authz.Store.Placement` itself already bypasses the generic HTTP/Authz-checked path for its
   own internal operations. `subject` here is the newly-generated UUID (§4.1), not yet a verified
   token claim — this is fine, since `claim_tenant_if_unclaimed/2`'s own contract only needs an opaque
   subject string.
3. On `:already_claimed` — returns `409` immediately, no write attempted. This route only ever creates
   a Tenant's *first* account, precisely because it's the one case that must work without any prior
   authentication; it has no way to decide whether an anonymous caller is allowed to add an account to
   a Tenant someone else already owns. Adding a second account to an already-claimed Tenant is the
   already-authenticated flow described in §4.1 and worked through in §5 — a plain write through the
   *existing* generic, Authz-checked route — not this one.
4. On `:claimed` — writes the account fact (§4.1's shape) directly via the same low-level
   `write_patch/3` primitive `Catalog`/`ResourceController` themselves call internally (not through the
   generic HTTP resource-write path, for the same chicken-and-egg reason as step 2).
5. Signs and returns a JWT (§4.5) plus the newly-generated `sub`.

### 4.3 `POST /auth/login` — anonymous, reads one account fact and verifies it

Request: `{"tenant_id": "guild-a", "username": "alice", "password_hash": "<sha256 hex, client-computed>"}`

Reads the single account resource at `stream_id_for({:tenant, tenant_id}, ["accounts", username])`
directly (same low-level read primitive as signup's write, for the same reason — no token exists yet
to go through the generic Authz-gated read path, and reading one's own not-yet-authenticated account
record isn't a generic resource read to begin with). Compares the submitted `password_hash` against
the stored `passwordHashSha256` value. On match, signs and returns a JWT using the account's own
`accountSubject` as `sub`. On any failure (Tenant doesn't exist, username doesn't exist, hash doesn't
match), returns a uniform `401` with no distinguishing detail (§6) — this deliberately doesn't reveal
whether a Tenant or username exists, to avoid enumeration.

### 4.4 Why signup/login are ordinary synchronous request/response, not reactive Job execution

Both routes are plain, synchronous Phoenix controller actions — read or write one fact, respond in the
same request. This was a real design fork worth recording: Riptide's reactive Job-triggering mechanism
(6l) — write a fact, a leader node notices *later* and reacts — is a poor fit here for two independent
reasons, not a stylistic one. First, that pattern requires the write to already be durable and
replicated *before* anything reacts to it; a raw (or even client-hashed-but-not-yet-validated) password
value momentarily existing in a Job fact would be exactly wrong for a value whose whole design goal is
to never sit in a permanently-replayable append-only log. Second, login fundamentally needs a
synchronous answer in the same HTTP response ("here's your token" or "wrong password") — Job execution
is asynchronous by design (submit a write, poll or watch via SSE for the eventual result), which is not
a usable login UX. Everything that *is* durable in this design (the account fact itself) is still
"just a stream" in every sense that matters — it's simply read and written through the same
synchronous request/response shape the *majority* of Riptide's own existing write endpoints already
use (`Hub.CapabilityController.propose/2`, `Authorize.maybe_bootstrap/4`, etc. are all synchronous
read-decide-write-respond flows already; only Task/Job *execution* — i.e. running untrusted, sandboxed,
potentially slow WASM code — is asynchronous, and signup/login are not that kind of operation at all).

### 4.5 `Riptide.Auth.Verifier.Password` and composite verifier dispatch

```elixir
defmodule Riptide.Auth.Verifier.Password do
  @behaviour Riptide.Auth.Verifier

  @impl true
  def verify(token) when is_binary(token) do
    Riptide.Auth.TokenConfig.verify_and_validate_required_claims(token)
    # ...verified against Riptide's own signing key (Application.get_env(:riptide,
    # :password_auth_signing_key)), an HS256 Joken.Signer, not an externally-fetched JWKS document —
    # the one place this differs from Verifier.OIDC's own verify/1.
  end
end
```

`RiptideWeb.Plugs.Authenticate` still calls exactly one configured verifier
(`Application.get_env(:riptide, :auth_verifier, ...)`) — unchanged contract. The default value changes
from `Riptide.Auth.Verifier.OIDC` to a new `Riptide.Auth.Verifier.Composite`, which itself implements
the same `Riptide.Auth.Verifier` behaviour and internally tries each module in
`Application.get_env(:riptide, :auth_verifiers, [Riptide.Auth.Verifier.OIDC,
Riptide.Auth.Verifier.Password])` in order, returning the first success or the last failure if none
succeed. This keeps `Authenticate` itself completely unmodified — from its perspective it's still
calling one verifier — while making both OIDC and Riptide-issued tokens acceptable by default,
matching "a random person shouldn't need their own OIDC server" without special-casing either
mechanism elsewhere in the request pipeline.

### 4.6 Rate limiting

`POST /auth/signup` and `POST /auth/login` both get a new `Riptide.PasswordAuthRateLimit`, mirroring
`Riptide.HubRateLimit`'s exact shape (`Hammer`, `:fix_window_per_key`, same reasoning about window
boundaries) — keyed by caller IP (there is no subject yet at this point in the request, by definition).
Login gets the tighter default limit of the two (brute-force protection); signup's own limit exists
primarily against automated account-creation spam.

## 5. Worked example

1. A fresh visitor opens the (future, 6p) demo page. It has no account yet.
2. Client hashes a chosen password client-side, `POST /auth/signup` with `{tenant_id: "guild-a",
   username: "alice", password_hash: "<hash>"}`. `guild-a` doesn't exist yet — `claim_tenant_if_unclaimed`
   succeeds, the account fact is written, a JWT comes back.
3. Later, Alice (now authenticated, using her token through the *existing* generic write path) invites
   a teammate by writing a second account fact directly: `PUT
   /tenants/guild-a/resources/accounts/bob` with the account's own RDF triples as the request body
   (Turtle, not JSON — this is `ResourceController.replace/2`, already built; note it's `PUT`, not
   `POST` — `create_child/2` mints its own random child ID and would ignore a caller-chosen `bob`,
   which is exactly the deterministic path `/auth/login` needs to find the account again later).
4. Having an account is not the same as being authorized to read/write Guild-A's own resources — Bob's
   account alone grants him nothing there yet, since credential storage (§4.1) and Authz policy grants
   are two entirely separate mechanisms. Alice, still using her own token, grants Bob's own subject a
   policy via the *existing* `POST /tenants/guild-a/policies` (Phase 4c, already built): `{"effect":
   "allow", "modes": ["read", "write"], "matcher": {"agent": "<bob's own sub, from his account fact>"}}`
   — again no new code, just the already-built multi-user-per-tenant mechanism this design leans on
   (§4.1).
5. Bob logs in: `POST /auth/login` with `{tenant_id: "guild-a", username: "bob", password_hash:
   "<hash>"}` — reads his own account fact, verifies, gets his own JWT carrying his own `sub`.
6. Both Alice's and Bob's tokens now work identically through the existing `Authenticate`/`Authorize`
   pipeline for every other route in the system — nothing downstream of authentication needed to
   change at all. Bob's own access is exactly as broad as whatever policy Alice granted him in step 4,
   same as any other multi-subject Tenant already works today.

## 6. Error handling

- `POST /auth/signup` for a `tenant_id` that's already claimed: `409`.
- `POST /auth/signup`/`login` with a `tenant_id` or `username` containing `/` (would break stream_id
  path-segment addressing, since `parse_stream_id/1` splits on `/`): `400`, rejected before any
  claim/write attempt.
- `POST /auth/login` for a nonexistent Tenant, nonexistent username, or wrong `password_hash`: uniform
  `401` in all three cases — never reveals which one, to avoid Tenant/username enumeration.
- Rate-limited: `429`, same shape as `Hub.DiscoveryController`'s existing `429` responses.
- Placement cluster unreachable (the underlying `claim_tenant_if_unclaimed`/`write_patch`/`read_graph`
  calls raise or exit): `503`, not a crash — both new routes get the same `rescue`/`catch` guard
  `SseController.subscribe/2`, `ReplicationChannel.join/3`, and `Authorize.call/2` already each have
  individually for this exact failure mode.
- **Accepted risk, not closed by this phase**: the server stores the client-computed SHA-256 hash
  as-is, with no additional server-side re-hash (bcrypt/argon2/etc.). This means the stored value is a
  directly replayable credential — anyone who ever reads it (e.g. a future bug in this path's Authz
  gating, or direct data-store access) can authenticate as that user immediately, without needing to
  crack anything. This was an explicit, informed tradeoff made during design, not an oversight; closing
  it (a small additional server-side bcrypt wrap before storage) is straightforward follow-up work if
  the risk profile changes, and does not require touching the client-side hashing, the storage shape,
  or any other part of this design.

## 7. Testing

- `Riptide.Auth.Verifier.Password` unit tests: valid self-issued token verifies; expired/wrong-issuer/
  wrong-audience/missing-`sub` tokens each fail, mirroring `Verifier.OIDC`'s own existing test shape.
- `Riptide.Auth.Verifier.Composite`: a token from either configured verifier succeeds; a token from
  neither fails with the last verifier's own error.
- `POST /auth/signup`: fresh tenant_id succeeds and returns a usable token; repeat signup against the
  same tenant_id returns `409`; a `tenant_id`/`username` containing `/` returns `400` without writing
  anything or claiming the tenant.
- `POST /auth/login`: correct credentials succeed; wrong password, wrong username, and nonexistent
  tenant_id all return the same `401` shape (assert on status/body equality across all three, not just
  that each individually fails, to actually verify the non-enumeration property).
- Capstone: signup as Alice → (using her token via the *existing* generic write route) create Bob's
  account under the same Tenant → (using the *existing* policy endpoint) grant Bob's own subject a
  policy on that Tenant → Bob logs in independently → both tokens independently pass through the
  existing `Authenticate`/`Authorize` pipeline against an ordinary Tenant-scoped resource, proving
  nothing downstream needed to change.
- Rate-limit tests for both routes, mirroring `HubRateLimit`'s own existing test shape (stub the limit
  to `0`, assert `429`).

## 8. Explicitly out of scope

See §3 (Non-goals).
