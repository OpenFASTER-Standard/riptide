# Derivation and Execution Layer — Architecture Design

**Status:** Draft, fifth revision — a dedicated research pass grounding
§3.3 (large objects) and §4's daemon-capability gap together, per explicit
direction not to treat them as separate concerns (§8.12). This is one
architecture spec defining a single new top-level Riptide sub-project,
**Sub-project 6**, decomposed into phases 6a–6i, the same way Riptide's
own sub-projects 3, 4, and 5 are already decomposed. Each phase gets its
own implementation plan (`writing-plans`) when work on it starts. See §11
for the itemized changelog across all five revisions.

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

**Deployment — resolved this revision.** This layer shares Riptide's Fact
store, Rule representation, and Signature/Dialect definitions as one
substrate, **and runs in the same OS process as Riptide's existing LDP
surface** — one deployable, not a companion service. No separate
scheduling, no separate deploy pipeline, no second thing to keep
available.

## 2. Scope

**In scope:** the object model (§3–6), the grounding for each decision
(§8), two worked examples (§9), and Sub-project 6's phase breakdown (§7).

**`administration-commons` note.** An earlier local project used the term
"pattern" for a similar idea and sketched its own kernel. Superseded by
this work, not something this spec reconciles with.

**Explicitly still open** (§10 for the full list): concurrent-effectful-
execution coordination (confirmed this revision as real design work owed
here, not a literature gap to close by more research); the bisimilar-
term-graph constraint question; formal versioning/supersedes theory for
rules; large-object/persistent-capability engineering details (§3.3, §4,
§8.12 — the formal grounding is now confirmed, the concrete
representation isn't); automated detection of ontology overlap (out of
scope *by design*, §6.5).

## 3. Core concepts — facts and rules

### 3.1 Fact, Event, Tenant

- **Fact** — an atomic RDF(-star) assertion in the EDB. Carries
  *TransactionTime* (from Riptide's sequence number) and optionally a
  *ValidTime* interval (RDF-star-annotated, §8.4). Produced by one **Event**.
- **Tenant** *(name settled this revision — "Tenant" itself, no rename)* —
  an isolated administrative/institutional space. Facts, Rules,
  CatalogEntries, and Capabilities are all tenant-partitioned. A Capability
  grant in one Tenant is never exercisable by a Rule in another; this
  composes with Riptide's shipped Phase 4c ACP authorization (default-deny,
  container-level inheritance, deny-overrides-allow, tenant-root bootstrap
  claim — confirmed accurate against the shipped design, `PROGRESS.md`
  §4), not a parallel system. **Current note, updated this revision**: the
  security-audit remediation flagged as in-progress on a sibling branch in
  the prior revision has since landed on `main` (three parts: auth/authz,
  Ra error handling, resource limits, and observability; dual-leader
  repair fencing; closing the SSE/WS `Authz.evaluate` placement-down gap —
  merged via PR #32) — as regular commits, not its own committed design
  spec. Sub-project 6b's integration point should target this now-current
  ACP surface directly.
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

### 3.3 Large objects (blobs) — direction confirmed by research this revision

**The problem, stated plainly.** Every Fact today is a small RDF triple,
replicated through a per-stream Ra (Raft) cluster's consensus log. A
multi-MB/GB blob (a PDF a Capability extracted a page from, a submitted
tax form, an uploaded file) does not belong directly in that log — every
replica would need to push the full blob through consensus on every
write, and Ra's own snapshots would grow with it. This needs solving
without introducing an external blob-storage service (S3-shaped or
otherwise) as a second system operators must run and keep available
alongside Riptide, and without blobs feeling bolted-on rather than a
first-class Riptide concept.

**Direction confirmed by a dedicated research pass this revision (§8.12
for full grounding):** split identity from bytes, the same way this whole
document already treats every other layer (§1's organizing idea). A blob
is content-addressed (hashed) and immutable once written; a Fact
references it by hash (e.g. `<urn:riptide-blob:sha256:...>`), making a
blob just another kind of Term any Rule or Fact can point at. The small
hash-pointer goes through Riptide's existing per-stream Ra log exactly
like any other RDF triple value; the actual bytes live in an ordinary,
independently-replicated, content-addressed local store that no single
replication mechanism needs to fully mirror everywhere — confirmed as the
real, convergent architecture across git, casync/desync, and IPFS/UnixFS
(content-defined chunking, e.g. casync/desync's buzhash with a 16KB/64KB/
256KB min/avg/max window; strong content-hash naming; chunk storage
deliberately decoupled from the pointer/index structure that names them).
Mainstream Raft-based stores (etcd, TiKV, CockroachDB) were checked and
confirmed to *discourage or hard-limit* large values through consensus
(etcd's default max request size is 1.5MiB) rather than solving this
themselves — validating the premise that a genuinely separate mechanism
is needed, without supplying one ready-made.

**A concrete production precedent for the chunk-store-plus-GC half of
this** exists in Riak CS (discontinued — historical precedent, not a
currently-maintained reference implementation): objects split into fixed
1MB blocks keyed by `{UUID, BlockId}`, with garbage collection driven by
an explicit manifest state machine
(`writing → active → pending_delete → scheduled_delete`) plus a dedicated
GC bucket scanned by a background process. Shared-log/consensus systems
(CORFU, Delos) independently confirm the same shape at a different layer:
a lightweight ordering/coordination step (CORFU's sequencer just hands
out position tokens) stays separate from the bulk data plane (clients
read/write flash units directly), with garbage collection via trim-plus-
watermark rather than synchronous cross-replica compaction.

**Connects directly to §4's daemon-capability question — see §8.12's
verdict.** In every one of these precedents, the component clients
actually talk to for bulk reads/writes is a **long-running, supervised,
directly-addressable server process** — never a one-shot invocation. That
is structurally the same shape §4 needs for a persistent capability like
"serve this content over HTTP." Riptide's own blob store should be built
as one privileged, built-in instance of that same supervised-process
lifecycle pattern (a GenServer/supervision-tree-managed chunk store, hash-
pointer metadata replicated via Ra) — **not** by routing blob storage
through the general-purpose, tenant-facing, WASI-sandboxed Capability
path meant for untrusted third-party code. "The blob store literally is a
WASI capability grant" is the wrong framing; "both need the same
supervised-long-running-process primitive underneath" is the right one.

**Still genuinely open** (§10): a concrete garbage-collection/reference-
counting scheme for the case this document's own EDB actually creates —
many RDF triples referencing the *same* chunk hash, unlike the
object-store/shared-log semantics every precedent above was built for;
what security boundary/tenant-scoping governs the privileged blob-serving
process itself, given it sits outside the general WASI sandbox by design;
and whether WASI Preview 2 (or later) has any native notion of a
persistent/resumable component instance that could simplify this, which
this pass could not confirm either way.

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
  - **A universality check surfaced a real gap, now grounded by research
    (§8.12).** "File a tax return," "extract page 2 of a PDF," and "serve
    this web page over HTTP" should all be expressible as Capabilities —
    that's the whole point of the model's generality, not a feature to add
    later. The first two are one-shot: invoke, get a discrete Outcome,
    done — exactly what `(Rule, Bindings, EDB-state) → Outcome` (§5)
    already models. "Serve this page" is not: it's a long-running,
    continuously-listening process serving arbitrarily many requests over
    its lifetime. **The formalism that actually fits this shape is session
    types with runtime adaptation (Di Giusto & Pérez), not an extension of
    the algebraic-effect/handler theory §5 already leans on for one-shot
    Interpretations** — no confirmed literature extends effect-handler
    theory to persistent effects, but this process-calculus line proves
    exactly the safety property a revocable, tenant-scoped long-running
    Capability needs: an update/restart action on a running process is
    only permitted when it isn't currently mid-session, so a long-running
    Capability can be replaced or revoked without corrupting in-flight
    requests. The same paper directly works out Erlang/OTP supervision
    trees as a formal example of this calculus — both `one_for_one` and
    `one_for_all` restart strategies typed within it — giving a real,
    citable bridge between this theory and `Riptide.Stream.StreamServer`'s
    own supervision-tree shape, not an analogy this document is making
    unaided. A long-running Capability's implementation is a supervised
    OTP process wearing a Capability grant, typed for exactly this
    adaptation safety property. Whether that's a second Capability
    dimension (e.g. `Ephemeral` vs `Persistent`, alongside StabilityClass)
    or something structurally different is still open (§10) — this
    revision confirms the right formal grounding, not the concrete
    representation.
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

**8.7.1 Formal supersedes theory — real anchors found this revision, no
exact fit.** A dedicated research pass (four angles, 20 primary sources,
25 claims adversarially verified) found two genuine formal theories in
this space, and closed off one dead end:

- **AGM/Katsuno-Mendelzon logic-program-update theory is real, peer-reviewed,
  and still actively cited (2007–2023)** — Delgrande/Peppas/Woltran (LPNMR
  2013) rephrase the AGM postulates for logic programs with SE-model-based
  semantic revision operators and representation theorems by program class;
  Slota & Leite (TPLP 2014) adapt Katsuno-Mendelzon's postulates to
  answer-set-program *update* specifically, with a constructive
  representation theorem. This is the closest existing formalism to "what
  does it mean to update a rule set given a new rule" found anywhere in
  this research. **But it comes with a proven limitation, not just a
  caveat**: Slota & Leite's Theorem 31 proves any SE-model/KM-based ASP
  update operator satisfying syntax-independence cannot simultaneously
  satisfy both the *support* and *fact update* properties — a real
  adequacy ceiling on this branch of theory, to design around rather than
  discover the hard way.
- **Description-logic conservative-extension/inseparability theory was
  directly extended in 2022 to existential rules (TGDs)** — Jung, Lutz &
  Marcinkowski (KR 2022) give two independent formal criteria (conjunctive-
  query-answer preservation; chase-homomorphism preservation) for whether
  one TGD set safely extends another, the closest syntactic match to
  Datalog-style rules found. Decidable only for restricted fragments
  (e.g. frontier-one TGDs) — undecidable in general (linear/guarded TGDs).
  This formalizes *safe extension without changing prior entailments*, not
  a directional generalize/refine "supersedes" relation — a real, useful,
  but different question than the one this spec actually has.
- **Patch theory (categorical and homotopical/HoTT formalizations of
  Darcs) is a confirmed non-fit, not an unexplored option.** Every formal
  object and worked example across four primary sources is generic
  text/structured data (lines, integers, boolean lists) — zero mentions of
  rules, logic programs, ontologies, or knowledge bases anywhere in the
  primary literature. Its only notion of combining changes (merge as
  categorical pushout) is symmetric, not the directional relation needed
  here. Should not be revisited as a lead without new information.
- **No rigorous, non-conventional theory of breaking-vs-compatible
  schema/rule change was found** — a genuine gap in what this pass
  surfaced, not proof none exists; it may hide under different
  terminology (view update problem, schema mapping evolution, Horn/rule
  theory revision) a future pass should search directly.
- **The most promising unexplored angle, surfaced by this research but not
  itself researched yet:** anti-unification's own literature (Plotkin's
  least-general-generalization, Inductive Logic Programming's
  generalization/specialization lattices under θ-subsumption) may connect
  *directly* to a formal subsumption ordering between rules — closer to
  this spec's actual mechanism (§5's Generalization) than either DL/TGD or
  AGM/KM, and not covered by any of the four angles this pass researched.
  Worth its own dedicated pass before concluding no exact fit exists
  anywhere.

Net: no single existing formalism directly answers "rule B (refined)
supersedes rule A (generalized)" — the pragmatic git/TerminusDB-style
model stays the adopted approach, but AGM/KM update theory and TGD
conservative-extension are now real candidate anchors to build a more
rigorous foundation on later, and ILP's own generalization-lattice
literature is the most promising unexplored lead.

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

**8.12 Large objects and persistent capabilities — researched together
this revision, per explicit direction not to treat them as separate.** A
dedicated research pass investigated both §3.3 and §4's daemon-capability
gap as one question, since a native blob store and a long-running
capability are plausibly the same underlying problem. 18 underlying
claims individually passed adversarial verification (mostly 3-vote,
primary sources: official docs, project wikis, peer-reviewed papers).

- **Blob architecture**: Ra (this project's own Raft library) already
  implements chunked, non-blocking transfer for its *internal* consensus
  snapshots — `ra_snapshot`'s leader-side `begin_read`/`read_chunk` and
  follower-side `begin_accept`/`accept_chunk`/`complete_accept`, with
  integrity validation. Real BEAM-ecosystem precedent, but scoped to Ra's
  own snapshots, not a general blob API — suggestive, not ready-made.
  Content-addressed chunking (git, casync/desync, IPFS/UnixFS) converges
  on one architecture: content-defined chunks named by a strong hash,
  stored as independently-addressable objects, with the pointer/index
  structure that names them deliberately decoupled from chunk storage.
  Riak CS (discontinued; historical precedent) is the closest concrete
  precedent for the *whole* shape: fixed blocks keyed by `{UUID,
  BlockId}`, garbage-collected via an explicit manifest state machine.
  CORFU/Delos confirm the same separation at the consensus layer:
  lightweight ordering stays separate from the bulk data plane, GC via
  trim-plus-watermark rather than synchronous cross-replica compaction.
- **Persistent-capability formalism**: session types with runtime
  adaptation (Di Giusto & Pérez, arXiv:1312.2699) — not algebraic-effect
  handler theory, which no confirmed source extends to persistent effects
  — proves the safety property this needs: an update/restart action on a
  running process is only valid when it isn't mid-session. The same paper
  formalizes Erlang/OTP supervision trees (both `one_for_one` and
  `one_for_all` restart strategies) as a worked example of this exact
  calculus — a genuine, citable bridge from capability-lifecycle theory to
  OTP semantics, not an analogy invented for this document.
- **Connecting verdict** (medium confidence — a synthesis across two
  source clusters, not itself one independently-verified claim): the two
  problems need the *same* underlying primitive — a supervised, long-lived,
  directly-addressable process with a revocable/restartable lifecycle —
  but a native blob store should **not** be literally implemented as an
  instance of the general-purpose, tenant-facing, WASI-sandboxed
  Capability abstraction meant for untrusted third-party code. It should
  be a privileged, built-in instance of the *same* supervision/lifecycle
  formalism a persistent Capability would also use. "The blob store is a
  WASI capability grant" is false; "both need the same supervised-process
  primitive underneath" is real and load-bearing.
- **Explicitly unresolved by this pass**: whether WASI Preview 2 (or
  later) has any native notion of a persistent/resumable component
  instance, as opposed to strict instantiate-call-terminate — no claim
  survived verification either way; whether the RabbitMQ/Ra maintainer
  team has ever discussed blob co-location with Raft-backed metadata
  beyond Ra's own internal snapshot-chunking — no claim surfaced; a
  concrete garbage-collection scheme for the case this document's own EDB
  actually creates (many RDF triples referencing the *same* chunk hash,
  unlike the object-store/shared-log semantics every precedent above was
  built for); and what security boundary governs the privileged
  blob-serving process itself, given it sits outside the general WASI
  sandbox by design.

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

**Resolved this revision** (kept here, struck through, rather than
deleted silently — see §11's changelog for the full reasoning):
- ~~Final Tenant name~~ — resolved: **"Tenant"**, no rename.
- ~~OpenFASTER-Standard public governance status~~ — resolved:
  **Riptide-internal for now**, not public/OpenFASTER-Standard governance.
- ~~Whether this engine is a separate deployable from Riptide's LDP
  surface~~ — resolved: **same OS process**, one deployable (§1).

**Still open:**
- Concurrent-effectful-execution coordination (6d-ii's actual subject
  matter) — confirmed this revision as real design work owed directly by
  this project, not a literature gap a further research pass would close.
- Whether the Rule/workflow-graph representation can be constrained to the
  bisimilar-term-graph fragment, or whether DedupGate must arbitrate a
  finite set of incomparable generalizations (§8.2).
- Formal versioning/supersedes theory for declarative rules — real
  candidate anchors found this revision (AGM/KM logic-program update, TGD
  conservative-extension), neither an exact fit; ILP's generalization-
  lattice literature is the most promising unresearched lead (§8.7.1).
- `linkml-datalog`'s dormancy — re-check again immediately before 6c
  depends on it, not just at spec-writing time (§8.6).
- Large-object/persistent-capability engineering details researched but
  not yet resolved this revision (§8.12): a garbage-collection scheme for
  many RDF triples referencing the same content-addressed chunk hash
  (every precedent found was built for object-store/shared-log semantics,
  not this); the privileged blob-serving process's own security boundary,
  given it sits outside the general WASI sandbox by design; whether WASI
  Preview 2+ has any native persistent/resumable component-instance
  notion; whether the concrete Capability representation for a persistent
  process is a second dimension alongside StabilityClass or something
  structurally different (§3.3, §4 confirm the formal grounding —
  session types with runtime adaptation, content-addressed chunking — not
  the concrete representation).

## 11. Changelog

**This revision (fifth) — §3.3 and §4 researched together, per direction
not to treat them as separate:**
- Rewrote §3.3 (large objects) from a flagged-unverified sketch to a
  research-grounded direction: content-addressed chunking (git/casync/
  desync/IPFS architecture), confirmed mainstream Raft stores discourage
  rather than solve large values through consensus, and a concrete
  chunk-plus-GC production precedent (Riak CS, historical).
- Rewrote §4's daemon-capability gap: the fitting formalism is session
  types with runtime adaptation (Di Giusto & Pérez), not an extension of
  algebraic-effect handler theory — and the same paper directly formalizes
  Erlang/OTP supervision trees as a worked example, a real citable bridge
  to `Riptide.Stream.StreamServer`'s own shape.
- Added §8.12 with the full grounding for both, including the connecting
  verdict the research was explicitly asked to investigate: blob storage
  and persistent capabilities need the same supervised-long-running-
  process primitive underneath, but a blob store should be a privileged
  built-in instance of that primitive, not literally a general-purpose
  WASI Capability grant.
- Updated §10: replaced "not yet researched"/"not designed" framing for
  both items with the specific engineering questions the research
  surfaced but didn't resolve (RDF-triple-shaped chunk GC, the privileged
  process's own security boundary, WASI persistent-instance support,
  concrete Capability representation).

**Fourth revision — resolving open decisions plus new research:**
- Resolved three of §10's open decisions: Tenant name (**"Tenant"**, no
  rename — Polity/Civitas/Demesne shortlist dropped), governance
  (**Riptide-internal for now**, not OpenFASTER-Standard public
  governance), and deployability (**same OS process** as Riptide's
  existing LDP surface, confirmed as one deployable, §1).
- Confirmed concurrent-effectful-execution coordination (6d-ii) as real
  design work this project owes directly, not a literature gap — no
  change to its treatment as an open question, but the framing is now
  explicit rather than ambiguous between "unresearched" and "unresolvable
  by research."
- Added §8.7.1: a dedicated four-angle research pass on formal
  versioning/supersedes theory for declarative rules. Found two genuine
  candidate anchors (AGM/Katsuno-Mendelzon logic-program-update theory;
  description-logic conservative-extension theory extended to existential
  rules/TGDs in 2022) — neither an exact fit for this spec's directional
  "rule B supersedes rule A" need. Confirmed patch theory (Darcs,
  categorical and homotopical) as a closed non-fit, not an unexplored
  option. Surfaced ILP's own generalization-lattice literature
  (anti-unification's own home field) as the most promising unresearched
  lead — closer to this spec's actual mechanism than either anchor found.
- Added §3.3: large object (blob) storage as a new open concern, with a
  candidate content-addressed direction sketched (git's own object-store/
  ref-layer split, reused rather than invented) — explicitly not yet
  researched the way the rest of this document's claims are.
- Added to §4: a universality check (does "serve this web page," not just
  "file a tax return," fit the Capability model?) surfaced a real gap —
  the current model implicitly assumes one-shot Interpretations, and a
  long-running/daemon-shaped Capability doesn't fit that shape. Noted as
  open, not designed.
- Updated §3.1's currency note: the security-audit remediation flagged as
  in-progress in the prior revision has since landed on `main` (PR #32) —
  Sub-project 6b's integration point is no longer targeting a moving
  target.

**Third revision — a currency pass, not new design work:**
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
