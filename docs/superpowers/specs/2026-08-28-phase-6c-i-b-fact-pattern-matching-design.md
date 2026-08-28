# Fact-Pattern Matching and Joins — Design

**Status:** Draft, first revision. Implements Sub-project 6, phase **6c-i-b**
([issue #61](https://github.com/OpenFASTER-Standard/riptide/issues/61)) — the
second link in the Sub-project 6 walking skeleton
(`6b-i → 6c-i-a → 6c-i-b → 6d-i → 6e-i → 6e-ii → 6e-iii → {6f, 6g-i}`).
Depends on 6c-i-a (Rule/Signature representation and parser, shipped
2026-08-28, PR #83). Parent spec:
`docs/superpowers/specs/2026-08-27-derivation-and-execution-layer-design.md`
(§3.2, §7). Prior phase spec:
`docs/superpowers/specs/2026-08-28-rule-signature-representation-design.md`.

## 1. What this phase does

6c-i-a built the shape of a Rule; this phase makes the fact-pattern-only
fragment of it actually run. Per 6c-i-a's own §1: "the Body's literals are
a Datalog query. Fact-pattern literals are matched against the EDB,
bindings that satisfy the whole conjunction are found, the Head is
concluded as an answer." That is QueryInterpretation, restricted here to
Bodies containing only `Literal.FactPattern` — no capability-reference or
rule-reference literals (those need 6b-i's WASI substrate and are 6d-i's
concern), no recursion/fixpoint iteration (6c-ii), no negation or
aggregation (6c-iii-a).

Concretely: given a Rule and an RDF graph to match against, find every
binding of the Body's shared variables that satisfies every fact-pattern
literal simultaneously (a **join**, when more than one literal shares a
variable — the classical Datalog case), then substitute each binding into
the Head to produce the Rule's concluded output facts.

## 2. What "the EDB" is for this phase

Riptide has no cross-stream triple index today: each `stream_id` is its own
independently-replicated Ra log, folded to a single `RDF.Graph.t()` on read
(`RiptideWeb.LDP.ResourceController.current_state/1`). `Riptide.Placement`
gives a stream_id → node routing index, not a content index. Building a
real multi-stream secondary index (materialized incrementally as events are
appended, or scanned live across every stream a Tenant owns) is a
substantially bigger piece of infrastructure than a join algorithm, and
nothing downstream (6d-i's exit criterion uses "a hand-authored set of
NativeTemplate instances," not live production data) needs it yet.

**Decision: this phase takes an `RDF.Graph.t()` as an explicit input and
joins over exactly that.** It has no knowledge of streams, Placement, or
Tenants at all. How a caller assembles that graph from real Riptide
streams — one stream's current state, several merged together, a Tenant's
entire resource tree — is entirely 6d-i's integration concern. This keeps
6c-i-b a pure, fast-to-test algorithm module, the same shape as 6e-i's
anti-unification (also pure, also deferred integration to a later phase).
The exit criterion's "multi-stream joins" is satisfied by constructing the
input graph from several independently-authored per-stream graphs merged
together in the test suite (§6) — the join algorithm itself has no notion
of "stream" as a boundary, which is exactly why one caller-supplied graph
is sufficient to prove it.

## 3. Reusing `RDF.Query.BGP` instead of hand-rolling a join engine

`rdf` (`~> 3.0`, already a dependency) ships a real, W3C-compliance-tested
Basic Graph Pattern query engine — `RDF.Query`, `RDF.Query.BGP`, with a
selectivity-based query planner (`RDF.Query.BGP.QueryPlanner`) and
streaming execution. A BGP triple pattern is `{subject, predicate, object}`
where each position is either a bound RDF term or a variable — which is
exactly what Datalog fact-pattern matching over an EDB already is.
`Literal.FactPattern`'s predicate is always a fixed `RDF.IRI.t()` (never a
variable), so translating it into a BGP triple pattern is direct, with no
semantic gap to bridge.

**Decision: `Riptide.Derivation.Matcher` is a thin adapter over
`RDF.Query`/`RDF.Query.BGP`, not a hand-rolled nested-loop join.** This
reuses arbitrary N-way joins, self-joins, cyclic patterns, and query
planning that a mature library has already solved and tested, rather than
re-deriving backtracking-join logic from scratch for no corresponding
benefit — the same reasoning that led 6c-i-a to reuse SPIN's vocabulary and
`RDF.List` rather than inventing parallel mechanisms. `RDF.Query.BGP`
itself is never exposed outside `Matcher` — callers (6d-i) see only
`Matcher`'s own contract, so if a future phase (6c-ii's recursive fixpoint
evaluation, most plausibly) needs different join semantics, only this one
module changes.

## 4. Variable translation and the atom-exhaustion hazard

`RDF.Query.BGP`'s matcher hardcodes `is_atom/1` as its internal test for
"this position is a variable" — not just in the builder's convenience
syntax (`RDF.Query.Builder`), but in the matcher and query-planner's own
dispatch logic (`bgp/helper.ex`'s `match_triple/2` clauses, `bgp/
query_planner.ex`'s `var_info/1`, both guarded on `is_atom`). Every
distinct Body variable must therefore become a BEAM atom to participate in
a BGP match at all.

This is the same resource-exhaustion risk class Riptide has already hit
twice (unbounded atom creation via unauthenticated-adjacent reads; the
`RaCluster.server_id/1` stream-id-as-atom fix, both `PROGRESS.md` §8.11) —
BEAM atoms are never garbage-collected, and Rule Body text is explicitly
untrusted/LLM-authorable (6c-i-a spec §8's own framing). Naively calling
`String.to_atom/1` on a Rule's variable-name strings would let an adversary
or a buggy Rule generator (6f's LLMFallback loop is a real, planned source
of machine-authored Rules) grow the atom table without bound simply by
evaluating many distinct Rules with many distinct variable names over the
node's lifetime.

**Decision: never derive an atom from a variable's name.** `Matcher` uses a
small, fixed pool of pre-created atoms —
`:"$riptide_derivation_var_1"` .. `:"$riptide_derivation_var_64"`, module
attributes created once at compile time, never at runtime — as BGP's
internal variable placeholders. Within one `evaluate/2`/`bindings/2` call,
each distinct `Var.t()` in the Rule's Body is assigned one pool slot (plain
local state — a map built and discarded within that one call, not
persisted anywhere); the binding-result translation reverses this mapping
before returning results, so callers only ever see `Var.t()` keys, never
pool atoms. This bounds atom creation for this feature to a fixed 64
atoms, total, for the lifetime of the node, regardless of how many Rules
with how many distinct variable-name strings are ever evaluated. A Rule
whose Body has more than 64 distinct variables — already absurd for
realistic Datalog — is rejected with `{:error, :too_many_variables}` rather
than silently exceeding the pool.

## 5. Module & interface

One new module, `Riptide.Derivation.Matcher`:

```elixir
@spec bindings(Rule.t(), RDF.Graph.t()) ::
        {:ok, [%{Var.t() => RDF.Term.t()}]} | {:error, reason}

@spec evaluate(Rule.t(), RDF.Graph.t()) ::
        {:ok, [RDF.Triple.t()]} | {:error, reason}
```

- `bindings/2` — the raw join: translates the Body into BGP triple
  patterns (§3, §4), executes via `RDF.Query.execute/2`, translates each
  resulting binding map back from pool atoms to `Var.t()` keys. One map
  per satisfying solution; `[]` (not an error) when the Body is
  unsatisfiable against the given graph.
- `evaluate/2` — calls `bindings/2`, then for each binding substitutes into
  the Head's `[Var.t() | RDF.Term.t()]` args to produce one concluded
  `RDF.Triple.t()`. This is what "a Rule evaluates correctly" means for
  this phase's exit criterion, matching 6c-i-a's framing of
  QueryInterpretation concluding the Head as an answer.

`reason` is one of: `{:unsupported_literal, literal}` (§6), `{:unsafe_rule,
Var.t()}` (§7), or `:too_many_variables` (§4) — all detected structurally,
before any graph access, so a malformed Rule fails fast and deterministically
regardless of the input graph's contents.

## 6. Scope enforcement: fact-pattern literals only

`evaluate/2` and `bindings/2` require every Body literal to be a
`Literal.FactPattern`. A `Literal.CapabilityReference` or
`Literal.RuleReference` anywhere in the Body returns
`{:error, {:unsupported_literal, literal}}` immediately — no partial
evaluation of the fact-pattern subset while silently ignoring the rest.
This matches the exit criterion's literal wording ("a Rule with only
fact-pattern literals in its Body") and keeps this phase from reaching into
6d-i's territory: invoking a Capability needs 6b-i's WASI substrate, which
does not exist yet.

## 7. Rule safety (range restriction)

Classical Datalog safety: every variable appearing in the Head must also
appear in at least one Body literal. A Head variable with no Body
occurrence would be unbound for every solution — not an empty result, an
ill-formed Rule. Checked structurally against the Rule's AST alone, before
any matching: `{:error, {:unsafe_rule, var}}` names the offending variable
rather than producing a triple with a dangling variable or crashing deep
inside triple substitution.

## 8. Testing

A hand-written golden-case suite, mirroring 6c-i-a's style:

- A two-literal shared-variable join:
  `sibling(X,Y) :- parent(P,X), parent(P,Y).`
- A chained multi-hop join: `path(X,Y) :- edge(X,Z), edge(Z,Y).`
- A self-join within one literal (the same variable used twice in one fact
  pattern, e.g. matching only reflexive facts).
- A query with zero solutions (Body is well-formed but unsatisfiable
  against the given graph) — asserts `{:ok, []}`, not an error.
- An unsafe Rule (Head variable absent from the Body) — asserts
  `{:error, {:unsafe_rule, _}}`.
- A Body containing a `capability(...)`/`rule(...)` literal — asserts
  `{:error, {:unsupported_literal, _}}`.
- **The exit criterion's explicit "multi-stream" case**: facts assembled
  from several separately-constructed graphs (standing in for separate
  streams' current states) merged into one input graph via
  `RDF.Graph.add/2`, proving the join binds variables across facts that
  originated from different sources — the join algorithm has no notion of
  "stream" as a boundary (§2), so this demonstrates that directly.

## 9. Exit criterion (from issue #61, restated)

A Rule with only fact-pattern literals in its Body evaluates correctly
against multi-stream joins in the EDB (§8's golden-case suite, including
the explicit multi-graph-merge case), via `Riptide.Derivation.Matcher.
evaluate/2`.

## 10. Explicitly deferred

- Recursion/fixpoint iteration over the Body (6c-ii's exit criterion
  explicitly owns this — "a recursive Rule ... reaches a correct fixpoint
  ... with a documented stratification/termination discipline"). This
  phase parses and rejects nothing about a syntactically recursive Rule
  (6c-i-a already scoped *parsing* recursive shapes as in-scope), but
  `evaluate/2` only ever runs the Body once — it does not iterate to a
  fixpoint.
- Negation, aggregation (6c-iii-a), ValidTime-aware filtering (6c-iii-b) —
  none of the fact-pattern literals or grammar 6c-i-a shipped carry any of
  these, so there is nothing for this phase to evaluate yet.
- How a caller assembles the input `RDF.Graph.t()` from real Riptide
  streams in production (single stream, several explicitly merged, a
  Tenant's full resource tree, or a future materialized index) — entirely
  6d-i's integration concern (§2).
- AST → text pretty-printing of concluded facts or bindings for human
  display — no current consumer needs it (same deferral 6c-i-a made for
  the Rule AST itself).
