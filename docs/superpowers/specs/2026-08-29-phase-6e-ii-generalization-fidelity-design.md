# Generalization Fidelity Replay Harness — Design

**Status:** Draft, first revision. Implements Sub-project 6, phase **6e-ii**
([issue #79](https://github.com/OpenFASTER-Standard/riptide/issues/79)) —
the fifth link in the Sub-project 6 walking skeleton
(`6b-i → 6c-i-a → 6c-i-b → 6d-i → 6e-i → 6e-ii → 6e-iii → ...`), unblocked
by 6e-i (needs a Generalization to test against) and 6b-i (needs the WASI
sandbox to replay into), both already shipped. Parent spec:
`docs/superpowers/specs/2026-08-27-derivation-and-execution-layer-design.md`
(§4 — Capability/NativeTemplate/Template, `kind: :effect | :observe` on
`Riptide.Capability.Definition`; §5 — Trace, Generalization, Interpretation,
Provenance, and Generalization Fidelity named explicitly as this phase's own
concern).

## 1. Scope

Per issue #79: given a Generalization and its source Traces, reproduce each
Trace's recorded effects (`EffectCapability`) or recorded response
(`ObserveCapability`) and report fidelity pass/fail, exercised against
hand-authored fixture Capabilities (real `wasmtime` invocation, not mocked).

## 2. The key insight

A Trace, per §5, is *just* a `Rule.t()` with no free parameters — nothing
more. A ground Trace's `CapabilityReference.result` field, once ground,
**already is** that invocation's recorded output. No new
Provenance/recording type needs inventing for this phase — §5's own
Provenance term (the dependency edge used for generalization/installation
lineage) is untouched by 6e-ii.

Checking "does this Trace replay faithfully" is recursive and self-similar:
a `RuleReference` literal inside a ground Trace points to another ground
Trace (the nested Rule's own concrete run), resolved through the exact same
`Context.rules: %{IRI => Rule.t()}` map `ExecuteInterpreter` already uses
for live execution — with the added invariant that, for replay, every entry
reached this way must itself be ground. RuleReference support therefore
isn't a separate feature needing a new "trace bundle" type — it falls out
as one more literal kind in the same recursive walk, resolved through a
struct (`ExecuteInterpreter.Context`) that already exists.

This means the harness never touches `AntiUnifier`/Generalization/
substitution at all. It operates on **one ground `Rule.t()` (a Trace) + a
graph + a Context**. The "Generalization → Trace" reconstruction
(`substitute(generalization, σᵢ)`, proven structurally equal to `Traceᵢ` by
6e-i's own round-trip tests) is the **caller's/test's job**, not part of
the harness's own API surface — this keeps the module boundary crisp:
`AntiUnifier` computes generalizations, `GeneralizationFidelity` checks
whether a *given* ground Rule replays faithfully. §6's test suite composes
them, which is how the exit criterion's literal wording ("given a
Generalization and its source Traces...") gets satisfied via test
composition rather than the module's own signature.

## 3. Approaches considered

- **A — Adopted.** A new, small, dedicated module
  `Riptide.Derivation.GeneralizationFidelity`. A straight-line **recursive**
  walk over a ground Trace's Body — no bindings/joins needed at all,
  everything is already concrete, unlike `ExecuteInterpreter`'s join
  search. Reuses `ExecuteInterpreter.Context` and the real, unmodified
  `Capability.invoke/4`.
- **B — Ruled out.** Extend `ExecuteInterpreter` itself. Doesn't actually
  work without real surgery: `bind_result/3` only fires when a literal's
  `result` is a `%Var{}` — a ground Trace's `CapabilityReference.result` is
  already a constant, so the current code never reads or compares against
  it, and has no seam for "skip invocation, trust this value" per-kind.
  Fixing this would mean restructuring 6d-i's already-shipped, tested
  execution model around a concern it wasn't designed for.
- **C — Ruled out.** No reusable module, just ad hoc per-test assertions.
  Fails the exit criterion directly — it explicitly asks for "the harness,"
  something 6e-iii's orchestration will call later.

## 4. Module and interface

```elixir
@spec check(Rule.t(), RDF.Graph.t(), ExecuteInterpreter.Context.t()) ::
        {:ok, :fidelity_pass}
        | {:ok, {:fidelity_fail, reason}}
        | {:error, :not_ground | {:unresolvable, RDF.IRI.t()} | {:unsupported_arity, RDF.IRI.t()}}
```

**Structural precondition, checked upfront:** the given Rule must be fully
ground (no `%Var{}` anywhere in Head or Body — sweep both, same style as
6e-i's own `vars_in_rule` test helper, but as a real production check this
time). Violation → `{:error, :not_ground}`.

## 5. Per-literal replay semantics

Walk the Body in order, short-circuit on first failure. There is only one
branch per literal, since everything is ground — no multiplicity like
`ExecuteInterpreter`'s join search has.

- **FactPattern** `{predicate, [s, o]}` → check
  `RDF.Graph.include?(graph, {s, predicate, o})` (`RDF.Graph.include?/2`,
  `deps/rdf/lib/rdf/model/graph.ex:1146` — accepts a `{subject, predicate,
  object}` triple directly and returns a boolean; verified against the
  vendored `rdf` dependency's actual source, not assumed). Failure reason:
  `{:fact_not_present, {subject, predicate, object}}`.
- **CapabilityReference, kind `:effect`** → convert `args` (ground
  `RDF.Term.t()` values) to plain strings via a small local
  `term_to_arg/1`-equivalent (duplicate 6d-i's private 3-line helper of the
  same name/shape — matches this project's established tolerance for small
  local duplication rather than exporting a private helper across
  modules), call the real, unmodified `Capability.invoke/4`, compare the
  result against the literal's own recorded `result` field via `==`.
  - Mismatch → `{:capability_mismatch, iri, expected, actual}`.
  - Invoke error (`:unauthorized` / `:resource_exhausted` / `{:trap, _}`) →
    `{:capability_error, iri, reason}`.
- **CapabilityReference, kind `:observe`** → **never invoke.** Always trust
  the recorded `result` — no failure path for this kind at all, by design
  (matches spec §4's literal wording: "does not re-invoke... it replays the
  response recorded... since the external world isn't expected to be
  frozen between runs"). **No authorization recheck either**, even though
  it would be side-effect-free and cheap — scope stays exactly matched to
  the spec's literal description. This is a deliberate scope line, stated
  explicitly here rather than a silent omission.
- **RuleReference** → look up `context.rules[iri]`.
  - Absent → `{:error, {:unresolvable, iri}}` (matches 6d-i's own error
    shape for the identical situation).
  - `length(args) != 1` → `{:error, {:unsupported_arity, iri}}` (matches
    6d-i's own convention — RuleReference is scoped to exactly one input
    arg, an existing project-wide invariant, not new to this phase).
  - Otherwise recurse `check/3` on that nested Rule (itself required to be
    ground) with the same graph/context; on failure, wrap the reason as
    `{:nested, iri, inner_reason}` for diagnosability.

## 6. Known pre-existing quirk, documented not fixed

`ExecuteInterpreter.bind_result/3` binds a CapabilityReference's raw
invoke-output **string** directly (not wrapped as `RDF.Literal`), so in
practice a ground Trace's `CapabilityReference.result` field holds a raw
Elixir binary, not a proper `RDF.Term.t()` as the struct's declared type
(`Var.t() | RDF.Term.t()`, from 6c-i-a) implies. **Decision: not 6e-ii's
job to fix** — fixing it would mean touching already-shipped, tested 6d-i
code and risks breaking its existing tests, which assert exactly this
raw-string shape (see `execute_interpreter_test.exs`'s
`{:ok, [{t("riptide"), rel("greeted"), "\"Hello, Riptide!\""}]}`
assertion). This is documented as a named, explicit finding, matching
6d-i's own precedent of documenting real inconsistencies rather than
silently papering over them (see `PROGRESS.md`'s own 6d-i section). No code
complexity is actually needed to handle this: both sides of the `==`
comparison (freshly-invoked value, recorded value) come from the same
`Capability.invoke/4` code path, so they're type-consistent with each
other even though inconsistent with the struct's declared type.

## 7. Testing

- Fixture Capabilities backed by real `wasmtime` invocation, same pattern
  as `execute_interpreter_test.exs`.
- Pass case covering all three literal kinds (FactPattern present,
  `:effect` result matches, `:observe` result trusted without invocation)
  in one ground Trace.
- One failing case per failure reason in §5:
  `{:fact_not_present, _}`, `{:capability_mismatch, _, _, _}`,
  `{:capability_error, _, _}`.
- `:not_ground` precondition — a Rule with a `%Var{}` in the Body is
  rejected before any replay work happens.
- `RuleReference` recursion: a passing nested case, and a failing nested
  case asserting the `{:nested, iri, inner_reason}` wrapping.
- `{:error, {:unresolvable, iri}}` and `{:error, {:unsupported_arity,
  iri}}` for a `RuleReference` pointing outside `context.rules` and one
  called with other than one arg, respectively.
- A full round-trip test composing `AntiUnifier.generalize/2` →
  reconstruct each candidate via a test-local substitute helper (same
  shape as 6e-i's own test file's `substitute_rule/2`) → `check/3` on each
  reconstructed Trace, satisfying the exit criterion's literal wording
  ("given a Generalization and its source Traces...") end-to-end.

## 8. Exit criterion (from issue #79, restated)

Given a Generalization and its source Traces, the harness reproduces each
Trace's recorded effects (`EffectCapability`) or recorded response
(`ObserveCapability`) and reports fidelity pass/fail, exercised against
hand-authored fixture Capabilities. Satisfied by §7's round-trip test plus
the per-literal-kind pass/fail cases, all against real `wasmtime`-backed
fixtures (no mocked Capability invocation).

## 9. Explicitly deferred

- Orchestrating fidelity checks across an entire Catalog, or deciding what
  happens on a fidelity failure (reject the Generalization? flag for
  review?) — DedupGate's own job, 6e-iii, out of scope here.
- Fixing `ExecuteInterpreter.bind_result/3`'s raw-string-vs-`RDF.Term.t()`
  quirk (§6) — pre-existing, shipped, tested 6d-i behavior; documented,
  not touched.
- Authorization re-checking for `:observe`-kind literals during replay
  (§5) — deliberately out of scope, matching the spec's literal wording.
- Any notion of Provenance recording for a fidelity check's own outcome —
  §6.5's concern once a real Catalog exists, not this phase's.
