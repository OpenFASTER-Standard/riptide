# DedupGate Orchestration — Design

**Status:** Draft, first revision. Implements Sub-project 6, phase **6e-iii**
([issue #66](https://github.com/OpenFASTER-Standard/riptide/issues/66)) —
the sixth link in the Sub-project 6 walking skeleton
(`6b-i → 6c-i-a → 6c-i-b → 6d-i → 6e-i → 6e-ii → 6e-iii → {6f, 6g-i}`),
unblocked by 6e-i (#78), 6e-ii (#79), and 6d-i (#64), all already shipped.
Parent spec:
`docs/superpowers/specs/2026-08-27-derivation-and-execution-layer-design.md`
(§5 — Trace/Generalization/Provenance; §6 — Catalog, DedupGate, Discovery,
Crosswalk; §8.2 — anti-unification's multi-candidate consequence; §8.11 —
`scratch-command-bar`'s propose/review precedent).

## 1. Scope

Per issue #66: Catalog lookup, the `Reject`/`Merge`/`Admit` decision, and
the human review workflow (`scratch-command-bar`'s propose/review
precedent). Built scope-parameterized (`Tenant` or `Hub`, §6) from the
start, so 6h-ii can reuse it directly.

**Exit criterion:** two independently-produced real Traces (from 6d-i's
NativeTemplate instances) anti-unify into a single Generalization, pass
the `Admit` path with 6e-ii's fidelity evidence and human review, and
become a live CatalogEntry.

## 2. The key insight — no new persistence layer

`Riptide.Derivation.RuleRDFCodec` (6c-i-a/6d-i) already established
**"Rules are Facts"**: `to_rdf/1` reifies any `Rule.t()` as plain RDF
triples. A `CatalogEntry ⊑ Rule` (§6), so **a CatalogEntry is just more
Facts** — it needs no bespoke storage subsystem of its own.

Riptide already has real, production persistence for exactly this shape:
`RiptideWeb.LDP.ResourceController` (`lib/riptide_web/ldp/resource_controller.ex`)
treats every resource as a `stream_id`, written via
`StreamServer.append(stream_id, Event.new(stream_id, operation, payload))`
and read via `StreamServer.get_since/2` folded through `Riptide.RDF.Patch.apply/2`
— a real, Ra-backed durable log, not test scaffolding. Verified during
design: `RDF.BlankNode` is just `%RDF.BlankNode{value: string}`
(`deps/rdf/lib/rdf/blank_node.ex`), and `Event`/`Patch` encode/decode pass
`RDF.Graph.t()`/triples straight through as plain Elixir terms into Ra's
command log — no Turtle round-trip happens on that path (Turtle is only
used for `ResourceController`'s own HTTP wire). So blank-node identity is
stable across reads/writes through this storage path, and `RuleRDFCodec`'s
default blank-node top node is a perfectly good stable identity for a
CatalogEntry or PendingReview item — no IRI-minting scheme needed.

This also closes a gap `RuleRDFCodec`'s own moduledoc explicitly left
open: "discovering a Rule's node identity from a graph with no such
handle... is left to a future phase." This phase is that future phase —
`Riptide.Derivation.Matcher.bindings/2` (already shipped) already answers
"find all subjects matching `rdf:type riptide:CatalogEntry`" with zero new
query machinery.

A second, smaller instance of the same idea resolves `Merge`: rather than
inventing any graph-merge algorithm (the parent spec explicitly flags
three-way graph merge as "provably weaker than git's," §6/§8.7 — a known
unsolved problem, not something to casually re-attempt), **`Merge` is just
`AntiUnifier.generalize/2` applied a second time** — candidate ×
existing-CatalogEntry instead of Trace × Trace. `Reject` vs. `Merge`
becomes mechanically checkable with zero new theory, reusing only what
`generalize/2` already returns: call
`AntiUnifier.generalize(candidate, entry)`, giving back
`{new_generalization, sub_candidate, sub_entry}`. `sub_entry`'s domain is
exactly the positions where candidate and entry *disagreed* (§3 of the
6e-i design spec — a position where both sides already matched never gets
a memo-map entry at all, so it's absent from `sub_entry`, not present as
an identity mapping). For each such disagreement, `sub_entry` maps the
fresh generalization variable back to *entry's own original subterm*
there. Two cases: entry already had a `Var.t()` at that position (its own
free variable, just renamed by this step — nothing about entry's shape
changed) — or entry had a ground constant there that differed from
candidate's value (that constant just got abstracted away into a
variable — entry's own shape genuinely broadened). So:
**`entry_unchanged? = Enum.all?(Map.values(sub_entry), &match?(%Var{}, &1))`**
(vacuously `true` when `sub_entry` is empty, i.e. candidate and entry are
already identical) is the complete, mechanical test — no alpha-equivalence
checker needs writing. `entry_unchanged?` true → `Reject` (nothing about
the admitted entry needed to broaden to cover this candidate);
`entry_unchanged?` false → `Merge` (the candidate revealed structure entry
didn't already have).

## 3. Approaches considered

- **A — Adopted.** Reuse `StreamServer`/`Event`/`Patch`/`RuleRDFCodec`/
  `Matcher` exactly as they exist today for Catalog storage; reuse
  `AntiUnifier.generalize/2` a second time for the `Merge` decision. Two
  new focused modules: `Riptide.Derivation.Catalog` (storage primitives)
  and `Riptide.Derivation.DedupGate` (orchestration/decision/review).
- **B — Ruled out.** Back Catalog with new, dedicated Ra infrastructure
  built specifically for it. Ruled out: this would duplicate
  `StreamServer`/`RaMachine` wholesale for data that is, once
  `RuleRDFCodec`-reified, structurally identical to any other tenant
  resource — a real "Rules are Facts" already means Catalog data needs no
  new physical storage shape, only a new logical stream namespace.
- **C — Ruled out.** Caller-supplied in-memory Catalog (matching
  `ExecuteInterpreter.Context`'s own pattern), with real persistence
  deferred to a later phase. Ruled out: the exit criterion requires a
  "live CatalogEntry" that survives long enough for 6g-i's own future
  Discovery to find it — the walking skeleton's own restated goal (§7: a
  third Task hitting Discovery with zero LLM calls) doesn't hold for an
  ephemeral, per-process Catalog. Unlike 6d-i/6e-ii's Context (where no
  real Catalog existed yet to reuse), `StreamServer` is fully available
  today at zero extra engineering cost once CatalogEntry is understood as
  "just more Facts" — there's no real reason left to defer persistence.

## 4. Module: `Riptide.Derivation.Catalog` — storage primitives

```elixir
@type scope :: {:tenant, String.t()} | :hub

@spec catalog_stream_id(scope()) :: String.t()
@spec pending_review_stream_id(scope()) :: String.t()
```

Stream IDs follow `ResourceController`'s own `@stream_id_prefix`
convention (`"https://riptide.example/tenants/" <> tenant_id <> ...`) but
a new, non-colliding segment (`/catalog`, `/catalog/pending-review`) —
Catalog data isn't an LDP resource, so it stays out of the `/resources/`
namespace entirely:

- `{:tenant, "acme"}` → `"https://riptide.example/tenants/acme/catalog"`
  and `".../acme/catalog/pending-review"`.
- `:hub` → `"https://riptide.example/hub/catalog"` and
  `"https://riptide.example/hub/catalog/pending-review"` — a fixed,
  tenant-independent stream id, the entirety of what "Hub scope" means at
  the storage layer. `Hub` has no other special home anywhere in the
  codebase today (verified during design — no reserved/global tenant_id
  convention exists); this phase is what gives it one.

```elixir
@spec list_entries(scope()) :: {:ok, [{RDF.BlankNode.t(), Rule.t()}]} | {:error, :not_ready}
@spec admit_entry(scope(), Rule.t()) :: :ok | {:error, :not_ready}
@spec supersede_entry(scope(), RDF.BlankNode.t()) :: :ok | {:error, :not_ready}

@spec queue_pending_review(scope(), DedupGate.PendingReview.t()) ::
        {:ok, RDF.BlankNode.t()} | {:error, :not_ready}
@spec list_pending_reviews(scope()) ::
        {:ok, [{RDF.BlankNode.t(), DedupGate.PendingReview.t()}]} | {:error, :not_ready}
@spec resolve_pending_review(scope(), RDF.BlankNode.t()) :: :ok | {:error, :not_ready}
```

Every read/write goes through the exact same sequence
`ResourceController` already uses
(`lib/riptide_web/ldp/resource_controller.ex:237-298`):
`Placement.lookup/1` (existence check) → `StreamSupervisor.ensure_ready/1`
→ `ensure_ready_status/1` → `StreamServer.get_since/2` (read) or
`StreamServer.append/2` (write), folded via the same
`:replace`/`:delete`/`:patch` reduce as `fold_events/1`. That ~10-line
fold is duplicated locally in `Catalog` rather than extracted into a
shared module — it's `defp` today, HTTP-shaped call sites don't need
`Catalog`'s `{:error, :not_ready}` contract (vs. `ResourceController`'s
503), and this matches the project's established tolerance for small
local duplication (`term_to_arg` in `ExecuteInterpreter`/
`GeneralizationFidelity`) over premature cross-module extraction.

`list_entries/1` and `list_pending_reviews/1` fold the relevant stream
into an `RDF.Graph.t()`, then use `Matcher.bindings/2` with a
`{rdf:type, [Var, riptide:CatalogEntry]}` (respectively
`riptide:PendingReview`) fact-pattern to enumerate root nodes, decoding
each via `RuleRDFCodec.from_rdf/2` (respectively this phase's own small
`PendingReview` codec, §6).

## 5. `AntiUnifier` gets one promoted function

```elixir
@spec substitute(Rule.t(), substitution()) :: Rule.t()
```

Lifts the `substitute_rule/2`-shaped logic already duplicated in 6e-i's
and 6e-ii's own *test* files (reconstructing a ground Trace from a
generalization + one of its recovering substitutions) into real
production code, in the module that already owns the `substitution` type.
`DedupGate` is its first production caller — the point at which
duplication should end, per this project's own established practice of
tolerating small duplication only until a genuine second (here, third)
consumer appears.

## 6. `Riptide.Derivation.DedupGate.PendingReview`

```elixir
@type kind :: :admit | :merge
@type fidelity_evidence :: :fidelity_pass | {:fidelity_fail, term()}

@enforce_keys [:kind, :candidate, :fidelity_evidence, :replaces]
defstruct [:kind, :candidate, :fidelity_evidence, :replaces]

@type t :: %__MODULE__{
        kind: kind(),
        candidate: Rule.t(),
        fidelity_evidence: [fidelity_evidence()],
        replaces: RDF.BlankNode.t() | nil
      }
```

`fidelity_evidence` holds one entry per source Trace, in order — the
`GeneralizationFidelity.check/3` result for each of the candidate's two
(or more, for a `RuleReference`-chained future case — out of scope here,
6e-i/6e-ii's own algorithms are pairwise) reconstructed source Traces.
`replaces` is the existing CatalogEntry's own node, present only for
`:merge`.

**RDF reification** (new `urn:riptide:vocab:` terms, minted the same way
`RuleRDFCodec` already mints its own — no new vocabulary source):
`riptide:PendingReview` (type), `riptide:kind` (literal `"admit"` or
`"merge"` — a plain literal, not a minted IRI, since this is an enum value
rather than a structural node type, unlike `RuleRDFCodec`'s
`CapabilityReference`/`RuleReference` class IRIs), `riptide:candidate`
(the `RuleRDFCodec`-reified candidate Rule's own node),
`riptide:fidelityEvidence` (an `RDF.List` — reusing the same
`RDF.List.from/1`/`RDF.List.values/1` pattern `RuleRDFCodec` already uses
for `args`/`body` — of small evidence nodes, each carrying
`riptide:fidelityStatus` `"pass"`/`"fail"` and, on failure, a
`riptide:fidelityReason` literal holding `inspect(reason)` — a deliberate
simplification, not a rich structured encoding: the reviewer needs to
*see* why a check failed, not programmatically parse it, and this project
already tolerates `inspect/1`-based encoding where a richer schema isn't
yet justified), and `riptide:replaces` (the existing entry's node,
`:merge` only).

## 7. `Riptide.Derivation.DedupGate` — the pipeline

```elixir
@type candidates :: [{Rule.t(), AntiUnifier.substitution(), AntiUnifier.substitution()}]
@type outcome ::
        {:rejected, reason :: term()}
        | {:fidelity_failed, [PendingReview.fidelity_evidence()]}
        | {:queued, RDF.BlankNode.t(), PendingReview.kind()}

@spec propose(Catalog.scope(), candidates(), RDF.Graph.t(), Context.t()) ::
        {:ok, [outcome()]} | {:error, term()}
```

`candidates` is `AntiUnifier.generalize/2`'s own raw return — the caller
runs `AntiUnifier` itself before calling `propose/4`, the same crisp
module-boundary precedent 6e-ii established (`GeneralizationFidelity`
never touches `AntiUnifier` either). `graph`/`context` are caller-supplied
(`ExecuteInterpreter.Context.t()`, reused as-is, matching every prior
phase in this sub-project) — assembling "the right EDB graph" for a
Tenant is explicitly out of scope everywhere in Sub-project 6 so far, not
newly deferred here.

For each `{generalization, sub1, sub2}` in `candidates`, independently
(§8's testing plan covers the multi-candidate case explicitly — different
tied candidates can land in different dispositions):

1. Reconstruct both source Traces: `AntiUnifier.substitute(generalization, sub1)`,
   `AntiUnifier.substitute(generalization, sub2)`.
2. `Catalog.list_entries(scope)`, prefiltered to entries sharing the
   candidate's Head predicate (cheap, matches `AntiUnifier`'s own
   `check_heads_compatible` O(1) prune), in the order `list_entries/1`
   returns them (stream order — a plain, deterministic tie-break, not
   claimed to be meaningful beyond that). No matching entry at all →
   `Admit`. Otherwise, walk the matches in that order, calling
   `AntiUnifier.generalize(generalization, entry)` and checking
   `entry_unchanged?` (§2) for each: the **first** entry found
   `entry_unchanged?` → this candidate is `Reject`ed immediately, done —
   no fidelity check runs, nothing is persisted, matching the parent
   spec's literal "`Reject` skips review," regardless of what any other
   matching entry would have shown. If none of the matching entries are
   `entry_unchanged?`, the candidate is `Merge`d against the **first**
   matching entry in that same order — for this phase's exit criterion
   (an empty-Catalog `Admit`), at most one matching entry ever exists in
   practice; a real tie between two genuinely-different broader-merge
   candidates is left as a documented, deterministic-but-arbitrary
   tie-break rather than new arbitration machinery, matching 6e-i's own
   precedent of not over-building for a case the exit criterion doesn't
   exercise.
3. `Admit`/`Merge` only: run `GeneralizationFidelity.check/3` on **both**
   reconstructed Traces against `graph`/`context`. Either
   `{:ok, {:fidelity_fail, _}}` or `{:error, _}` means this candidate
   doesn't reach review — the parent spec's own words: "Capabilities that
   can't be safely replay-tested may need to stay ungeneralized." Returned
   as `{:fidelity_failed, evidence}`, not queued.
4. Both pass → `Catalog.queue_pending_review/2` with a `PendingReview`
   struct built from steps 1-3, into the scope's `pending-review` stream.
   Returned as `{:queued, pending_id, kind}`.

```elixir
@spec approve_review(Catalog.scope(), RDF.BlankNode.t()) :: :ok | {:error, term()}
@spec decline_review(Catalog.scope(), RDF.BlankNode.t()) :: :ok | {:error, term()}
```

`approve_review/2`: loads the `PendingReview` by node from the pending
stream, then —

- `:admit` — `Catalog.admit_entry(scope, pending_review.candidate)`
  (writes the `RuleRDFCodec`-reified candidate + `rdf:type
  riptide:CatalogEntry` into the catalog stream), then
  `Catalog.resolve_pending_review(scope, node)` (retracts it from
  pending).
- `:merge` — same `admit_entry/2` call, **plus** a deliberately simple
  supersede: `Catalog.supersede_entry(scope, pending_review.replaces)`
  retags the *old* entry — retracts only its `rdf:type
  riptide:CatalogEntry` triple and asserts `rdf:type
  riptide:SupersededCatalogEntry` in its place, plus a
  `riptide:supersedes` triple (new entry's node → old entry's node) —
  **no transitive graph surgery**, matching §2's "graph three-way merge is
  weaker than git's" caution. The old entry's own triples are left
  untouched (Discovery's future type-tag query naturally stops surfacing
  it once retagged; the data remains for provenance/audit, reusing §6.5's
  own Provenance framing — `riptide:supersedes` *is* a Provenance edge).
  Then `resolve_pending_review/2` as above.

`decline_review/2`: `Catalog.resolve_pending_review(scope, node)` only —
nothing else is written. A declined proposal leaves no trace beyond
having briefly existed in the pending stream (already retracted); no
audit record is kept for v1 — a deliberate scope line, consistent with
`Reject`'s own "skips review, nothing persisted" treatment above, not an
oversight.

## 8. Testing

Fixture Capabilities (real `wasmtime`, same pattern as
`GeneralizationFidelityTest`'s `FakeStore`); real `StreamServer`-backed
stream IDs throughout — no mocking of storage or Capability invocation,
matching the exit criterion's own "real Traces... become a live
CatalogEntry."

- `Admit` on an empty Catalog — the walking skeleton's own case (§7 of the
  parent spec's restated goal): two hand-authored fixture-Capability
  Traces, `AntiUnifier.generalize/2`, `DedupGate.propose/4` returns
  `{:queued, _, :admit}`, `approve_review/2`, then
  `Catalog.list_entries/1` finds it live.
- `Reject` — a candidate that anti-unifies with an existing entry into
  something structurally equal to that entry (up to variable renaming);
  `propose/4` returns `{:rejected, _}`, `Catalog.list_pending_reviews/1`
  stays empty.
- `Merge` — a candidate genuinely broader than an existing entry;
  `propose/4` returns `{:queued, _, :merge}`; `approve_review/2` admits
  the new entry, retags the old one to `riptide:SupersededCatalogEntry`,
  and asserts `riptide:supersedes`; `list_entries/1` (which only ever
  queries `riptide:CatalogEntry`) no longer surfaces the old one.
- A fidelity-failing candidate (one reconstructed Trace's recorded
  Capability result doesn't match a fresh invocation) never reaches
  `pending-review` — `propose/4` returns `{:fidelity_failed, _}`.
- Multiple tied `AntiUnifier` candidates (engineered the same way 6e-i's
  own test suite engineers a tied pair) queued independently, landing in
  **different** dispositions against the same Catalog — proving step 2 of
  §7 runs per-candidate, not once for the whole batch.
- `Hub` vs. `{:tenant, _}` scope write to genuinely separate streams —
  admitting into one never surfaces in `list_entries/1` for the other.
- `decline_review/2` — a queued proposal is removed from
  `list_pending_reviews/1` and never appears in `list_entries/1`.

## 9. Exit criterion (from issue #66, restated)

Two independently-produced real Traces (from 6d-i's NativeTemplate
instances, using real fixture Capabilities) anti-unify into a single
Generalization via `AntiUnifier.generalize/2`; `DedupGate.propose/4`
classifies it `Admit` against an empty Catalog, attaches 6e-ii's fidelity
evidence via `GeneralizationFidelity.check/3` on both reconstructed
Traces, and queues it for review; `approve_review/2` (the human review
step) admits it; `Catalog.list_entries/1` finds it live. Satisfied by §8's
first test case end-to-end, with no mocking of storage or Capability
invocation.

## 10. Explicitly deferred

- Any UI or network-reachable endpoint for triggering `approve_review/2`/
  `decline_review/2` — this phase is a library-level API only, called
  directly (by tests now, by whatever orchestrates 6f's LLMFallback loop
  or a future admin surface later). Network exposure of Hub-scope Catalog
  specifically is explicitly 6h-ii's own job ("a distinct,
  network-publicly-reachable deployment," parent spec §7) — nothing in
  Track A between 6e-iii and 6h-ii touches `RiptideWeb`.
- An audit trail for declined proposals or `Reject`ed candidates — both
  are deliberately left with no persisted record (§7).
- Aggregating a whole Tenant's EDB across multiple resource streams into
  one graph for fidelity-checking purposes — `propose/4` takes a
  caller-supplied `graph`, exactly matching every prior phase in this
  sub-project; this problem isn't newly deferred here, it was never in
  scope anywhere in Sub-project 6 yet.
- Real Discovery (exact/keyword lookup over `Catalog.list_entries/1`) —
  6g-i's own job, this phase only needs to prove a CatalogEntry becomes
  genuinely queryable, not build the lookup UX around it.
- Crosswalk-based Install (§6.5) — 6i's own job, Hub-scope content this
  phase's `Hub` scope parameter makes possible but doesn't itself build.
