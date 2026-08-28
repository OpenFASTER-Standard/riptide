# Rule/Signature Representation and Parser — Design

**Status:** Draft, first revision. Implements Sub-project 6, phase **6c-i-a**
([issue #76](https://github.com/OpenFASTER-Standard/riptide/issues/76)) —
the Foundation-track phase identified as the single highest-leverage phase
in the whole Sub-project 6 roadmap: nearly everything else (6c-i-b's join
evaluation, 6d-i's NativeTemplate, 6e-i's anti-unification, 6f's Trace,
the LinkML rule schema) needs this shape fixed first. Parent spec:
`docs/superpowers/specs/2026-08-27-derivation-and-execution-layer-design.md`
(§3.2, §8.1, §8.2, §8.6).

## 1. What a Rule actually does

A Rule is a reusable, declarative "recipe." The same object means two
different things depending on how it's evaluated — this is the parent
spec's own thesis (§1): "answer a question about the facts" and "cause an
effect in the world" are two interpretations of one object, not two kinds
of object.

- **QueryInterpretation (pure):** the Body's literals are a Datalog
  query. Fact-pattern literals are matched against the EDB, bindings that
  satisfy the whole conjunction are found, the Head is concluded as an
  answer. Nothing external is invoked for effect.
- **ExecuteInterpretation:** the *same* Rule, but capability-reference and
  rule-reference literals are actually invoked, not just pattern-matched.
  Example — the walking skeleton's own billing-service scenario:

  ```
  deployed(Svc, Result) :-
      pendingDeploy(Svc, Target),
      capability(deployService, Svc, Target, Outcome),
      rule(notifyTeam, Svc, Outcome, Result).
  ```

  Under ExecuteInterpretation with `Svc`/`Target` bound: `pendingDeploy`
  is matched against the EDB as usual, `capability(deployService, ...)`
  really calls the `deployService` Capability (a WASI component that
  talks to k8s), `rule(notifyTeam, ...)` recursively invokes the
  `notifyTeam` sub-Rule the same way, and the Head is asserted as a new
  Fact.

  Running this once with real bindings produces a **Trace** — a Rule
  with no free variables, a record of one concrete run (parent spec §5).
  Anti-unifying two Traces (6e-i) produces a reusable, parameterized
  Rule admitted into the Catalog; a later Task is then matched to it via
  Discovery and re-executed with new bindings.

**What this means for 6c-i-a's scope:** the representation doesn't pick
an Interpretation mode — it just needs to preserve enough structure
(which literal is a fact-pattern vs. a capability-reference vs. a
rule-reference) for both interpreters to walk it later. Evaluating either
mode is out of scope here (6c-i-b, 6d-i, 6e-i's concern); this phase
builds the shape both walk.

## 2. Data flow and representations

Three forms of a Rule exist, with one clear direction of truth:

```
concrete text (Soufflé-shaped Datalog)
        │  parse (one-way: text → AST)
        ▼
in-memory AST (Elixir structs)  ◄──────┐
        │  to_rdf/1                     │ from_rdf/1
        ▼                               │
RDF triples (SPIN-ish + riptide: vocab) ─┘
        │  assert via existing Event/Fact mechanism
        ▼
EDB (persisted, canonical form — "the Rule is a Fact")
```

- **The AST is the working representation.** 6c-i-b's matching, 6e-i's
  anti-unification, and 6d-i's NativeTemplate check operate on it
  directly — it is not re-derived from raw triples on every access.
- **The RDF form is canonical at rest**, satisfying "Rules are Facts."
  It's also what 6e-i's anti-unification ultimately reasons about
  structurally, since term-graph anti-unification (parent spec §8.2) is
  fundamentally a graph operation, and a Rule's Body is genuinely an RDF
  graph (blank nodes / RDF lists), not opaque text — full reification,
  not a text blob attached to an otherwise-plain Rule resource.
- **Round-trip, defined precisely** (the exit criterion's phrase, made
  concrete): text → AST → RDF → AST must be **structurally equivalent**
  to the original AST, up to variable renaming (blank-node skolemization
  doesn't preserve variable names as strings) — not byte-identical text.
  AST → text pretty-printing (showing a Rule back to a human) is
  deferred; nothing currently scheduled needs it.

## 3. Concrete authoring syntax

**Decision: a bespoke, Soufflé/Prolog-shaped Datalog-clause syntax**, not
literal SPARQL-RL text. Two other options were considered and rejected:

- **Literal/extended SPARQL-RL** (`RULE { head } WHERE { body }`, per the
  actual W3C draft's syntax — smaller than full SPARQL query syntax, but
  still SPARQL's pattern grammar). Rejected because the SPARQL-RL draft
  is explicit, in its own text, that it is pure inference with **no
  notion of side effects or external actions** ("...without invoking
  external capabilities or producing side effects"). Capability-reference
  literals have no conceptual home in SPARQL-RL at all — bolting them on
  via `BIND(riptide:invokeCapability(...) AS ?x)` (SPARQL 1.1's real,
  already-supported extension-function mechanism — no grammar fork
  needed) would work syntactically, but disguises an effectful call as
  SPARQL's own "compute a pure value" idiom, which is actively misleading
  to anyone reading a Rule's Body. A magic-predicate alternative (forking
  the `sparql` hex package's grammar to recognize special triple-pattern
  predicates) doesn't fix that readability problem and costs real
  parser-surgery risk on someone else's grammar for no corresponding
  benefit.
- **Soufflé-shaped syntax was chosen instead** because the parent spec
  already names Soufflé's extended Datalog as the *reference evaluation
  engine* (not SPARQL-RL's own machinery) — SPARQL-RL is the semantic/
  institutional target (§8.1's Horn-clause grounding), Datalog-shaped
  syntax was always the intended concrete form. Soufflé's own grammar
  already has exactly the three-literal-kind shape this needs
  (ordinary predicates, negated predicates, functor/constraint literals)
  — `capability(...)` and `rule(...)` slot in as new literal kinds the
  same way, visually and grammatically distinct from ordinary fact-
  pattern literals, with no ambiguity about which literals are pure
  lookups versus which cause effects or recurse.

Representative rule in the chosen syntax:

```
deployed(Svc, Result) :-
    pendingDeploy(Svc, Target),
    capability(deployService, Svc, Target, Outcome),
    rule(notifyTeam, Svc, Outcome, Result).
```

**Disambiguating the grammar rule this implies** (not obvious from the
example alone): a `capability(...)`/`rule(...)` literal's **last**
positional argument is always the result binding; every argument before
it is passed as input to the invocation. `capability(deployService, Svc,
Target, Outcome)` means "invoke `deployService` with `(Svc, Target)`,
bind its result to `Outcome`" — not four independent arguments. This
mirrors Soufflé's own functor convention (e.g. `fib(idx+1, x+y)`'s
functor result is likewise positional, not named) rather than inventing
a new one.

## 4. Elixir AST structures

Reuses `RDF.Term` (from the already-present `rdf` hex dependency) for
constant values, rather than inventing a parallel value type — constants
map 1:1 onto RDF terms already, which keeps reification direct.

```elixir
defmodule Riptide.Derivation.Signature do
  defstruct [:name, :parameters, :reads, :produces]
end

defmodule Riptide.Derivation.Rule do
  defstruct [:signature, :head, :body]  # body: ordered list of literals
end

defmodule Riptide.Derivation.Var, do: defstruct [:name]

defmodule Riptide.Derivation.Literal.FactPattern do
  defstruct [:predicate, :args]  # args: [Var.t() | RDF.Term.t()]
end

defmodule Riptide.Derivation.Literal.CapabilityReference do
  defstruct [:capability, :args, :result]
end

defmodule Riptide.Derivation.Literal.RuleReference do
  defstruct [:rule, :args, :result]
end
```

A Body is `[Literal.t()]` — an ordered list, matching Soufflé/Prolog's
conjunction-of-literals shape directly, and directly reifiable as an RDF
List (`rdf:first`/`rdf:rest`).

## 5. RDF reification vocabulary

Reuses SPIN's real `sp:` vocabulary terms for the part SPIN already
solved (fact-pattern literals are triple patterns, the same shape SPIN
was built for): `sp:TriplePattern`, `sp:subject`/`sp:predicate`/
`sp:object`, `sp:varName` for variables. Mints new `riptide:` terms
(formalized via LinkML, §8.6) for the two literal kinds no existing
vocabulary has a concept of:

- `riptide:CapabilityReference` — `riptide:capability`, `riptide:args`
  (an `rdf:List`), `riptide:result`.
- `riptide:RuleReference` — `riptide:rule`, `riptide:args`,
  `riptide:result`.
- `riptide:Rule` ties it together — `riptide:signature`, `riptide:head`,
  `riptide:body` (an `rdf:List` of literals, each one of
  `sp:TriplePattern | riptide:CapabilityReference | riptide:RuleReference`).

Rules are never hand-authored directly as raw RDF (always via the
concrete syntax in §3, reified programmatically) — so SPIN's well-known
verbosity as a *hand-authoring* format doesn't apply here; only its
value as an already-solved, precedented shape for the triple-pattern
portion does.

## 6. Grammar scope (v1)

**In scope:** n-ary fact-pattern atoms, `capability(...)`/`rule(...)`
literals, conjunction, variables vs. constants, Head `:-` Body shape —
including recursive definitions (a Head's predicate may match one of its
own Body's literal predicates; this phase only needs to *parse* that
shape, 6c-ii owns evaluating it).

**Deferred (YAGNI, matching this project's established discipline of
extending incrementally from real need rather than front-loading):**
negation, arithmetic/string functors, aggregation (owned by 6c-iii-a
regardless), disjunction, stratification annotations. Nothing currently
scheduled (6c-i-b, 6d-i, 6e-i, 6f) needs any of these.

## 7. Parser implementation

**NimbleParsec** (Elixir's combinator-based parser library), not
Erlang's leex/yecc. This is a small, fresh grammar — not an adaptation of
an existing large one (unlike, hypothetically, extending `sparql-ex`'s
grammar, which was rejected in §3 anyway) — so NimbleParsec is the more
idiomatic fit for a from-scratch Elixir-side parser in this codebase.
**New dependency**: `{:nimble_parsec, "~> 1.4"}` (or current stable) added
to `mix.exs`.

`{:ok, Rule.t()} | {:error, reason}` return contract, matching
`Riptide.RDF.TurtleCodec`'s existing decode/encode convention.

## 8. Security — resource-exhaustion guard

Riptide has a documented precedent directly on point:
`Riptide.RDF.TurtleCodec.decode/1` carries a `@max_heap_size_words` /
`Process.flag(:max_heap_size, ...)` guard, added after confirming
empirically that a ~3MB deeply-nested Turtle body drove ~863MB/~19s in
the decoding process (fixed in PR #32; cited again in the parent Sub-
project 6 spec's §4 WASI-metering requirement). A Datalog-clause parser
processing untrusted or LLM-authored text is the same risk shape —
deeply chained rule-reference calls or deeply nested argument terms can
drive unbounded recursive-descent parsing cost. `Riptide.Derivation.
Parser.decode/1` gets the same guard before parsing, sized tighter than
Turtle's (Datalog rule text is expected to be far smaller than an RDF
document).

## 9. Testing

Golden-case suite: fact-pattern-only rule, capability-reference rule,
rule-reference rule, all three literal kinds combined, and a recursive
rule — each parsed → reified via `to_rdf/1` → asserted into a test EDB
via the existing Event/Fact mechanism → read back → decoded via
`from_rdf/1` → checked for structural equivalence to the original AST
(§2's round-trip definition).

`linkml-datalog` re-verified 2026-08-28 (immediately before this design,
per the exit criterion's own requirement): still last pushed
2024-02-14, not archived, 1 open issue — unchanged from the parent
spec's prior check, still dormant.

## 10. Exit criterion (from issue #76, restated)

The Rule/Signature representation and its Datalog-clause parser round-trip
(§2's definition) a hand-written set of representative Rules covering all
three literal kinds (§9's golden-case suite), and `linkml-datalog`'s
liveness has been re-checked immediately before this phase starts (done,
§9) rather than assumed from spec-writing time.

## 11. Explicitly deferred

- AST → text pretty-printing (no current consumer needs it).
- Negation, arithmetic/string functors, aggregation, disjunction,
  stratification annotations in the grammar (§6) — added when a real
  consumer needs them, not speculatively.
- Formal LinkML schema authoring for the `riptide:` vocabulary terms in
  §5 — tracked as ongoing work per the parent spec's own "LinkML applied
  to each new schema as created" note (§7), not a blocking prerequisite
  for this phase's own exit criterion.
