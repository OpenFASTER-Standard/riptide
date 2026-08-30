# Phase 6c-ii — Recursion and Fixpoint Evaluation

## 1. Context & motivation

Sub-project 6 (`docs/superpowers/specs/2026-08-27-derivation-and-execution-layer-design.md`)
decomposes into a shared Foundation, a primary spine (Track A), and three independent
side-tracks. Track B — "pure query capability" — has been completely untouched all session;
6c-i-b (fact-pattern matching and joins, `Riptide.Derivation.Matcher`) shipped the single-rule,
non-recursive join engine it depends on, but nothing yet evaluates a *recursive* Rule to a
fixpoint. This phase (issue #62) is Track B's first link.

**Exit criterion** (parent spec §7): "a recursive Rule (e.g. transitive closure) reaches a
correct fixpoint over the EDB, with a documented stratification/termination discipline."

## 2. Scope

- A new evaluator that takes a **ruleset** — a list of `Riptide.Derivation.Rule.t()`, e.g. a
  base-case clause plus a recursive clause sharing one head predicate (classic transitive
  closure: `ancestor(X,Y) :- parent(X,Y).` and `ancestor(X,Z) :- parent(X,Y), ancestor(Y,Z).`) —
  and an initial EDB graph, and iterates to the least fixpoint.
- Mutual recursion across multiple distinct head predicates (e.g. even/odd via a successor
  relation) falls out of the same algorithm for free — nothing about naive bottom-up evaluation
  cares whether a ruleset self-recurses through one predicate or cycles through several.
- A documented stratification and termination discipline, per the exit criterion's own wording.
- A configurable safety bound (max iterations, max fact count) as defense-in-depth against a
  large or adversarial ruleset, consistent with every other untrusted-input entry point in this
  codebase (parser heap caps, WASI fuel/memory limits, atom-exhaustion guards, per-tenant quotas).

## 3. Out of scope

- **Semi-naive evaluation.** Soufflé's delta-restricted-join technique (parent spec §8.8) is the
  natural future optimization once something needs the performance; naive bottom-up (re-evaluate
  the whole ruleset each round against the whole accumulated graph) is simpler, more directly
  provably correct, and sufficient for this phase's own exit criterion, which asks for
  correctness, not throughput.
- **Negation.** No literal type in this codebase expresses it (`FactPattern`,
  `CapabilityReference`, `RuleReference` — none of them), so it's not something this phase adds
  or needs to guard against; see §5.
- **ExecuteInterpretation integration.** This phase is purely `QueryInterpretation` — fact-pattern
  literals only (`CapabilityReference`/`RuleReference` stay excluded, same as `Matcher`'s own
  existing fact-pattern-only fragment). Recursive rules that invoke Capabilities are not this
  phase's concern.
- **Catalog/Discovery integration.** Tested standalone against a hand-written suite, same as
  6c-i-b's own exit criterion — not wired into `DedupGate`/`Discovery`, which assume one
  canonical admitted Rule per predicate, not a multi-clause ruleset.
- **Aggregation (6c-iii-a) and ValidTime-aware querying (6c-iii-b).** Both depend on this phase
  and extend the same `QueryInterpreter` module later; neither is built here.

## 4. Module & API

New `lib/riptide/derivation/query_interpreter.ex` — the first piece of "QueryInterpretation
proper" (the parent spec's own §5 names `QueryInterpretation`/`ExecuteInterpretation` as the two
Interpretation modes; `Matcher`'s own moduledoc already calls itself "the fact-pattern-only
fragment of QueryInterpretation," implying a broader module was always expected to exist).
`Matcher` stays exactly as-is — the low-level single-rule join primitive `QueryInterpreter`
composes, unchanged.

```elixir
@spec evaluate([Rule.t()], RDF.Graph.t(), keyword()) ::
        {:ok, RDF.Graph.t()}
        | {:error,
           :too_many_variables
           | {:unsupported_literal, Rule.literal()}
           | {:unsafe_rule, Var.t()}
           | :iteration_limit_exceeded
           | :fact_limit_exceeded}
```

Takes the ruleset and an initial EDB graph; returns the full closure graph (EDB ∪ every derived
fact) on success. The first three error shapes are `Matcher.evaluate/2`'s own, propagated
unchanged from whichever rule in the set first fails to evaluate. `opts` accepts
`:max_iterations`/`:max_fact_count` overrides for tests; production defaults come from
`Application.get_env(:riptide, :query_interpreter_max_iterations, ...)`/
`Application.get_env(:riptide, :query_interpreter_max_fact_count, ...)`, mirroring
`Riptide.NewStreamRateLimit`/`Riptide.HubRateLimit`'s own config-with-default-fallback shape.

## 5. Stratification and termination — the documented discipline

**Stratification is trivial here, structurally, not by any runtime check.** Stratification
exists in Datalog to give negation-as-failure a well-defined meaning: partition rules into
strata by negation-dependency, fully evaluate each stratum's own fixpoint before the next stratum
(which may negate on it) starts. This codebase's `Rule.literal()` union type is exactly
`FactPattern.t() | CapabilityReference.t() | RuleReference.t()` — none of the three express
negation, and `QueryInterpretation`'s own fact-pattern-only fragment excludes the latter two
regardless. There is no way to construct a negated literal at all, so every rule is monotonic by
construction, and a single stratum always suffices — there is nothing to validate at runtime
because the type system already makes the alternative unconstructible. If negation is ever added
to the Literal language in the future, that work would need to introduce genuine multi-stratum
evaluation; it is explicitly out of this phase's scope (§3).

**Termination is guaranteed by a finite Herbrand universe.** Fact-pattern-only rules only ever
combine constants already present in the EDB — no arithmetic, no string functions, no capability
invocation that could synthesize a fresh value (excluded per §3/§4). The set of all possible
ground facts constructible from the EDB's own constants and the ruleset's predicate arities is
therefore finite. Each round of naive evaluation either adds at least one new fact or reaches
fixpoint; since the total reachable fact count is bounded, the loop cannot run forever — the
classical Datalog least-fixpoint theorem (Van Emden & Kowalski 1976: the immediate-consequence
operator is monotonic on a finite domain, so iterating from the EDB alone converges to a unique
least fixpoint in finitely many steps). The `:max_iterations`/`:max_fact_count` safety bound
(§6) is defense-in-depth on top of this guarantee — the classical result ensures the loop *will*
halt, not that it will halt *quickly enough* or using *bounded memory* for an adversarial or
merely very large ruleset.

## 6. Algorithm

```
evaluate(rules, graph, opts):
  max_iterations = opts[:max_iterations] || config default
  max_fact_count = opts[:max_fact_count] || config default
  loop(rules, graph, 0, max_iterations, max_fact_count)

loop(rules, graph, round, max_iterations, max_fact_count):
  if round >= max_iterations: {:error, :iteration_limit_exceeded}
  else:
    new_triples = evaluate_all_rules(rules, graph)   # halts on first Matcher error
    case new_triples:
      {:error, reason} -> {:error, reason}
      {:ok, triples} ->
        next_graph = RDF.Graph.add(graph, triples)   # set semantics: duplicates are no-ops
        if triple_count(next_graph) > max_fact_count: {:error, :fact_limit_exceeded}
        elif triple_count(next_graph) == triple_count(graph): {:ok, next_graph}  # fixpoint
        else: loop(rules, next_graph, round + 1, max_iterations, max_fact_count)

evaluate_all_rules(rules, graph):
  # Matcher.evaluate/2 per rule, collecting every rule's derived triples;
  # propagates the first rule-level error (unsafe rule / unsupported literal /
  # too many variables) immediately rather than evaluating the rest.
```

Fixpoint detection is a plain triple-count comparison before/after merging a round's new
triples in — `RDF.Graph` is set-valued, so a round that only re-derives already-known facts
leaves the count unchanged, which is exactly "nothing new" (`RDF.Graph.add/2`'s dedup is not new
behavior added by this phase; every existing Catalog/DedupGate graph-merge already relies on it).

## 7. Testing

Hand-written suite (`test/riptide/derivation/query_interpreter_test.exs`), no Capability, no
Catalog, no Discovery involved:

- Transitive closure via a base-case clause + a recursive clause sharing one head predicate — the
  exit criterion's own literal example.
- Mutual recursion across two distinct head predicates (e.g. even/odd via a successor relation),
  proving the algorithm generalizes to any ruleset shape, not just single-predicate self-recursion.
- An EDB with no matching chains reaches fixpoint immediately (round 1 adds nothing).
- `:max_iterations` and `:max_fact_count` each actually tripping, with a small configured
  override and a ruleset engineered to exceed it.
- `Matcher`'s existing error shapes (`:unsafe_rule`, `{:unsupported_literal, _}`,
  `:too_many_variables`) surfacing correctly through `QueryInterpreter.evaluate/2` too, not just
  through `Matcher.evaluate/2` directly.

## 8. Exit criterion

Restated from §1, satisfied by §7's transitive-closure test plus §5's documented
stratification/termination discipline.
