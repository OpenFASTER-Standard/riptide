# Anti-Unification Algorithm — Design

**Status:** Draft, first revision. Implements Sub-project 6, phase **6e-i**
([issue #78](https://github.com/OpenFASTER-Standard/riptide/issues/78)) —
the fourth link in the Sub-project 6 walking skeleton
(`6b-i → 6c-i-a → 6c-i-b → 6d-i → 6e-i → 6e-ii → 6e-iii → ...`), unblocked
by 6c-i-a alone (already shipped). Parent spec:
`docs/superpowers/specs/2026-08-27-derivation-and-execution-layer-design.md`
(§5, §6, §8.2, §7's 6e-i entry). Research grounding:
`docs/superpowers/specs/2026-08-27-derivation-and-execution-layer-research-log.md`
(Part 1, Pass 3).

## 1. Scope

Per §7: "Rule × Rule → Rule least-general-generalization (Plotkin 1970)
over 6c-i-a's representation, including arbitration when anti-unification
yields several mutually-incomparable candidates... via bottom-clause-style
bounding." This phase is a **pure, syntactic, in-memory algorithm** over
`Riptide.Derivation.{Rule, Signature, Var, Literal.*}` — no execution
substrate, no EDB access, no real Capability or NativeTemplate, matching
the exit criterion's own "using no real Capability or NativeTemplate."

**§8.2 is more hedged than §7's phrasing might suggest, and this spec
follows §8.2's actual text, not the looser summary.** §8.2 states the
concrete arbitration mechanism is explicitly left open — "present all
candidates for human review; some ranking heuristic; bottom-clause-style
bounding per §6; some other approach... is Sub-project 6e-i's own design
work, not specified here." This phase adopts bottom-clause-style bounding
as one real, well-grounded tool (§4 below), but treats it as a
**narrowing** step, not a guarantee of always collapsing to one answer —
DedupGate (6e-iii, out of scope here) is where a still-ambiguous result
ultimately goes for human review, per the parent spec's own framing.

**Where the research log's own citation actually applies.** The research
log's Part 1 Pass 3 traces bottom-clause bounding to a different original
problem (fixing ILP's *specialization*-search lattice, not
*generalization* itself, which is classically well-behaved for flat
terms) and explicitly reframes it as a repurposed tool for this phase:
"anchoring a generalization attempt to a maximally-specific reference
point." Combined with §8.2's own citation that minimizing generalization
variables is NP-complete (Yernaux & Vanhoof 2022), this phase's concrete
reading of "bottom-clause-style bounding" is: **prefer the candidate
generalization that introduces the fewest fresh variables** — the
smallest, most specific structure that still generalizes both inputs.

## 2. Where multi-candidate ambiguity actually comes from

Plotkin's classical algorithm is deterministic once you've fixed which
subterm of one term corresponds to which subterm of the other — there is
exactly one answer for two *fixed* terms. A Rule's Body, however, is a
logical conjunction (order-independent, matching Datalog semantics), so
anti-unifying two Bodies is not one fixed term comparison — it's a search
over which literal in Rule₁'s Body corresponds to which literal in
Rule₂'s Body. **Different correspondences (alignments) can produce
different, mutually-incomparable generalizations.** This is the real,
tractable source of the ambiguity the exit criterion asks to engineer a
test case for — not an appeal to abstract graph theory.

## 3. Term-level anti-unification

This operates on the **arguments** of an already-matched pair of literals
(same predicate/capability/rule IRI — §4 establishes that literals are
only ever compared once they share that identifying IRI) — never on two
whole literals with different identifying IRIs. A whole literal's
predicate/capability/rule position can never become a `Var` (§4's own
structural constraint applies equally to the Head, which is why a
Head-vs-Head predicate mismatch is its own special case below, not routed
through this generic algorithm).

Recursive rule over two argument terms `s`, `t`:

- If `s` and `t` have the same shape — both are literals sharing the same
  identifying IRI, or both are the same kind of constant — recurse into
  each corresponding position and reassemble with the same shape.
- Otherwise, look up the pair `{s, t}` in a **shared, injective memo
  map** (`%{ {term, term} => Var.t() }`): if present, reuse that
  variable; if absent, mint a fresh one (a name guaranteed not to
  collide with any variable already present in either input Rule, e.g.
  a distinct prefix plus counter) and record it. The same mismatched
  pair recurring anywhere in the comparison — most importantly, the same
  shared join variable appearing in two different Body literals — gets
  the same fresh variable both times, which is what correctly preserves
  shared structure instead of generalizing it away.

**A real correctness point found during design, not obvious from the
classical statement of the algorithm:** a `Var.t()` must **never**
short-circuit the "same shape, no generalization needed" fast path via
string-name equality. `Riptide.Derivation.Var{name: "X"}` in Rule₁ and
`Var{name: "X"}` in Rule₂ are unrelated entities that merely happen to
share an arbitrary, rule-local name — variable names carry no meaning
across different Rules, and a Rule author could rename a variable without
changing the Rule's meaning at all. Treating same-named variables from
different Rules as "already equal" would make anti-unification's output
depend on incidental naming choices, breaking the algorithm's required
invariance under variable renaming (alpha-equivalence). **Every `Var.t()`
comparison goes through the mismatch/memo path unconditionally** —
only non-`Var` constants (`RDF.IRI.t()`, `RDF.Literal.t()`, etc.) are
checked for real equality first.

The two recovering substitutions fall directly out of the same memo map:
for the fresh variable assigned to pair `{s, t}`, `σ₁` maps it to `s`
(recovering Rule₁'s original subterm) and `σ₂` maps it to `t` (recovering
Rule₂'s).

## 4. Body alignment — pruned by an existing structural constraint, not a new rule

`Literal.FactPattern.predicate`, `Literal.CapabilityReference.capability`,
and `Literal.RuleReference.rule` are all typed `RDF.IRI.t()` — never
`Var.t()` — in the structs 6c-i-a already shipped. A predicate/capability/
rule position can never become a variable in a well-formed literal, so
**two literals can only be paired in an alignment if they share the exact
same identifying IRI and literal kind.** A `pendingDeploy(...)`
fact-pattern can never align with an `approved(...)` one. This is not a
new design rule invented for this phase — it falls directly out of the
struct shapes already shipped, and it prunes the alignment search
dramatically: genuine ambiguity only arises when a Body has **two or more
literals sharing the same identifying IRI**, which is exactly the case
this phase's own test suite engineers (§6).

For a given valid alignment (a bijection over same-IRI-pairable
literals): a literal with no same-IRI partner in the other Rule's Body is
**dropped from the generalization entirely** — standard clause
anti-unification treats a requirement present in only one of two inputs
as unable to survive into something both inputs must subsume.

**The Head is always compared directly, never through an alignment
search** — a Rule has exactly one Head each, so there's nothing to align.
But the same "predicate can't become a variable" constraint applies to it
too: if `Head₁.predicate ≠ Head₂.predicate`, there is no valid `FactPattern`
shape that generalizes both (unlike Body literals, a mismatched Head can't
simply be dropped — a Rule must have a Head). This is a **structural
failure of the whole call**, returned immediately as
`{:error, :no_common_structure}` (§7) — never routed through §3's
generic argument-level mismatch/memo mechanism, which only ever applies
to a Head/literal's *arguments*, not to the literal itself.

## 5. Arbitration — bottom-clause bounding, concretely

1. Enumerate every valid alignment (§4).
2. For each, compute one candidate generalization: the Head anti-unified
   directly, the Body from the matched pairs, all sharing **one** memo
   map across the whole candidate (required for §3's correctness
   property to hold across the entire Rule, not just within one
   literal).
3. Score each candidate by the number of fresh variables its own memo
   map introduced.
4. Keep only the candidates at the **minimum** score — this is the
   concrete cash-out of §1's "bottom-clause-style bounding" reading.

This is a **narrowing** step, not a guaranteed collapse to one answer: if
multiple candidates tie at the same minimum variable count, all of them
are returned (§7's own return type is a list for exactly this reason) —
per §1, resolving that further (if ever needed) is DedupGate's (6e-iii)
job, not this phase's.

**Combinatorial safety cap**, matching this project's established pattern
(`Matcher`'s 64-variable pool, `wasmtime`'s fuel/timeout limits): the
alignment search is combinatorial in the worst case (many literals
sharing the same identifying IRI), so a Body longer than a fixed limit —
**32 literals** — is rejected with a structural error before any search
begins, the same "fail fast on a structural problem before doing real
work" discipline `Matcher`/`ExecuteInterpreter` already established.

## 6. Generalization safety is not checked here

A generalization could end up with a Head variable absent from its
(possibly-shrunk-by-dropped-literals) Body — an unsafe Rule by
`Matcher.evaluate/2`'s own existing `check_safety/2` definition. This
phase does not duplicate that check on its own output. Whoever later
tries to evaluate a generalization (6e-ii's fidelity replay, most
plausibly) already gets that check for free from the existing `Matcher`
machinery — re-implementing it here would be redundant, matching this
project's pattern of not re-checking what a downstream consumer already
enforces.

## 7. Module and interface

```elixir
@spec generalize(Rule.t(), Rule.t()) ::
        {:ok, [{Rule.t(), substitution, substitution}]} | {:error, :no_common_structure | :body_too_large}

@type substitution :: %{Var.t() => RDF.Term.t() | Var.t()}
```

Returns a list because bounding narrows rather than always collapsing
(§5) — the common case is a single-element list; the deliberately
engineered multi-candidate case (§6 of the test plan below) is a
multi-element one. `{:error, :no_common_structure}` when even the two
Heads share no common shape at all (nothing to generalize). `{:error,
:body_too_large}` for the cap in §5.

## 8. Testing

- A simple two-literal Rule pair with one obvious unique lgg — proving
  the basic mechanism, the shared-memo-map correctness property (a
  repeated join variable generalizes to one shared fresh variable, not
  two), and that both recovering substitutions actually reconstruct
  their original Rule when applied to the generalization.
- A pair engineered with two same-predicate Body literals in each Rule,
  admitting more than one valid alignment, where at least two alignments
  produce mutually-incomparable results at the same minimum variable
  count — proving arbitration narrows to (and returns) that tied set
  rather than picking one arbitrarily or returning everything
  unfiltered.
- A pair with genuinely no common structure (different Head shapes
  entirely) — asserts `{:error, :no_common_structure}`.
- A Body longer than 32 literals — asserts `{:error, :body_too_large}`
  before any alignment search runs.
- A same-named-but-unrelated-variable case (Rule₁ and Rule₂ each use
  `Var{name: "X"}` for genuinely different purposes) — proving the §3
  correctness point holds: the shared name does not cause incorrect
  "already equal" treatment.

## 9. Exit criterion (from issue #78, restated)

Anti-unifying two hand-constructed Rules produces their least-general-
generalization plus recovering substitutions (§8's first case); a case
engineered to yield multiple incomparable generalizations is resolved via
bottom-clause-style bounding (§8's second case), covered by unit tests
using no real Capability or NativeTemplate.

## 10. Explicitly deferred

- Collapsing a still-tied candidate set to exactly one answer (human
  review, a further ranking heuristic, or something else) — DedupGate's
  own job, 6e-iii.
- Enforcing Datalog safety on a generalization's own output (§6) —
  already covered downstream by `Matcher.evaluate/2`.
- Fidelity-replay-based validation of a generalization (does
  `ExecuteInterpretation(generalization, σᵢ)` actually reproduce Traceᵢ's
  effects) — 6e-ii's own concern, explicitly named in the parent spec's
  §5.
- Any notion of Provenance recording for a generalization — 6e-iii/§6.5's
  concern once a real Catalog exists.
