# Phase 6p-i — Demo Backend Additions (`mutex_key` + Query Endpoint)

## 1. Context and motivation

Sub-project 6 (Derivation and execution layer) is being built phase-by-phase against
`docs/superpowers/specs/2026-08-27-derivation-and-execution-layer-design.md`. This phase — like 6j,
6k, 6l, 6d-ii, 6m, 6n, and 6o before it — emerged from real need rather than the original 21-phase
breakdown, and gets its own letter continuing that same sequence.

**Direct origin.** Brainstorming the Sub-project 6 demo (6p — pushed back from 6o once that letter was
reassigned to username/password authentication) settled on a six-beat narrative meant to show off
everything Sub-project 6 has actually built. Two of those beats need real backend surface that doesn't
exist yet: "two players, one chest" (a live demonstration of 6d-ii's concurrent-effects guarantee) needs
a way to mark two Task submissions as mutually exclusive, and "ask a question, not just store data" (a
live demonstration of 6c-ii's recursive/fixpoint rule evaluation) needs *any* HTTP surface at all for
`QueryInterpreter` — confirmed by direct code search that it is 100% library-only today, never
referenced anywhere under `lib/riptide_web/`. Because the demo itself (6p-iii) depends on both, and
because a third genuinely independent piece (hand-authoring the demo's own WASM components, 6p-ii) is
also needed, 6p was split into three sub-phases during brainstorming, each with its own spec → plan →
implementation cycle. This spec covers the first: the backend additions, pure Elixir/Phoenix, with no
dependency on 6p-ii or 6p-iii.

## 2. Scope

- Rename `Job.resource_key` → `Job.mutex_key` throughout — the existing field genuinely means "Jobs
  sharing this value never run concurrently," which the current name collides with Riptide's own,
  much more prominent "LDP resource" concept (`/resources/*path`) used everywhere else in this
  codebase. No behavioral change (§4.1).
- Thread an optional `mutex_key` through `POST /tenants/:tenant_id/tasks` — `TaskController` currently
  builds every `%Job{}` it writes without ever reading this field from the request body at all, so it's
  silently dropped even if a caller sends it (§4.2).
- A new `POST /tenants/:tenant_id/query` — the first HTTP surface anywhere for
  `Riptide.Derivation.QueryInterpreter`'s recursive/fixpoint evaluation. Reuses existing storage
  entirely: the ruleset comes from the Tenant's own already-admitted Catalog (`Catalog.list_entries/1`,
  unchanged), the starting facts come from reading one caller-named existing Tenant resource (§4.3).

## 3. Non-goals

- **An ad hoc query language or arbitrary rule submission over HTTP.** The query endpoint evaluates
  exactly what the Tenant has already admitted to its own Catalog against exactly one named existing
  resource's current facts — not a general-purpose "submit any ruleset, any starting graph" sandbox.
  Considered and rejected during brainstorming: it would require inventing a wire format for submitting
  `Rule` literals over HTTP, which doesn't exist anywhere in this codebase today, for a need the demo
  doesn't actually have.
- **Fixing `Authorize`'s write-mode-on-every-non-GET quirk.** `RiptideWeb.Plugs.Authorize.mode_for/1`
  maps every verb but `GET` to `:write`, so the new query endpoint — a `POST` because its request body
  doesn't fit a query string, but semantically a pure read — needs `:write` permission to use. This is
  not a new problem this phase introduces: `POST /tenants/:tenant_id/tasks` and
  `POST /tenants/:tenant_id/policies` already have the exact same property today (confirmed directly in
  `RiptideWeb.Authz.PolicyController`'s own moduledoc). A real fix belongs to whatever phase reconsiders
  `Authorize`'s mode-inference model generally, not this one.
- **The demo's own WASM components** (6p-ii) and **the demo page itself** (6p-iii) — separate phases,
  each depending on this one.

## 4. Detailed design

### 4.1 `mutex_key` rename

Purely mechanical, no behavior change. Touches:

- `lib/riptide/derivation/job.ex` — `:resource_key` → `:mutex_key` in `@enforce_keys`/`defstruct`/`@type
  t`, and the moduledoc paragraph describing it.
- `lib/riptide/derivation/job_rdf_codec.ex` — `@riptide_job_resource_key` module attribute renamed to
  `@riptide_job_mutex_key`, its IRI value changed from `urn:riptide:vocab:jobResourceKey` to
  `urn:riptide:vocab:jobMutexKey`, and both the `to_rdf/1` (`maybe_add(node, @riptide_job_mutex_key,
  job.mutex_key && RDF.literal(job.mutex_key))`) and `from_rdf/2` (`decode_optional_string(description,
  @riptide_job_mutex_key)`) call sites updated to match.
- `lib/riptide/derivation/job_trigger.ex` — every `%Job{resource_key: ...}` pattern match (confirmed at
  `try_spawn_execution/3`'s two clauses) becomes `%Job{mutex_key: ...}`; every doc/comment reference to
  "resource_key"/"resource" in this file's own prose (the `run_exclusively/2`
  `{tenant_id, resource_key}` pair, its moduledoc) is updated to "mutex_key"/"the mutex" for the same
  clarity reason.

No RDF data exists anywhere using the old predicate — confirmed during 6o's own brainstorming that no
real deployment of this system exists yet — so this is a clean rename, not a migration.

### 4.2 `mutex_key` threading through `POST /tasks`

`TaskController.handle_create/4`'s two Job-construction sites — `write_discovery_job/5` and
`write_llm_fallback_job/4` — both currently build a `%Job{}` literal with no `mutex_key` field at all,
confirmed by reading `lib/riptide_web/task_controller.ex` directly. Both gain
`mutex_key: Map.get(params, "mutex_key")` (already-decoded JSON, `nil` when the caller doesn't send
one — the exact same "most Jobs don't declare a mutex_key" default `Job.mutex_key`'s own moduledoc
already documents). No validation needed beyond what `Map.get/2` already gives: a `mutex_key` is an
opaque string like any other Job field, and `JobTrigger`'s own exclusion logic (§4.1, unchanged
otherwise) already tolerates any string value or `nil`.

### 4.3 `POST /tenants/:tenant_id/query`

New `RiptideWeb.TenantQueryController.create/2`, same `[:api, :tenant, :auth, :authz]` pipeline as
every other route under `scope "/tenants/:tenant_id"`.

Request: `{"starting_resource_path": ["characters", "alice"]}` — an array of path segments, the exact
same shape `ResourceController.stream_id_for/2`'s own `path_segments` argument already takes.

1. Reads the Tenant's own admitted Catalog rules: `Catalog.list_entries({:tenant, tenant_id})`
   (existing, unchanged), extracting just the `Rule.t()` values (`Enum.map(entries, fn {_node, rule} ->
   rule end)`).
2. Reads the named starting resource's current graph — a small, dedicated read helper mirroring
   `ResourceController`'s own private `current_state_for_existing/1` (confirmed private, so this is
   deliberate small duplication, the same "small, deliberate duplication" precedent already used
   repeatedly in this codebase, e.g. `Riptide.Accounts`'s own `write_patch/3`/`read_graph/1` in 6o)
   — but with one deliberate divergence from that precedent: an unwritten resource is not an error
   here. `Riptide.Placement.lookup/1` returning `nil` yields an empty `RDF.Graph.new()` starting graph
   rather than a 404, since "no starting facts yet" is a legitimate query outcome (the rules alone may
   or may not derive anything from nothing), not a broken request — genuinely different from
   `GET /resources/*path`'s own "give me exactly this resource" semantics.
3. Calls `QueryInterpreter.evaluate(rules, starting_graph)` (existing, unchanged).
4. On `{:ok, result_graph}`: encodes `result_graph` via `TurtleCodec.encode/1` (existing, unchanged) and
   returns it as the `200` body — the same "return the current full graph as Turtle" shape
   `ResourceController.show/2` already uses for its own `200` responses, not a new response
   convention. Confirmed by reading `QueryInterpreter.loop/5` directly that the returned graph is the
   *union* of the starting facts and everything newly derived, not a diff — so this is exactly the
   right fit for that existing convention.
5. On `{:error, reason}` (any of `QueryInterpreter.evaluate/3`'s own documented error atoms —
   `:too_many_variables`, `{:unsupported_literal, _}`, `{:unsafe_rule, _}`, `:iteration_limit_exceeded`,
   `:fact_limit_exceeded`): `422`, body `{"error": "query_evaluation_failed", "reason": "<inspect(reason)>"}`
   — a well-formed request that hit a real evaluation limit, not a malformed request (`400`) or a
   transient unavailability (`503`, reserved for the placement-cluster-unreachable case below).

## 5. Worked example

1. Guild A has already admitted a small recursive ruleset to its own Catalog (e.g. "if X unlocks Y and
   Y unlocks Z then X unlocks Z" — a base clause plus a recursive clause sharing one head predicate,
   the same shape 6c-ii's own worked examples already use) via the ordinary propose/DedupGate/admit
   flow every other pattern in this demo already goes through.
2. Guild A has separately written ordinary facts at `/tenants/guild-a/resources/characters/alice`
   recording which skills Alice's character currently has.
3. `POST /tenants/guild-a/query` with `{"starting_resource_path": ["characters", "alice"]}` — reads the
   admitted ruleset, reads Alice's current skill facts, evaluates to fixpoint, returns the full
   resulting graph (Alice's original facts plus every skill she transitively unlocks) as Turtle.
4. Two players fire `POST /tenants/guild-a/tasks` with the same `"mutex_key": "guild-a-shared-chest"`
   at the same time — `JobTrigger`'s existing exclusion logic (§4.1, only its field name has changed)
   ensures the second one waits for the first to finish before executing, exactly as it already does
   today for any two Jobs sharing what used to be called `resource_key`.

## 6. Error handling

- `POST /query` with a missing, non-array, or empty `starting_resource_path`: `400`, rejected before any
  read is attempted — an empty path would join to a bare `.../resources/` stream_id
  (`Enum.join([], "/") == ""`), addressing nothing meaningful.
- `POST /query` for a `starting_resource_path` that's never been written: evaluates against an empty
  starting graph, `200` (not `404` — see §4.3).
- `POST /query` when `QueryInterpreter.evaluate/3` returns an error: `422` with the reason (§4.3).
- `POST /query`/`POST /tasks` when the placement cluster is unreachable (the underlying
  `Catalog.list_entries/1`/read-helper/`Catalog.write_job/2` calls raise or exit): `503`, via the same
  `rescue`/`catch :exit` guard already used throughout this codebase for this exact failure mode
  (`RiptideWeb.Plugs.Authorize.call/2`, `RiptideWeb.Realtime.SseController.subscribe/2`, and every
  6o-era controller).
- `POST /tasks` with a `mutex_key` present: no new validation — an opaque string, same as any other
  Job field, already tolerated by the unchanged `JobTrigger` exclusion logic.

## 7. Testing

- `mutex_key` rename: every existing test referencing `resource_key` gets its own assertions/fixtures
  renamed to `mutex_key`, not new scenarios — confirmed by direct search, this is exactly three files:
  `test/riptide/derivation/job_rdf_codec_test.exs` (the round-trip coverage), and
  `test/riptide/derivation/job_trigger_test.exs` +
  `test/riptide/derivation/job_trigger_cluster_test.exs` (the mutual-exclusion coverage, single- and
  multi-node respectively).
- `TaskController`: a new test confirming a submitted `"mutex_key"` actually lands on the written
  `Job.mutex_key` field (read back via `Catalog.list_jobs/1`), for both the Discovery-resolved and
  LLMFallback-resolved code paths.
- `TenantQueryController`: an admitted recursive ruleset + a written starting resource returns the
  correct fixpoint closure as Turtle; a `starting_resource_path` that's never been written returns
  `200` with just whatever the rules alone derive from nothing (likely empty, but not an error); a
  ruleset/starting-graph combination that trips `QueryInterpreter`'s own iteration or fact-count limit
  returns `422` with the reason.
- Capstone: mirrors §5's worked example directly over real HTTP — admit a recursive ruleset, write
  starting facts, query, assert the derived closure is present in the response; separately, fire two
  same-`mutex_key` Task submissions concurrently and assert (via timestamps on their own recorded
  results, the same technique 6d-ii's own existing concurrent-effects tests already use) that they
  never overlap.

## 8. Explicitly out of scope

See §3 (Non-goals).
