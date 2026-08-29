# LLM Fallback Loop — Design

**Status:** Draft, first revision. Implements Sub-project 6, phase **6f**
([issue #67](https://github.com/OpenFASTER-Standard/riptide/issues/67)) —
the seventh link in the Sub-project 6 walking skeleton
(`6b-i → 6c-i-a → 6c-i-b → 6d-i → 6e-i → 6e-ii → 6e-iii → {6f, 6g-i}`),
unblocked by 6e-iii (#66), already shipped. Parent spec:
`docs/superpowers/specs/2026-08-27-derivation-and-execution-layer-design.md`
(§6 — Task/LLMFallback; §7's 6f entry; §9.1's worked example).

## 1. Scope

Per issue #67: orchestration only, now that the Capability-grant/OAuth flow
is its own task (#80). Task with no Catalog match → LLM-guided Capability
invocation → ground Trace.

**Exit criterion:** a Task with no Catalog match completes via LLMFallback,
produces a Trace, and that Trace is accepted by 6e-iii's `DedupGate` gate
without manual code changes.

`"Task with no Catalog match"` is a caller-supplied precondition — matching
every prior phase in this sub-project, `LLMFallback.run/3` does not itself
query the Catalog or Discovery (6g-i, a separate, parallel, unblocked
phase — not a dependency of 6f). A future real `Task` entry point (not
built here) is responsible for having already determined there's no match
before calling this.

## 2. Key insights

**LLM-authored Rule text, not a new response format.** `Riptide.Derivation.
Matcher`'s and `Riptide.Derivation.Parser`'s own doc comments already say
Rule Body text is "untrusted/LLM-authorable" — written before this phase
existed, as an annotation on already-shipped 6c-i-a/6c-i-b code. The
original design intent was always for an LLM to author Rule text directly,
in the exact syntax `Parser.decode/1` already parses (proven throughout
`golden_case_test.exs`) — not a separate tool-calling/JSON response shape.
This phase is the first to actually exercise that intent, reusing
`Parser.decode/1` completely unmodified.

**A real gap, not yet built: turning a live execution into a ground
Trace.** `ExecuteInterpreter.call_template/3` returns only *concluded Head
triples* — it discards the variable bindings that produced them. That's
correct for live execution (§5's `Interpretation` need not expose its own
working state), but a ground Trace needs *every* Body position filled too,
including Body-only variables that never appear in the Head (e.g. an
intermediate match variable). Reconstructing bindings from the Head triple
alone would leave those unbound. `ExecuteInterpreter` gets one small,
purely additive function, `resolve_bindings/3`, reusing its existing
private `check_resolvable`/`execute_body` machinery unchanged — zero risk
to `call_template/3`'s own already-shipped, tested behavior.

**Investigated and ruled out: modeling the LLM call itself as a
Capability.** A `Capability` models a *tenant's own* external-system
integration — sandboxed and authorized per-tenant. The LLM
decision-making call ("given this task, what should happen?") is Riptide's
*own* platform-level reasoning step, not something a tenant grants access
to; it doesn't fit the same slot conceptually. This was also independently
blocked in practice: `Riptide.Capability.invoke/4` hardcodes `-S
inherit-network=n` on every WASI invocation today (`lib/riptide/
capability.ex`), and the 6b-i design spec explicitly notes "no Capability...
needs outbound network access *yet*, and a per-Capability network grant
deserves its own decision once a real consumer needs it" — routing the LLM
call through the WASI sandbox would mean taking on that scope expansion
too, for a conceptual fit that's wrong regardless. The LLM call is
Elixir-level platform infrastructure instead (§3), matching this
project's existing pattern for pluggable stores (`Riptide.Authz.Store`).

## 3. Approaches considered

- **A — Adopted.** LLM authors Rule text directly (reusing `Parser.decode/1`
  unmodified); a new `ExecuteInterpreter.resolve_bindings/3` exposes the
  bindings a live run needs to become a ground Trace via
  `AntiUnifier.substitute/2` (its fourth real production caller); the LLM
  call itself is a small injectable `Client` behaviour, not a Capability.
- **B — Ruled out.** LLM outputs structured JSON naming a Capability +
  args (tool-calling style), assembled into a Rule/Trace by new Elixir
  code. Ruled out: ignores the "Rule Body text is... LLM-authorable"
  design intent already encoded in shipped 6c-i-a/6c-i-b comments, and
  would need new assembly logic where reusing `Parser.decode/1` needs
  none.
- **C — Ruled out.** Model the LLM call as an `ObserveCapability` (WASI
  sandboxed, provider-swappable by pointing a `Definition` at a different
  component). Ruled out per §2's investigation above — conceptual
  mismatch (platform infrastructure, not tenant-granted external-system
  access) plus a real, separate blocker (`inherit-network=n` hardcoded,
  no per-Capability network grant exists yet).

## 4. Module: `Riptide.Derivation.LLMFallback.Client`

```elixir
@callback complete(prompt :: String.t()) :: {:ok, String.t()} | {:error, term()}
```

One callback, deliberately minimal. Configured via
`Application.get_env(:riptide, :llm_fallback_client,
Riptide.Derivation.LLMFallback.Client.Anthropic)` — the exact pattern
`Riptide.Authz` already uses for `authz_store`
(`Application.get_env(:riptide, :authz_store, Riptide.Authz.Store.
Placement)`), overridden in tests via the same `Riptide.AppEnvTestHelpers.
put_env/3` helper every `FakeStore`-using test file already calls.

`Riptide.Derivation.LLMFallback.Client.Anthropic` (its own file,
`lib/riptide/derivation/llm_fallback/client/anthropic.ex` — provider-specific,
not tiny like the behaviour) is the real implementation: a Tesla-based call
(Tesla is already a direct dependency, `mix.exs`, with a real precedent for
outbound HTTP in this codebase — `lib/riptide/auth/jwks_strategy.ex`'s JWKS
fetch) against Anthropic's Messages API. The API key is read from the
standard `ANTHROPIC_API_KEY` environment variable via `System.get_env/1` —
no Riptide-specific secret-provisioning mechanism needed.

## 5. `ExecuteInterpreter.resolve_bindings/3`

```elixir
@spec resolve_bindings(Rule.t(), RDF.Graph.t(), Context.t()) ::
        {:ok, [%{Var.t() => RDF.Term.t()}]}
        | {:error, {:unresolvable, RDF.IRI.t()} | {:unsupported_arity, RDF.IRI.t()}}
```

Same signature shape as `call_template/3`; same structural precondition
check (`check_resolvable/2`, unchanged) and the same recursive
`execute_body/4` walk (unchanged) — the only difference is the return
value: the raw bindings list instead of `Enum.map(bindings_list,
&conclude(rule.head, &1))`. A purely additive public function; nothing
about `call_template/3`'s own existing contract, tests, or callers changes.

## 6. Module: `Riptide.Derivation.LLMFallback`

```elixir
@spec run(String.t(), RDF.Graph.t(), Context.t()) ::
        {:ok, Rule.t()}
        | {:error,
           {:llm_error, term()}
           | {:unparseable_response, term()}
           | :no_match
           | :ambiguous_match
           | {:unresolvable, RDF.IRI.t()}
           | {:unsupported_arity, RDF.IRI.t()}}
```

Pipeline, each step reusing existing machinery except the one genuinely
new piece (the LLM call itself):

1. `build_prompt/2` — task description + the tenant's available Capability
   and Rule *names* from `context.capabilities`/`context.rules` (so the
   LLM only ever references things that actually exist for this tenant,
   never a hallucinated reference) + the exact grammar `Parser.decode/1`
   expects: `predicate(args) :- literal, literal.`, `UPPERCASE` Vars,
   `"quoted strings"` for opaque values, `<IRI>` for entity references,
   `capability(name, args..., result)`/`rule(name, args..., result)`
   literals — plus an instruction to output *only* the rule text, nothing
   else. Then `client.complete/1` (§4). LLM call failure →
   `{:error, {:llm_error, reason}}`.
2. `Parser.decode/1` on the raw response, completely unmodified. No
   post-processing (no markdown-fence stripping, no prose extraction) —
   a non-conforming response is a real, surfaced
   `{:error, {:unparseable_response, reason}}`, not silently patched
   around; the prompt's own instruction to output only rule text is the
   only lever for compliance, matching this project's preference for
   surfacing real problems over working around them.
3. `ExecuteInterpreter.resolve_bindings/3` (§5) against the caller-supplied
   `graph`/`context` — real Capability invocation happens here, real
   `wasmtime`, exactly as everywhere else in this sub-project. Zero
   bindings → `{:error, :no_match}`; more than one → `{:error,
   :ambiguous_match}` (a well-formed one-off task shouldn't resolve
   ambiguously — that's a signal the LLM under-constrained the Rule it
   wrote, not something to silently pick one binding from); an
   unresolvable Capability/Rule reference or bad arity propagates
   `resolve_bindings/3`'s own error shape unchanged.
4. `AntiUnifier.substitute(candidate_rule, binding)` — the ground Trace.
   `AntiUnifier.substitute/2`'s fourth real production caller (after
   `DedupGate`'s three call sites in 6e-iii).

## 7. Testing

Fake `Client` throughout (§4's injectable behaviour — real wasmtime, real
storage where those already apply, only the network call to the LLM
provider is faked, matching the project's now-established "everything
except the one genuinely new external dependency stays real" pattern):

- Pass case: canned response text referencing a real fixture Capability
  (the `greet` fixture already used throughout this sub-project) and a
  real `FactPattern`, producing exactly one binding → the resulting ground
  Trace matches what `AntiUnifier.substitute/2` would independently
  compute.
- Unparseable response → `{:error, {:unparseable_response, _}}`.
- Response referencing an unregistered Capability → `{:error,
  {:unresolvable, iri}}` (propagated from `resolve_bindings/3`).
- Response whose Body matches nothing in the graph → `{:error, :no_match}`.
- Response whose Body matches ambiguously (multiple bindings) → `{:error,
  :ambiguous_match}`.
- Fake `Client` itself returns `{:error, _}` (simulating a network/API
  failure) → `{:error, {:llm_error, _}}`.
- `ExecuteInterpreter.resolve_bindings/3` direct unit tests, mirroring
  `call_template/3`'s own existing test style (`execute_interpreter_test.exs`)
  — pass/fail cases asserting bindings instead of concluded triples.
- **Capstone:** two separate `LLMFallback.run/3` calls (fake `Client`, two
  different canned responses, matching §9.1's own worked example — the
  walking skeleton "runs through LLMFallback twice") produce two ground
  Traces → `AntiUnifier.generalize/2` → `DedupGate.propose/4` →
  `approve_review/2` → live in `Catalog.list_entries/1`. The first test in
  this sub-project to exercise the *entire* walking skeleton end-to-end in
  one place, real fixture Capabilities and real storage throughout.

## 8. Exit criterion (from issue #67, restated)

A Task with no Catalog match (a caller-supplied precondition, §1) completes
via `LLMFallback.run/3`, producing a ground Trace, and that Trace is
accepted by 6e-iii's `DedupGate` gate (`AntiUnifier.generalize/2` against a
second such Trace, then `DedupGate.propose/4`) without manual code changes.
Satisfied by §7's capstone test end-to-end.

## 9. Explicitly deferred

- A real `Task` module/entry point, and real Discovery-triggered "no
  match" detection — 6g-i's own job; `run/3` takes the precondition as
  already established by its caller (§1).
- The Capability-grant/OAuth flow (#80) — only needed for the subset of
  fallbacks requiring a fresh external grant, not the walking-skeleton
  path this phase's exit criterion covers (issue #67's own scope note).
- Per-Capability network grants / lifting `inherit-network=n` — a real,
  identified gap (§2), but not this phase's to fix; no Capability in this
  phase's own worked example needs outbound network access (only the LLM
  call itself does, and that's Elixir-level, not WASI-sandboxed).
- §9.2's full German-tax-filing scope (ObserveCapability-with-Provenance
  checks, real content-layer fact extraction, StabilityClass-based
  Discovery tie-breaking) — explicitly presented in the parent spec as
  "the case that found real gaps," not a build target for this phase;
  this phase covers §9.1's clean-case shape only.
- Retry/backoff or prompt-repair logic for a non-conforming LLM response —
  a single attempt, a real surfaced error on failure; no automatic retry
  loop.
