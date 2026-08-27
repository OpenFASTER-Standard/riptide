# Derivation and Execution Layer — Architecture Design

**Status:** Draft, second substantive revision. This is one architecture spec
defining several sub-projects (§7) — each gets its own implementation plan
(`writing-plans`) when work on it starts. This revision adds the public
Pattern Hub and ontology Crosswalk mechanism, corrects a mis-scoped
institution-theoretic claim caught by dedicated verification, closes a real
consistency gap between observing external state and the fidelity
requirement, and folds `administration-commons` in as superseded rather than
something to reconcile with — see §10 for the itemized changelog.

## 1. Motivation and vision

Riptide today is an event-sourced fact store: an append-only, per-resource
log of RDF facts, with one hardcoded derivation. This spec adds the layer
that's structurally missing: a general **derivation and execution engine**,
so that "answer a question about the facts" and "cause an effect in the
world" become two interpretations of the same declarative object, evaluated
by one engine.

The organizing idea: **the atomic unit should have a stable identity, and
everything else should be a *view* derived from that identity, never the
identity itself.** This spec extends that discipline from facts to rules,
and — new in this revision — to the *vocabularies rules are expressed in*,
which is what §6 (Pattern Hub) and §6.5 (Crosswalks) are for. The same
underlying instinct shows up a third time there: when no existing bridge
covers something (no matching prior Trace, no matching CatalogEntry, no
matching Crosswalk), a human/direct-origination step fills the gap once, and
the bridge gets built incrementally from real use — never front-loaded.
That's not three separate design choices; it's one discipline, applied
consistently, which is itself evidence the design is coherent rather than a
pile of individually-plausible ideas.

**What's settled about deployment, and what isn't.** Settled: this layer
shares Riptide's Fact store, Rule representation, and Signature/Dialect
definitions as one substrate. Not settled, and not asserted here: whether
the engine runs in the same OS process as Riptide's existing LDP surface —
genuinely open, see §9.

## 2. Scope

**In scope:** the object model (§3–6), the grounding for each decision (§8),
two worked examples (§9), and the sub-project breakdown (§7).

**`administration-commons` note.** An earlier local project used the term
"pattern" for a similar idea and sketched its own kernel (content-addressed
store, Merkle log, WASI executor). It's superseded by this work, not
something this spec reconciles with — noted here once so a future reader
finding that repo isn't confused about which is current.

**Explicitly still open** (§9 for the full list): concurrent-effectful-
execution coordination; whether this engine is a separate deployable from
Riptide's LDP surface; formal versioning/supersedes theory for rules (a
pragmatic git-like model is adopted instead); the final Tenant name; and,
new in this revision, automated detection of ontology overlap (deliberately
out of scope *by design*, not by gap — see §6.5).

## 3. Core concepts — facts and rules

### 3.1 Fact, Event, Tenant

- **Fact** — an atomic RDF(-star) assertion in the EDB. Carries
  *TransactionTime* (from Riptide's sequence number) and optionally a
  *ValidTime* interval (RDF-star-annotated, §8.4). Produced by one **Event**.
- **Tenant** *(name TBD — shortlist: Polity, Enclave, Civitas, Demesne)* —
  an isolated administrative/institutional space. Facts, Rules,
  CatalogEntries, and Capabilities are all tenant-partitioned. A Capability
  grant in one Tenant is never exercisable by a Rule in another; this
  composes with Riptide's existing Phase 4c ACP authorization, not a
  parallel system.
- **A Tenant's vocabulary is observed, not declared.** No separate
  "ontology preference" object. Whichever Signature a Tenant's own Facts
  happen to already use *is* their working vocabulary for that area — it
  falls out of usage. A brand-new Tenant installing its first Pattern simply
  adopts that Pattern's native Signature; there's nothing to translate yet.
  This removes a concept ("domain area," "ontology preference") that isn't
  actually needed once Crosswalk resolution (§6.5) is field-level, not
  whole-ontology: two Signatures with zero overlapping predicates simply
  coexist, and Crosswalk resolution only engages where fields genuinely
  overlap.

### 3.2 Signature, Dialect, Rule

- **Signature** — a Rule's typed interface: its parameters and which
  predicates it reads/produces. Institution-theoretically, this is DOL's
  `Sign`, reused precisely — an arrow in one institution's `Sign` category
  (confirmed against Goguen & Burstall's own definition; see §8.1).
- **Dialect** — which concrete rule language a Rule is expressed in. Two
  candidates tracked in parallel, not one succeeding the other: **SPARQL-RL**
  and **SHACL 1.2 Rules**, both live W3C Working Drafts on the
  Recommendation track, developed in parallel by the Data Shapes Working
  Group. Reference evaluation engine: Soufflé's extended Datalog.
- **Rule** — a declarative IDB definition over a Signature: given a Body,
  conclude a Head. A Body is a conjunction of three literal kinds:
  - **Fact-pattern literals** — matched against the EDB, classical Datalog.
  - **Capability-reference literals** — a reference to a Capability (§4)
    that ExecuteInterpretation may invoke.
  - **Rule-reference literals** — a call to another Rule, with argument
    bindings. **Added in this revision, closing a real bug**: the previous
    version of this document restricted Body to the first two kinds, which
    made Rule composability — a Template calling other Templates, the whole
    point of the design — inexpressible. Caught by tracing a real scenario
    through the model (§9), not by re-reading the document.

## 4. Capability, NativeTemplate, Template

- **Capability** — an explicit, tenant-scoped, grantable permission. Split
  into two kinds, **new in this revision**, because collapsing them created
  a real inconsistency (§8.5, §9):
  - **EffectCapability** — changes something in the world (deploy a
    service). Fidelity replay-testing (§5) actually re-invokes it,
    sandboxed, and compares against the recorded Trace.
  - **ObserveCapability** — reads external state and asserts the result as
    new Facts, changing nothing external (check whether a filing already
    exists). Fidelity replay-testing does *not* re-invoke the real external
    system — the world isn't expected to be frozen between runs. It replays
    the response recorded in Provenance instead, and checks that downstream
    Rule logic behaves consistently given that recorded response. This
    means an ObserveCapability's Provenance must record the actual observed
    data, not just which capability was called with which parameters.
  - Both kinds carry a **StabilityClass** — `documented` (a stable, versioned
    public interface) or `undocumented` (a reverse-engineered or otherwise
    unversioned interface, liable to silent breakage). This doesn't solve
    fragility; it makes it visible and queryable. Discovery (§6) uses it as
    a ranking input alongside recency/specificity when multiple
    CatalogEntries could satisfy the same Task — this is not a new
    selection mechanism, it's one more input to the mechanism §6 already
    has.
  - Backed by WASI Preview 2 (no ambient authority, no subprocess spawning
    by design) plus WASIX where subprocess spawning is specifically
    granted (§8.3).
- **NativeTemplate** — a Rule whose Body is exactly one capability-reference
  literal. The base case, backed by a real, capability-scoped WASI
  component. Sequencing note: Sub-project 2 (§7) builds the WASI execution
  substrate standalone, with no Rule representation involved — it doesn't
  produce NativeTemplate instances yet, since NativeTemplate is a Rule and
  Rule's representation isn't built until Sub-project 3. Sub-project 4 is
  what wraps Sub-project 2's substrate as actual NativeTemplate instances.
- **Template** — `Template ⊑ Rule ⊓ (∃ a reachable step whose
  ExecuteInterpretation invokes a Capability)`. A structural (graph-
  reachability) predicate over the one Rule representation everything
  shares — not a separate primitive.

## 5. Trace, Generalization, Interpretation, Provenance

- **Trace ⊑ Rule** — a Rule whose Signature has no free parameters; every
  value already ground, from one concrete run.
- **Generalization — uniformly `Rule × Rule → Rule`.** Anti-unification
  (Plotkin 1970) computes the least-general-generalization of any two
  Rules, whether both ground, one ground and one not, or neither. One
  operation, one type signature, used identically wherever it appears in
  §6's pipeline. Always accompanied by the recovering substitutions and by
  mandatory **Provenance**.
- **Admission consequence**: a Rule generalized from only one Trace (still
  ground, zero free parameters) is not admissible anywhere — a
  zero-parameter "template" isn't reusable. Admission (§6) requires at
  least one real Generalization step.
- **Interpretation** — `(Rule, Bindings, EDB-state) → Outcome`. At least
  **QueryInterpretation** (pure, Outcome ⊑ new Facts, capability-reference
  literals inert) and **ExecuteInterpretation** (capability-reference
  literals actually invoked; Outcome may include both effects and, for
  ObserveCapability steps, newly-observed Facts — the same shape
  QueryInterpretation produces, just externally sourced). More modes
  expected later (dry-run, cost-estimate, explain/audit). Algebraic
  effects/handler theory is the closest established formalism for this
  shape; neither it nor tagless-final is a proof this specific design is
  correct — real inspiration, not borrowed authority (re-verified in an
  earlier pass of this process, not this revision's final one).
- **Generalization Fidelity — an engineering requirement, not an inherited
  proof.** Anti-unification proves syntactic recoverability of term
  structure, not semantic reproduction of real-world effects. The actual
  requirement: for a Generalization `g` from Traces `t₁, t₂` with
  substitutions `σ₁, σ₂`, `ExecuteInterpretation(g, σᵢ)` should reproduce
  `tᵢ`'s effects, verified by sandboxed replay-testing — with the kind-
  specific replay semantics from §4 (EffectCapability re-invoked and
  compared; ObserveCapability replayed from its recorded response, never
  re-queried live). Capabilities that can't be safely replay-tested at all
  (destructive, non-idempotent) may need to stay ungeneralized, or require
  the human reviewer (§6) to certify fidelity manually. Real engineering,
  scoped to Sub-project 5, not resolved here.
- **Provenance** — the dependency edge back to what a Rule was generalized
  or installed from (§6.5). What keeps a derived Rule from becoming an
  ungoverned second source of truth.

## 6. Catalog, DedupGate, Discovery, Task, LLMFallback, Pattern

**Catalog is parameterized by scope: `Tenant` or `Hub`.** This is new in
this revision and replaces an earlier, unresolved question about whether
the public hub needed its own separate curation mechanism — it doesn't. One
mechanism, two scopes:

- **DedupGate** — anti-unifies a freshly-generalized candidate against its
  Catalog (whichever scope) and yields `Reject`, `Merge`, or `Admit`. Both
  `Admit` and `Merge` require human review before the result is live —
  `Admit` because review-before-entry is the working precedent this whole
  process already established (`scratch-command-bar`'s propose/review
  loop); `Merge` additionally because graph three-way merge is provably
  weaker than git's — RDF's unordered-set structure lets adds/removes
  combine mechanically without ever raising a syntactic conflict, silently
  producing a semantically wrong result. `Reject` skips review.
- **CatalogEntry** — `⊑ Rule`, admitted or merged by DedupGate, subject to
  §5's admission consequence.
- **Pattern is not a separate type.** It's the name for a CatalogEntry at
  **Hub** scope — a published, human-validated, publicly-installable unit.
  Everything else about it (Signature, Dialect, Body, Provenance) is
  ordinary CatalogEntry structure. Reusing "Pattern" as a name (not a new
  formal type) matters for a concrete reason: this generalizes to *any*
  computer-doable action — "extract page 2 of this PDF" is as much a
  Pattern as a tax-form submission is — and giving it a second, narrower
  formal type would misrepresent that scope.
- **Discovery** — search over CatalogEntry (either scope). Two
  sub-capabilities with different readiness: exact/keyword lookup (viable
  as soon as any CatalogEntry exists) and hybrid keyword+embedding
  progressive disclosure (once the catalog is large). Conflict resolution
  when multiple entries match: recency, then StabilityClass (§4), then
  specificity as final tiebreaker — extending, not replacing, CLIPS's LEX
  precedent (recency before specificity) with the one new ranking input
  this revision added.
- **Task** — the entry point. Triggers Discovery against the Tenant's own
  Catalog; a confident match invokes that CatalogEntry directly; no match
  triggers **LLMFallback**, whose resulting Trace feeds Generalization →
  DedupGate (Tenant scope) → possibly a new local CatalogEntry.
- **Install** — `CatalogEntry(Hub) × Tenant → CatalogEntry(Tenant)`, the
  operation for adopting a public Pattern (§6.5 covers the mechanism in
  full). Its result goes through the same DedupGate as any other candidate
  entering the Tenant's local Catalog — review scope is narrower than a
  fresh `Admit` (confirming the specific field bindings are correct for
  this Tenant, not re-reviewing content the Hub already curated), but it's
  the same gate, not a separate mechanism.

### 6.5 Crosswalk — corrected from an earlier draft's overreach

Installing a Hub Pattern against a Tenant whose own vocabulary differs
requires translating some of the Pattern's Signature fields. What that
translation actually *is*, formally, was mis-scoped in an earlier version
of this document and has now been checked properly rather than asserted:

- **When the Pattern and the Tenant's existing vocabulary share a Dialect**
  (both SPARQL-RL, say), the correct formal tool is a **signature
  morphism** — an arrow within one institution's `Sign` category. This is
  established, textbook institution theory (confirmed against Goguen &
  Burstall's own definition), and it is *already in this document's own
  vocabulary* — it's the same kind of thing Signature itself already is.
  No new borrowed machinery needed. If a signature morphism's soundness
  needs checking, the literature's own vocabulary for that is model-
  conservativeness / Mod-strictness / Sen-maximality — not the
  sublogic/embedding/faithful/exact scale, which is documented specifically
  for the next case, not this one.
- **When the Pattern and the Tenant's vocabulary are in *different*
  Dialects** (one SPARQL-RL, one SHACL 1.2 Rules), the correct tool is a
  full **comorphism** — categorically heavier (a functor between the two
  Dialects' `Sign` categories plus natural transformations translating
  their sentences and models), and *this* is where the
  sublogic/embedding/faithful/(weakly) exact fidelity scale actually
  applies, per DOL's own worked practice.
- **An earlier draft of this document proposed modeling all Crosswalks as
  comorphisms and borrowing that fidelity scale universally. Checked
  directly against the primary institution-theory literature: that's
  wrong** for the (more common) same-Dialect case, and the correction
  matters — it's the difference between reaching for machinery that's
  already sitting in this document (a signature morphism, essentially a
  second Signature with a translation) versus machinery that's
  categorically heavier and was never actually needed for most Crosswalks.
- **The human-facing representation, regardless of which formal case
  applies, is SSSOM** — `exact_match`/`close_match`/`broad_match`/
  `narrow_match`/`related_match`, each with a curator's confidence. This is
  the right layer for the actual working mechanism, and it composes
  cleanly with the formal distinction above rather than competing with it:
  SSSOM's own specification is explicit that these are practical,
  curatorial judgments calibrated to "fitness for purpose," *not* claims of
  model-theoretic equivalence — checked directly against SSSOM's own paper,
  which discusses DOL by name in its related work and never once invokes
  institution theory, confirming the two are genuinely separate layers, not
  one dressed as the other. A human curating an `exact_match` is making a
  practical judgment call, available for later, optional strengthening
  into a formally-checked signature morphism or comorphism if anyone
  wants that — never a prerequisite for using the mapping.
- **Detection of overlap is human-only, by design, for now** — not a gap to
  fill later with automated ontology-alignment matching, a deliberate
  scoping decision. A curator proposes a Crosswalk entry (an SSSOM mapping
  row); it goes through the same Hub-scope DedupGate as any other Hub
  content.
- **Crosswalks are Hub-scope content** (a mapping between two named
  standards is a general, reusable fact, not tenant-specific); which
  vocabulary a given Tenant has actually settled into, per §3.1, is the one
  genuinely tenant-local fact.
- **Installation with partial coverage** — the actual mechanism, precisely:
  for each field in the Pattern's Signature, look up an existing Crosswalk
  entry against the Tenant's own established vocabulary. Matched fields
  bind through the Crosswalk. **Unmatched fields — no Crosswalk entry
  exists yet — the Tenant is prompted to supply those Facts directly**, in
  the Pattern's own native vocabulary, since there's nothing to translate
  from. This is recorded as manually-originated Provenance, not a
  translation. Crosswalks grow incrementally from real installation
  friction — the same anti-Xanadu discipline ("the graph should grow from
  real transactions, not an a priori exhaustive ontology") already applied
  to Traces (§5) and Tasks (§6), applied a third time here. For a Pattern
  with a thin, largely-uncontested Signature (page-extraction-shaped
  actions), this degrades to zero friction — most fields hit exact matches,
  nothing left to fill in by hand. It only gets elaborate where a domain
  genuinely has competing standards, which is a property of the domain, not
  a cost the mechanism imposes uniformly.

## 7. Sub-projects

Each of these becomes its own spec → plan → implementation cycle when work
on it starts; this document defines their scope and dependencies, not their
detailed plans.

1. **Bitemporal fact shape.** RDF-star `validFrom`/`validTo`, a defined
   OWL-Time Allen-relation subset, ValidTime defaulting to TransactionTime.
   Applies to Riptide's existing LDP write path. Depends on nothing but
   Riptide as it exists today. Detailed scope: §9.1... *(unchanged from the
   prior revision; kept minimal here since it's already fully specified and
   nothing in this revision touches it)*. Deferred to Sub-project 3+:
   making ValidTime queryable/joinable in rule logic.
2. **Execution substrate.** WASI component execution, WASIX capability
   grant, **tenant-scoped and split into EffectCapability/ObserveCapability
   from the start** (§4) — new requirement in this revision. Must produce
   the integration point with Riptide's Phase 4c ACP model as an exit
   criterion, not a follow-up. Tested with no Rule representation involved.
3. **Pure derivation engine.** Cross-stream joins, recursion, aggregation,
   query interpretation only. Depends on Sub-project 1.
4. **Wiring**, split by risk:
   - **4a — mechanical wiring.** Execute interpreter, real NativeTemplate
     instances, `call_template` against a small hand-authored set. Low
     risk.
   - **4b — concurrent-effects design spike.** No established theory
     answers coordinating concurrent ExecuteInterpretations over
     overlapping, irreversible resources (checked: neither sagas nor CRDTs
     establish this). Real, open design work, not a checklist item inside
     4a.
5. **Generalization and DedupGate**, including replay-testing fidelity with
   the kind-specific (Effect vs. Observe) semantics from §4. Depends on 4a.
6. **LLM fallback loop.** OAuth ported to Elixir by hand (no ecosystem to
   lean on — `lambdaclass/datalog` dead, `fogfish/datalog` real but
   dormant since 2019). Needs Sub-project 5's gate to have somewhere to put
   its output.
7. **Discovery**, split by readiness:
   - **7a — exact/keyword lookup**, viable as soon as any CatalogEntry
     exists (as early as Sub-project 5) — a real walking skeleton well
     before the rest of the roadmap ships.
   - **7b — hybrid keyword+embedding progressive disclosure**, deferred
     until the catalog is large enough to need it.
8. **Pattern Hub.** **New in this revision.** Stand up Hub-scope Catalog
   (§6) as a distinct, publicly-reachable deployment of the same DedupGate
   mechanism Sub-project 5 already builds — genuinely low new-mechanism
   risk, since it reuses rather than duplicates. Depends on Sub-project 5.
9. **Ontology Crosswalks and Installation.** **New in this revision.**
   SSSOM-shaped Hub-scope Crosswalk content, the Install operation (§6.5),
   and the human-curation workflow for proposing Crosswalk entries. Depends
   on Sub-project 8. The signature-morphism/comorphism distinction (§6.5)
   only needs to inform how Crosswalk correctness is *reasoned about* when
   questioned — the day-to-day mechanism is SSSOM curation plus DedupGate,
   which Sub-project 8 already provides.

**Ongoing, not sequential:** LinkML authoring applied to each new schema as
created (§8.6).

## 8. Grounding

**8.1 Rule dialects.** Institution theory covers Horn Clause Logic as a
genuine sub-institution of first-order logic (Diaconescu 2006). Soufflé's
extended Datalog and both target Dialects go beyond pure Horn Clause Logic —
the institution-theoretic grounding covers their Horn-clause core, not
their full extent; stated honestly rather than left implicit. Soufflé's
hard requirement that user-defined functors stay pure and reentrant remains
real, independent validation that effects belong in a separate interpreter.

**8.2 Anti-unification.** Plotkin/Reynolds (1970): flat first-order
syntactic anti-unification, proven unitary. Term-graph anti-unification is
a *different* result (Baumgartner, Kutsia, Levy & Villaret, FSCD 2018),
proving the general case only **finitary** (a finite, possibly-plural set
of incomparable generalizations), with unitarity proven only for the
narrower bisimilar-term-graph case. Open question this creates, unresolved:
whether the Rule/workflow-graph representation can be constrained to that
narrower fragment, or whether DedupGate genuinely needs to arbitrate among
several incomparable candidates. Minimizing generalization variables is
NP-complete in the closest scalable formalism (Yernaux & Vanhoof 2022) —
accept bounded/greedy generalization regardless.

**8.3 Execution kernel.** WASI Preview 2 excludes fork/exec/subprocess
spawning by design; WASIX is the separate superset restoring it. Kernel
primitive: execute a capability-scoped WASM component; subprocess spawning
one optional grantable capability among others.

**8.4 Bitemporal facts.** Datomic is unitemporal; XTDB's two-axis model
(system transaction-time, user-assigned valid-time) is the target shape,
via RDF-star + OWL-Time. Valid-time must be duplicated into ordinary
queryable fact form for the derivation layer to reason over it.

**8.5 Capability kinds — new grounding this revision.** The
EffectCapability/ObserveCapability split wasn't researched against external
literature; it fell directly out of tracing a real scenario (§9.2) through
the model and finding that "replay this to check fidelity" means two
different things depending on whether the capability changes the world or
just reads it — re-querying a live external system during a fidelity check
would fail spuriously whenever that system's real state has simply moved on
since the original Trace, which isn't a fidelity failure at all. This is
this document's own synthesis, not a citation, and is presented as such.

**8.6 Authoring.** LinkML adopted for Sub-project 3's rule schema and
Sub-project 8/9's Pattern and Crosswalk schemas specifically —
`linkml-datalog` (real, alpha, dormant since Feb 2024 at last check, worth
a fresh liveness check before depending on it) already demonstrates
"author in LinkML, generate a working Soufflé Datalog program" as a working
pattern, not a hypothesis.

**8.7 Versioning.** TerminusDB and Fluree implement git's model over graph
data; graph three-way merge is weaker than git's (§6's DedupGate `Merge`
rule). Maintenance-status claims about both projects are time-sensitive and
worth a fresh check before Sub-project 6 planning.

**8.8 Parallelism.** Soufflé compiles `par...endpar` to OpenMP-annotated
C++ implementing semi-naive evaluation, backed by a concurrent B-tree and
Brie (a concurrent trie). Adoptable for QueryInterpretation.
ExecuteInterpretation concurrency has no equivalent answer (§7, Sub-project
4b).

**8.9 Signature morphisms vs. comorphisms — the correction driving §6.5.**
Confirmed directly against Goguen & Burstall's own definitions and
follow-on literature (Diaconescu; the 2-institutions literature): a
signature morphism is an arrow within one institution's `Sign` category — a
translation within one Dialect. A comorphism is a categorically heavier
triple (a functor between two institutions' `Sign` categories, plus natural
transformations translating their sentences and models) — needed only when
crossing between genuinely different Dialects. The
sublogic/embedding/faithful/(weakly) exact fidelity scale is documented
specifically for comorphisms; same-institution signature-morphism quality
uses different, unrelated vocabulary (model-conservativeness,
Mod-strictness, Sen-maximality) in the literature that actually works
within one institution. SSSOM's own specification frames its match
predicates as practical/curatorial ("fitness for purpose," explicitly not
correctness), and no citable work connects SSSOM/SKOS mappings to
institution-theoretic morphisms of either kind — confirmed by a direct
search of SSSOM's own paper, which discusses DOL by name in its related
work without ever invoking institution theory.

**8.10 Conflict resolution.** CLIPS's LEX strategy: recency checked before
specificity, specificity the final tiebreaker. StabilityClass (§4) is a new
ranking input this revision adds ahead of specificity, not documented CLIPS
behavior — this document's own extension, stated as such.

**8.11 Human review, UI, repo integration.** External research on
review-gate placement and generic-shape-driven UI came back empty twice —
a real signal, not bad luck. Local precedent used instead:
`scratch-command-bar`'s propose/review loop, `graphsheet`'s shipped
SHACL-driven UI. This layer should be reflected in Riptide's own
PROGRESS.md sub-project table no later than Sub-project 2's start.

## 9. Worked examples

**9.1 — the clean case (unchanged from the prior revision).** Task "deploy
the billing service" → no CatalogEntry match → LLMFallback produces a
ground Trace → not admitted alone (§5) → weeks later, a second, similar
Task's Trace anti-unifies against the first, producing a genuinely
parameterized candidate → DedupGate `Admit` with human review, including
sandboxed-replay fidelity evidence → becomes CatalogEntry
`deploy-service-to-prod` → a third occurrence hits Discovery's exact lookup
directly, zero LLM calls.

**9.2 — the case that found real gaps: a German tax filing, walked through
deliberately, not as a domain this spec builds.** A fresh Tenant, Task
"file my tax return." Discovery finds nothing (empty Catalog). LLMFallback
doesn't decompose this into one Trace — it needs, in order:

1. **An ObserveCapability check**: has this year's filing already been
   submitted? Queries the external tax authority, asserts the answer as a
   new Fact with its own ValidTime (per §8.4, distinct from when Riptide
   learned it). This Fact's Provenance records the actual response, so a
   later fidelity replay of any Rule built from this Trace replays that
   recorded answer rather than re-querying — the real external system
   isn't expected to still say the same thing days or months later, and
   that's not a fidelity failure (§4, §8.5).
2. **Gathering the actual facts to file** — no existing Signature in this
   ecosystem covers personal income tax; the Tenant supplies them via the
   same extraction-and-review loop `scratch-command-bar` already uses. This
   is real content-layer work this spec doesn't provide, correctly out of
   scope (§2) — but the example is worth keeping precisely because it shows
   *how much* has to exist before "file my tax return" can complete on a
   fresh instance, which the simpler §9.1 example doesn't reveal.
3. **An EffectCapability submission.** Two independently-viable
   implementations exist in principle for the same real-world outcome — a
   documented official interface and a reverse-engineered one — exactly
   the shape Discovery's own multi-match resolution (§6) already handles:
   eligibility differences show up as Signature preconditions (a documented
   path's CatalogEntry requires a Fact this Tenant may or may not have),
   and StabilityClass (§4) correctly ranks the documented path over the
   reverse-engineered one when both apply. No new mechanism needed —
   genuine validation that §6's existing machinery covers this, not a gap.
4. Composability (§3.2's rule-reference literals, fixed in this revision)
   is what lets a `file-annual-return` Rule call a `submit-return` Rule
   that calls a lower-level submission NativeTemplate — the bug this
   example caught when it was still missing.

Nothing about German tax law is proposed as part of this spec's own
deliverables; this example exists to stress-test the object model against
something with real regulatory weight, external system fragility, and
composability requirements a purely infrastructural example wouldn't
surface.

## 10. Changelog

**This revision (second):**
- Rule's Body gained a rule-reference literal kind — composability was
  inexpressible without it, caught by §9.2.
- Capability split into EffectCapability/ObserveCapability with distinct
  fidelity-replay semantics — caught by the same trace.
- StabilityClass added, feeding Discovery's existing conflict resolution.
- Catalog generalized to Tenant/Hub scope; Pattern defined as a name for
  Hub-scope CatalogEntry, not a new type.
- Crosswalk mechanism added: SSSOM as the working representation;
  signature morphisms for same-Dialect translation (corrected from an
  earlier, wrong instinct to model all of this as comorphisms); comorphisms
  reserved for genuinely cross-Dialect translation, with the
  sublogic/embedding/faithful/exact scale now correctly scoped to that case
  only.
- Sub-projects 8 and 9 added; the whole document restructured as one spec
  defining many sub-projects rather than a single phased roadmap.
- `administration-commons` reframed as superseded, not something to
  reconcile with.

**Prior revision:** fixed Rule's definition to accommodate NativeTemplate,
made Trace `⊑ Rule` with one consistent Generalization type signature,
reframed the Generalization Fidelity requirement from an inherited proof to
an engineering obligation, corrected the SPARQL-RL/SHACL 1.2 Rules
relationship, corrected the term-graph anti-unification citation and scope,
added tenant-scoping to Capability, split the wiring phase by risk, and
added a walking-skeleton milestone before the end of the roadmap.
