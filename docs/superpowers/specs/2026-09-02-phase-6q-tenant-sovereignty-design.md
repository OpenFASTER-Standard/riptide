# Phase 6q — Tenant Sovereignty (Hub, Authz Storage, and Blob Storage, Fully Tenant-Scoped)

## 1. Context and motivation

Brainstorming 6p-iii (the Sub-project 6 demo page) surfaced a question about the demo's own "Hub Browser"
pane: why is Hub a single, instance-wide shared scope rather than tenant-scoped, "like everything else"?
Investigating that question deeply found it wasn't an isolated oddity — three separate mechanisms in this
codebase are structurally shared/instance-wide rather than partitioned per tenant:

1. **Hub** (`Catalog.scope() :: {:tenant, id} | :hub`) — one global catalog, `Authz.evaluate/4` hardcoding
   `:hub`+`:read` to always `:allow`, `:hub`+`:write` to always `:deny`.
2. **The placement/Authz cluster** — one shared Ra cluster (`:riptide_placement`) holds every tenant's
   Authz policies (and stream-placement metadata) comingled in one state map.
3. **Blob storage** — one global, content-addressed store, deliberately deduplicated across tenants.

None of these were oversights. Hub's global scope was a deliberate interim stand-in for eventual
cross-*instance* federation (explicitly named and deferred in the master Sub-project 6 design doc). The
placement cluster's comingling and blob storage's cross-tenant dedup were both already identified —
during Phase 6o's own brainstorming — as known, accepted exceptions to Riptide's stated principle that "a
Tenant should be trivially movable to a different instance, no structural ties."

**The guiding principle for this phase, stated directly by the operator**: treat each Tenant as if it were
its own completely independent server. Under that framing, Hub's "instance-scoped" design and the
already-deferred "cross-*instance* federation" goal become the same problem viewed at a different
granularity — a Tenant *is* the independent unit; sharing between two Tenants should work the same way
sharing between two genuinely separate Riptide deployments eventually would. This directly mirrors a
decision Phase 6o already made and shipped: accounts could have lived in a global "system tenant" (a
shared, arbitrated structure) but were deliberately made ordinary per-tenant facts instead. This phase
applies the same move — replace shared, arbitrated structures with ordinary tenant-owned data plus
explicit, narrow coordination only where genuinely unavoidable — to Hub, Authz policy storage, and blob
storage together, as one continuous rework rather than three separate phases.

This spec is the product of extensive investigation (multiple deep research passes across `Catalog`,
`DedupGate`, every `Hub.*Controller`, `PlacementMachine`, `Riptide.Placement`, `Riptide.Authz.Store`,
`BlobStore`/`LocationIndex`/`Healer`, and the relevant design specs/`PROGRESS.md` history) before any
design decision below was finalized — every claim about what currently exists is grounded in the real
code, not assumed.

## 2. Scope

Four pillars, landing together:

1. **Tenant identity** — a self-generated UUIDv4 (no coordination, no claim race), matching the pattern
   `sub` already uses.
2. **Tenant naming** — a thin, separate, still-coordinated `name → tenant_id` registry, replacing today's
   `tenant_id`-is-the-claimed-string model. This is the *only* piece that still needs a shared arbiter.
3. **Authz policy storage** — moves out of the shared placement cluster into ordinary facts inside each
   tenant's own stream, the same storage pattern `Riptide.Accounts` already established for account data.
4. **Hub collapse** — `Catalog.scope()` becomes just `{:tenant, id}` everywhere. "Publishing" becomes
   "admit into your own Catalog, then grant a `:public` read policy on it" — both already-existing
   mechanisms, composed rather than a new one invented.
5. **Blob storage** — becomes fully tenant-scoped; cross-tenant dedup is given up.

Plus five concrete gap-resolutions this phase must land, not defer: tenant-bootstrap-owner-policy
sequencing (§4.4), Authz policy list-by-prefix storage shape (§4.3), cross-tenant Capability blob access
(§4.7), public-read abuse protection (§4.6), and `ContextResolver`'s Hub-rule-merge removal (§4.5).

## 3. Non-goals

- **General cross-tenant discovery of *unknown* tenants** (a search/crawler spanning every tenant on an
  instance without already knowing who to ask). This phase supports discovery of a *specifically named*
  tenant's public data (already mechanically trivial — see §4.5/§4.2) but does not build a general index or
  aggregator. This mirrors exactly how the original Hub design named cross-*instance* federation as a
  real goal while deferring it — an unbounded "search everyone" primitive is a separate, later piece of
  work, not required for this rework's core correctness.
- **Cross-instance federation itself** — unchanged from the original design's own deferral. This phase
  makes tenants *structurally* capable of being federated (self-certifying identity, no comingled
  storage) but does not build any cross-instance protocol.
- **Actual tenant export/import/migration tooling.** This phase removes the *structural* obstacles that
  currently prevent a tenant from being cleanly moved (comingled policies, comingled blobs) — it does not
  build the mechanism that would actually perform a move.
- **Cryptographic tenant identity.** Tenant identity is a plain UUIDv4, explicitly decided over a
  keypair-derived/self-certifying scheme — simpler, consistent with `sub`'s existing precedent, and this
  codebase has no existing cryptographic-identity infrastructure to build on.
- **Multi-name tenants, tenant renaming, or name transfer.** A tenant claims exactly one name once, at
  creation, permanently — matching today's one-shot `claim_tenant_if_unclaimed` semantics as closely as
  possible given the new split between identity and name.

## 4. Detailed design

### 4.1 Tenant identity

`tenant_id` becomes a locally-generated `Uniq.UUID.uuid4()`, generated the same way and at the same
moment `sub` already is — no collision check, no coordination. This is the load-bearing simplification
everything else follows from: today's `claim_tenant_if_unclaimed`'s entire reason for existing is
arbitrating a race over who gets a given `tenant_id`; once `tenant_id` is self-generated, that race
cannot occur, because no two signups ever generate the same UUID to race over.

### 4.2 Name registry

The one thing that still needs coordination: a human-chosen name (what today's signup form calls
`tenant_id`, e.g. `"guild-a"`) must still be globally unique and still requires a shared arbiter, since
uniqueness of a short human-picked string is fundamentally a coordination problem no amount of local
randomness solves.

`PlacementMachine`'s state (`lib/riptide/placement/placement_machine.ex`) changes from
`%{streams, policies, repair_claims}` to `%{streams, names, repair_claims}` — `policies` is removed
entirely (§4.3), `names :: %{String.t() => String.t()}` (name → tenant_id) replaces it. New Ra command:

```elixir
def apply(_meta, {:claim_name, name, tenant_id}, state) do
  if Map.has_key?(state.names, name) do
    {state, :already_claimed, []}
  else
    {put_in(state, [:names, name], tenant_id), :claimed, []}
  end
end
```

This is structurally identical to today's `claim_tenant_if_unclaimed` clause, just claiming a name
instead of a bare tenant_id and not also writing an owner policy as a side effect (that responsibility
moves to the caller — see §4.4). `Riptide.Placement.claim_tenant_if_unclaimed/2` is renamed/repurposed to
`Riptide.Placement.claim_name/2`, reusing all of its existing discovery/retry plumbing
(`with_current_members/1` and everything below it) completely unchanged — that machinery is generic
RPC-to-the-cluster infrastructure, agnostic to which command is sent.

`streams` and `repair_claims` are **not** moving — they're physical-routing/operational infrastructure
(which nodes host which stream's Ra replicas; in-flight repair claims), not tenant-owned data. A tenant's
portability isn't compromised by the fleet needing an index of where things currently live, any more than
a real independent website's independence is compromised by DNS/routing infrastructure existing alongside
it. Confirmed via full read of `placement_machine.ex` that `streams`/`repair_claims` have zero other
coupling to `policies`.

**Name resolution.** A caller who already knows another tenant's chosen name (not its opaque `tenant_id`)
needs a way to resolve one to the other — this is genuinely new surface, not present in any form today
(the old model never separated the two). New route: `GET /tenant-names/:name`, anonymous (matching
`/auth/*`'s own unauthenticated pipeline — resolving a public name is not itself sensitive), backed by a
new `Riptide.Placement.lookup_name/1` reading `state.names` via the existing `local_query`/`consistent_query`
machinery `Placement`'s other read functions already use. `200 {"tenant_id": "..."}` on a hit, `404` on a
name that was never claimed.

### 4.3 Authz policy storage

`Riptide.Authz.Store`'s behaviour shape (`list_policies/2`, `add_policy/3`) stays exactly as-is — only the
backing implementation changes, from `Riptide.Authz.Store.Placement` (calls into the shared cluster) to a
new `Riptide.Authz.Store.TenantFacts` (reads/writes ordinary facts in the tenant's own stream, mirroring
`Riptide.Accounts`'s existing `write_patch/3`/`read_graph/1`/`fold_events/1` pattern exactly).
`claim_tenant_if_unclaimed/2` is **removed from the `Authz.Store` behaviour** — it was never really an
authz-policy-store concern; it existed to arbitrate tenant_id races, which no longer exist (§4.1), and its
name-claiming successor (§4.2) lives on `Riptide.Placement` directly, not behind this behaviour.

**Storage shape**: policies live at a well-known nested path within the tenant's own stream —
`stream_id_for({:tenant, tenant_id}, ["_authz", "policies"])` — one small RDF graph per tenant holding
every policy at every prefix, the same "single stream, folded from its own event history" pattern
`Riptide.Accounts` already uses for a tenant's accounts.

**Access pattern — the one real shape mismatch from the `Accounts` precedent.** Accounts are addressed by
exact key (one username → one account). `Authz.evaluate/4`'s `prefixes/1` needs every policy at every
*prefix* of a path, unioned — a range-scan, not a point lookup. Since policy sets are already capped
(`@max_policies_per_prefix 1000` per prefix today, and realistically far smaller), the resolution is: read
the tenant's whole policy graph (one stream read, folded — identical cost profile to `Accounts.read_account/2`
today) and filter to matching prefixes client-side in `list_policies/2`'s own implementation. This is not a
new access pattern this codebase has never used — it's the same "fold the whole small graph, then filter"
shape `Accounts` already established, just with a `Enum.filter` step added for the prefix match.

### 4.4 Tenant-bootstrap-owner-policy sequencing

Today, `claim_tenant_if_unclaimed` atomically does two things in one Ra command: claim the tenant_id *and*
write the owner policy. Once those split (§4.1 removes the race; §4.2's `claim_name` only claims the
name), the owner-policy write needs its own home — but it turns out not to need its own atomicity
primitive at all. Signup becomes a strict sequence:

1. Generate `tenant_id = Uniq.UUID.uuid4()` locally (no coordination).
2. Call `Riptide.Placement.claim_name(name, tenant_id)` — the *only* racy step, resolved atomically by
   the shared cluster exactly as today.
3. **Only the caller that receives `:claimed` from step 2** proceeds to write the owner policy (via
   `Authz.Store.TenantFacts.add_policy/3`, §4.3) into the *newly-identified* tenant's own stream.

Step 3 is never actually raced: because step 2 is atomic and only one caller can ever win a given `name`,
at most one caller ever reaches step 3 for that `tenant_id`. No new atomicity mechanism is needed for the
owner-policy write itself — it inherits safety from the name-claim it's sequenced after.

**`RiptideWeb.Plugs.Authorize.maybe_bootstrap/4` is deleted, not adapted.** That function exists today to
handle a request arriving against an *unclaimed* `tenant_id` path outside of `/auth/signup` — a real
concern under the old model, where `tenant_id` was a human-guessable string anyone could speculatively
write to before it was claimed. Under this phase's model, `tenant_id` is an opaque UUID nobody could ever
guess or write to before it exists — a tenant only ever comes into being via the explicit three-step
signup sequence above, so there is no "unclaimed tenant someone stumbles onto" case left to bootstrap.

### 4.5 Hub collapse

`Catalog.scope()` becomes `{:tenant, id}` only — `:hub` is removed from the type entirely.

- **`Catalog.capability_stream_id/0`/`crosswalk_stream_id/0`** (currently zero-arity, hardcoded) become
  `capability_stream_id(scope)`/`crosswalk_stream_id(scope)`, mirroring `catalog_stream_id/1`'s existing
  polymorphism. This one change collapses `supersede_capability/1`/`supersede_crosswalk/1` into the same
  shape as the already-scope-polymorphic `supersede_entry/2` (confirmed via direct comparison: all three
  are structurally identical RDF-type-flip `write_patch` calls, differing only in which stream_id function
  and which pair of type IRIs).
- **`Riptide.Authz.evaluate/4`** loses its two hardcoded `:hub` clauses entirely — every scope now goes
  through the existing `{:tenant, tenant_id}` clause, consulting `Authz.Store` normally. "Public"
  visibility is no longer a structural property of a scope value; it's an ordinary `matcher: :public`
  policy grant (already-existing mechanism, confirmed `matches?(:public, _current_subject), do: true` —
  matches any subject, including an unauthenticated `nil`).
- **"Publishing"** becomes: admit an entry into your own tenant's Catalog via the *already-existing*
  `TenantProposeController`/`DedupGate.propose/4` path (already scope-polymorphic, confirmed — Hub's
  target/review scope split was never hardcoded inside `DedupGate` itself), then separately
  `POST /tenants/:tenant_id/policies` with `{"matcher": "public", "modes": ["read"], "effect": "allow"}`
  on the admitted node's path. No new propose/approve mechanism — composition of two mechanisms that
  already exist.
- **Deleted outright**: `Hub.ProposeController`, `Hub.ReviewController` (pure duplicates of
  `TenantProposeController`/`TenantReviewController` — confirmed line-for-line, the only difference was a
  hardcoded `:hub` target argument), `RiptideWeb.Plugs.ResolveHubScope` (confirmed its only caller is the
  `/hub/resources/*path` route, which is also deleted), the `:hub`-matching clauses in
  `SseController.subscribe_with_rate_limit/3`, `ReplicationChannel.join_with_rate_limit/4`,
  `maybe_log_tenant_metadata/1` in both files, and `ResourceController.stream_id_for/2`/`parse_stream_id/1`'s
  `:hub` clauses (all become unreachable once nothing ever mints a `hub/resources/` stream_id).
- **New, thin Tenant-scoped controllers** (mechanical — confirmed their underlying logic has zero
  Hub-specific classification/matching beyond the target scope): `TenantCrosswalkController` and a
  Capability-propose/review surface, both bodies copied from `Hub.CrosswalkController`/
  `Hub.CapabilityController` with `target_scope`/`review_scope` both `{:tenant, tenant_id}`.
- **`Hub.InstallController`'s underlying engine, `Riptide.Derivation.Install.install/3`, is preserved
  unchanged** — confirmed it's already scope-agnostic (takes a source node, a `Rule.t()`, and a target
  `tenant_id`; the vocabulary-comparison/Crosswalk-matching/Provenance-stamping logic never references
  `:hub`). Only its one caller's hardcoded `Catalog.list_entries(:hub)` read becomes
  `Catalog.list_entries({:tenant, source_tenant_id})`, with `source_tenant_id` becoming an explicit
  request parameter (the installing tenant must know which tenant they're installing *from* — see §3's
  Non-goal on general discovery).
- **`Hub.DiscoveryController.search/2`** collapses into `TenantDiscoveryController.search/2` unmodified
  (already `Discovery.find({:tenant, tenant_id}, query)`-shaped) — a caller wanting another tenant's
  public entries just calls `GET /tenants/:other_tenant_id/discovery/search` directly, gated by that
  tenant's own `:public` policy grants exactly like any other read. `Hub.DiscoveryController.show/2`
  (fetch one entry by node id) has no existing Tenant-scoped analogue — a new
  `GET /tenants/:tenant_id/entries/:node_id` route/action is added to `TenantDiscoveryController`,
  mechanically mirroring `show/2`'s existing body with `{:tenant, tenant_id}` in place of `:hub`.
- **`ContextResolver.all_rules/1`** loses its Hub-merge entirely (`hub_rules = rules_by_signature_name(:hub);
  Map.merge(hub_rules, tenant_rules)` → just `tenant_rules`). This is a deliberate behavior change, not a
  mechanical rename: under the old model, every tenant automatically saw every Hub-published rule in its
  own Task/LLMFallback pipeline; under this phase's model, implicit cross-tenant rule visibility is exactly
  the kind of comingling the whole rework exists to remove. A tenant now only ever resolves rules it
  authored itself or explicitly installed (via `Install.install/3`, described earlier in this section) into
  its own Catalog — reuse becomes an explicit action, not ambient visibility. This removes the need for any
  new cross-tenant rule-enumeration mechanism, rather than requiring one.

### 4.6 Public-read abuse protection

`HubRateLimit.check_read/1` (subject/IP-keyed) is the *only* rate limiting Hub's anonymous/cross-tenant
read surface has ever had — confirmed directly that ordinary `GET /tenants/:tenant_id/resources/*path`
has zero rate limiting today (`ResourceController.show/2` calls straight through to `current_state/1`,
no limiter anywhere in the module or its pipeline). Collapsing Hub into "ordinary tenant read + `:public`
policy" would silently drop this protection unless something new triggers a quota specifically when a
request resolves via a `:public` (not tenant-owned) policy match.

`Riptide.HubRateLimit` is renamed and split along its own existing internal seam, not rebuilt from
scratch: `check_propose/1` (tenant_id-keyed) is, confirmed directly, *already* the general per-tenant
write-throttle — reused verbatim today by `TenantProposeController` and `TaskController`, neither of
which is Hub-specific. It's renamed to `Riptide.WriteRateLimit.check/1` with no behavior change, and its
config keys (`:hub_propose_rate_limit`, `:hub_propose_rate_scale_ms`) renamed to match.
`check_read/1` (subject/IP-keyed) becomes `Riptide.PublicReadRateLimit.check/1`, identical
implementation, retargeted as follows: `RiptideWeb.Plugs.Authorize` gains a check after `Authz.evaluate/4`
returns `:allow` — if the specific policy that matched had `matcher: :public` (requires `Authz.evaluate/4`'s
internal matching to surface *which* policy matched, not just the allow/deny outcome — a small internal
signature change, not a public API one), apply `PublicReadRateLimit.check/1` before proceeding, mirroring
exactly what `check_read/1` already does today, just triggered by policy outcome instead of by scope
value. A tenant-owned request (matched via `{:agent, subject}` or `:authenticated`) is unaffected, exactly
as today's Tenant-scoped reads are unaffected by `HubRateLimit`.

### 4.7 Cross-tenant Capability invocation vs. tenant-scoped blob storage

`Riptide.BlobStore.put/1`/`get/1` gain a `tenant_id` parameter; `path_for/2` incorporates it into the
on-disk path so two tenants' identical bytes land in different files (dedup given up, per §2 pillar 5).
`Riptide.BlobStore.LocationIndex` becomes one stream *per tenant*
(`stream_id_for({:tenant, tenant_id}, ["_blob_location_index"])`) instead of one well-known global stream
— mechanically straightforward, the module's existing `write_patch/2`/`read_graph/0`/`list_all/0`
machinery is reused unchanged, just parameterized. `Riptide.BlobStore.Healer.sweep/0` enumerates tenants
to sweep via the name registry (§4.2) — every tenant that exists has, by construction (§4.4's sequencing),
successfully claimed a name, so the `names` map doubles as a complete tenant directory for this purpose.

**The real gap**: `CapabilityCatalog.materialize/1` has no `tenant_id` in scope today, because a Capability
approved via the old Hub model is invoked from any tenant with an authorized policy — but its WASM bytes
would now live in whichever tenant originally proposed it, and full blob privacy means that tenant's
storage isn't reachable from outside.

**Resolution: copy-on-install.** This isn't a new pattern — it's the exact same thing `Install.install/3`
(§4.5) already does for Rules and Crosswalks: installing a pattern from another tenant gives you your own
durable, independent copy, not a live reference back to the source. Extending this to Capabilities: when a
tenant installs a Capability another tenant published (an admitted, `:public`-granted
`CapabilityCatalogEntry`), the installing tenant's own `BlobStore.put/2` receives a copy of the referenced
bytes (fetched once, at install time, via the same kind of direct tenant-to-tenant read §4.5's Install
flow already performs for the entry's own facts) and the installed `CapabilityCatalogEntry` in the
installing tenant's own Catalog points at its own local copy's hash. After install, invocation never
crosses a tenant boundary — fully consistent with "each tenant is its own independent server," and it
means a tenant's Capabilities keep working even if the tenant they were originally installed from is later
moved, renamed, or removed.

## 5. Worked example

Guild A and Guild B, replaying the Sub-project 6 demo's own beats 1 and 4 under this new model:

1. Alice's browser generates `tenant_id = "a1b2c3d4-..."` locally, calls
   `POST /auth/signup {"name": "guild-a", "username": "alice", "password_hash": "..."}`.
   `Riptide.Placement.claim_name("guild-a", "a1b2c3d4-...")` returns `:claimed` (the only race in the whole
   flow); `Riptide.Accounts.sign_up/3` then writes Alice's account fact *and* her owner Authz policy into
   `{:tenant, "a1b2c3d4-..."}`'s own stream, sequenced, no separate atomicity needed (§4.4).
2. Alice proposes+approves the badge/QR-code generator Capability into her own tenant's Catalog (ordinary,
   already-existing `TenantCapabilityController`, §4.5) — its bytes land in
   `BlobStore.put("a1b2c3d4-...", wasm_bytes)`.
3. Alice grants `{"matcher": "public", "modes": ["read"], "effect": "allow"}` on the Capability's path —
   this *is* "publishing to Hub" now, with no separate Hub-specific action.
4. Bob's browser signs up the same way, claiming `"guild-b"`, generating its own opaque `tenant_id`.
5. Guild B's client, already knowing Guild A's chosen name, calls `GET /tenant-names/guild-a` (§4.2) to
   resolve it to `tenant_id`, then `GET /tenants/a1b2c3d4-.../discovery/search` — Alice's `:public` grant
   lets this succeed with no token at all, subject to the new public-read rate limit (§4.6).
6. Guild B installs the discovered Capability — `Install.install/3` copies the Rule/Capability facts *and*
   (§4.7) the WASM bytes into Guild B's own tenant, independently invocable from then on.

## 6. Error handling

- `claim_name/2` returning `:already_claimed` — `409`, identical to today's `claim_tenant_if_unclaimed`
  behavior on the signup path, just now a name conflict rather than a tenant_id conflict.
- A policy grant referencing a path with no admitted entry yet — unchanged, existing `PolicyController`
  validation already handles this (policies aren't required to reference existing content).
- A `GET /tenants/:tenant_id/discovery/search` (or any tenant-scoped read) against a tenant with no
  matching `:public` policy — `403`, exactly today's default-deny behavior, unchanged.
- Blob copy-on-install failing mid-way (source tenant's bytes unreachable, e.g. a transient placement
  failure) — the whole install fails atomically (`503`), the same failure-handling shape
  `Install.install/3` already has for its Rule/Crosswalk copy today; no partial install (facts copied,
  blob missing) is left behind.
- `GET /tenant-names/:name` for a name that was never claimed — `404`.

## 7. Testing

- `PlacementMachine`: new tests for `{:claim_name, ...}` (first-claim succeeds, second claim of the same
  name fails with `:already_claimed`) replacing the deleted `policies`-namespace tests.
- `Authz.Store.TenantFacts`: round-trip `add_policy/3` + `list_policies/2` against a real tenant stream,
  including the prefix-filtering behavior (a policy at `[]` matches a request at `["docs", "x"]`; a policy
  at `["docs", "y"]` does not).
- Full-suite regression on every test file the earlier research identified as calling
  `Store.Placement.claim_tenant_if_unclaimed/2` purely as fixture setup (~25 files) — mechanical
  rename/re-point to the new signup sequence, confirmed not to change test intent.
- `TenantCrosswalkController`/new Capability-propose-review surface: adapted directly from
  `test/riptide_web/hub/crosswalk_controller_test.exs`/`hub/capability_controller_test.exs`'s existing
  test bodies, target/review scope both `{:tenant, tenant_id}`.
- `Install.install/3`: existing Crosswalk-auto-mapping tests re-pointed at a `{:tenant, source_id}` source
  instead of `:hub` — same assertions, confirming zero behavior change in the auto-mapping engine itself.
- New: a capstone test proving copy-on-install for Capabilities — install a Capability from tenant A into
  tenant B, then confirm tenant B can still invoke it correctly even after tenant A's own copy is deleted
  (proving true independence, not a live reference).
- New: public-read rate-limit test — repeated anonymous reads against a `:public`-granted tenant resource
  trip the new quota; the same resource read by its owning tenant's own authenticated token does not.
- New: `BlobStore.Healer` test confirming it enumerates tenants via the `names` registry and heals
  per-tenant location indexes independently.

## 8. Explicitly out of scope

See §3 (Non-goals): general cross-tenant discovery of unknown tenants, cross-instance federation itself,
tenant export/migration tooling, cryptographic tenant identity, tenant renaming.
