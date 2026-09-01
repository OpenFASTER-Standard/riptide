# Phase 6n — Hub Resource Lifecycle (generalized addressing + Capability/Crosswalk supersede)

## 1. Context and motivation

Sub-project 6 (Derivation and execution layer) is being built phase-by-phase against
`docs/superpowers/specs/2026-08-27-derivation-and-execution-layer-design.md`. This phase — like 6j,
6k, 6l, 6d-ii, and 6m before it — emerged from real need rather than the original 21-phase breakdown,
and gets its own letter continuing that same sequence.

**Direct origin.** While preparing to brainstorm the Sub-project 6 demo (6o, provisionally — pushed
back one letter by this phase), the concrete first step is registering a real `generate-qr-code`
Capability into Riptide. That surfaced two gaps, both confirmed by reading the code directly rather
than assumed:

1. **Capabilities (and Crosswalks) are Create+Read only.** `Riptide.Derivation.Catalog`'s Rule
   admission already has a proven "update"/"retire" primitive — `supersede_entry/2`, a PATCH event
   that flips an entry's `rdf:type` from `CatalogEntry` to `SupersededCatalogEntry` while its full RDF
   description stays in the stream's history forever, plus `admit_entry/3`'s own `replaces` param
   linking a new entry to what it supersedes. 6k's own design spec named the Capability half of this
   gap explicitly and deferred it: *"Revoking/un-admitting a live Capability, or versioning... left for
   later work."* Crosswalks never had it either — nobody has needed it until now.
2. **Hub has no generic read or live-watch surface for anything.** Every Hub-scoped stream (the Rule
   catalog, Capabilities, Crosswalks, every kind of pending review) is already internally an
   append-only `Riptide.Event`/`Riptide.Stream.StreamServer` stream — the same mechanism 6m proved out
   for Tenant-scoped resources. But `RiptideWeb.Realtime.SseController.subscribe/2` routes every
   subscription through `RiptideWeb.LDP.ResourceController.parse_stream_id/1`, which only recognizes
   the `https://riptide.example/tenants/:id/resources/*path` shape — a Hub stream_id doesn't match and
   is rejected with `403`. This is the direct, structural consequence of 6m's own design spec
   explicitly scoping Hub out (*"Hub's own addressing/HTTP surface — unchanged; already has its own
   working model, not touched here"*) — that "existing model" turns out to have no read/watch story at
   all beyond `GET /hub/search` (keyword Discovery) and `GET /hub/entries/:node_id` (single Rule by
   node), neither of which generalizes to "list/watch everything of one kind."

**The higher-order framing.** The instinct to "add CRUD to Capabilities" and "add a generic resource
surface for Hub" are the same problem once `Riptide.Derivation.Catalog.scope/0`
(`:hub | {:tenant, tenant_id}`) is taken seriously as the one type that should flow through the HTTP
layer too — every function in `Catalog`/`Discovery`/`DedupGate`/`ContextResolver` is already
scope-polymorphic; only `Riptide.Authz.evaluate/4`, `Authz.Store`, and `ResourceController`'s own
addressing are still hardcoded to a raw `tenant_id` string. Generalizing those closes both gaps at
once, without building a second, parallel Hub-specific controller or SSE-dispatch path.

## 2. Scope

- **Generalize `Catalog.scope()` through the HTTP layer.** `Riptide.Authz.evaluate/4`,
  `RiptideWeb.LDP.ResourceController.stream_id_for/2` + `parse_stream_id/1`, and every
  `ResourceController` action take/produce `scope :: Catalog.scope()` instead of a raw `tenant_id`
  string. `Authz.Store`'s own implementation is untouched (§4.1).
- **One new read route:** `GET /hub/resources/*path` — reuses `ResourceController.show/2` verbatim.
  No write verbs are wired for it; Hub writes stay exactly as they are today (bespoke, review-gated
  POST endpoints under `/hub/*`) (§4.2).
- **Hub streams move under the same `/resources/*path` convention Tenant scope already uses.**
  `Catalog.catalog_stream_id(:hub)` moves from `.../hub/catalog` to `.../hub/resources/catalog` — the
  one literal every other Hub stream_id (crosswalks, capabilities, pending-reviews) derives from by
  concatenation, so this one change cascades to all of them (§4.3).
- **Capability and Crosswalk supersede**, mirroring `Catalog.supersede_entry/2` and `admit_entry/3`'s
  `replaces` param exactly: `Catalog.supersede_capability/1`, `supersede_crosswalk/1`,
  `admit_capability/2` (gains `replaces`), `admit_crosswalk/2` (gains `replaces`), with the
  corresponding `DedupGate`/Hub-controller propose flows threading an optional `replaces` node through
  (§4.4, §4.5).

## 3. Non-goals

- **Convenient WASM component authoring/production tooling.** Registering a real `generate-qr-code`
  Capability still means hand-writing a WIT world and Rust source, `cargo component build`ing it, and
  proposing the resulting bytes through the existing (now supersede-capable) flow. A more convenient
  authoring path is real, separate follow-up work — this phase makes the *lifecycle* around a component
  stream-native; it does not change how the component itself gets produced.
- **The demo itself** — 6o (provisionally), built on top of this phase and 6m together.
- **Hub's own write authorization model.** Propose/review/approve already flows through the *proposing
  tenant's own* `{:tenant, tenant_id}` Authz-gated pipeline (confirmed by reading
  `Hub.CapabilityController.propose/2`, which lives under `scope "/tenants/:tenant_id"` and calls
  `DedupGate.propose_capability({:tenant, tenant_id}, entry)` — the review queue is the proposing
  tenant's own, not Hub's). Only final admission into the shared Hub catalog skips a check, and that's
  the existing, working governance model (approving in your own reviewed queue *is* the authorization)
  — unchanged by this phase.
- **`Riptide.HubRateLimit`** — reused as-is for the new read route (§4.2); not redesigned.

## 4. Detailed design

### 4.1 `Riptide.Authz.evaluate/4` and `Authz.Store` — scope-polymorphic, not Hub-aware inside the Store

Current signature: `evaluate(tenant_id :: String.t(), path_segments, current_subject, mode)`. New:

```elixir
@spec evaluate(Catalog.scope(), [String.t()], map() | nil, Policy.mode()) :: :allow | :deny
def evaluate(:hub, _path_segments, _current_subject, :read), do: :allow

def evaluate(:hub, _path_segments, _current_subject, :write), do: :deny

def evaluate({:tenant, tenant_id}, path_segments, current_subject, mode) do
  # existing body, unchanged — store.list_policies(tenant_id, prefix) as today
end
```

The `:hub` clauses are hardcoded short-circuits, not policy rows: Hub's read-openness is a structural
property of what Hub *is* (`Hub.DiscoveryController`'s own moduledoc already states this — *"reads are
inherently cross-tenant, nobody 'acts as' a Tenant to search"*), not a per-scope setting that should be
editable/revocable through the same mechanism a Tenant's own policies are. Both `:hub` clauses return
before ever calling `Authz.Store` — **`Authz.Store`'s behaviour and its `Placement`-backed
implementation are completely unchanged**, so there is no `"hub"`-string-vs-real-tenant_id collision
risk to design around at all (a concern raised and then dismissed during brainstorming: it doesn't
arise because the Store is never consulted for `:hub`).

`RiptideWeb.Plugs.Authorize` changes its two `conn.assigns.tenant_id` reads to
`conn.assigns.scope`, and `maybe_bootstrap/4` — which calls
`Store.claim_tenant_if_unclaimed/2`, a genuinely Tenant-only "first write claims ownership" concept —
gets an explicit `{:tenant, tenant_id}` clause for the existing bootstrap behavior plus a catch-all
clause (covering `:hub` and any future non-tenant scope) that rejects outright. `:hub` can never reach
`Authorize` in practice (no write route is wired for it — see §4.2), but this keeps the function total
and crash-free rather than relying on that never happening.

### 4.2 `ResourceController` — one route added, zero new controller modules

`stream_id_for/2` and `parse_stream_id/1` become scope-polymorphic, mirroring how
`Catalog.catalog_stream_id/1` already branches on scope:

```elixir
@spec stream_id_for(Catalog.scope(), [String.t()]) :: String.t()
def stream_id_for({:tenant, tenant_id}, path_segments),
  do: @tenant_stream_id_prefix <> tenant_id <> @resources_segment <> Enum.join(path_segments, "/")

def stream_id_for(:hub, path_segments),
  do: @hub_stream_id_prefix <> Enum.join(path_segments, "/")

@spec parse_stream_id(String.t()) :: {:ok, Catalog.scope(), [String.t()]} | :error
def parse_stream_id(@tenant_stream_id_prefix <> rest) do
  case String.split(rest, @resources_segment, parts: 2) do
    [tenant_id, path] when tenant_id != "" -> {:ok, {:tenant, tenant_id}, String.split(path, "/")}
    _ -> :error
  end
end

def parse_stream_id(@hub_stream_id_prefix <> path) when path != "",
  do: {:ok, :hub, String.split(path, "/")}

def parse_stream_id(_other), do: :error
```

(`@hub_stream_id_prefix` is `"https://riptide.example/hub/resources/"` — the exact prefix `show/2`'s
new route below constructs stream_ids under.)

Every action (`show/2`, `replace/2`, `delete/2`, `patch/2`, `create_child/2`) changes its internal
`conn.assigns.tenant_id` reference to `conn.assigns.scope` — mechanical, and the compiler catches every
missed call site once the function signatures change. In practice only `show/2` is ever reached with
`scope = :hub`, since the router change below wires only `GET` for the Hub route; the other four
actions still only ever receive `{:tenant, tenant_id}`, unchanged in behavior.

Router addition, alongside the existing routes (no change to the existing `/tenants/:tenant_id/...`
block):

```elixir
scope "/hub" do
  pipe_through [:api, :auth, :resolve_hub_scope, :authz]

  get "/resources/*path", RiptideWeb.LDP.ResourceController, :show
end
```

A new pipeline stage, `:resolve_hub_scope`, backed by a tiny new plug mirroring `ResolveTenant`'s own
shape:

```elixir
defmodule RiptideWeb.Plugs.ResolveHubScope do
  @moduledoc """
  Assigns `conn.assigns.scope = :hub` for the `/hub/resources/*path` read route — the Hub-side
  counterpart to `ResolveTenant` assigning `{:tenant, tenant_id}`. No route param to resolve; this
  plug exists purely so `Authorize`/`ResourceController` see the same `conn.assigns.scope` shape
  regardless of which scope a request is for.
  """
  import Plug.Conn
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts), do: assign(conn, :scope, :hub)
end
```

`ResolveTenant` gains one additional assign alongside its existing `:tenant_id` one —
`assign(conn, :scope, {:tenant, tenant_id})` — additive, so every other controller that still reads
`conn.assigns.tenant_id` directly (`TaskController`, `Authz.PolicyController`, the Tenant-scoped
propose/review/discovery controllers from 6m, etc.) is unaffected.

No write verbs (`POST`/`PUT`/`PATCH`/`DELETE`) are routed under `/hub/resources/*path` at all — unlike
Tenant scope's reserved-path write-guard (6m §4.2), there is nothing to guard here, since the routes
simply don't exist. Hub writes stay exactly as they are: bespoke, review-gated POST endpoints under
`/hub/*`, unchanged by this phase.

There are exactly four real callers of `Authz.evaluate/4` in the codebase (confirmed by grepping, not
assumed) — every one needs to keep working once its first argument widens from a bare `tenant_id`
string to `Catalog.scope()`:

1. **`RiptideWeb.Plugs.Authorize`** — covered above.
2. **`RiptideWeb.Realtime.SseController.subscribe/2`** — parses `stream_id` via
   `ResourceController.parse_stream_id/1`, then calls `evaluate/4` with whatever it returns. Once that
   parser accepts `:hub`, this caller needs no code change to keep compiling — but it needs one
   *behavioral* addition: before this phase, no Hub-shaped stream_id could ever reach it
   (`parse_stream_id/1` rejected every one with `:error` → `403`), so subscribing was never a reachable
   Hub-scoped code path and never needed Hub's abuse-rate-limit layer. Once it's reachable, `evaluate/4`'s
   new `:hub` + `:read` short-circuit means *anyone*, unauthenticated, can open a live subscription — the
   exact same abuse surface `HubRateLimit.check_read/1` already exists to bound for `GET /hub/search`/
   `GET /hub/entries/:node_id`. The rule: **every entry point that reads Hub-scoped data — one-shot
   `GET` or a live subscribe-*open* — gets exactly one `HubRateLimit.check_read/1` check**, applied once
   when the connection opens (a subscription is one long-lived connection, not a per-event hit, so this
   is a check at open-time, not a per-message throttle). `do_subscribe/2` gains a scope match: for
   `{:ok, :hub, path_segments}`, check `HubRateLimit.check_read/1` before proceeding; for `{:ok,
   {:tenant, tenant_id}, path_segments}`, unchanged.
3. **`RiptideWeb.Realtime.ReplicationChannel.join/3`** — the WebSocket-replication sibling of
   `SseController.subscribe/2`, following the exact same `parse_stream_id/1` → `evaluate/4` shape
   (confirmed by reading it directly). Gets the identical treatment as #2 for the identical reason — a
   `:hub`-scoped `"replication:<stream_id>"` channel join becomes newly reachable the same way SSE
   subscribe does, so it needs the same `HubRateLimit.check_read/1` guard at join-time.
4. **`Riptide.Capability.authorized?/3`** — calls `evaluate(tenant_id, path, current_subject, :invoke)`
   where `tenant_id` is always the invoking Tenant's own id (a Capability invocation is always on behalf
   of a real tenant; `:hub` invoking something is meaningless). This caller only needs its argument
   wrapped — `evaluate({:tenant, tenant_id}, path, current_subject, :invoke)` — no behavioral change,
   since `:invoke` mode was never handled by the new `:hub` clauses anyway (only `:read`/`:write` are).

Both #2 and #3's new `HubRateLimit.check_read/1` calls need the same rate-limit key
`Hub.DiscoveryController`'s own `rate_limit_key/1` already computes (`current_subject["sub"]` when
present, else caller IP) — that helper is a private `defp` inside `Hub.DiscoveryController`, so each of
the two new call sites needs its own 2-line copy of the same logic rather than calling it directly;
small, deliberate duplication in the same spirit as `GeneralizationFidelity`'s own `term_to_arg/1`, not
worth extracting a shared module for two call sites.

### 4.3 Catalog stream-id convention move (Hub side)

Mechanical, mirrors 6m's own Task 1 exactly, applied to the one Hub-scope literal:

```elixir
def catalog_stream_id(:hub), do: @stream_id_prefix <> "hub/resources/catalog"
```

`crosswalk_stream_id/0` (`catalog_stream_id(:hub) <> "/crosswalks"`), `capability_stream_id/0`
(`catalog_stream_id(:hub) <> "/capabilities"`), and `pending_review_stream_id/1` (already
scope-polymorphic, `catalog_stream_id(scope) <> "/pending-review"`) all derive from this one function
by string concatenation — no separate change needed for any of them.

### 4.4 Capability supersede

New functions in `Catalog`, direct mirrors of the existing Rule ones:

```elixir
@spec admit_capability(CapabilityCatalogEntry.t(), RDF.BlankNode.t() | nil) :: :ok | {:error, :not_ready}
def admit_capability(%CapabilityCatalogEntry{} = entry, replaces) do
  {node, entry_graph} = CapabilityCatalogRDFCodec.to_rdf(entry)

  graph =
    entry_graph
    |> RDF.Graph.add({node, @rdf_type, @riptide_capability_catalog_entry})
    |> maybe_add_supersedes(node, replaces)

  write_patch(capability_stream_id(), RDF.Graph.triples(graph), [])
end

@spec supersede_capability(RDF.BlankNode.t()) :: :ok | {:error, :not_ready}
def supersede_capability(node) do
  write_patch(
    capability_stream_id(),
    [{node, @rdf_type, @riptide_superseded_capability_catalog_entry}],
    [{node, @rdf_type, @riptide_capability_catalog_entry}]
  )
end
```

(`admit_capability/1`'s current single-arg form becomes `admit_capability/2` with `replaces` — every
existing call site passes `nil`, matching how `admit_entry/3`'s own callers already do.)

`list_capabilities/0` needs **no change** — it already filters by
`nodes_of_type(graph, @riptide_capability_catalog_entry)` (confirmed by reading it directly), so a
superseded entry's type-flip removes it from the live list automatically, the same way
`list_entries/1` already excludes superseded Rules for free.

`DedupGate.propose_capability/2` becomes `propose_capability/3`, gaining an optional `replaces` param
and threading it into the
`PendingCapabilityReview` it queues (mirroring `PendingReview.replaces` exactly); its approval path
(`approve_capability_review/2`) calls `Catalog.admit_capability(entry, pending.replaces)` followed by
`Catalog.supersede_capability(pending.replaces)` when `replaces` is non-nil — the exact
`finish_proposal/8` shape Rules already use. `Hub.CapabilityController.propose/2`'s request body gains
an optional `"replaces"` field (a node_id string, `RDF.BlankNode.new/1`'d the same way
`TenantReviewController`'s existing approve/decline actions already reconstruct a node from a path
param).

### 4.5 Crosswalk supersede

Identical shape to §4.4, applied to `Crosswalk`/`CrosswalkRDFCodec`/`crosswalk_stream_id/0`:
`admit_crosswalk/2` (gains `replaces`), `supersede_crosswalk/1`, `DedupGate.propose_crosswalk/2`
becomes `propose_crosswalk/3` (gains `replaces`), `Hub.CrosswalkController.propose/2`'s body gains an
optional `"replaces"` field.
`list_crosswalks/0` needs no change, for the same reason as §4.4.

## 5. Data flow — worked example

1. `POST /tenants/acme/hub/capabilities {"name": "urn:riptide:capability:generate-qr-code", ...,
   "component_bytes": "<base64>"}` — proposes into `acme`'s own review queue, exactly as today.
2. `acme` approves it: `POST /tenants/acme/hub/capability-reviews/<node>/approve` — admits into the
   Hub catalog with `replaces: nil` (a genuinely new Capability, nothing to supersede).
3. `GET /hub/resources/capabilities` — the entry appears, live-watchable via
   `GET /streams/:stream_id/subscribe?stream_id=https://riptide.example/hub/resources/capabilities`
   for the first time ever, no polling required.
4. A bug is found in the component. `acme` proposes a fixed build:
   `POST /tenants/acme/hub/capabilities {..., "replaces": "<old_node>"}` — same review flow, but the
   `PendingCapabilityReview` now carries `replaces`.
5. `acme` approves it: the new entry is admitted linked to the old one via `supersedes`, and the old
   entry's type flips to `SupersededCapabilityCatalogEntry` in the same admission — `GET
   /hub/resources/capabilities` immediately reflects only the new version; the old version's full RDF
   description remains readable from the stream's own history (`GET /hub/resources/capabilities` folds
   *current* state; nothing was deleted from the underlying event log).

## 6. Error handling

- `GET /hub/resources/*path` for a never-written Hub stream (e.g. before any Capability has ever been
  admitted): `404`, mirroring `ResourceController.show/2`'s existing never-written-resource handling —
  no new logic needed, since `current_state/1`'s `Placement.lookup/1` check is scope-agnostic already.
- `GET /hub/resources/*path` rate-limited: `429`, via the same `HubRateLimit.check_read/1` guard
  `Hub.DiscoveryController` already uses (exact reuse, not a new limiter).
- Proposing a Capability/Crosswalk with `"replaces"` pointing at a node that isn't actually a live
  (non-superseded) entry: mirrors whatever `DedupGate`'s existing Rule-merge path does for an invalid
  `replaces` reference today (confirm exact behavior when writing the plan — likely a `{:error,
  :not_found}`-shaped rejection at admission time, not a crash).

## 7. Testing

- `RiptideWeb.LDP.ResourceControllerTest`-style tests for `GET /hub/resources/*path`: never-written
  404, a Hub-admitted Capability/Rule/Crosswalk visible after admission, rate-limit 429.
- `Authz.evaluate/4`'s two new `:hub` clauses, unit-tested directly (read always allows, write always
  denies) — mirroring the existing `Authz` test suite's own per-clause style.
- `Catalog`/`DedupGate` supersede tests for both Capability and Crosswalk, mirroring
  `catalog_test.exs`'s existing `supersede_entry/2` coverage exactly: old entry disappears from
  `list_capabilities/0`/`list_crosswalks/0`, new entry appears, `supersedes` linkage round-trips.
  Capstone-style test: propose → approve → propose-with-replaces → approve → verify only the new
  version is live, old version's history still readable via a raw `StreamServer.get_since/2` read from
  cursor 0.
- SSE subscription and `ReplicationChannel` join to a Hub-shaped stream_id, each mirroring their
  existing Tenant-scoped test coverage, plus a dedicated case per transport confirming
  `HubRateLimit.check_read/1` is actually consulted at open/join time (a stubbed/exhausted limiter
  returns `429`/`{:error, ...}` instead of opening the connection) — the one genuinely new code path
  this phase adds to each, not just a wider-type passthrough.
- `Riptide.Capability.authorized?/3` regression test confirming Capability invoke-authorization still
  works unchanged after its `evaluate/4` call site wraps `tenant_id` as `{:tenant, tenant_id}`.

## 8. Explicitly out of scope

See §3 (Non-goals).
