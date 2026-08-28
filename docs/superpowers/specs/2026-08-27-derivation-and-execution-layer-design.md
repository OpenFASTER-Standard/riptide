# Derivation and Execution Layer — Architecture Design

**Status:** Draft, ninth revision (2026-08-28 restructuring). This is one
architecture spec defining a single new top-level Riptide sub-project,
**Sub-project 6**, decomposed into phases 6a–6j, the same way Riptide's
own sub-projects 3, 4, and 5 are already decomposed. Each phase gets its
own implementation plan (`writing-plans`) when work on it starts.

This revision followed an independent cold-context architecture review
(the review found real, previously-undetected defects — see §11) and
restructured the document itself: the detailed research trail (three
versioning-research passes, the blob/persistent-capability research) and
the full revision-by-revision changelog through revision eight now live
in a companion file,
[`2026-08-27-derivation-and-execution-layer-research-log.md`](2026-08-27-derivation-and-execution-layer-research-log.md)
("the research log" below). This document states current decisions and
open questions plainly, without re-narrating "resolved this revision" /
"corrected this revision" framing for facts that are now simply true —
that framing is preserved, once, in the research log's own history.

## 1. Motivation and vision

**Riptide's production-readiness roadmap (its own sub-projects 1–5:
persistence, Docker/CI, clustering/HA, security/multi-tenancy,
observability) is complete**, per `PROGRESS.md`. This spec's work is the
first thing built on top of that stable foundation, not a parallel effort
competing with an unfinished one.

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

**Deployment.** This layer shares Riptide's Fact store, Rule
representation, and Signature/Dialect definitions as one substrate, **and
runs in the same OS process as Riptide's existing LDP surface** — one
deployable, not a companion service. No separate scheduling, no separate
deploy pipeline, no second thing to keep available.

## 2. Scope

**In scope:** the object model (§3–6), the grounding for each decision
(§8), two worked examples (§9), and Sub-project 6's phase breakdown (§7).

**`administration-commons` note.** An earlier local project
(`/work/misc/administration-commons`) used the term "pattern" for a
similar idea and sketched its own kernel. Superseded by this work, not
something this spec reconciles with.

**"OpenFASTER-Standard" naming note.** This repo (`riptide`) lives in the
`OpenFASTER-Standard` GitHub org — an aspirational name chosen early, not
evidence of an active, independently-governed standards body today. §10's
governance resolution ("Riptide-internal for now") means decision
authority over what gets admitted to the Catalog/Hub rests with Riptide's
own maintainers, regardless of which org hosts the repo. If OpenFASTER-
Standard ever becomes a real multi-stakeholder governance body, that's a
distinct future decision, not something this spec's org placement implies.

**Still open** (§10 has the full list, kept in one place — not duplicated
here or in a separate changelog): concurrent-effectful-execution
coordination; formal versioning/supersedes theory for rules; large-object/
persistent-capability engineering details; a threat model for the
Pattern Hub's public surface; automated detection of ontology overlap
(out of scope *by design*, §6.5).

## 3. Core concepts — facts and rules

### 3.1 Fact, Event, Tenant

- **Fact** — an atomic RDF(-star) assertion in the EDB. Carries
  *TransactionTime* (from Riptide's sequence number) and optionally a
  *ValidTime* interval (RDF-star-annotated, §8.4). Produced by one **Event**.
- **Tenant** — an isolated administrative/institutional space (this is the
  final name — no rename). Facts, Rules, CatalogEntries, and Capabilities
  are all tenant-partitioned. A Capability grant in one Tenant is never
  exercisable by a Rule in another; this composes with Riptide's shipped
  Phase 4c ACP authorization (default-deny, container-level inheritance,
  deny-overrides-allow, tenant-root bootstrap claim — confirmed accurate
  against the shipped design, `PROGRESS.md` §4), not a parallel system.
  **Current integration target:** the security-audit remediation on
  Riptide's ACP/auth surface has landed on `main` (PR #32) — a broad
  remediation (auth/authz correctness, Ra error handling, resource limits,
  concurrency/resilience fixes, observability), not only the narrower
  atom-exhaustion fix `PROGRESS.md` currently documents for it (tracked as
  a `PROGRESS.md` update, §8.11). Sub-project 6b's integration point
  should target this full, current ACP surface directly.
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
- **Dialect: SPARQL-RL**, tracked as one document. (The separate "SHACL
  1.2 Rules" draft this spec originally tracked in parallel has been
  consolidated by the Data Shapes Working Group into the SPARQL-RL
  document — confirm this hasn't changed again before Sub-project 6c-i
  locks in a concrete grammar, since it's a live Working Draft, not a
  finished Recommendation.) Reference evaluation engine: Soufflé's
  extended Datalog.
- **Rule** — a declarative IDB definition over a Signature: given a Body,
  conclude a Head. A Body is a conjunction of three literal kinds:
  - **Fact-pattern literals** — matched against the EDB, classical Datalog.
  - **Capability-reference literals** — a reference to a Capability (§4)
    that ExecuteInterpretation may invoke.
  - **Rule-reference literals** — a call to another Rule, with argument
    bindings. Without this, Rule composability (Templates calling other
    Templates) is inexpressible — caught by tracing a real scenario (§9)
    through the model, not by re-reading the document.

### 3.3 Large objects (blobs)

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

**Direction (full grounding: research log Part 2):** split identity from
bytes, the same way this whole document already treats every other layer
(§1's organizing idea). A blob is content-addressed (hashed) and
immutable once written; a Fact references it by hash (e.g.
`<urn:riptide-blob:sha256:...>`), making a blob just another kind of Term
any Rule or Fact can point at. The small hash-pointer goes through
Riptide's existing per-stream Ra log exactly like any other RDF triple
value; the actual bytes live in an ordinary, independently-replicated,
content-addressed local store that no single replication mechanism needs
to fully mirror everywhere — this is the convergent architecture across
git, casync/desync, and IPFS/UnixFS, and mainstream Raft-based stores
(etcd, TiKV, CockroachDB) confirm the same thing negatively: they
discourage or hard-limit large values through consensus rather than
solving this themselves.

**Connects directly to §4's persistent-capability question.** Every
concrete precedent for the chunk-store-plus-GC half of this (Riak CS;
CORFU/Delos) puts a **long-running, supervised, directly-addressable
server process** between clients and bulk data — never a one-shot
invocation. That is structurally the same shape §4 needs for a persistent
capability like "serve this content over HTTP." Riptide's own blob store
should be built as one privileged, built-in instance of that same
supervised-process lifecycle pattern (a GenServer/supervision-tree-managed
chunk store, hash-pointer metadata replicated via Ra) — **not** by routing
blob storage through the general-purpose, tenant-facing, WASI-sandboxed
Capability path meant for untrusted third-party code. Sub-project 6j
(§7) is where this gets built.

**Still genuinely open** (§10): a concrete garbage-collection/reference-
counting scheme for the case this document's own EDB actually creates —
many RDF triples referencing the *same* chunk hash, unlike the
object-store/shared-log semantics every precedent was built for; what
security boundary/tenant-scoping governs the privileged blob-serving
process itself, given it sits outside the general WASI sandbox by design;
and whether WASI Preview 2 (or later) has any native notion of a
persistent/resumable component instance that could simplify this.

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
  - **Resource metering is a hard requirement, not an enhancement.**
    Riptide has already hit two independent resource-exhaustion incidents
    from unmetered execution against untrusted-shaped input: unbounded
    BEAM atom creation via unauthenticated-adjacent reads, and a
    ~3MB deeply-nested Turtle body driving ~863MB/~19s in the decoding
    process (both fixed in PR #32; the second is not yet reflected in
    `PROGRESS.md`, §8.11). A Capability is exactly this risk shape again —
    tenant-scoped, but running arbitrary WASI component code — so 6b
    (§7) must enforce fuel and memory limits from its first exit
    criterion, not add them after a third incident. `wasmex` (the Elixir
    WASM host this stack would use) has verified, real APIs for both:
    `Wasmex.EngineConfig.consume_fuel/2` plus `Wasmex.StoreOrCaller.set_fuel/2`
    trap deterministically when a component's fuel is exhausted, and
    `Wasmex.StoreLimits` bounds `:memory_size`, `:table_elements`,
    `:instances`, `:tables`, and `:memories` per store.
  - **Long-running Capabilities.** "File a tax return," "extract page 2 of
    a PDF," and "serve this web page over HTTP" should all be expressible
    as Capabilities — that's the whole point of the model's generality.
    The first two are one-shot: invoke, get a discrete Outcome, done —
    exactly what `(Rule, Bindings, EDB-state) → Outcome` (§5) already
    models. "Serve this page" is not: it's a long-running,
    continuously-listening process serving arbitrarily many requests over
    its lifetime. The formalism that fits this shape is session types with
    runtime adaptation (Di Giusto & Pérez — full grounding in the research
    log's Part 2), not an extension of the algebraic-effect/handler theory
    §5 leans on for one-shot Interpretations: it proves the safety property
    a revocable, tenant-scoped long-running Capability needs (an
    update/restart action on a running process is only permitted when it
    isn't currently mid-session), and the same paper formalizes Erlang/OTP
    supervision trees as a worked example — a real, citable bridge to
    `Riptide.Stream.StreamServer`'s own supervision-tree shape. A
    long-running Capability's implementation is a supervised OTP process
    wearing a Capability grant, typed for exactly this adaptation-safety
    property. Whether that's a second Capability dimension (e.g.
    `Ephemeral` vs `Persistent`, alongside StabilityClass) or something
    structurally different is still open (§10) — the formal grounding is
    settled, the concrete representation isn't.
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
  git's. `Reject` skips review. **Must also handle multiple candidates**:
  Rule expressiveness is not constrained to the bisimilar-term-graph
  fragment (§8.2), so anti-unifying two Rules can yield several
  mutually-incomparable generalizations rather than one canonical answer —
  DedupGate's arbitration mechanism for that case is Sub-project 6e's own
  design work, not specified here. One concrete, well-precedented tool
  worth trying first: bottom-clause-style bounding (Muggleton's inverse
  entailment), applied per anti-unification call, which recovers a
  well-defined single generalization locally without a blanket restriction
  on Rule expressiveness — a real ILP-system technique (Progol, Golem),
  not invented for this spec (full grounding: research log Part 1, Pass 3).
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

- **Same-Dialect translation** (the common case, especially with §3.2's
  Dialect target consolidated to one document): a **signature
  morphism** — an arrow within one institution's `Sign` category, already
  this document's own vocabulary. Soundness vocabulary, if ever checked:
  model-conservativeness / Mod-strictness / Sen-maximality.
- **Cross-Dialect translation**: a full **comorphism** — categorically
  heavier, and the case where the sublogic/embedding/faithful/(weakly)
  exact fidelity scale actually applies (per DOL's own worked practice).
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
Each phase becomes its own spec → plan → implementation cycle. Every
phase below states its dependencies (normalized as **Depends on:**) and
one falsifiable exit criterion.

### Walking skeleton

The minimal phase subset that proves the whole design end-to-end, ahead
of the full roadmap: **6b → 6c-i → 6d-i → 6e → 6f → 6g-i**. Exit
criterion, concretely: a Task with no Catalog match runs through
LLMFallback twice, and the resulting CatalogEntry is admitted; a third,
similar Task hits Discovery's exact/keyword lookup directly, with **zero**
LLM calls (this is §9.1's own worked example, made falsifiable). Getting
here doesn't require 6a, 6c-ii/6c-iii, 6d-ii, 6g-ii, 6h, 6i, or 6j — those
extend the skeleton, they don't gate it.

### Phases

- **6a — Bitemporal fact shape.** RDF-star `validFrom`/`validTo`, a defined
  OWL-Time Allen-relation subset, ValidTime defaulting to TransactionTime.
  Applies to Riptide's existing LDP write path, building on the
  already-shipped Phase 3a schema-versioning envelope (`PROGRESS.md` §3,
  shipped 2026-08-24) rather than treating the `Event`/`Patch` shape
  change as a fresh, unaddressed risk.
  **Depends on:** nothing.
  **Exit criterion:** a Fact can carry a ValidTime interval distinct from
  its TransactionTime, round-trips through the existing LDP write/read
  path unchanged for Facts that don't set one, and is covered by a
  migration test against the Phase 3a envelope.
- **6b — Execution substrate.** WASI component execution, WASIX capability
  grant, tenant-scoped and split into EffectCapability/ObserveCapability
  from the start. Tested with no Rule representation involved.
  **Depends on:** nothing.
  **Exit criterion:** a tenant-scoped WASI component can be invoked as an
  EffectCapability or ObserveCapability against Riptide's current ACP
  surface (§3.1); a component that exceeds a configured fuel or memory
  limit (§4's `wasmex` APIs) traps deterministically instead of degrading
  the host, exercised by a test analogous to the Turtle-parsing and
  atom-exhaustion incidents already fixed in PR #32.
- **6c — Pure derivation engine**, split by concern (following the
  established Phase 3c-i/ii/iii precedent for splitting an oversized
  phase):
  - **6c-i — Fact-pattern matching and joins.**
    **Depends on:** nothing beyond Riptide's fact store as it exists
    today (bitemporal joins are 6c-iii's concern, not this one's).
    **Exit criterion:** a Rule with only fact-pattern literals in its Body
    evaluates correctly against multi-stream joins in the EDB, verified
    against a hand-written suite of representative join queries.
  - **6c-ii — Recursion and fixpoint evaluation.**
    **Depends on:** 6c-i.
    **Exit criterion:** a recursive Rule (e.g. transitive closure) reaches
    a correct fixpoint over the EDB, with a documented stratification/
    termination discipline.
  - **6c-iii — Aggregation and full QueryInterpretation.**
    **Depends on:** 6c-ii. ValidTime-aware querying additionally depends
    on 6a — that dependency is scoped to this sub-phase, not to 6c as a
    whole, so 6a and 6c-i/6c-ii can proceed in parallel.
    **Exit criterion:** QueryInterpretation supports aggregation and, for
    Facts carrying a ValidTime interval, can filter/join on it.
    `linkml-datalog`'s liveness (§8.6) must be re-checked immediately
    before this phase starts, not assumed from spec-writing time.
- **6d — Wiring**, split by risk:
  - **6d-i — Mechanical wiring.** Execute interpreter, real NativeTemplate
    instances, `call_template` against a small hand-authored set.
    **Depends on:** 6b (execution substrate) and 6c-i (fact-pattern
    matching — the minimum Rule representation NativeTemplate needs;
    6c-ii/6c-iii are not required here).
    **Exit criterion:** a hand-authored set of NativeTemplate instances is
    invoked end-to-end through ExecuteInterpretation via `call_template`,
    exercising 6b's substrate and 6c-i's matching together.
  - **6d-ii — Concurrent-effects design spike.** No established theory
    answers coordinating concurrent ExecuteInterpretations over
    overlapping, irreversible resources (checked: neither sagas nor CRDTs
    establish this). Real, open design work.
    **Depends on:** 6b (needs EffectCapability semantics to design
    coordination for); benefits from 6d-i's concrete wiring as a
    prototyping substrate but isn't blocked on it.
    **Exit criterion:** a written design decision (not a test) for how
    concurrent, overlapping EffectCapability invocations are coordinated.
- **6e — Generalization and DedupGate**, including replay-testing fidelity
  with the kind-specific semantics from §4.
  **Depends on:** 6d-i.
  **Exit criterion:** two independently-produced Traces anti-unify into a
  single Generalization, pass DedupGate's `Admit` path with sandboxed
  replay-testing evidence, and become a live CatalogEntry.
- **6f — LLM fallback loop.** OAuth ported to Elixir by hand (no ecosystem
  to lean on — `lambdaclass/datalog` dead, `fogfish/datalog` real but
  dormant since 2019; full Datalog-library liveness tracking lives in
  §8.6/6c-iii, not here, since this phase's own subject is the LLM
  fallback loop, not Datalog tooling).
  **Depends on:** 6e.
  **Exit criterion:** a Task with no Catalog match completes via
  LLMFallback, produces a Trace, and that Trace is accepted by 6e's gate
  without manual code changes.
- **6g — Discovery**, split by readiness:
  - **6g-i — Exact/keyword lookup**, viable as soon as any CatalogEntry
    exists — the walking skeleton's own last step.
    **Depends on:** 6e.
    **Exit criterion:** a CatalogEntry admitted by 6e is found by exact/
    keyword Discovery and invoked without an LLM call.
  - **6g-ii — Hybrid keyword+embedding progressive disclosure**, deferred
    until the catalog is large enough to need it.
    **Depends on:** 6g-i.
    **Exit criterion:** not yet defined — deferred with the phase.
- **6h — Pattern Hub.** Stand up Hub-scope Catalog as a distinct,
  network-publicly-reachable deployment of the same DedupGate mechanism
  6e already builds. **"Publicly-reachable" is a network-exposure fact,
  independent of §2's governance clarification** — the Hub can be
  reachable by any Tenant (including future external ones) while curation
  /admission authority stays Riptide-internal; these are orthogonal axes,
  not in tension. Because this is Riptide's first network-public-facing
  surface, it needs its own auth/rate-limit threat model defined in 6h's
  own future spec **before implementation starts**, not discovered during
  implementation (§10).
  **Depends on:** 6e.
  **Exit criterion:** a CatalogEntry can be published to Hub scope and
  installed into a different Tenant via 6i, over a network-reachable
  endpoint gated by the auth/rate-limit model that phase's own spec
  defines.
- **6i — Ontology Crosswalks and Installation.** SSSOM-shaped Hub-scope
  Crosswalk content, the Install operation, human-curation workflow.
  **Depends on:** 6h.
  **Exit criterion:** installing a Hub Pattern into a Tenant with partial
  vocabulary overlap binds matched fields through an existing Crosswalk
  and records manually-originated Provenance for unmatched fields, per
  §6.5.
- **6j — Large object (blob) storage.** Implements §3.3/the research
  log's Part 2 blob architecture: content-addressed chunk store as a
  privileged, built-in supervised process, hash-pointer Facts through
  Riptide's existing per-stream Ra log. No phase covered this in prior
  revisions of this document — added this revision after the gap was
  found during restructuring (§11).
  **Depends on:** 6b (shares the supervised-process substrate 6b's own
  daemon-capability grounding establishes, per §3.3/§4).
  **Exit criterion:** a Capability can write a blob larger than 10MB,
  addressed by content hash, retrievable via a hash-pointer Fact
  replicated through Riptide's existing per-stream Ra log, with a
  documented (even if provisional) garbage-collection scheme and an
  explicit statement of what security boundary governs the privileged
  blob-serving process.

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
bisimilar-term-graph case. Minimizing generalization variables is
NP-complete in the closest scalable formalism (Yernaux & Vanhoof 2022).

**Decision: Rule expressiveness is not constrained to the
bisimilar-term-graph fragment.** A Rule's Body may express arbitrary
cross-referencing between rule-reference literals (real composability,
e.g. one sub-Rule's output feeding another's input, matters more than
guaranteed-unique anti-unification). The consequence is accepted
explicitly: DedupGate (§6) must handle the case where anti-unifying two
Rules yields several mutually-incomparable candidate generalizations, not
assume there's always exactly one. The concrete arbitration mechanism
(present all candidates for human review; some ranking heuristic; bottom-
clause-style bounding per §6; some other approach) is Sub-project 6e's
job, once a real Rule representation exists to test it against.

**8.3 Execution kernel.** WASI Preview 2 excludes fork/exec/subprocess
spawning by design; WASIX is the separate superset restoring it. See §4
for the resource-metering requirement layered on top of this kernel.

**8.4 Bitemporal facts.** Datomic is unitemporal; XTDB's two-axis model is
the target shape, via RDF-star + OWL-Time. Valid-time must be duplicated
into ordinary queryable fact form for the derivation layer to reason over
it.

**8.5 Capability kinds.** The EffectCapability/ObserveCapability split
fell out of tracing §9.2 through the model, not external research — this
document's own synthesis, presented as such.

**8.6 Authoring.** LinkML adopted for 6c's rule schema and 6h/6i's Pattern
and Crosswalk schemas. `linkml-datalog`: last pushed 2024-02-14, one open
issue, not archived — dormant. Re-check immediately before 6c-iii
actually depends on it, not just at spec-writing time.

**8.7 Versioning — formal supersedes theory for declarative rules.**
TerminusDB and Fluree are both actively maintained (graph three-way merge
is still weaker than git's regardless — §6's DedupGate `Merge` rule).
Three dedicated research passes (five independent directions: AGM/
Katsuno-Mendelzon logic-program update theory, description-logic
conservative-extension/TGD theory, patch theory, the view-update problem
and schema-mapping-evolution theory, and ILP's own subsumption/
refinement-operator/version-space literature) found **no existing
formalism that directly answers "rule B (refined) supersedes rule A
(generalized)."** The pragmatic git/TerminusDB-style model is the adopted
approach. The one genuinely actionable output of this research is
recorded where it's used: bottom-clause-style bounding as a concrete tool
for Sub-project 6e's DedupGate arbitration (§6). Full citations and the
per-pass narrative: research log, Part 1.

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
`graphsheet`'s shipped SHACL-driven UI. **Two `PROGRESS.md` updates owed,
no later than 6b's start:** add Sub-project 6 as a row in the sub-project
table, and expand the existing "Post-4d hardening" section to reflect
PR #32's full scope (currently documents only the atom-exhaustion slice,
not the Turtle-parsing heap-cap fix or the rest of that PR — §3.1, §4).

**8.12 Large objects and persistent capabilities.** Researched together,
per explicit direction not to treat them as separate, since a native blob
store and a long-running capability are plausibly the same underlying
problem. Full grounding, citations, and the 18 individually-verified
claims behind this: research log, Part 2. Net conclusions are stated
where they're used: the blob architecture in §3.3, the persistent-
capability formalism in §4, and the connecting verdict (both need the
same supervised-process primitive, but the blob store should be a
privileged built-in instance of it, not a general WASI Capability grant)
in both places consistently.

## 9. Worked examples

**9.1 — the clean case.** Task "deploy the billing service" → no
CatalogEntry match → LLMFallback produces a ground Trace → not admitted
alone (§5) → weeks later, a second Task's Trace anti-unifies against the
first → DedupGate `Admit` with human review and sandboxed-replay fidelity
evidence → CatalogEntry `deploy-service-to-prod` → a third occurrence hits
Discovery's exact lookup directly, zero LLM calls. (This is the walking
skeleton's own exit criterion, §7.)

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

**Resolved:**
- Final Tenant name: **"Tenant"**, no rename.
- OpenFASTER-Standard public governance status: **Riptide-internal for
  now** (§2 disambiguates this from the org name itself).
- Whether this engine is a separate deployable from Riptide's LDP
  surface: **same OS process**, one deployable (§1).
- Whether the Rule/workflow-graph representation can be constrained to
  the bisimilar-term-graph fragment: **no constraint**; full
  expressiveness is kept, and DedupGate must arbitrate a finite set of
  incomparable generalizations when anti-unification isn't unitary (§8.2,
  §6). The concrete arbitration mechanism is Sub-project 6e's own design
  work.

**Still open:**
- Concurrent-effectful-execution coordination (6d-ii's actual subject
  matter) — real design work this project owes directly, not a
  literature gap a further research pass would close.
- Formal versioning/supersedes theory for declarative rules — three
  dedicated passes found no exact fit across five independent directions
  (§8.7, research log Part 1). Bottom-clause-style bounding is a concrete
  actionable tool for 6e even without closing the formal gap itself.
- `linkml-datalog`'s dormancy — re-check again immediately before 6c-iii
  depends on it, not just at spec-writing time (§8.6).
- Large-object/persistent-capability engineering details (§3.3, §4,
  §8.12, research log Part 2): a garbage-collection scheme for many RDF
  triples referencing the same content-addressed chunk hash; the
  privileged blob-serving process's own security boundary; whether WASI
  Preview 2+ has any native persistent/resumable component-instance
  notion; whether the concrete Capability representation for a
  persistent process is a second dimension alongside StabilityClass or
  something structurally different. The formal grounding (session types
  with runtime adaptation; content-addressed chunking) is settled; the
  concrete representation isn't.
- A threat model for the Pattern Hub's public network surface (6h, §7) —
  must be written as 6h's own spec, before 6h's implementation starts,
  not discovered mid-implementation.

## 11. Changelog

Revisions one through eight — including the full research narrative for
the three versioning-research passes and the blob/persistent-capability
research — are archived in the research log's Part 3, not repeated here.

**This revision (ninth) — restructuring after an independent cold-context
architecture review**, which found several genuine defects that had
survived all eight prior revisions:
- Split the detailed research trail and full revision history out to a
  companion research log, so this document states current decisions once
  instead of interleaving them with "resolved this revision" narration.
- Fixed a real dependency-graph gap: 6d-i/6d-ii previously stated no
  dependency on 6b or 6c despite needing both — now explicit.
- Moved a misplaced Datalog-library-liveness note from 6f (LLM fallback
  loop — the wrong home for it) to §8.6/6c-iii.
- Added WASI resource metering (fuel + memory limits, via `wasmex`'s
  verified `EngineConfig.consume_fuel`/`StoreLimits` APIs) as an explicit
  6b exit criterion, grounded in two real prior incidents (atom
  exhaustion; the Turtle-parsing heap cap), not a hypothetical concern.
- Added a phase for the blob-storage design that had never been assigned
  one: **6j**.
- Split 6c into 6c-i/6c-ii/6c-iii (matching/joins; recursion/fixpoint;
  aggregation + full QueryInterpretation), following the established
  Phase 3c-i/ii/iii precedent, and relaxed 6c's blanket dependency on 6a
  to apply only to 6c-iii's ValidTime-aware slice.
- Added a "Walking skeleton" subsection to §7 naming the minimal phase
  subset and making §9.1's own example its falsifiable exit criterion.
- Added a falsifiable exit criterion to every phase.
- Clarified that 6h's "publicly-reachable" is a network-exposure axis
  independent of §2's Riptide-internal-governance axis, and required a
  threat model before 6h's implementation starts.
- Disambiguated the "OpenFASTER-Standard" org name from the governance
  decision (§2).
- Linked `administration-commons` to its real path.
- Normalized "Depends on:" phrasing across every phase.
- Deduplicated the Riak CS/CORFU precedent text between §3.3 and §8.12 —
  detail lives in the research log only.
- Flagged (not yet applied — tracked separately) that `PROGRESS.md`'s
  "Post-4d hardening" section needs expanding to reflect PR #32's full
  scope, not just the atom-exhaustion slice (§8.11).
