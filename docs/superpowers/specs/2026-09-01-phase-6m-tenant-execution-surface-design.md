# Phase 6m — Tenant-Scoped Execution Surface

## 1. Context and motivation

Sub-project 6 (Derivation and execution layer) is being built phase-by-phase against
`docs/superpowers/specs/2026-08-27-derivation-and-execution-layer-design.md`. This phase — like 6j,
6k, 6l, and 6d-ii before it — emerged from real need rather than the original 21-phase breakdown, and
gets its own letter continuing that same sequence (not part of Track A/B/C/D's original numbering).

**Direct origin.** During earlier brainstorming (2026-08-29), the request was for a new `examples/`
folder demo "that shows the full power of everything we've done," styled "like the tutorial of a
computer game" — a direct visual sequel to `examples/live-story`, but for Sub-project 6. That
brainstorm found the demo had no floor to stand on: no durable Capability registry (→ 6k, shipped),
no reactive write-triggers-computation mechanism (→ 6l, shipped, then hardened by 6d-ii). The demo
itself was set aside to build those prerequisites and never came back — no spec, no tracked issue.
Resuming that brainstorm (2026-09-01) found a *third* prerequisite, still unresolved: there is no
Tenant-scoped HTTP surface at all for submitting a Task (→ `LLMFallback`), proposing a Generalization
against the caller's own catalog (→ `DedupGate.propose/5`), or searching the caller's own catalog (→
Discovery). Every one of those is a library call with no public entry point a browser can reach —
`lib/riptide_web/router.ex` only has `/hub/*` endpoints today.

This phase closes that gap. The demo itself (§9.1's worked example, finally made real and browsable)
is **explicitly out of scope here** — its own phase, built on top of this one, once this ships.

## 2. Scope

- **Stream-id convention change**: Job and Tenant-scope Catalog/PendingReview streams move under the
  existing `/resources/*path` LDP namespace, so reading and live-watching them needs zero new
  mechanism — the existing generic `GET /resources/*path` and `GET /streams/:stream_id/subscribe`
  already work, unchanged (§4.1).
- **A write-guard** on those now-reserved paths, so the existing generic `PUT`/`PATCH`/`DELETE
  /resources/*path` can't be used to bypass `Job`/`Catalog`'s own invariant-preserving write
  functions (§4.2).
- **Three new optional fields on `Job`** (`resolved_via`, `original_description`, `trace`) recording
  how a Task-derived Job came to exist — including, when relevant, the full ground Trace `LLMFallback`
  actually produced — extending the same precedent 6d-ii's `resource_key` already set, rather than a
  second Fact type (§4.3).
- **`POST /tenants/:tenant_id/tasks`** — Task submission: Discovery-first, `LLMFallback` fallback,
  writes a `Job` (§5). The one genuinely new mechanism this phase builds.
- **Thin Tenant-scoped mirrors** of the three existing Hub controllers — propose, review
  approve/decline, Discovery search — targeting the caller's own catalog instead of Hub (§6).

**Depends on:** 6k (`CapabilityCatalog`, for resolving `context.capabilities`, which every existing
caller currently hand-builds as an empty or hardcoded map), 6l (`Job`, `JobTrigger`), 6f
(`LLMFallback`), 6e-iii (`DedupGate`), 6g-i (Discovery).

**Exit criterion:** given a Tenant with no matching CatalogEntry, `POST
/tenants/:tenant_id/tasks` with a plain-English description resolves via `LLMFallback`, writes a
`Job`, and that Job's execution is observable live through the existing generic subscription
mechanism with no bespoke watch endpoint; a second, independently-produced similar Task's Trace can
be proposed against the first via the new Tenant-scoped propose endpoint, admitted through the new
review endpoint, and a third similar Task then resolves via the new Discovery endpoint with zero
`LLMFallback` calls — recorded as `resolved_via: :discovery` on the Job it writes.

## 3. Key architectural decision: reuse the LDP surface instead of building a parallel one

Working through this phase's design surfaced that Riptide has exactly one stream storage mechanism —
confirmed directly in code: `RiptideWeb.LDP.ResourceController`'s writes and every one of
`Riptide.Derivation.Catalog`'s write functions (`write_job/2`, `admit_entry/3`, etc.) call the
identical primitives, `Riptide.Event.new/3` + `Riptide.Stream.StreamServer.append/2`, with the same
`Riptide.RDF.Patch{additions, removals}` shape. There is no such thing as a "Job stream" versus a
"resource stream" underneath — only one Ra-replicated event log implementation, always.

What differs is entirely the API layer stacked on top, and for Job/Catalog/PendingReview streams that
layer has historically stopped at "a narrow Elixir function exists" — no public HTTP read or
live-watch surface at all, because nothing needed one until now. Building that surface as its own new
parallel mechanism (a bespoke "watch my tenant's jobs" SSE endpoint, a bespoke "can you read your own
jobs" authorization check, eventually a "list catalog entries" endpoint) would duplicate — with new
bugs to match — the read/authorize/subscribe machinery `ResourceController` and
`RiptideWeb.Realtime.SseController` already have, tested, and working for every other Tenant-owned
resource.

**Decision:** put Job and Tenant-scope Catalog/PendingReview streams *in* the `/resources/*path`
namespace instead of introducing a parallel one. Concretely:

```elixir
# lib/riptide/derivation/catalog.ex
def job_stream_id(tenant_id), do: @stream_id_prefix <> "tenants/" <> tenant_id <> "/resources/jobs"

def catalog_stream_id({:tenant, tenant_id}),
  do: @stream_id_prefix <> "tenants/" <> tenant_id <> "/resources/catalog"

# catalog_stream_id(:hub) is unchanged — Hub already has its own working, separate /hub/* HTTP
# surface and addressing model; this phase touches only the Tenant-scoped side.
```

`pending_review_stream_id/1` (`catalog_stream_id(scope) <> "/pending-review"`) and
`crosswalk_stream_id/0` need no separate edit — both are derived from `catalog_stream_id/1` and
inherit the change automatically. `CapabilityCatalog` has no stream_id of its own (Capabilities are
just another entry type in the same per-scope catalog stream `Catalog` already owns), so it inherits
the change too, with no code changes there either.

**What this makes free, not just simpler:**
- `GET /tenants/:tenant_id/resources/jobs` — reading current Job state for the whole tenant — already
  works via the existing `ResourceController.show`, unchanged.
- `GET /streams/:stream_id/subscribe` — watching Jobs execute live — already works unchanged:
  `RiptideWeb.LDP.ResourceController.parse_stream_id/1` now recognizes the path, and the *same*
  per-path `Riptide.Authz.evaluate/4` check every other resource already gets applies here too. No
  new authorization model — "can you read your own jobs" collapses into "can you read this path,"
  which already exists.
- Same for `GET /tenants/:tenant_id/resources/catalog` and
  `GET /tenants/:tenant_id/resources/catalog/pending-review` — the demo's "watch the review queue"
  and "watch a Pattern crystallize" panels need no new backend surface either, in this phase or the
  next one.

**One thing this does *not* silently change**: `JobTrigger.periodic_sweep/0`'s own
`String.ends_with?(stream_id, "/jobs")` filter (the only other place in the codebase that touches the
raw stream-id string rather than calling `job_stream_id/1`) still matches — `"…/resources/jobs"` still
ends with `"/jobs"` — confirmed directly, not assumed, before this decision was finalized.

**Bonus, not incidental:** `GET /resources/jobs` returns exactly the same folded RDF graph
`Catalog.list_jobs/1` already reads internally — raw triples over the wire, no bespoke JSON shaping.
That matches `examples/live-story`'s own stated philosophy ("Peek at the data" shows the literal wire
Turtle, not a stringified JSON blob) more closely than a hand-shaped "list jobs" JSON endpoint would
have.

## 4. Concrete design

### 4.1 Stream-id convention change (recap of §3, made concrete)

Already fully specified above — two one-line changes to `Riptide.Derivation.Catalog`'s
`job_stream_id/1` and the `{:tenant, tenant_id}` clause of `catalog_stream_id/1`.

### 4.2 Write-guard on reserved paths

Reusing the generic namespace for reads means the generic namespace's existing unconditional
`PUT`/`PATCH`/`DELETE /resources/*path` handlers must not be usable to bypass `Job`/`Catalog`'s own
invariant-preserving write functions — e.g. a caller with plain write authorization on path `["jobs"]`
must not be able to `PATCH` a forged `status: "done"` onto a Job directly, skipping `JobTrigger` and
`mark_job_done/3` entirely.

`RiptideWeb.LDP.ResourceController`'s `replace/2`, `patch/2`, and `delete/2` each gain a guard,
checked before any authorization or stream logic runs:

```elixir
@reserved_path_prefixes [["jobs"], ["catalog"]]

defp reserved_path?(path_segments) do
  Enum.any?(@reserved_path_prefixes, &List.starts_with?(path_segments, &1))
end
```

`List.starts_with?/2` (prefix match, not exact match) means `["catalog"]` alone correctly also covers
`["catalog", "pending-review"]`, `["catalog", "crosswalks"]`, and any future nested Catalog sub-path,
with one entry — no per-sub-path enumeration to keep in sync. A write to a reserved path returns `409
Conflict` with a body naming the correct endpoint (e.g. `"write Jobs via POST
/tenants/:tenant_id/tasks, not PATCH /resources/jobs"`), not a silent 403 that reads like an
authorization failure — the caller may well have write authorization on that path in the ordinary
sense; the rejection is about *shape*, not permission.

Reads (`show/2`) and the SSE subscription controller are unaffected — no guard, no change — that's the
entire point of §3.

### 4.3 `Job` gains three optional fields

```elixir
# lib/riptide/derivation/job.ex
defstruct [
  :tenant_id, :status, :reference, :args, :job_graph, :result, :error, :resource_key,
  :resolved_via, :original_description, :trace
]

@type resolved_via :: :discovery | :llm_fallback

@type t :: %__MODULE__{
        # ...existing fields unchanged...
        resolved_via: resolved_via() | nil,
        original_description: String.t() | nil,
        trace: Rule.t() | nil
      }
```

All three `nil` by default — set only when a Job is written by the new Task-submission endpoint
(§4.4), not when a Job is written directly (as every current test and the existing capstone flow
already does). `trace` specifically is set only on the `resolved_via: :llm_fallback` path: it's the
full ground `Riptide.Derivation.Rule.t()` `LLMFallback.run/3` actually returns — `Job.reference` alone
(a single Capability/Rule IRI + args) is a *pointer* to what to execute, not the full Trace §4.5's
propose step needs to anti-unify against another one. A `resolved_via: :discovery` Job has nothing new
to propose in the first place — it already matched an admitted CatalogEntry — so `trace` stays `nil`
there, which is exactly the condition §6's `job_has_no_trace` error checks for.

This follows the precedent 6d-ii's `resource_key` already established: Job carries metadata about *why
and how* it came to exist alongside *what to execute*, rather than needing a second Fact type
(`TaskSubmission`) purely to avoid mixing those concerns — considered and rejected during brainstorming
specifically because it would have doubled the RDF vocabulary/codec/stream work this phase needs for
no behavioral gain over three more optional fields on an existing, already-precedented pattern.

`JobRDFCodec` gains two more IRI constants and two more `maybe_add`/`decode_optional_string` pairs for
`resolved_via`/`original_description`, following the exact shape `job_graph`/`error`/`resource_key`
already use (`resolved_via` encoded as one of the two fixed literal strings
`"discovery"`/`"llm_fallback"`, mirroring `Job.status`'s own `encode_status`/`decode_status` pattern,
not a bare literal). `trace` is a different shape — a full reified Rule, not a literal — so it follows
`RuleRDFCodec`'s own `to_rdf/1`/`from_rdf/2` pattern instead: `to_rdf/1` adds `{job_node,
@riptide_job_trace, rule_node}` and merges `RuleRDFCodec.to_rdf(job.trace)`'s own graph fragment in,
exactly the way `maybe_add_provenance/3` already merges a nested reification into a larger graph
elsewhere in this same codebase; `from_rdf/2` reads it back via `RDF.Description.first(description,
@riptide_job_trace)` and, if present, `RuleRDFCodec.from_rdf/2` on that node — `nil` when the predicate
is absent, matching every other optional field's own `nil` handling.

### 4.4 `POST /tenants/:tenant_id/tasks` — Task submission

The one genuinely new mechanism. Request body: `{"description": "make a QR code for this line",
"facts": [...]}` (facts shaped exactly like `ProposeController`'s existing `facts_to_graph/1` input —
same convention, not a new one).

```
1. Build context.capabilities from 6k's CapabilityCatalog (real entries, materialized on demand) and
   context.rules from the Tenant's own Catalog — replacing every existing caller's hand-built empty/
   hardcoded map with the first real, general-purpose construction of an
   ExecuteInterpreter.Context for a Tenant's own catalog.
2. Discovery lookup (Riptide.Derivation.Discovery.find/2 — 6g-i) against the Tenant's own catalog for
   the description.
   - Match found: resolve args from the match. resolved_via: :discovery.
   - No match: call LLMFallback.run(description, graph, context). resolved_via: :llm_fallback.
     LLMFallback failure (:no_match, :ambiguous_match, {:llm_error, _}, etc.) -> 422, error body
     naming the specific reason; no Job written.
3. Write a Job (tenant_id, status: :pending, reference/args from step 2, resolved_via,
   original_description: description, trace: the ground Rule LLMFallback.run/3 returned, or nil on
   the Discovery-hit path) via the existing Catalog.write_job/2 — unchanged.
4. 202 Accepted, body: {"job_node": "<blank-node id>", "resolved_via": "discovery" | "llm_fallback"}.
```

The response never contains a result — that arrives asynchronously, observed by subscribing to
`GET /tenants/:tenant_id/resources/jobs`'s stream (§3) the same way any other live Riptide surface is
watched, including by this phase's own tests.

### 4.5 Tenant-scoped propose / review / Discovery — thin mirrors

Three controllers, each a direct Tenant-scoped analogue of an existing Hub one, reusing that
controller's own request/response shape and rate-limiting pattern
(`Riptide.HubRateLimit`-equivalent Tenant check) exactly, with `target_scope`/`review_scope` set to
`{:tenant, tenant_id}` instead of `:hub`:

- `POST /tenants/:tenant_id/propose` — mirrors `RiptideWeb.Hub.ProposeController.propose/2`. Unlike
  the Hub version (which takes raw `trace1`/`trace2` Turtle text), this phase's version takes two Job
  node references (`{"job1": "<node>", "job2": "<node>"}`) and reads each Job's own recorded Trace
  back from its stream — the natural shape now that Traces are already durably recorded as part of
  Task resolution (§4.4), not re-supplied by the caller.
- `POST /tenants/:tenant_id/pending-reviews/:node_id/approve` (and `/decline`) — mirrors
  `RiptideWeb.Hub.ReviewController` exactly, `{:tenant, tenant_id}` in place of `:hub` for both
  `target_scope` and `review_scope`.
- `GET /tenants/:tenant_id/discovery/search` — mirrors `RiptideWeb.Hub.DiscoveryController.search/2`
  exactly, searching the Tenant's own catalog instead of Hub's.

## 5. Data flow — worked example

Grounding §4 against the QR-code Capability chosen for the demo phase that follows this one (not
itself part of this phase's own deliverable):

1. `POST /tenants/acme/tasks {"description": "make a QR code for this line", "facts": [...]}`. No
   matching CatalogEntry. `LLMFallback.run/3` resolves it to a ground Trace whose body invokes
   `{capability: generate-qr-code, args: [line_url]}`. `Job` written: `resolved_via: :llm_fallback,
   original_description: "make a QR code for this line", trace: <the ground Rule itself>`. `202
   {"job_node": "_:b1", "resolved_via": "llm_fallback"}`.
2. Demo UI, already subscribed to `GET /tenants/acme/resources/jobs`, observes `_:b1` transition
   `pending -> done` with a result, live — no new mechanism, §3.
3. A second, similar Task from a different Tenant resolves the same way, writing its own Job — a
   second ground Trace now durably recorded.
4. `POST /tenants/acme/propose {"job1": "_:b1", "job2": "<job2 node>"}` — reads both Jobs' own
   recorded Traces, anti-unifies, produces a Generalization sitting in `GET
   /tenants/acme/resources/catalog/pending-review` (watchable live, same mechanism again).
5. `POST /tenants/acme/pending-reviews/<node>/approve` — admits the Generalization as a live
   CatalogEntry, in `GET /tenants/acme/resources/catalog`.
6. A third, similar Task: `POST /tenants/acme/tasks`. Discovery now matches the admitted CatalogEntry
   directly. `Job` written: `resolved_via: :discovery` — zero `LLMFallback` calls, and *the exact same
   Job-writing and live-watching path as every other step* — the "0 LLM calls" badge the demo phase
   wants to show is a real, observable field on a real Job, not a UI-only claim.

## 6. Error handling

- `LLMFallback` failure during Task submission (§4.4 step 2): `422`, no Job written, specific reason
  in the body (`:no_match`, `:ambiguous_match`, `{:unresolvable, iri}`, `{:unsupported_arity, iri}`,
  `{:llm_error, reason}`, `{:unparseable_response, reason}` — `LLMFallback.run/3`'s existing full
  error union, unchanged).
- Write to a reserved path (§4.2): `409`, naming the correct endpoint.
- Propose (§4.5) referencing a Job node with no recorded Trace (e.g. the Job never went through
  `LLMFallback` — a Discovery-resolved Job has no Trace to propose): `422`,
  `{"error": "job_has_no_trace"}`.
- Every new controller reuses `RiptideWeb.Plugs.{ResolveTenant,Authenticate,Authorize}` exactly as
  the existing Hub controllers do — no new authorization primitive anywhere in this phase, matching
  6h-i's own threat model's scope (Tenant's own ordinary write/read authorization, nothing new to
  threat-model).

## 7. Testing expectations

- `JobRDFCodec` round-trip tests for all three new fields (mirroring 6d-ii's own
  `job_rdf_codec_test.exs` addition), including a `trace`-present case verifying the nested
  `RuleRDFCodec` reification round-trips correctly, not just that a triple exists.
- Write-guard tests: `PUT`/`PATCH`/`DELETE` against `/tenants/:tenant_id/resources/jobs` and
  `/tenants/:tenant_id/resources/catalog(/pending-review)` all `409`; `GET` and SSE subscription to
  the same paths still succeed.
- Task-submission controller tests: Discovery-hit path (`resolved_via: :discovery`, no `LLMFallback`
  call — assert via a test double on the LLM client that it's never invoked), `LLMFallback`-fallback
  path (`resolved_via: :llm_fallback`), each `LLMFallback` failure mode's `422`.
- A capstone test reproducing §5's full worked example end-to-end over real HTTP, mirroring
  6l's/6k's own capstone precedent — the actual falsifiable exit criterion (§2), not a narrower proxy
  for it.

## 8. Explicitly out of scope

- **The demo itself** — its own phase (6n, provisionally), built on top of this one once it ships. Not
  designed in this document beyond the worked example in §5, which exists to validate this phase's own
  design against a real path through it, not to specify the demo's UI.
- **Hub's own addressing/HTTP surface** — unchanged; already has its own working model, not touched
  here.
- **Automatic/background anti-unification candidate discovery** — §4.5's propose endpoint requires the
  caller (a human, or the demo's own UI) to pick which two Jobs' Traces to compare, mirroring Hub's
  existing `/hub/propose` precedent exactly (caller-supplied `trace1`/`trace2`). A background process
  that automatically searches for anti-unifiable Trace pairs is real, separate work this phase doesn't
  attempt.
