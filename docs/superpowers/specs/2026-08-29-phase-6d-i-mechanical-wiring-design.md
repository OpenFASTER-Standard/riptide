# Mechanical Wiring — Design

**Status:** Draft, first revision. Implements Sub-project 6, phase **6d-i**
([issue #64](https://github.com/OpenFASTER-Standard/riptide/issues/64)) —
the third link in the Sub-project 6 walking skeleton
(`6b-i → 6c-i-a → 6c-i-b → 6d-i → 6e-i → ...`), now fully unblocked
(6b-i, 6c-i-a, 6c-i-b all shipped). Parent spec:
`docs/superpowers/specs/2026-08-27-derivation-and-execution-layer-design.md`
(§4, §5, §7's 6d-i entry). Prior phase specs:
`docs/superpowers/specs/2026-08-28-rule-signature-representation-design.md`,
`docs/superpowers/specs/2026-08-28-phase-6c-i-b-fact-pattern-matching-design.md`,
`docs/superpowers/specs/2026-08-28-phase-6b-i-wasi-execution-substrate-design.md`.

## 1. Scope

Per §7: "Execute interpreter, real NativeTemplate instances, `call_template`
against a small hand-authored set." This is the first phase that exercises
6b-i's `Riptide.Capability.invoke/4` and 6c-i-b's `Riptide.Derivation.Matcher`
together, in one real end-to-end path — proving the walking skeleton's
central thesis (parent spec §1): "answer a question about the facts" and
"cause an effect in the world" are two interpretations of the same Rule,
not two kinds of object.

**`NativeTemplate` and `Template` are not new types.** The parent spec is
explicit: `Template ⊑ Rule ⊓ (∃ a reachable step whose ExecuteInterpretation
invokes a Capability)` — "a structural predicate over the one Rule
representation everything shares — not a separate primitive." `NativeTemplate`
is "a Rule whose Body is exactly one capability-reference literal." Neither
needs its own struct; this phase's hand-authored test set simply constructs
`Riptide.Derivation.Rule` values with that shape.

**Out of scope, matching this project's established deferral discipline**
(6b-i's own §1, 6c-i-b's own §10):

- A Capability/Rule catalog, registry, or Discovery mechanism (6e-iii,
  6g-i own this). This phase resolves `CapabilityReference`/`RuleReference`
  IRIs via a **caller-supplied map**, not a lookup service — the same
  "caller-supplied graph, not an index" decision 6c-i-b made for the EDB.
- Trace/Provenance recording. Nothing downstream needs a *real* Trace yet
  — 6e-i's own exit criterion is tested against hand-constructed Rule
  fixtures standing in for Traces, not ones actually produced by
  `ExecuteInterpretation`.
- Any ObserveCapability-specific behavior (asserting its result as new
  Facts). 6b-i already established no kind-based behavioral difference at
  invocation time; this phase doesn't add one either.
- RuleReference cycle/depth protection (§6).

## 2. Module and interface

New module, `Riptide.Derivation.ExecuteInterpreter`:

```elixir
defmodule Riptide.Derivation.ExecuteInterpreter.Context do
  @enforce_keys [:capabilities, :rules, :tenant_id, :current_subject]
  defstruct [:capabilities, :rules, :tenant_id, :current_subject]

  @type t :: %__MODULE__{
          capabilities: %{RDF.IRI.t() => Riptide.Capability.Definition.t()},
          rules: %{RDF.IRI.t() => Rule.t()},
          tenant_id: String.t(),
          current_subject: map() | nil
        }
end

@spec call_template(Rule.t(), RDF.Graph.t(), Context.t()) ::
        {:ok, [RDF.Triple.t()]} | {:error, {:unresolvable, RDF.IRI.t()}}
```

`Context.capabilities`/`rules` are plain maps built by the caller — for
this phase, the hand-authored golden-case test fixtures. An IRI referenced
by a `CapabilityReference`/`RuleReference` literal with no entry in the
matching map is a **structural** error, checked eagerly (§5) before any
graph access or invocation — matching `Matcher`'s own "fail fast on
structural problems before touching the graph" discipline (its
`check_literal_kinds/1`/`:too_many_variables` checks run the same way).

## 3. Body execution algorithm

`call_template` is a direct generalization of `Matcher.evaluate/2`, not a
parallel algorithm bolted alongside it. A Body resolves left-to-right by
one recursive rule:

1. Take the **maximal leading run of `FactPattern` literals** in the
   remaining Body (0, 1, or many literals). Substitute any variable
   already bound (from an earlier step) as a constant, then resolve the
   run via `Matcher.bindings/3` (§4) — a real join over 6c-i-b's own BGP
   engine when the run has 2+ literals sharing a variable, exactly
   reusing the multi-stream-join machinery 6c-i-b built, not a
   reimplementation of it.
2. For each resulting binding (0, 1, or many — real backtracking, free
   from `Matcher.bindings/3`), recurse into the rest of the Body with
   that binding as the new seed.
3. When the next literal is a `CapabilityReference` or `RuleReference`
   instead of a `FactPattern`: invoke it **once** per active branch (via
   `Riptide.Capability.invoke/4`, or a recursive `call_template` call,
   respectively). What "the result" binds to differs by literal kind,
   because the two invocations have genuinely different shapes:
   - `CapabilityReference`: `Riptide.Capability.invoke/4` returns exactly
     one `{:ok, String.t()}` value by construction — no backtracking is
     possible or needed, since a real external invocation isn't a search
     over hypothetical solutions. That string binds `result` directly.
   - `RuleReference`: the nested `call_template` can return **multiple**
     concluded triples (§3's own point 4 — a Rule's Interpretation is not
     required to be single-valued). Every `Rule.head` is a 2-arity
     `FactPattern` (the same system-wide invariant `RuleRDFCodec`
     enforces), so each concluded triple's **object** position is one
     candidate value for `result` — each one spawns its own branch,
     exactly like a fact-pattern run's multiple bindings do. A
     `RuleReference` is backtracked over; a `CapabilityReference` never is.

   Extend each resulting branch's bindings with its `result` value and
   recurse into the rest of the Body from there.
4. Base case, empty Body: the branch's accumulated bindings substitute
   into the Rule's Head, using the same substitution logic
   `Matcher.evaluate/2` already has (`conclude/2`'s pattern).

This degenerates to exactly the walking-skeleton shape (one fact-pattern
run, then two effects in sequence) with no special-casing, while handling
any other literal ordering for free — it is the general algorithm, not a
restricted one, so there is no "simple mode" vs. "general mode" to choose
between. One direct consequence, not a special case: if a fact-pattern run
produces multiple bindings and effects follow, those effects run once per
surviving branch, and `call_template` returns one Outcome per branch —
exactly mirroring `Matcher.evaluate/2` already returning one triple per
`QueryInterpretation` solution.

## 4. `Matcher.bindings/3` — a backward-compatible extension

`Riptide.Derivation.Matcher.bindings/2` (shipped in 6c-i-b) only accepts a
whole `Rule.t()` with no pre-existing bindings. This phase adds:

```elixir
@spec bindings([Rule.literal()], RDF.Graph.t(), %{Var.t() => RDF.Term.t()}) ::
        {:ok, [%{Var.t() => RDF.Term.t()}]}
        | {:error, :too_many_variables | {:unsupported_literal, Rule.literal()}}
```

taking a literal list directly plus a seed-bindings map, substituting any
`Var` already present in the seed as its bound constant before building
BGP triple patterns for the remaining free variables — reusing the exact
same fixed-atom-pool translation (6c-i-b's own §4 safety property: never
`String.to_atom/1` on untrusted variable-name text) for whatever remains
unbound. `bindings/2`'s existing public contract is unchanged; internally
it becomes `bindings(rule.body, graph, %{})`. No existing caller of
`bindings/2` needs to change.

## 5. Failure semantics — branches fail independently

A well-formed Template that produces no Outcomes is not an error — this
phase treats an unmatched fact-pattern run and a failed effect invocation
symmetrically, both simply meaning "this potential Outcome doesn't
materialize," consistent with `Matcher.evaluate/2`'s own "`{:ok, []}`, not
an error" precedent for an unsatisfiable Body:

- A fact-pattern run with zero solutions: that branch contributes nothing,
  silently (matches existing `Matcher` behavior exactly).
- A Capability invocation that fails (`{:error, :unauthorized}`,
  `{:error, :resource_exhausted}`, `{:error, {:trap, _}}}` from
  `Riptide.Capability.invoke/4`): that branch is dropped, but logged via
  `Logger.warning` — matching this project's established "never silently
  swallow" discipline (e.g. `RiptideWeb.Realtime.SseController`'s own
  rescue/catch fix). A failure in one branch never aborts sibling
  branches — those may represent real effects that already happened in
  the world and shouldn't be discarded from the result because a
  different, independent branch failed.
- `call_template` returns `{:error, _}` **only** for the structural
  `{:unresolvable, iri}` case (§2), checked before any graph access or
  invocation. A Template that runs to completion but yields zero
  Outcomes returns `{:ok, []}`.

## 6. Recursion — no depth guard in v1, explicitly deferred

A `RuleReference` literal lets a Rule's `ExecuteInterpretation` recursively
invoke another Rule via `call_template`, which may itself contain a
`RuleReference`. Nothing in this project's Rule representation checks for
cycles — 6c-i-a's own parser explicitly permits a Head predicate to
reappear in its own Body. A `Context.rules` map with a genuine cycle (rule
A → rule B → rule A) would hang this recursive call indefinitely.

**Decided scope for this phase: no depth guard.** The hand-authored test
set (§7) is small and known non-cyclic, matching this phase's own stated
scope ("mechanical wiring... a small hand-authored set"). This is a real,
documented gap, not a silently-accepted one: real protection is owed once
any untrusted or LLM-authored rule chain becomes reachable — 6f's
LLMFallback loop is the most plausible first phase that needs it — flagged
here explicitly (§8) so it isn't rediscovered from scratch later.

## 7. Testing

Golden-case suite, hand-authored:

- A bare `NativeTemplate` (a Rule whose Body is exactly one
  `CapabilityReference` literal) invoked directly through `call_template`
  — the base case, exercising 6b-i's substrate alone.
- The walking-skeleton's own shape: a real multi-stream fact-pattern join
  (reusing 6c-i-b's own join-fixture style — facts assembled from
  separately-constructed graphs merged together, proving this phase
  doesn't bypass that machinery) feeding a `CapabilityReference`, feeding
  a `RuleReference` to a second, NativeTemplate-shaped Rule — proving
  6b-i and 6c-i-b are genuinely exercised **together** in one path, per
  the exit criterion's own wording.
- An unresolvable capability IRI (referenced by a `CapabilityReference`
  but absent from `Context.capabilities`) — asserts
  `{:error, {:unresolvable, _}}`.
- An unresolvable rule IRI (same, for `RuleReference`/`Context.rules`).
- A Capability invocation that fails authorization — asserts
  `{:ok, []}`, not a crash, and (via `ExUnit.CaptureLog`) that a warning
  was logged.
- A fact-pattern run with zero matches against the given graph — asserts
  `{:ok, []}`.
- A `RuleReference` to a nested Rule whose own fact-pattern run yields
  multiple bindings — asserts `call_template` returns multiple Outcomes,
  one per nested solution (§3), not just the first one silently.

## 8. Exit criterion (from issue #64, restated)

A hand-authored set of `NativeTemplate` instances is invoked end-to-end
through `ExecuteInterpretation` via `call_template`, exercising 6b-i's
substrate and 6c-i-b's matching together (§7's suite, specifically the
walking-skeleton-shaped case) — with resolver-map lookups covering the
structural failure mode (§5) and Capability-invocation failures handled
without crashing (§5).

## 9. Explicitly deferred

- A Capability/Rule catalog, registry, or Discovery mechanism (6e-iii,
  6g-i) — `Context.capabilities`/`rules` stay caller-supplied maps in this
  phase; how a real deployment populates them is out of scope here, the
  same way 6c-i-b left "how does a caller assemble the input graph from
  real streams" to this very phase (now answered narrowly, by hand, for
  the test fixtures only — production wiring remains open).
- Trace/Provenance recording (6e-i's own tests use hand-constructed
  fixtures, not real ones from this phase).
- ObserveCapability-specific fact-assertion behavior.
- RuleReference cycle/depth protection (§6) — owed to whichever phase
  first makes an untrusted or LLM-authored rule chain reachable.
- Negation, aggregation, recursive fixpoint evaluation over fact-pattern
  literals (6c-ii/6c-iii-a, unrelated to this phase's RuleReference
  recursion, which is a different mechanism entirely).
