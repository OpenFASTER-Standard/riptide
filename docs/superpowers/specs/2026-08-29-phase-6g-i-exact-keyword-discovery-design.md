# Exact/Keyword Discovery — Design

**Status:** Draft, first revision. Implements Sub-project 6, phase **6g-i**
([issue #68](https://github.com/OpenFASTER-Standard/riptide/issues/68)) —
the eighth link in the Sub-project 6 walking skeleton, and its own final
step (`6b-i → 6c-i-a → 6c-i-b → 6d-i → 6e-i → 6e-ii → 6e-iii → {6f, 6g-i}`),
unblocked by 6e-iii (#66), already shipped. Parent spec:
`docs/superpowers/specs/2026-08-27-derivation-and-execution-layer-design.md`
(§6 — Discovery; §7's 6g-i entry; §8.10 — conflict resolution; §9.1 — the
walking skeleton's own worked example).

## 1. Scope

Per issue #68: exact/keyword lookup over CatalogEntry, viable as soon as
any CatalogEntry exists. Built scope-parameterized (`Tenant` or `Hub`)
from the start, matching 6e-iii, so 6h-ii reuses it directly.

**Exit criterion:** a CatalogEntry admitted by 6e-iii is found by
exact/keyword Discovery and invoked without an LLM call.

This is the walking skeleton's own last step, and §9.1's worked example
made concrete: a task repeated a third time hits Discovery directly,
**zero** LLM calls, closing the loop `6b-i → ... → 6f → 6g-i` was built to
prove.

## 2. Key findings

**A real gap, same shape as 6f's `resolve_bindings/3`:**
`ExecuteInterpreter.call_template/3`'s public API always starts execution
from an empty seed (`%{}`) — there is no way to invoke a *found* template
against a *new* Task's own concrete arguments (a found CatalogEntry is
still a template — e.g. `deployed(Svc, Result) :- ...`, `Svc` still
free — invoking it for "deploy billing-service, again" needs `Svc` seeded
first). Unlike 6f's gap, this needs **no new logic at all**: the module's
existing *private* 4-arg `call_template/4` clause already accepts a
caller-supplied seed (it's what `RuleReference` invocation already uses
internally, `lib/riptide/derivation/execute_interpreter.ex`). Making it
`def` instead of `defp` is the entire change — a pure visibility widening,
zero behavior change, nothing new to test beyond "it's now reachable."

**`StabilityClass` and `recency` are both real, both deferred — for two
different reasons, verified rather than assumed.** §6/§8.10 name a
three-tier conflict-resolution ordering: recency, then `StabilityClass`,
then specificity.

- `StabilityClass` (§4: `documented`/`undocumented`) is defined on
  `Capability`, not on `CatalogEntry`/`Rule`/`Signature`, and doesn't
  exist as a field anywhere in shipped code (`grep` confirms zero hits).
  Using it here would mean retrofitting a new field onto the
  already-shipped, tested `Capability.Definition` struct (6b-i) for
  something issue #68 never asks for.
- `recency` was initially assumed to be "free" (derivable from data
  already in hand) during this phase's own brainstorm — checked directly
  and found wrong. `Catalog.list_entries/1` folds the event log into an
  `RDF.Graph`, an unordered set of triples that discards *when* each
  entry was admitted. Blank-node creation order was considered as a
  proxy (`RDF.BlankNode.new()`'s value comes from a monotonic counter)
  and rejected: that counter is per-BEAM-process, not a sound ordering
  signal for a distributed, Ra-replicated system. Real recency needs new
  admission-order tracking Catalog doesn't have yet.

Both are deferred explicitly (§8), leaving **specificity** — free
variable count in a found entry, reusing the same idea 6e-i/6e-iii already
established for anti-unification scoring — as this phase's only
conflict-resolution tier, since it's the only one derivable from data
that already exists.

## 3. Approaches considered

- **A — Adopted.** One function, `Discovery.find/2`, plain-string query
  input matching `LLMFallback.run/3`'s own `task_description` shape (so a
  future caller can naturally try Discovery first, fall back to
  LLMFallback second). Exact-word-set match ranks above any
  partial-overlap keyword match; specificity breaks ties within either
  tier. `ExecuteInterpreter.call_template/4` gains public visibility,
  unchanged otherwise.
- **B — Ruled out.** Two separate public functions (`find_exact/2` taking
  an `RDF.IRI.t()`, `find_keyword/2` taking a string). Ruled out: splits
  one coherent "try precise first, fall back to fuzzy" operation across
  two call sites a caller would need to sequence themselves, for no real
  benefit — 6g-ii's own future upgrade (hybrid keyword+embedding
  "progressive disclosure," §6) is naturally a third fallback tier inside
  the *same* function, not a third public entry point.
- **C — Ruled out.** Implement full three-tier conflict resolution now,
  including `StabilityClass` and `recency`. Ruled out per §2 — both need
  real new infrastructure issue #68 doesn't ask for; building them now
  would be scope creep into 6h-ii/a future phase's own territory (a
  `StabilityClass` field is more naturally paired with whatever phase
  first needs to distinguish Hub-curated Patterns' trust levels).

## 4. Module: `Riptide.Derivation.Discovery`

```elixir
@spec find(Catalog.scope(), String.t()) ::
        {:ok, [{RDF.BlankNode.t(), Rule.t()}]} | {:error, :not_ready}
def find(scope, query_text) do
  with {:ok, entries} <- Catalog.list_entries(scope) do
    query_words = MapSet.new(tokenize(query_text))

    ranked =
      entries
      |> Enum.map(fn {node, rule} -> {node, rule, score(rule, query_words)} end)
      |> Enum.reject(fn {_node, _rule, score} -> score == :no_match end)
      |> Enum.sort_by(fn {_node, rule, score} -> sort_key(score, rule) end)
      |> Enum.map(fn {node, rule, _score} -> {node, rule} end)

    {:ok, ranked}
  end
end
```

`tokenize/1`: lowercase, split on non-alphanumeric runs. `score/2`: an
entry's predicate — `rule.signature.name`'s IRI local name — split into
words (camelCase-aware: `pendingDeploy` → `["pending", "deploy"]`,
matching the same splitting `tokenize/1` does for the query, so the two
sides compare on equal footing) compared against `query_words`. Word-set
equality → `{:exact}`; any non-empty intersection → `{:keyword,
overlap_count}`; no intersection → `:no_match` (filtered out — `{:ok,
[]}` for a genuinely unmatched query, not an error).

`sort_key/2` — **the same 3-tuple shape for both tiers**, found and fixed
during this phase's own brainstorm before any code was written: an
earlier draft used `{0, specificity}` for exact vs. `{1, -overlap,
specificity}` for keyword, which would have worked only by accident of
Erlang's arity-first tuple comparison (2-tuples sort before 3-tuples
regardless of content) rather than by clear design. Corrected to:

```elixir
defp sort_key({:exact}, rule), do: {0, 0, specificity(rule)}
defp sort_key({:keyword, overlap}, rule), do: {1, -overlap, specificity(rule)}
```

Tier first (`0` before `1`, exact always outranks keyword); within
`:keyword`, `-overlap` sorts higher-overlap first; `specificity/1` —
count of `%Var{}` occurrences across `rule.head` and `rule.body` (fewer =
more specific = sorts first) — breaks remaining ties in both tiers.

## 5. `ExecuteInterpreter.call_template/4` — visibility only

```elixir
@spec call_template(Rule.t(), %{Var.t() => RDF.Term.t()}, RDF.Graph.t(), Context.t()) ::
        {:ok, [RDF.Triple.t()]}
        | {:error, {:unresolvable, RDF.IRI.t()} | {:unsupported_arity, RDF.IRI.t()}}
```

The existing private clause's body is unchanged; only `defp` → `def`, plus
a `@doc`/`@spec` explaining the seed's purpose for external callers (its
only prior caller, `invoke_rule/4`, already used it correctly without
documentation since it was internal). `call_template/3`'s own public
contract, tests, and every existing caller are untouched.

## 6. Testing

- Exact match: query text whose words exactly match a found entry's
  predicate local name.
- Keyword match: partial word overlap, no exact candidate.
- No match: `{:ok, []}`, not an error.
- Specificity tiebreak: two entries sharing a predicate, one with fewer
  free `Var`s ranks first.
- Exact outranks a higher-overlap keyword hit (proving tier, not raw
  score, is the primary sort key).
- Empty Catalog (never admitted anything) → `{:ok, []}`.
- `ExecuteInterpreter.call_template/4` direct test, mirroring
  `call_template/3`'s own existing test style — a Rule with a free Head
  variable, seeded, produces the seeded-in triple.
- **Capstone — the walking skeleton's actual final step, matching §9.1
  word-for-word:** two `LLMFallback.run/3` calls (reusing 6f's own
  capstone shape) admit a CatalogEntry via `AntiUnifier.generalize/2` →
  `DedupGate.propose/4` → `approve_review/2`; a *third* task, expressed as
  plain text, is found via `Discovery.find/2`'s keyword path; a seed is
  built by zipping the found entry's own `Signature.parameters` against
  the third task's concrete argument; `ExecuteInterpreter.call_template/4`
  invokes it for real — **zero LLM calls**, closing the walking skeleton
  end-to-end for the first time with no LLM involvement anywhere in the
  final step.

## 7. Exit criterion (from issue #68, restated)

A CatalogEntry admitted by 6e-iii is found by `Discovery.find/2`
(exact/keyword) and invoked via `ExecuteInterpreter.call_template/4`
without an LLM call. Satisfied by §6's capstone test end-to-end.

## 8. Explicitly deferred

- `recency` and `StabilityClass` conflict-resolution tiers (§2) — both
  need real new infrastructure (admission-order tracking on `Catalog`;
  a new field on the shipped `Capability.Definition` struct
  respectively) that issue #68 doesn't ask for. `specificity` alone
  satisfies this phase's own exit criterion.
- 6g-ii's hybrid keyword+embedding progressive disclosure — explicitly a
  separate, later phase (§6, §7); `find/2`'s keyword tier is deliberately
  simple (word-overlap counting, no embeddings) so 6g-ii has a clean
  fallback tier to add inside the same function later, not a design to
  unwind.
- A real `Task` entry point that automatically tries Discovery before
  falling back to LLMFallback — not built by 6f, not built here either;
  `find/2` and `LLMFallback.run/3` stay two independently-callable
  primitives, matching every prior phase's "caller composes, module stays
  crisp" precedent.
- Hub-scope network exposure (6h-ii's own job, per 6b-i/6e-iii/6f's
  identical precedent) — `Discovery.find/2` works identically for `:hub`
  and `{:tenant, _}` scope by construction (same `Catalog.list_entries/1`
  call), but nothing in this phase stands up any network-reachable
  endpoint.
