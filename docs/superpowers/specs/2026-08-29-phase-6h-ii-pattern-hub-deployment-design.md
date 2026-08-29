# Pattern Hub Deployment — Design

**Status:** Draft, first revision. Implements Sub-project 6, phase **6h-ii**
(Track A — value-delivery spine). Parent spec:
`docs/superpowers/specs/2026-08-27-derivation-and-execution-layer-design.md`
(§6 — Catalog/DedupGate/Discovery/Pattern, corrected eleventh revision;
§7 — 6h-ii's own roadmap entry). Depends on:
`docs/superpowers/specs/2026-08-29-phase-6h-i-pattern-hub-threat-model-design.md`
(the auth/rate-limit model this deployment is gated by).

## 1. Scope

Per the parent spec's §7 entry: stand up Hub-scope Catalog as a
network-publicly-reachable extension of 6e-iii's DedupGate mechanism plus
6g-i's Discovery.

**Exit criterion:** a CatalogEntry can be published to Hub scope by its
own Tenant and installed into a different Tenant via 6i, over a
network-reachable endpoint gated by 6h-i's auth/rate-limit model.

**Depends on:** 6e-iii, 6g-i, 6h-i (all shipped).

**Explicit scoping note, read literally from the exit criterion:**
"installed into a different Tenant **via 6i**" attributes the actual
Install operation (Crosswalk-aware field binding, human-curation
workflow) to **6i**, a separate, not-yet-built phase — not to 6h-ii.
6h-ii's own job is to make Discovery, publish (propose-to-Hub), and
review network-reachable, plus expose the one read primitive 6i's future
Install logic will need (fetching a specific Hub entry by id) — not to
build Install itself. Building full Install now would be scope creep
into 6i's own territory.

## 2. Key findings

**Route topology dissolves the "who is the acting Tenant" ambiguity —
by shape, not by new mechanism.** `RiptideWeb.Plugs.ResolveTenant`/
`Authorize` are hard-wired to a URL-path-shaped `tenant_id`
(`lib/riptide_web/plugs/resolve_tenant.ex`, `lib/riptide_web/plugs/authorize.ex`).
Rather than inventing a new "acting tenant from request body" mechanism,
Hub routes split by their own natural shape: **reads** (Discovery,
entry-fetch) are inherently cross-tenant — nobody "acts as" a tenant to
search — and live at a tenant-less `/hub/...` path, optional auth only
(6h-i §6). **Writes** (propose, approve/decline-review) are always
performed *as* some real Tenant (6h-i §2) and live under
`/tenants/:tenant_id/hub/...`, reusing the exact existing
`[:api, :tenant, :auth, :authz]` pipeline every other tenant-scoped route
already uses — zero new plug logic.

**Propose-to-Hub needs no new DedupGate/Catalog mechanism for the
candidate itself — found and verified against the real code.**
`DedupGate.propose/4`'s signature is untouched: a Tenant's own
Task/LLMFallback flow already produces `candidates()` (a generalization
plus its two recovering substitutions) immediately before calling
`propose({:tenant, id}, candidates, graph, context)`. Publishing to Hub
is the same call, `scope: :hub`, using the same still-fresh candidates —
not a later "share my already-admitted entry" action (which would need
substitutions `PendingReview` never retains — confirmed directly,
`lib/riptide/derivation/dedup_gate.ex:11-22`, no such field exists). Full
`GeneralizationFidelity` replay-testing runs for both scopes; no quality
regression versus Tenant-scope admission.

**But `propose/4`'s single `scope` argument couples two things that need
to split for Hub targets.** `Catalog.list_entries(scope)` (classify
against) and `Catalog.queue_pending_review(scope, pending_review)`
(review-queue storage) both currently use the *same* `scope` value
(`lib/riptide/derivation/dedup_gate.ex:157,185`). For a Hub-scope
proposal, classification and eventual admission must target `:hub`'s own
Catalog, but the review itself must be queued into the *proposing
Tenant's own* pending-review stream — not `:hub`'s, which would merge
every Tenant's proposals into one un-owned queue with no way to enforce
"only the proposing Tenant's own team reviews this." This needs no new
field on `PendingReview` — the tenant-scoped *stream itself* already
answers "which Tenant" by construction, the same way a file needs no
"which cabinet" label once it's filed in the right cabinet. It needs
`propose/4`'s single `scope` split into two independently-specified
scopes.

**Blank-node entry identifiers are durably stable — verified empirically,
not assumed.** `Catalog.list_entries/1`'s `RDF.BlankNode.t()` labels are
part of the persisted `RDF.Graph` data written via `write_patch/3` into
the Ra log (`RuleRDFCodec.to_rdf/1` creates the node once, at admission
time) — decoded verbatim on every later read, inheriting the same
durability guarantees already proven throughout this project (Sub-project
1's "durable before ack"). Confirmed directly: three separate
`Catalog.list_entries/1` calls against the same admitted entry returned
the identical blank-node label every time. Safe to use directly as the
Hub entry identifier in Discovery results and entry-fetch requests — no
new stable-IRI scheme needed.

**No Capability registry exists anywhere in this codebase — verified via
grep, zero hits.** `DedupGate.propose/5`'s `GeneralizationFidelity`
replay-testing needs a real `Context.capabilities` to re-invoke any
`CapabilityReference` literal in a candidate's Body. A network caller
can't safely supply a `Capability.Definition` inline — its `component`
field is a server-local WASM file path, and accepting one from an
untrusted request is an arbitrary-file-execution risk. Capabilities are
clearly meant to be pre-registered server-side and looked up by name,
but no such registry exists yet anywhere in this project — a real,
separate infrastructure gap, not specific to 6h-ii. `ProposeController`
(§6) is therefore scoped to fact-pattern-only candidates (no
`CapabilityReference`/`RuleReference` literals in the Body) — fidelity
replay-testing for those needs no real Capability context at all,
sidestepping the registry gap entirely rather than inventing one.
EffectCapability-bearing Hub proposals over HTTP are explicitly deferred
(§9), the same way full Install was deferred to 6i.

## 3. Approaches considered

- **A — Adopted.** Split Hub routes by read/write shape (tenant-less
  reads, tenant-scoped writes reusing the existing pipeline unchanged);
  split `DedupGate.propose/4`'s `scope` into `target_scope`
  (classify/admit) and `review_scope` (where the `PendingReview` is
  filed); scope 6h-ii to publish+discover+fetch, explicitly deferring
  full Install to 6i.
- **B — Ruled out.** A single top-level `/hub/...` route family for
  everything, resolving the acting Tenant from a request-body field via
  new plug logic. Ruled out: reinvents tenant resolution when the
  existing path-shaped mechanism already fits every write operation
  here — the only genuinely tenant-less operations are reads.
- **C — Ruled out.** Build full Install (Crosswalk-aware field binding,
  human-curation workflow) as part of 6h-ii, since the exit criterion
  mentions installation. Ruled out per §1 — the exit criterion's own
  wording attributes Install to 6i; building it now duplicates work 6i
  will need to redo with Crosswalk-awareness anyway.

## 4. Routes

| Method | Path | Auth | Operation |
|---|---|---|---|
| `GET` | `/hub/search?q=...` | Optional (6h-i §6) | `Discovery.find(:hub, query)` |
| `GET` | `/hub/entries/:node_id` | Optional (6h-i §6) | fetch one entry by blank-node id (from `Catalog.list_entries(:hub)`) |
| `POST` | `/tenants/:tenant_id/hub/propose` | Tenant write (existing pipeline) | `DedupGate.propose(target_scope: :hub, review_scope: {:tenant, tenant_id}, candidates, graph, context)` |
| `POST` | `/tenants/:tenant_id/hub/pending-reviews/:node_id/approve` | Tenant write (existing pipeline) | `DedupGate.approve_review(target_scope: :hub, review_scope: {:tenant, tenant_id}, node_id)` |
| `POST` | `/tenants/:tenant_id/hub/pending-reviews/:node_id/decline` | Tenant write (existing pipeline) | `DedupGate.decline_review(review_scope: {:tenant, tenant_id}, node_id)` |

All four `/tenants/:tenant_id/...` routes pipe through the exact existing
`[:api, :tenant, :auth, :authz]` pipeline (`router.ex:40`) — zero new
plug wiring, per 6h-i §8's requirement that 6h-ii reuse auth identically
to every existing route.

Rate limiting (6h-i §7, T1/T2/T10): a new `Riptide.HubRateLimit` module,
`use Hammer, backend: :ets, algorithm: :fix_window_per_key`, mirroring
`Riptide.NewStreamRateLimit`'s exact shape
(`lib/riptide/new_stream_rate_limit.ex`) — one limiter keyed
`"hub_read:#{subject_or_ip}"` for the two `GET` routes, one keyed
`"hub_propose:#{tenant_id}"` for propose (a per-tenant quota, mirroring
`@max_streams_per_tenant`, not a shared cross-tenant one — 6h-i §2's
finding).

## 5. `DedupGate.propose/4` and `approve_review/2`/`decline_review/2` —
scope split

```elixir
@spec propose(target_scope :: Catalog.scope(), review_scope :: Catalog.scope(), candidates(), RDF.Graph.t(), Context.t()) ::
        {:ok, [outcome()]} | {:error, term()}
def propose(target_scope, review_scope, candidates, graph, context) do
  with {:ok, entries} <- Catalog.list_entries(target_scope) do
    {:ok, Enum.map(candidates, &propose_one(target_scope, review_scope, &1, entries, graph, context))}
  end
end
```

`classify/2` (unchanged) still checks against `target_scope`'s own
entries. `finish_proposal/8` gains `review_scope` and calls
`Catalog.queue_pending_review(review_scope, pending_review)` instead of
`target_scope`. `approve_review/2`/`decline_review/2` gain the same
split: `list_pending_reviews`/`resolve_pending_review` read from
`review_scope`, while `apply_approved/3`'s own `Catalog.admit_entry/3`
call (and `supersede_entry/2` for `:merge`) target `target_scope`.

**Backward compatibility:** every existing Tenant-scope caller (6f, 6g-i,
6e-iii's own tests) currently calls `propose(scope, ...)` /
`approve_review(scope, node)` with one scope meaning both "target" and
"review owner" — which is exactly correct for Tenant-scope proposals
(a Tenant reviews its own Tenant-scope candidates in its own Tenant-scope
queue). `target_scope == review_scope` for every existing call site;
this change is a pure signature widening, not a behavior change for any
already-shipped caller.

## 6. Module: `RiptideWeb.Hub` (new namespace)

- `RiptideWeb.Hub.DiscoveryController` — `GET /hub/search`, `GET
  /hub/entries/:node_id`. Optional auth (reuses `Authenticate`
  unmodified, per 6h-i §6); rate-limited via `HubRateLimit`.
- `RiptideWeb.Hub.ProposeController` — `POST
  /tenants/:tenant_id/hub/propose`. Request body carries the two ground
  Traces (Rule text via the existing `Parser.decode/1`, matching how a
  Tenant's own LLMFallback-produced Trace is already represented) plus
  the RDF graph needed for `AntiUnifier.generalize/2` +
  `DedupGate.propose/5`'s `target_scope: :hub, review_scope: {:tenant,
  tenant_id}`. Scoped to fact-pattern-only Traces (no
  `CapabilityReference`/`RuleReference` literals) per §2's Capability-
  registry finding — `context.capabilities`/`context.rules` are built as
  empty maps server-side, never accepted from the request body, so there
  is no arbitrary-file-execution surface here at all.
- `RiptideWeb.Hub.ReviewController` — `POST .../approve`, `POST
  .../decline`. Thin wrappers over `DedupGate.approve_review/3`/
  `decline_review/2` with the split scopes.

## 7. Testing

- `Discovery.find(:hub, query)` reachable at `GET /hub/search` with no
  auth token, and with one present — both succeed, subject-keyed vs.
  IP-keyed rate limiting exercised for each.
- `GET /hub/entries/:node_id` returns the correct entry for a real
  admitted Hub-scope CatalogEntry's own blank-node id (proving the
  stability finding, §2, holds through the real HTTP path too).
- A real propose-to-Hub round trip: two ground Traces submitted via
  `POST /tenants/:tenant_id/hub/propose`, `target_scope: :hub` correctly
  classified against Hub's existing entries, `PendingReview` queued into
  `review_scope: {:tenant, tenant_id}` — confirmed by reading that
  Tenant's own pending-review stream directly, not Hub's.
  `POST .../approve` admits into `:hub`'s Catalog, confirmed via `GET
  /hub/search` finding the newly-live entry.
- A different, uninvolved Tenant's own write authorization is denied on
  `approve`/`decline` for a review it didn't propose — proving the
  review-queue split enforces per-Tenant review ownership with zero new
  authorization code (just the existing `Authorize` plug, unchanged).
- A per-tenant propose quota (`HubRateLimit`) throttles one Tenant's own
  excessive propose volume without affecting a different Tenant's own
  quota.
- Every existing `DedupGate`/`Catalog` test (6e-iii, 6f, 6g-i) continues
  passing unchanged, proving the `scope` → `target_scope`/`review_scope`
  split is backward compatible.

## 8. Exit criterion (from parent spec §7, restated)

A CatalogEntry can be published to Hub scope by its own Tenant (§7's
propose+approve round trip) and is fetchable over a network-reachable
endpoint (`GET /hub/entries/:node_id`, `GET /hub/search`) ready for 6i's
own future Install logic to build on — gated by 6h-i's auth/rate-limit
model (§4's route table, §7's testing plan). Satisfied by §7 end-to-end.

## 9. Explicitly deferred

- **Full Install** (Crosswalk-aware field binding, human-curation
  workflow) — explicitly 6i's own job (§1, §3 Approach C ruled out).
  6h-ii ships the one primitive 6i needs (`GET /hub/entries/:node_id`),
  nothing more.
- **EffectCapability-bearing Hub proposals over HTTP** — blocked on a
  Capability registry/lookup-by-name mechanism that doesn't exist
  anywhere in this project yet (§2's finding), not something 6h-ii
  invents. `ProposeController` accepts fact-pattern-only candidates
  only, for now.
- **Cross-instance federation** — 6h-i §10's own deferral carries over
  unchanged; every route/limiter here is subject/IP-keyed, already
  extending sensibly to a future cross-instance caller without redesign.
- **Crosswalk-propose** — structurally identical to propose-to-Hub per
  6h-i §2, but Crosswalk content itself (SSSOM shape, §6.5) is 6i's own
  scope to define; 6h-ii's `ProposeController` is written generically
  enough to extend to it later, not built for it now.
