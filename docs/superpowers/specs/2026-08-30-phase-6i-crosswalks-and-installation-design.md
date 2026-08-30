# Phase 6i — Ontology Crosswalks and Installation

## 1. Context & motivation

Track A's Hub arc (`docs/superpowers/specs/2026-08-27-derivation-and-execution-layer-design.md`
§7) is 6h-i (threat model) → 6h-ii (deployment) → 6i (this phase). 6h-ii's own exit criterion
explicitly deferred half its own promise to this phase: *"a CatalogEntry can be published to Hub
scope by its own Tenant and installed into a different Tenant via 6i, over a network-reachable
endpoint gated by 6h-i's auth/rate-limit model."* This phase closes that arc.

**Exit criterion** (parent spec §7): "installing a Hub Pattern into a Tenant with partial
vocabulary overlap binds matched fields through an existing Crosswalk and records
manually-originated Provenance for unmatched fields, per §6.5."

**A structural gap found during brainstorming, resolved before design could proceed:**
`Provenance` is called "mandatory" for every Generalization in the parent spec's own §5, but has
zero implementation anywhere — no module, struct, or storage exists, and no already-shipped
phase's exit criterion ever actually required it to be concrete data (6e-i's `AntiUnifier` ships
without it; nothing retroactively wired it in). This phase is the first whose own exit criterion
genuinely needs Provenance to be real, so it defines Provenance generally (not narrowly
Install-scoped) and retrofits it into `AntiUnifier.generalize/2` in the same pass, closing the
spec/implementation gap everywhere rather than deferring it a second time.

## 2. Scope

- `Riptide.Derivation.Provenance` — a general, reusable data model for "where did this Rule come
  from," covering both existing origin (Generalization) and new origin (Install).
- Retrofit `AntiUnifier.generalize/2` to stamp Provenance onto every Rule it produces; update
  every existing call site (6e-iii, 6f, 6g-i) accordingly.
- `Riptide.Derivation.Crosswalk` + `CrosswalkRDFCodec` — SSSOM-shaped predicate-IRI mappings,
  Hub-scope content.
- Tenant vocabulary observation (§3.1: "observed, not declared") — derived from a Tenant's own
  already-admitted Catalog entries, no new raw-Fact scanning.
- The install-time rewrite: per predicate IRI in a Hub pattern's Signature, rewrite through an
  existing Crosswalk if one maps it into the target Tenant's vocabulary, else leave it in the
  pattern's native form and record that gap.
- `DedupGate.propose_install/3` — reuses `classify/2` unchanged, skips fidelity-replay-testing
  (structurally inapplicable — see §5), queues for the installing Tenant's own review.
- Crosswalk proposal, review, and installation over HTTP, mirroring 6h-ii's existing route shape
  and pipeline exactly.

## 3. Out of scope

- Automated verification of a Crosswalk's own semantic correctness. §6.5 is explicit: *"Detection
  of overlap is human-only, by design, for now"* and SSSOM match types are *"a curator's practical
  judgment... explicitly not a claim of model-theoretic equivalence."* The installing Tenant's own
  human review, seeing exactly which fields were Crosswalk-bound vs. manual (via
  `pending_review.candidate.provenance`), is the sole and by-design-sufficient safeguard — matching
  every other Hub trust boundary this project has already resolved the same way (6h-i's threat
  model).
- Cross-Dialect Crosswalks (comorphisms, §6.5's "categorically heavier" case) — same-Dialect
  signature-morphism translation only, matching §3.2's Dialect target already being consolidated
  to one document (SPARQL-RL).
- Rewriting `CapabilityReference`/`RuleReference` literals — Crosswalk rewriting only ever touches
  `FactPattern.predicate` occurrences; a Capability's own identity is never something a vocabulary
  mapping should touch.
- Automatic promotion/re-publishing of an installed pattern back to Hub scope from the installing
  Tenant — installation only ever writes into the installing Tenant's own Catalog.

## 4. Provenance

```elixir
defmodule Riptide.Derivation.Provenance do
  @moduledoc """
  The dependency edge back to what a Rule was generalized or installed
  from (design spec §5). A general, reusable concept from the start —
  not narrowly scoped to Install — since a Generalization's own
  provenance (§5: "always accompanied by... mandatory Provenance") was
  never actually implemented before this phase; see §1.
  """

  alias Riptide.Derivation.Rule

  @type field_binding :: %{
          predicate: RDF.IRI.t(),
          binding: {:crosswalk, crosswalk_node :: RDF.BlankNode.t()} | :manual
        }

  @type origin ::
          {:generalized_from, source1 :: Rule.t(), source2 :: Rule.t()}
          | {:installed_from, source_entry :: RDF.BlankNode.t(), field_bindings :: [field_binding()]}

  @enforce_keys [:origin]
  defstruct [:origin]

  @type t :: %__MODULE__{origin: origin()}
end
```

`Rule.t()` gains `provenance: Provenance.t() | nil` — `nil` for hand-authored fixture Rules never
generalized or installed (e.g. 6d-i's own NativeTemplate-produced ground Traces). Elixir struct
pattern matching is not exhaustive, so every existing `%Rule{signature: s, head: h, body: b}`
match across `Matcher`/`QueryInterpreter`/`ExecuteInterpreter`/`Catalog`/`Discovery` keeps working
unchanged — Provenance travels through the whole system for free, with no separate wiring needed
at each consumption point.

`RuleRDFCodec.to_rdf/1`/`from_rdf/2` gain encode/decode for the new field, following the exact
same reification pattern already used for `signature`/`head`/`body` (a `urn:riptide:vocab:`
predicate on the Rule's own node, pointing at a `Provenance` sub-node). `AntiUnifier.generalize/2`
sets `{:generalized_from, trace1, trace2}` on every Generalization it produces — the two full
source Rules embedded inline (matching how `PendingReview.to_rdf/1` already embeds its own
candidate Rule inline, not by reference).

## 5. Why fidelity-replay-testing doesn't apply to Install

Generalization-Fidelity (6e-ii) validates a Generalization by re-invoking `CapabilityReference`
literals (EffectCapability) or checking recorded Provenance against an ObserveCapability's
original invocation. It never inspects `FactPattern` literals at all. Crosswalk rewriting, by
construction (§4/§6 below), only ever substitutes `FactPattern.predicate` occurrences — a
Capability's own `capability`/`args`/`result` fields are untouched by Install. So re-running
fidelity-replay-testing at install time wouldn't just be redundant (the pattern already passed it
once, at Hub-admission time) — it is structurally incapable of validating the one thing Install
actually changes, since it never looks at fact-pattern predicates in the first place. It was never
the right tool for this risk.

The risk Install actually introduces — "did this Crosswalk rewrite preserve meaning" — is exactly
what §6.5 already scopes as human-only (§3, above). `DedupGate.propose_install/3` therefore reuses
`classify/2` (Reject/Merge/Admit against the target Tenant's own existing Catalog — pure
structural comparison, unaware of and unaffected by where its input Rule came from) but skips
`fidelity_evidence/4` entirely.

`DedupGate.PendingReview.fidelity_evidence` widens from `[fidelity_evidence()]` to
`[fidelity_evidence()] | :not_applicable` — self-documenting that "no evidence" here means
*doesn't apply to this kind of admission*, not *silently skipped*. `PendingReview.to_rdf/1`/
`from_rdf/2` gain the corresponding encode/decode branch (a distinct `urn:riptide:vocab:` marker
IRI in place of the evidence list for the `:not_applicable` case). No new field is needed for a
reviewer to see the Crosswalk field-bindings — they're already sitting on
`pending_review.candidate.provenance`, for free, because Provenance lives on the Rule itself (§4).

## 6. Crosswalk

```elixir
defmodule Riptide.Derivation.Crosswalk do
  @moduledoc """
  An SSSOM-shaped mapping between two predicate IRIs (design spec §6.5).
  Same-Dialect signature-morphism translation only — see design spec's
  own §3 for why cross-Dialect comorphisms are out of scope.
  """

  @type match_type :: :exact_match | :close_match | :broad_match | :narrow_match | :related_match

  @enforce_keys [:subject_predicate, :object_predicate, :match_type]
  defstruct [:subject_predicate, :object_predicate, :match_type]

  @type t :: %__MODULE__{
          subject_predicate: RDF.IRI.t(),
          object_predicate: RDF.IRI.t(),
          match_type: match_type()
        }
end
```

Always Hub-scope (§6.5: *"Crosswalks are Hub-scope content, published by whichever Tenant needs or
creates them and discoverable by any Tenant"*) — no `scope()` parameter needed anywhere in its own
API, unlike `Rule`-shaped `CatalogEntry`s. Storage: a new sibling stream off the existing Hub
catalog, `Catalog.catalog_stream_id(:hub) <> "/crosswalks"`, mirroring how
`pending_review_stream_id/1` already derives a sibling stream rather than inventing a new pattern.
A new `CrosswalkRDFCodec` (`to_rdf/1`/`from_rdf/2`) follows the exact reification style
`RuleRDFCodec`/`PendingReview` already use. `Catalog` gains `admit_crosswalk/1`/`list_crosswalks/0`
(no `scope` param — always `:hub`), reusing the existing `write_patch/3`/`read_graph/1` primitives
unchanged.

**Crosswalk proposals are reviewed, not directly admitted** — §6.5: *"A Tenant proposes a
Crosswalk entry through its own DedupGate authority — the same one it already exercises over any
other Hub-scope publication (§6), not a separate curator role."* Mirrors 6h-ii's own
propose-to-Hub pattern: `DedupGate.propose_crosswalk/2` queues a `%Crosswalk{}` into the proposing
Tenant's own review stream; approval admits it to the Hub crosswalk stream.

## 7. Tenant vocabulary observation

§3.1: *"A Tenant's vocabulary is observed, not declared... whichever Signature a Tenant's own
Facts happen to already use is their working vocabulary."* Operationalized as the union of every
predicate IRI already appearing in `reads`/`produces` across that Tenant's own admitted Catalog
entries — reusing the already-shipped `Catalog.list_entries/1` unchanged, not a new raw-Fact scan:

```elixir
@spec tenant_vocabulary(String.t()) :: MapSet.t(RDF.IRI.t())
defp tenant_vocabulary(tenant_id) do
  {:ok, entries} = Catalog.list_entries({:tenant, tenant_id})

  entries
  |> Enum.flat_map(fn {_node, rule} -> rule.signature.reads ++ rule.signature.produces end)
  |> MapSet.new()
end
```

## 8. Install

For each predicate IRI in a Hub pattern's own `signature.reads ++ signature.produces`:

1. **Already in the target Tenant's vocabulary** — no rewrite, nothing recorded (there is no gap
   to note).
2. **A Hub Crosswalk maps it to something in the target Tenant's vocabulary** — rewrite every
   occurrence of that predicate in the Rule's `FactPattern` literals (head and body) to the
   Tenant's own IRI; record `%{predicate: original_iri, binding: {:crosswalk, crosswalk_node}}`.
3. **Neither** — leave the predicate in the pattern's own native IRI (§6.5: *"the Tenant supplies
   those Facts directly, in the Pattern's native vocabulary"*); record
   `%{predicate: original_iri, binding: :manual}`.

```elixir
@spec install(RDF.BlankNode.t(), Rule.t(), String.t()) :: {Rule.t(), [Provenance.field_binding()]}
def install(hub_entry_node, %Rule{} = pattern, tenant_id) do
  vocabulary = tenant_vocabulary(tenant_id)
  {:ok, crosswalks} = Catalog.list_crosswalks()
  predicates = pattern.signature.reads ++ pattern.signature.produces

  {rewrites, field_bindings} =
    Enum.reduce(predicates, {%{}, []}, fn predicate, {rewrites, bindings} ->
      cond do
        MapSet.member?(vocabulary, predicate) ->
          {rewrites, bindings}

        {crosswalk, target_predicate} = find_crosswalk(crosswalks, predicate, vocabulary) ->
          {Map.put(rewrites, predicate, target_predicate),
           [%{predicate: predicate, binding: {:crosswalk, crosswalk_node(crosswalk)}} | bindings]}

        true ->
          {rewrites, [%{predicate: predicate, binding: :manual} | bindings]}
      end
    end)

  installed_rule = %{
    rewrite_predicates(pattern, rewrites)
    | provenance: %Provenance{origin: {:installed_from, hub_entry_node, field_bindings}}
  }

  {installed_rule, field_bindings}
end
```

`rewrite_predicates/2` walks the Rule's `head`/`body` `FactPattern` literals, substituting any
predicate present in `rewrites`; everything else (including every `CapabilityReference`/
`RuleReference` literal, untouched by construction — §3) passes through unchanged.

`find_crosswalk/3` returns `{crosswalk, target_predicate}` — a Crosswalk is a symmetric mapping
between two IRIs (either side may be the one whichever Tenant published it happened to already
use), so the lookup checks both directions explicitly and returns whichever *other* side is the
one actually in the target Tenant's vocabulary, never blindly `object_predicate`:

```elixir
defp find_crosswalk(crosswalks, predicate, vocabulary) do
  Enum.find_value(crosswalks, fn crosswalk ->
    cond do
      crosswalk.subject_predicate == predicate and
          MapSet.member?(vocabulary, crosswalk.object_predicate) ->
        {crosswalk, crosswalk.object_predicate}

      crosswalk.object_predicate == predicate and
          MapSet.member?(vocabulary, crosswalk.subject_predicate) ->
        {crosswalk, crosswalk.subject_predicate}

      true ->
        nil
    end
  end)
end
```

## 9. Review and HTTP surface

Unlike 6h-ii's propose-to-Hub (`target_scope: :hub`, `review_scope: {:tenant, id}` — deliberately
different scopes, since publishing writes into the shared Hub Catalog but review stays with the
proposing Tenant), Install's `target_scope` and `review_scope` are always the *same*
`{:tenant, installing_tenant_id}` — an install writes into and is reviewed by the installing
Tenant's own Catalog, never `:hub`. `propose_install/3` keeps both as separate parameters purely
for signature symmetry with `propose/5`, not because they can differ in practice for Install.

```elixir
@spec propose_install(Catalog.scope(), Catalog.scope(), Rule.t()) ::
        {:ok, DedupGate.outcome()} | {:error, term()}
def propose_install(target_scope, review_scope, installed_rule) do
  with {:ok, entries} <- Catalog.list_entries(target_scope) do
    case classify(installed_rule, entries) do
      {:reject, reason} ->
        {:ok, {:rejected, reason}}

      {kind, replaces} ->
        pending_review = %PendingReview{
          kind: kind,
          candidate: installed_rule,
          fidelity_evidence: :not_applicable,
          replaces: replaces
        }

        {:ok, node} = Catalog.queue_pending_review(review_scope, pending_review)
        {:ok, {:queued, node, kind}}
    end
  end
end
```

`DedupGate.approve_review/3`/`decline_review/2` (already shipped, 6h-ii) need zero changes —
`apply_approved/4` only ever operates on `pending_review.candidate` as a plain `Rule.t()`,
unaware of and unaffected by whether it came from Generalization or Install.

New routes, mirroring 6h-ii's exact existing shape (same `[:api, :tenant, :auth, :authz]`
pipeline, same JSON response conventions as `ProposeController`):

| Method | Path | Operation |
|---|---|---|
| POST | `/tenants/:tenant_id/hub/install` | Fetch the named Hub entry, run `install/3`, `propose_install/3` |
| POST | `/tenants/:tenant_id/hub/crosswalks` | Build a `Crosswalk`, `propose_crosswalk/2` |

Existing `/tenants/:tenant_id/hub/pending-reviews/:node_id/approve`/`decline` reused unchanged for
both new proposal kinds.

## 10. Testing

- `AntiUnifier.generalize/2` retrofit: existing tests (6e-iii/6f/6g-i) updated to assert
  `provenance == %Provenance{origin: {:generalized_from, trace1, trace2}}` on the produced Rule;
  every other existing assertion in those files continues to pass unchanged (Provenance is purely
  additive to `Rule.t()`).
- `Crosswalk`/`CrosswalkRDFCodec` round-trip test, mirroring `RuleRDFCodec`'s own test shape.
- `tenant_vocabulary/1` unit test.
- `install/3`: a hand-built pattern + a Tenant with partial vocabulary overlap + a real admitted
  Crosswalk — asserting the installed Rule's predicates are correctly rewritten and
  `provenance.origin`'s field_bindings correctly distinguish crosswalk-bound vs. manual fields.
- `propose_install/3`: classify still produces Reject/Merge/Admit correctly for an install
  candidate; `fidelity_evidence: :not_applicable` round-trips through `PendingReview`'s own RDF
  codec.
- Capstone HTTP test (matching 6h-ii's own capstone shape): Tenant A publishes a pattern to Hub →
  Tenant A proposes and gets a Crosswalk approved → Tenant B installs the pattern (partial
  vocabulary overlap with A) → Tenant B approves the install → the pattern now lives in Tenant B's
  own Catalog with correctly-rewritten predicates and correct Provenance, all over real HTTP.

## 11. Exit criterion

Restated from §1, satisfied by §10's capstone test: installing a Hub Pattern into a Tenant with
partial vocabulary overlap binds matched fields through an existing Crosswalk (§8, case 2) and
records manually-originated Provenance for unmatched fields (§8, case 3), per §6.5.
