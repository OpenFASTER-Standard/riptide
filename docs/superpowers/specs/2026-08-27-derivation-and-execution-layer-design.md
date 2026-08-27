# Derivation and Execution Layer — Architecture Design

**Status:** Draft, third revision — a currency pass against Riptide's actual
current state and external facts this document depends on, not new design
work. This is one architecture spec defining a single new top-level
Riptide sub-project, **Sub-project 6**, decomposed into phases 6a–6i, the
same way Riptide's own sub-projects 3, 4, and 5 are already decomposed.
Each phase gets its own implementation plan (`writing-plans`) when work on
it starts. See §11 for the itemized changelog across all three revisions.

## 1. Motivation and vision

**Riptide's production-readiness roadmap (its own sub-projects 1–5:
persistence, Docker/CI, clustering/HA, security/multi-tenancy,
observability) is complete as of today**, per `PROGRESS.md`. This spec's
work is the first thing built on top of that now-stable foundation, not a
parallel effort competing with an unfinished one — worth stating plainly,
since most of this document was drafted while that roadmap was still
in flight.

Riptide today is an event-sourced fact store: an append-only, per-resource
log of RDF facts, with one hardcoded derivation. This spec adds the layer
that's structurally missing: a general **derivation and execution engine**,
so that "answer a question about the facts" and "cause an effect in the
world" become two interpretations of the same declarative object, evaluated
by one engine.

The organizing idea: **the atomic unit should have a stable identity, and
everything else should be a *view* derived from that identity, never the
identity itself.** This spec extends that discipline from facts to rules,
and to the *vocabularies rules are expressed in* (§6, Pattern Hub; §6.5,
Crosswalks). The same underlying instinct shows up a third time there: when
no existing bridge covers something (no matching prior Trace, no matching
CatalogEntry, no matching Crosswalk), a human/direct-origination step fills
the gap once, and the bridge gets built incrementally from real use — never
front-loaded. Not three separate design choices; one discipline, applied
consistently.

**What's settled about deployment, and what isn't.** Settled: this layer
shares Riptide's Fact store, Rule representation, and Signature/Dialect
definitions as one substrate. Not settled: whether the engine runs in the
same OS process as Riptide's existing LDP surface — genuinely open, §10.

## 2. Scope

**In scope:** the object model (§3–6), the grounding for each decision
(§8), two worked examples (§9), and Sub-project 6's phase breakdown (§7).

**`administration-commons` note.** An earlier local project used the term
"pattern" for a similar idea and sketched its own kernel. Superseded by
this work, not something this spec reconciles with.

**Explicitly still open** (§10 for the full list): concurrent-effectful-
execution coordination; whether this engine is a separate deployable from
Riptide's LDP surface; formal versioning/supersedes theory for rules;
the final Tenant name; automated detection of ontology overlap (out of
scope *by design*, §6.5).

## 3. Core concepts — facts and rules

### 3.1 Fact, Event, Tenant

- **Fact** — an atomic RDF(-star) assertion in the EDB. Carries
  *TransactionTime* (from Riptide's sequence number) and optionally a
  *ValidTime* interval (RDF-star-annotated, §8.4). Produced by one **Event**.
- **Tenant** *(name TBD — shortlist: Polity, Enclave, Civitas, Demesne)* —
  an isolated administrative/institutional space. Facts, Rules,
  CatalogEntries, and Capabilities are all tenant-partitioned. A Capability
  grant in one Tenant is never exercisable by a Rule in another; this
  composes with Riptide's shipped Phase 4c ACP authorization (default-deny,
  container-level inheritance, deny-overrides-allow, tenant-root bootstrap
  claim — confirmed accurate against the shipped design, `PROGRESS.md`
  §4), not a parallel system. **Current note**: this ACP/auth surface is
  under active security-audit remediation in a sibling branch as of this
  writing (observed directly, not yet its own committed spec) — Sub-project
  6b's integration point should target whatever that lands as, not a frozen
  snapshot of the original Phase 4a–4d design.
- **A Tenant's vocabulary is observed, not declared.** No separate
  "ontology preference" object. Whichever Signature a Tenant's own Facts
  happen to already use *is* their working vocabulary for that area. A
  brand-new Tenant installing its first Pattern simply adopts that
  Pattern's native Signature. This works because Crosswalk resolution
  (§6.5) is field-level, not whole-ontology: two Signatures with zero
  overlapping predicates simply coexist.

### 3.2 Signature, Dialect, Rule

- **Signature** — a Rule's typed interface: its parameters and which
  predicates it reads/produces. Institution-theoretically, this is DOL's
  `Sign`, reused precisely (§8.1).
- **Dialect — corrected this revision.** Previously described as two
  independent, parallel W3C drafts (SPARQL-RL and SHACL 1.2 Rules). **As of
  a direct re-check today, that's no longer accurate**: the live,
  always-current URL for "SHACL 1.2 Rules" (`w3.org/TR/shacl12-rules/`) now
  redirects to `w3.org/TR/sparql12-rl/` — the two appear to have been
  consolidated by the Data Shapes Working Group into one document under the
  SPARQL-RL name. The historical dated snapshot
  (`w3.org/TR/2025/WD-shacl12-rules-20251209/`) is still directly reachable
  as an archival artifact, per normal W3C practice, but is no longer the
  current version of anything. **Target Dialect: SPARQL-RL**, tracked as
  one document, not two — simpler than the prior revision assumed. Worth a
  fresh check again before Sub-project 6c locks in a concrete grammar,
  since this is a live Working Draft, not a finished Recommendation.
  Reference evaluation engine: Soufflé's extended Datalog.
- **Rule** — a declarative IDB definition over a Signature: given a Body,
  conclude a Head. A Body is a conjunction of three literal kinds:
  - **Fact-pattern literals** — matched against the EDB, classical Datalog.
  - **Capability-reference literals** — a reference to a Capability (§4)
    that ExecuteInterpretation may invoke.
  - **Rule-reference literals** — a call to another Rule, with argument
    bindings. Without this, Rule composability (Templates calling other
    Templates) is inexpressible — caught by tracing a real scenario (§9)
    through the model, not by re-reading the document.

## 4. Capability, NativeTemplate, Template

- **Capability** — an explicit, tenant-scoped, grantable permission. Two
  kinds:
  - **EffectCapability** — changes something in the world. Fidelity
    replay-testing (§5) re-invokes it, sandboxed, and compares against the
    recorded Trace.
  - **ObserveCapability** — reads external state and asserts the result as
    new Facts, changing nothing external. Fidelity replay-testing does
    *not* re-invoke the real external system — it replays the response
    recorded in Provenance, since the external world isn't expected to be
    frozen between runs.
  - Both kinds carry a **StabilityClass** — `documented` or `undocumented`
    (reverse-engineered, liable to silent breakage). Discovery (§6) uses it
    as a ranking input alongside recency/specificity.
  - Backed by WASI Preview 2 (no ambient authority, no subprocess spawning
    by design) plus WASIX where subprocess spawning is specifically
    granted (§8.3).
- **NativeTemplate** — a Rule whose Body is exactly one capability-reference
  literal. The base case, backed by a real, capability-scoped WASI
  component. Sequencing note: Sub-project 6b (§7) builds the WASI execution
  substrate standalone, with no Rule representation involved — it doesn't
  produce NativeTemplate instances yet, since Rule's representation isn't
  built until 6c. 6d is what wraps 6b's substrate as actual NativeTemplate
  instances.
- **Template** — `Template ⊑ Rule ⊓ (∃ a reachable step whose
  ExecuteInterpretation invokes a Capability)`. A structural predicate over
  the one Rule representation everything shares — not a separate primitive.

## 5. Trace, Generalization, Interpretation, Provenance

- **Trace ⊑ Rule** — a Rule whose Signature has no free parameters; every
  value already ground, from one concrete run.
- **Generalization — uniformly `Rule × Rule → Rule`.** Anti-unification
  (Plotkin 1970) computes the least-general-generalization of any two
  Rules. Always accompanied by the recovering substitutions and by
  mandatory **Provenance**.
- **Admission consequence**: a Rule generalized from only one Trace is not
  admissible anywhere — a zero-parameter "template" isn't reusable.
  Admission (§6) requires at least one real Generalization step.
- **Interpretation** — `(Rule, Bindings, EDB-state) → Outcome`. At least
  **QueryInterpretation** (pure) and **ExecuteInterpretation** (capability-
  reference literals actually invoked; Outcome may include effects and,
  for ObserveCapability steps, newly-observed Facts). More modes expected
  later. Algebraic effects/handler theory is the closest established
  formalism for this shape; not a proof this specific design is correct.
- **Generalization Fidelity — an engineering requirement, not an inherited
  proof.** For a Generalization `g` from Traces `t₁, t₂` with substitutions
  `σ₁, σ₂`, `ExecuteInterpretation(g, σᵢ)` should reproduce `tᵢ`'s effects,
  verified by sandboxed replay-testing with the kind-specific semantics
  from §4. Capabilities that can't be safely replay-tested may need to
  stay ungeneralized, or require human certification (§6). Real
  engineering, scoped to Sub-project 6e.
- **Provenance** — the dependency edge back to what a Rule was generalized
  or installed from (§6.5).

## 6. Catalog, DedupGate, Discovery, Task, LLMFallback, Pattern

**Catalog is parameterized by scope: `Tenant` or `Hub`.** One mechanism,
two scopes:

- **DedupGate** — anti-unifies a freshly-generalized candidate against its
  Catalog and yields `Reject`, `Merge`, or `Admit`. Both `Admit` and
  `Merge` require human review before the result is live — `Admit` per
  `scratch-command-bar`'s existing propose/review precedent; `Merge`
  additionally because graph three-way merge is provably weaker than
  git's. `Reject` skips review.
- **CatalogEntry** — `⊑ Rule`, admitted or merged by DedupGate, subject to
  §5's admission consequence.
- **Pattern is not a separate type.** It's the name for a CatalogEntry at
  **Hub** scope — a published, human-validated, publicly-installable unit,
  generalizing to *any* computer-doable action, not an administrative-only
  subset.
- **Discovery** — search over CatalogEntry (either scope). Exact/keyword
  lookup (viable as soon as any CatalogEntry exists) and, later, hybrid
  keyword+embedding progressive disclosure. Conflict resolution: recency,
  then StabilityClass, then specificity as final tiebreaker.
- **Task** — the entry point. Triggers Discovery against the Tenant's own
  Catalog; a confident match invokes that CatalogEntry directly; no match
  triggers **LLMFallback**, whose resulting Trace feeds Generalization →
  DedupGate (Tenant scope) → possibly a new local CatalogEntry.
- **Install** — `CatalogEntry(Hub) × Tenant → CatalogEntry(Tenant)` (§6.5),
  going through the same DedupGate as any tenant-local candidate, with a
  narrower review scope (confirming field bindings, not re-reviewing
  already-curated content).

### 6.5 Crosswalk

- **Same-Dialect translation** (the common case, especially now that §3.2
  consolidates the Dialect target to one document): a **signature
  morphism** — an arrow within one institution's `Sign` category, already
  this document's own vocabulary. Soundness vocabulary, if ever checked:
  model-conservativeness / Mod-strictness / Sen-maximality.
- **Cross-Dialect translation**: a full **comorphism** — categorically
  heavier, and the case where the sublogic/embedding/faithful/(weakly)
  exact fidelity scale actually applies (per DOL's own worked practice). An
  earlier draft proposed modeling *all* Crosswalks as comorphisms; checked
  against the primary literature, that was wrong for the same-Dialect
  case, which is the common one.
- **Human-facing representation, either case: SSSOM** —
  `exact_match`/`close_match`/`broad_match`/`narrow_match`/`related_match`,
  a curator's practical judgment ("fitness for purpose," explicitly not a
  claim of model-theoretic equivalence, per SSSOM's own specification),
  available for later optional strengthening into a formally-checked
  morphism, never a prerequisite for use.
- **Detection of overlap is human-only, by design, for now.** A curator
  proposes a Crosswalk entry; it goes through the same Hub-scope DedupGate
  as any other Hub content.
- **Crosswalks are Hub-scope content**; a Tenant's actual vocabulary
  commitment (§3.1) is the one genuinely tenant-local fact.
- **Installation with partial coverage**: per Signature field, look up an
  existing Crosswalk against the Tenant's established vocabulary. Matched
  fields bind through it. **Unmatched fields — the Tenant supplies those
  Facts directly**, in the Pattern's native vocabulary, recorded as
  manually-originated Provenance. Crosswalks grow incrementally from real
  installation friction, the same discipline already applied to Traces and
  Tasks. Degrades to zero friction for thin, uncontested Signatures.

## 7. Sub-project 6: phases

Riptide's own `PROGRESS.md` sub-projects (1–5) are complete; this becomes
**Sub-project 6**, decomposed the same way sub-projects 3–5 already are.
Each phase becomes its own spec → plan → implementation cycle.

- **6a — Bitemporal fact shape.** RDF-star `validFrom`/`validTo`, a defined
  OWL-Time Allen-relation subset, ValidTime defaulting to TransactionTime.
  Applies to Riptide's existing LDP write path. **Must build on the
  already-shipped Phase 3a schema-versioning envelope** (`PROGRESS.md`
  §3, shipped 2026-08-24) rather than treat the `Event`/`Patch` shape
  change as a fresh, unaddressed risk — that envelope exists specifically
  so a struct-shape change like this one doesn't break reading
  previously-persisted data. Depends on nothing else. Deferred to 6c+:
  making ValidTime queryable/joinable in rule logic.
- **6b — Execution substrate.** WASI component execution, WASIX capability
  grant, tenant-scoped and split into EffectCapability/ObserveCapability
  from the start. Must produce the integration point with Riptide's
  *current* ACP model (§3.1's live-audit-remediation note) as an exit
  criterion. Tested with no Rule representation involved.
- **6c — Pure derivation engine.** Cross-stream joins, recursion,
  aggregation, query interpretation only. Depends on 6a.
- **6d — Wiring**, split by risk:
  - **6d-i — mechanical wiring.** Execute interpreter, real NativeTemplate
    instances, `call_template` against a small hand-authored set. Low risk.
  - **6d-ii — concurrent-effects design spike.** No established theory
    answers coordinating concurrent ExecuteInterpretations over
    overlapping, irreversible resources (checked: neither sagas nor CRDTs
    establish this). Real, open design work.
- **6e — Generalization and DedupGate**, including replay-testing fidelity
  with the kind-specific semantics from §4. Depends on 6d-i.
- **6f — LLM fallback loop.** OAuth ported to Elixir by hand (no ecosystem
  to lean on — `lambdaclass/datalog` dead, `fogfish/datalog` real but
  dormant since 2019, re-confirmed today, no change). Needs 6e's gate.
- **6g — Discovery**, split by readiness:
  - **6g-i — exact/keyword lookup**, viable as soon as any CatalogEntry
    exists (as early as 6e) — a real walking skeleton well before the rest
    of the roadmap ships.
  - **6g-ii — hybrid keyword+embedding progressive disclosure**, deferred
    until the catalog is large enough to need it.
- **6h — Pattern Hub.** Stand up Hub-scope Catalog as a distinct,
  publicly-reachable deployment of the same DedupGate mechanism 6e already
  builds. Depends on 6e.
- **6i — Ontology Crosswalks and Installation.** SSSOM-shaped Hub-scope
  Crosswalk content, the Install operation, human-curation workflow.
  Depends on 6h.

**Ongoing, not sequential:** LinkML authoring applied to each new schema as
created (§8.6).

## 8. Grounding

**8.1 Rule dialects.** Institution theory covers Horn Clause Logic as a
genuine sub-institution of first-order logic (Diaconescu 2006). Soufflé's
extended Datalog and SPARQL-RL (§3.2) go beyond pure Horn Clause Logic —
the institution-theoretic grounding covers their Horn-clause core, not
their full extent. Soufflé's hard requirement that user-defined functors
stay pure and reentrant remains real, independent validation that effects
belong in a separate interpreter.

**8.2 Anti-unification.** Plotkin/Reynolds (1970): flat first-order
syntactic anti-unification, proven unitary. Term-graph anti-unification
(Baumgartner, Kutsia, Levy & Villaret, FSCD 2018) proves the general case
only **finitary**, with unitarity proven only for the narrower
bisimilar-term-graph case — open question (§10) whether the Rule
representation can be constrained there. Minimizing generalization
variables is NP-complete in the closest scalable formalism (Yernaux &
Vanhoof 2022).

**8.3 Execution kernel.** WASI Preview 2 excludes fork/exec/subprocess
spawning by design; WASIX is the separate superset restoring it.

**8.4 Bitemporal facts.** Datomic is unitemporal; XTDB's two-axis model is
the target shape, via RDF-star + OWL-Time. Valid-time must be duplicated
into ordinary queryable fact form for the derivation layer to reason over
it.

**8.5 Capability kinds.** The EffectCapability/ObserveCapability split
fell out of tracing §9.2 through the model, not external research — this
document's own synthesis, presented as such.

**8.6 Authoring — liveness re-checked today.** LinkML adopted for 6c's
rule schema and 6h/6i's Pattern and Crosswalk schemas. `linkml-datalog`:
re-checked, still last pushed 2024-02-14, one open issue, not archived —
dormant, unchanged from the prior check, worth another look immediately
before 6c actually depends on it rather than assuming continued dormancy.

**8.7 Versioning — liveness re-checked today.** TerminusDB: last pushed
2026-08-10 (~2.5 weeks ago), actively maintained. Fluree: last pushed
2026-08-27 (today), very actively maintained. Both current as of this
check; graph three-way merge is still weaker than git's (§6's DedupGate
`Merge` rule) regardless of either project's activity level.

**8.8 Parallelism.** Soufflé compiles `par...endpar` to OpenMP-annotated
C++ implementing semi-naive evaluation, backed by a concurrent B-tree and
Brie (a concurrent trie). Adoptable for QueryInterpretation.
ExecuteInterpretation concurrency has no equivalent answer (6d-ii).

**8.9 Signature morphisms vs. comorphisms.** A signature morphism is an
arrow within one institution's `Sign` category — translation within one
Dialect. A comorphism is categorically heavier (a functor between two
institutions' `Sign` categories plus natural transformations translating
sentences and models) — needed only crossing Dialects. The
sublogic/embedding/faithful/(weakly) exact scale is documented specifically
for comorphisms; same-institution signature-morphism quality uses
different vocabulary (model-conservativeness, Mod-strictness,
Sen-maximality). SSSOM connects formally to neither.

**8.10 Conflict resolution.** CLIPS's LEX strategy: recency before
specificity, specificity the final tiebreaker. StabilityClass is this
document's own extension to that ordering, not documented CLIPS behavior.

**8.11 Human review, UI, repo integration.** External research on
review-gate placement and generic-shape-driven UI came back empty twice.
Local precedent used instead: `scratch-command-bar`'s propose/review loop,
`graphsheet`'s shipped SHACL-driven UI. **This work should be added to
Riptide's `PROGRESS.md` sub-project table as Sub-project 6 no later than
6b's start** — concrete now that 1–5 are confirmed complete and the table
has an obvious next row.

## 9. Worked examples

**9.1 — the clean case.** Task "deploy the billing service" → no
CatalogEntry match → LLMFallback produces a ground Trace → not admitted
alone (§5) → weeks later, a second Task's Trace anti-unifies against the
first → DedupGate `Admit` with human review and sandboxed-replay fidelity
evidence → CatalogEntry `deploy-service-to-prod` → a third occurrence hits
Discovery's exact lookup directly, zero LLM calls.

**9.2 — the case that found real gaps: a German tax filing**, walked
through deliberately, not as a domain this spec builds. A fresh Tenant,
Task "file my tax return." LLMFallback needs, in order: (1) an
ObserveCapability check with its own ValidTime and recorded-response
Provenance (§4, §8.5); (2) gathering facts via the same
extraction-and-review loop `scratch-command-bar` uses — real content-layer
work, correctly out of scope; (3) an EffectCapability submission, where
two independently-viable implementations for the same outcome are resolved
by §6's existing Discovery mechanism (Signature preconditions for
eligibility, StabilityClass for trust ranking) with no new mechanism
needed; (4) composability via rule-reference literals, the bug this
example caught.

## 10. Open questions

- OpenFASTER-Standard public governance status for this work.
- Whether this engine is operationally a separate deployable from
  Riptide's LDP surface.
- Concurrent-effectful-execution coordination (6d-ii's actual subject
  matter).
- Whether the Rule/workflow-graph representation can be constrained to the
  bisimilar-term-graph fragment, or whether DedupGate must arbitrate a
  finite set of incomparable generalizations (§8.2).
- Formal versioning/supersedes theory for declarative rules — none found;
  pragmatic git/TerminusDB model adopted instead.
- Final Tenant name.
- `linkml-datalog`'s dormancy — re-check again immediately before 6c
  depends on it, not just at spec-writing time (§8.6).

## 11. Changelog

**This revision (third) — a currency pass, not new design work:**
- Restructured all phase numbering from independent "Sub-project 1–9" into
  a single **Sub-project 6** with phases 6a–6i, avoiding a real collision
  with Riptide's own `PROGRESS.md` table (its sub-projects 1–5, confirmed
  complete as of today, use exactly this numbering scheme already).
- Corrected Dialect (§3.2, §8.1): SHACL 1.2 Rules' current URL now
  redirects to SPARQL 1.2 RL — the two W3C drafts previously tracked as
  independent appear to have been consolidated. Target simplified to
  SPARQL-RL alone.
- Added the live audit-remediation caveat on Riptide's ACP/auth surface
  (§3.1) — observed directly as in-progress, uncommitted work on a sibling
  branch as of this writing.
- Noted 6a's dependency on the already-shipped Phase 3a schema-versioning
  envelope (§7), which exists specifically to handle a fact-shape change
  like this one safely.
- Re-verified liveness of `linkml-datalog` (unchanged, still dormant),
  TerminusDB (active), and Fluree (very active, pushed today) against
  their actual current state, not carried forward from an earlier check
  (§8.6, §8.7).
- Noted Riptide's own production-readiness roadmap (sub-projects 1–5) is
  now complete (§1) — this work is the first thing built on a finished
  foundation, not alongside an unfinished one.

**Second revision:** added the Pattern Hub and Crosswalk mechanism, split
Capability into Effect/Observe kinds, added rule-reference literals fixing
a real composability bug, corrected an institution-theory overreach
(Crosswalks are signature morphisms in the common case, not universally
comorphisms), added StabilityClass, and reframed `administration-commons`
as superseded.

**First revision:** fixed Rule's definition to accommodate NativeTemplate,
made Trace `⊑ Rule` with one consistent Generalization type signature,
reframed Generalization Fidelity from an inherited proof to an engineering
obligation, corrected the term-graph anti-unification citation and scope,
added tenant-scoping to Capability, split the wiring phase by risk, and
added a walking-skeleton milestone.
