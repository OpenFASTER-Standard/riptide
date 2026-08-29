# Derivation and Execution Layer — Architecture Design

**Status:** Draft, tenth revision (2026-08-28, second restructuring same
day). This is one architecture spec defining a single new top-level
Riptide sub-project, **Sub-project 6**, decomposed into 21 phases across
one shared foundation and four tracks (§7) — grown from an initial 14
phases after a full pairwise dependency/leverage review (§11). Each phase
gets its own implementation plan (`writing-plans`) when work on it
starts.

The ninth revision followed an independent cold-context architecture
review (found real, previously-undetected defects) and restructured the
document itself: the detailed research trail (three versioning-research
passes, the blob/persistent-capability research) and the full
revision-by-revision changelog through revision eight now live in a
companion file,
[`2026-08-27-derivation-and-execution-layer-research-log.md`](2026-08-27-derivation-and-execution-layer-research-log.md)
("the research log" below). This tenth revision applied a second,
independent review method to the same content — pairwise comparison of
every phase against every other, not just re-checking the existing DAG —
and found the phase breakdown itself (§7) needed restructuring, not just
the grounding sections. This document states current decisions and open
questions plainly, without re-narrating "resolved this revision" /
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
evidence of an active, independently-governed standards body today. This
is independent of §6's own governance model: **Tenant is the sovereign
unit** — each Tenant governs what it admits to its own Catalog and what
it chooses to publish/share, with no central Riptide-internal reviewer
standing between a Tenant and its own content (§10's earlier
"Riptide-internal for now" resolution is corrected by this revision — see
§11). If OpenFASTER-Standard ever becomes a real multi-stakeholder
governance body, that would govern the *standard itself* (the spec/
protocol) — a distinct question from who curates any one deployment's
shared content, not something this spec's org placement implies.

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
  a `PROGRESS.md` update, §8.11). Sub-project 6b-i's integration point
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
  document — confirm this hasn't changed again before Sub-project 6c-i-a
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
Capability path meant for untrusted third-party code. Sub-project 6b-ii
(§7) builds the shared primitive; 6j (§7) builds the blob store itself on
top of it.

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
    tenant-scoped, but running arbitrary WASI component code — so 6b-i
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
  component. Sequencing note: Sub-project 6b-i (§7) builds the WASI
  execution substrate standalone, with no Rule representation involved —
  it doesn't produce NativeTemplate instances yet, since Rule's
  representation isn't built until 6c-i-a. 6d-i is what wraps 6b-i's
  substrate as actual NativeTemplate instances.
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
  engineering, scoped to Sub-project 6e-ii.
- **Provenance** — the dependency edge back to what a Rule was generalized
  or installed from (§6.5).

## 6. Catalog, DedupGate, Discovery, Task, LLMFallback, Pattern

**Catalog is parameterized by scope: `Tenant` or `Hub`.** One mechanism,
two scopes — but **Tenant is the sovereign unit governing both.** `Hub`
scope is not a separate, centrally-administered repository with its own
reviewer: it's where a Tenant makes a CatalogEntry broadly discoverable,
reviewed and admitted by that *same* Tenant's own DedupGate authority it
already exercises over its Tenant-scope Catalog. Publishing to Hub scope
is an explicit, Tenant-initiated action — never automatic promotion from
Tenant-scope content, and never gated by a third-party curator.

- **DedupGate** — anti-unifies a freshly-generalized candidate against its
  Catalog and yields `Reject`, `Merge`, or `Admit`. Both `Admit` and
  `Merge` require human review before the result is live — that review is
  performed by the *originating Tenant*, at either scope, per
  `scratch-command-bar`'s existing propose/review precedent (`Merge`
  additionally because graph three-way merge is provably weaker than
  git's); there is no additional Riptide-internal reviewer layer.
  `Reject` skips review. **Must also handle multiple candidates**: Rule
  expressiveness is not constrained to the bisimilar-term-graph fragment
  (§8.2), so anti-unifying two Rules can yield several
  mutually-incomparable generalizations rather than one canonical answer —
  DedupGate's arbitration mechanism for that case is Sub-project 6e-i's own
  design work, not specified here. One concrete, well-precedented tool
  worth trying first: bottom-clause-style bounding (Muggleton's inverse
  entailment), applied per anti-unification call, which recovers a
  well-defined single generalization locally without a blanket restriction
  on Rule expressiveness — a real ILP-system technique (Progol, Golem),
  not invented for this spec (full grounding: research log Part 1, Pass 3).
- **CatalogEntry** — `⊑ Rule`, admitted or merged by DedupGate, subject to
  §5's admission consequence.
- **Pattern is not a separate type.** It's the name for a CatalogEntry a
  Tenant has published at **Hub** scope — a Tenant-curated,
  publicly-installable unit, generalizing to *any* computer-doable action,
  not an administrative-only subset.
- **Discovery** — search over CatalogEntry (either scope). Exact/keyword
  lookup (viable as soon as any CatalogEntry exists) and, later, hybrid
  keyword+embedding progressive disclosure. Conflict resolution: recency,
  then StabilityClass, then specificity as final tiebreaker.
- **Task** — the entry point. Triggers Discovery against the Tenant's own
  Catalog; a confident match invokes that CatalogEntry directly; no match
  triggers **LLMFallback**, whose resulting Trace feeds Generalization →
  DedupGate (Tenant scope) → possibly a new local CatalogEntry.
- **Install** — `CatalogEntry(Hub) × Tenant → CatalogEntry(Tenant)` (§6.5),
  going through the *installing* Tenant's own DedupGate, with a narrower
  review scope (confirming field bindings, not re-reviewing
  already-curated content) — the installing Tenant exercises its own
  sovereignty over what enters its own Catalog here, exactly as it would
  for a Tenant-scope candidate.

**Cross-deployment federation is a stated design goal, not (yet) a build
target.** Because curation authority is per-Tenant rather than
per-deployment, sharing between two Tenants should work identically
whether they're on the same Riptide instance or on two
independently-operated ones — a company can host a single Riptide
instance with each of its own users as a Tenant, fully isolated from each
other by default (§3.1, Sub-project 4), except where a Tenant actively
chooses to share something, at which point it should not matter whether
the receiving Tenant lives on the same instance or a different one. This
follows the same "never front-load a bridge" discipline §1 already states
for Traces/CatalogEntries/Crosswalks: 6h-ii/6i build the network-reachable
protocol shape now (HTTP, not same-BEAM-node-only), but actual
cross-instance trust/identity verification is explicitly deferred until a
real cross-instance use case exists (§10).

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
- **Detection of overlap is human-only, by design, for now.** A Tenant
  proposes a Crosswalk entry through its own DedupGate authority — the
  same one it already exercises over any other Hub-scope publication
  (§6), not a separate curator role.
- **Crosswalks are Hub-scope content**, published by whichever Tenant
  needs or creates them and discoverable by any Tenant; a Tenant's actual
  vocabulary commitment (§3.1) is the one genuinely tenant-local fact.
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

**Structure, after a full pairwise dependency/leverage review (see §11's
latest revision).** The flat 6a–6j letter sequence looks like one serial
chain; it isn't. A full pairwise pass across every phase — checking each
against every other for a hidden dependency, not just re-deriving the
already-known DAG — found that the roadmap is actually **one small shared
foundation feeding one primary spine plus three genuinely independent
side-tracks**, and several phases were bundling two different kinds of
work under one name. That review split 14 phases into 21, all listed
below under their track. Two general findings drove the splits: (1) a
phase's *leverage* (how much depends on it) and its *readiness* (whether
it's blocked) are different axes — several always-blocked-nothing phases
turned out to have very different downstream weight; (2) wherever a
phase's own text carried a hedge ("...but *additionally* depends on X for
part of its scope," "...but Y must happen before Z starts") that hedge
was a sign of two phases pretending to be one.

### Foundation

Start immediately; nothing here depends on anything else in Sub-project 6.

- **6c-i-a — Rule/Signature representation and parser.** The Rule/Body/
  Head/Signature data representation and a SPARQL-RL-subset parser (§3.2).
  **The highest-leverage phase in the roadmap**: nothing that touches
  "Rule" — 6c-i-b's evaluation, 6c-ii, 6c-iii, 6d-i's NativeTemplate,
  6e-i's anti-unification, 6f's Trace, or the LinkML rule schema (§8.6)
  — can start until this shape is fixed. Previously bundled into "6c-i"
  together with join evaluation; split out because it has an order of
  magnitude more downstream consumers than the evaluation logic does, and
  splitting it off lets those consumers start sooner instead of waiting
  for the join engine too.
  **Depends on:** nothing.
  **Exit criterion:** the Rule/Signature representation and its SPARQL-RL
  parser round-trip a hand-written set of representative Rules (all three
  literal kinds from §3.2), and `linkml-datalog`'s liveness (§8.6) has
  been re-checked immediately before this phase starts, not assumed from
  spec-writing time — this is the schema `linkml-datalog` would target,
  if used.
- **6b-i — WASI execution substrate.** WASI component execution, WASIX
  capability grant, tenant-scoped and split into EffectCapability/
  ObserveCapability from the start, with resource metering as a hard
  requirement (§4). Tested with no Rule representation involved.
  (Previously plain "6b"; renamed to distinguish it from 6b-ii below,
  since both were being called "6b" and only one of them is what 6j
  actually needs.)
  **Depends on:** nothing.
  **Exit criterion:** a tenant-scoped WASI component can be invoked as an
  EffectCapability or ObserveCapability against Riptide's current ACP
  surface (§3.1); a component that exceeds a configured fuel or memory
  limit (§4's `wasmex` APIs) traps deterministically instead of degrading
  the host, exercised by a test analogous to the Turtle-parsing and
  atom-exhaustion incidents already fixed in PR #32.
- **6a — Bitemporal fact shape.** RDF-star `validFrom`/`validTo`, a defined
  OWL-Time Allen-relation subset, ValidTime defaulting to TransactionTime.
  Applies to Riptide's existing LDP write path, building on the
  already-shipped Phase 3a schema-versioning envelope (`PROGRESS.md` §3,
  shipped 2026-08-24). **Scheduled in the foundation despite low
  downstream leverage** (only 6c-iii-b needs it, and not until well into
  Track B) **because it's the first real exercise of Phase 3a's
  schema-versioning envelope**, which has shipped but never been used for
  an actual shape change — retiring that integration risk now, while
  little else depends on the current Fact shape, is cheap; retiring it
  after Track A/B are built on the current shape would not be.
  **Depends on:** nothing.
  **Exit criterion:** a Fact can carry a ValidTime interval distinct from
  its TransactionTime, round-trips through the existing LDP write/read
  path unchanged for Facts that don't set one, and is covered by a
  migration test against the Phase 3a envelope.
- **6b-ii — Supervised long-running process primitive.** An OTP
  supervision-tree-managed process lifecycle, typed for the
  revocable/restartable adaptation-safety property from session types
  with runtime adaptation (§4, §8.12, research log Part 2) — the
  primitive both a privileged blob store (6j) and any future persistent
  Capability grant would be built from. **Newly split out**: prior
  revisions had 6j claim a dependency on "6b" for this, but 6b as scoped
  (now 6b-i) never actually built it — that dependency was fictional
  until this phase existed to satisfy it. Scoped to just the reusable
  primitive, not the open question of how a general persistent Capability
  would be represented (§10) — that stays open; this phase doesn't need
  it resolved.
  **Depends on:** nothing (not even 6b-i — it's Riptide-native, privileged,
  and never goes through the WASI sandbox).
  **Exit criterion:** a supervised OTP process can be started, can be
  cleanly restarted/replaced without corrupting an in-flight session, and
  refuses a restart/revoke request that arrives mid-session, per the
  adaptation-safety property the grounding research requires.
- **6h-i — Pattern Hub threat model.** The auth/rate-limit spec for the
  Pattern Hub's network-public surface (§7's 6h-ii below). **Newly split
  out of "6h"**: 6h's own text already said this must be written before
  6h-ii's implementation starts — a hedge that was really two phases. This
  one is pure spec-writing against an already-designed API surface (§6,
  §6.5); it doesn't need 6e-iii or anything else in this document to be
  *implemented* first, only designed, which it already is.
  **Depends on:** nothing.
  **Exit criterion:** a written auth/rate-limit threat model for the Hub's
  network surface exists and is reviewed, before 6h-ii starts.

### Track A — value-delivery spine (walking skeleton and beyond)

The chain that proves the whole design end-to-end and then extends it to
Discovery, the Hub, and Crosswalks.

- **6c-i-b — Fact-pattern matching and joins.** The join-evaluation engine
  over 6c-i-a's representation (multi-stream joins, classical Datalog
  matching). (Considered splitting further into "single-pattern
  matching" for 6d-i's minimal needs vs. "multi-stream joins" for
  everything else — rejected: in a real Datalog engine a 1-pattern match
  is a trivial corner case of the N-pattern join algorithm, not a
  separate implementation effort, so there's nothing to gain by
  splitting it.)
  **Depends on:** 6c-i-a.
  **Exit criterion:** a Rule with only fact-pattern literals in its Body
  evaluates correctly against multi-stream joins in the EDB, verified
  against a hand-written suite of representative join queries.
- **6d-i — Mechanical wiring.** Execute interpreter, real NativeTemplate
  instances, `call_template` against a small hand-authored set.
  **Depends on:** 6b-i (execution substrate), 6c-i-a (Rule
  representation), and 6c-i-b (fact-pattern matching — the minimum
  derivation-engine slice NativeTemplate needs; 6c-ii/6c-iii, Track B, are
  not required here).
  **Exit criterion:** a hand-authored set of NativeTemplate instances is
  invoked end-to-end through ExecuteInterpretation via `call_template`,
  exercising 6b-i's substrate and 6c-i-b's matching together.
- **6e-i — Anti-unification algorithm.** `Rule × Rule → Rule`
  least-general-generalization (Plotkin 1970) over 6c-i-a's
  representation, including arbitration when anti-unification yields
  several mutually-incomparable candidates (§8.2's decision not to
  constrain Rule expressiveness) via bottom-clause-style bounding
  (research log Part 1, Pass 3). **Newly split out of "6e"**: this is a
  pure, syntactic algorithm that only needs 6c-i-a to exist — it was
  previously stuck waiting on 6d-i for no real reason, since it can be
  built and unit-tested against synthetic/hand-constructed Traces well
  before any real Capability or NativeTemplate exists.
  **Depends on:** 6c-i-a.
  **Exit criterion:** anti-unifying two hand-constructed Rules produces
  their least-general-generalization plus recovering substitutions; a
  case engineered to yield multiple incomparable generalizations is
  resolved via bottom-clause-style bounding, with the result covered by
  unit tests using no real Capability or NativeTemplate.
- **6e-ii — Generalization Fidelity / replay-testing harness.** The
  kind-specific sandboxed replay semantics from §4/§5 (EffectCapability
  re-invoked and compared; ObserveCapability replayed from recorded
  Provenance instead of re-invoked). **Newly split out of "6e"**: distinct
  engineering (sandboxed execution) from both the pure algorithm (6e-i)
  and Catalog orchestration (6e-iii) — the spec's own §5/§6 split already
  drew this boundary conceptually; the phase list just hadn't followed it.
  **Depends on:** 6e-i (needs a Generalization to test against) and 6b-i
  (needs the WASI sandbox to replay into).
  **Exit criterion:** given a Generalization and its source Traces, the
  harness reproduces each Trace's recorded effects (EffectCapability) or
  recorded response (ObserveCapability) and reports fidelity pass/fail,
  exercised against hand-authored fixture Capabilities.
- **6e-iii — DedupGate orchestration.** Catalog lookup, the
  `Reject`/`Merge`/`Admit` decision, and the human review workflow
  (`scratch-command-bar`'s propose/review precedent). Built
  scope-parameterized (`Tenant` or `Hub`, §6) from the start, so 6h-ii can
  reuse it directly rather than generalizing a Tenant-only version later.
  **Depends on:** 6e-i, 6e-ii, and 6d-i (needs a live NativeTemplate
  producing real Traces to exercise the full path end-to-end, not just
  synthetic fixtures).
  **Exit criterion:** two independently-produced real Traces (from 6d-i's
  NativeTemplate instances) anti-unify into a single Generalization, pass
  the `Admit` path with 6e-ii's fidelity evidence and human review, and
  become a live CatalogEntry.
- **Capability grant flow (OAuth)** — a delegated/outbound OAuth client
  (ported to Elixir by hand; no ecosystem to lean on) for obtaining a
  Capability grant to an external system on the fly. **Newly split out of
  "6f"**: this is Capability-layer infrastructure (§4 — granting access to
  an external system), not something specific to LLM orchestration; 6f
  can't be usefully tested without it if it stays inline, and nothing else
  in 6f depends on OAuth's internals. Distinct from 6h-i's threat model
  (that's inbound protection of Riptide's own Hub API; this is outbound,
  delegated access to *other* systems) — checked, no shared work.
  **Not required for the walking skeleton**: 9.1's own example (billing-
  service deploy) plausibly uses pre-granted Capabilities; OAuth is only
  needed for Capabilities requiring interactive consent, which 6f can
  defer past its own first working version.
  **Depends on:** 6b-i.
  **Exit criterion:** given an external system requiring OAuth consent, a
  Tenant can complete a grant flow that results in a usable Capability
  grant, independent of any specific LLMFallback scenario.
- **6f — LLM fallback loop.** Orchestration only, now that OAuth is its
  own task: Task with no Catalog match → LLM-guided Capability invocation
  → ground Trace.
  **Depends on:** 6e-iii (the gate its output Trace must pass); the
  Capability-grant/OAuth task only for the subset of fallbacks needing a
  fresh external grant, not for the walking-skeleton path itself.
  **Exit criterion:** a Task with no Catalog match completes via
  LLMFallback, produces a Trace, and that Trace is accepted by 6e-iii's
  gate without manual code changes.
- **6g-i — Exact/keyword lookup**, viable as soon as any CatalogEntry
  exists — the walking skeleton's own last step. Built scope-parameterized
  (`Tenant` or `Hub`) from the start, matching 6e-iii, so 6h-ii reuses it
  directly.
  **Depends on:** 6e-iii.
  **Exit criterion:** a CatalogEntry admitted by 6e-iii is found by
  exact/keyword Discovery and invoked without an LLM call.
- **6g-ii — Hybrid keyword+embedding progressive disclosure**, deferred
  until the catalog is large enough to need it.
  **Depends on:** 6g-i.
  **Exit criterion:** not yet defined — deferred with the phase.
- **6h-ii — Pattern Hub deployment.** Stand up Hub-scope Catalog as a
  network-publicly-reachable extension of 6e-iii's
  already-scope-parameterized DedupGate mechanism plus 6g-i's Discovery.
  **"Publicly-reachable" and "who curates" are orthogonal axes, not in
  tension** — the Hub is reachable by any Tenant (including, eventually,
  Tenants on other independently-operated Riptide deployments — §6's
  federation goal), while admission authority for any given CatalogEntry
  stays with the Tenant that published it, never a separate
  Riptide-internal reviewer (§6, corrected this revision — see §11).
  **Depends on:** 6e-iii, 6g-i, and 6h-i (the threat model this
  implementation must be gated by).
  **Exit criterion:** a CatalogEntry can be published to Hub scope by its
  own Tenant and installed into a different Tenant via 6i, over a
  network-reachable endpoint gated by 6h-i's auth/rate-limit model.
- **6i — Ontology Crosswalks and Installation.** SSSOM-shaped Hub-scope
  Crosswalk content, the Install operation, human-curation workflow.
  **Depends on:** 6h-ii.
  **Exit criterion:** installing a Hub Pattern into a Tenant with partial
  vocabulary overlap binds matched fields through an existing Crosswalk
  and records manually-originated Provenance for unmatched fields, per
  §6.5.

**Walking skeleton, restated at this finer grain:** **6b-i → 6c-i-a →
6c-i-b → 6d-i → 6e-i → 6e-ii → 6e-iii → {6f, 6g-i}**. Concretely: a Task
with no Catalog match runs through LLMFallback twice, and the resulting
CatalogEntry is admitted; a third, similar Task hits Discovery's
exact/keyword lookup directly, with **zero** LLM calls (§9.1's own worked
example, made falsifiable). Nothing in Track B, Track C, 6d-ii, 6g-ii,
6h-ii, or 6i gates this — they extend the skeleton, not gate it.

### Track B — pure query capability (parallel to Track A, not a prerequisite for it)

**A full pairwise check found this track was never actually on the path
to Track A** — 6d-i needs only the Execute interpreter and basic
matching (6c-i-b), 6e's phases need the Rule representation and
anti-unification, and Discovery (6g-i) is a lookup index over
CatalogEntry metadata, not a Datalog query. The walking-skeleton note in
prior revisions already excluded 6c-ii/6c-iii, but the flat 6a–6j
numbering visually implied a serial chain that wasn't real. This track
serves the "answer a question about the facts" half of §1's vision; Track
A serves the "cause an effect" half plus the Catalog/Discovery machinery
around it.

- **6c-ii — Recursion and fixpoint evaluation.**
  **Depends on:** 6c-i-b.
  **Exit criterion:** a recursive Rule (e.g. transitive closure) reaches
  a correct fixpoint over the EDB, with a documented stratification/
  termination discipline.
- **6c-iii-a — Aggregation support.** COUNT/SUM/etc. in QueryInterpretation.
  **Newly split out of "6c-iii"**: aggregation has no dependency on 6a;
  bundling it with the ValidTime-aware slice (which does) forced a hedge
  ("depends on 6c-ii; *additionally* depends on 6a for part of its
  scope") that a clean split resolves instead of carrying forward.
  **Depends on:** 6c-ii.
  **Exit criterion:** QueryInterpretation supports aggregation over the
  EDB, verified against a hand-written suite of representative queries.
- **6c-iii-b — ValidTime-aware querying.** Bitemporal filter/join support
  in QueryInterpretation.
  **Depends on:** 6c-ii and 6a.
  **Exit criterion:** QueryInterpretation can filter/join on Facts'
  ValidTime intervals where present.

### Track C — blob storage (fully independent)

Shares nothing with Track A or B beyond Riptide's existing Ra log (used
only for the hash-pointer Facts, not the blob bytes themselves) — this
track can be resourced and scheduled entirely separately from the rest of
Sub-project 6.

- **6j — Large object (blob) storage.** Implements §3.3/the research
  log's Part 2 blob architecture: content-addressed chunk store as a
  privileged, built-in instance of 6b-ii's supervised-process primitive,
  hash-pointer Facts through Riptide's existing per-stream Ra log.
  **Depends on:** 6b-ii (not 6b-i — blob storage never goes through the
  WASI sandbox, by design, §3.3).
  **Exit criterion:** a Capability can write a blob larger than 10MB,
  addressed by content hash, retrievable via a hash-pointer Fact
  replicated through Riptide's existing per-stream Ra log, with a
  documented (even if provisional) garbage-collection scheme and an
  explicit statement of what security boundary governs the privileged
  blob-serving process.

### Track D — design spikes

Cheap, near-zero-dependency deliverables that feed Track A but don't
block starting it. (6d-ii and 6h-i were checked against each other for
shared content, since both are "cheap early design spikes" — none found;
they stay separate.)

- **6d-ii — Concurrent-effects design spike.** No established theory
  answers coordinating concurrent ExecuteInterpretations over
  overlapping, irreversible resources (checked: neither sagas nor CRDTs
  establish this). Real, open design work.
  **Depends on:** 6b-i (needs EffectCapability semantics to design
  coordination for); benefits from 6d-i's concrete wiring as a
  prototyping substrate but isn't blocked on it.
  **Exit criterion:** a written design decision (not a test) for how
  concurrent, overlapping EffectCapability invocations are coordinated.

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
clause-style bounding per §6; some other approach) is Sub-project 6e-i's
job, once a real Rule representation (6c-i-a) exists to test it against.

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

**8.6 Authoring.** LinkML adopted for 6c-i-a's rule schema and 6h-ii/6i's
Pattern and Crosswalk schemas. `linkml-datalog`: last pushed 2024-02-14,
one open issue, not archived — dormant. Re-check immediately before
6c-i-a actually depends on it, not just at spec-writing time (moved this
check to 6c-i-a rather than 6c-iii, since 6c-i-a is where the rule schema
itself is authored — `linkml-datalog`'s relevance is to schema authoring,
not to aggregation/QueryInterpretation).

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
for Sub-project 6e-i's DedupGate arbitration (§6). Full citations and the
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
`graphsheet`'s shipped SHACL-driven UI. **Done:** `PROGRESS.md` now has
Sub-project 6 as a row in the sub-project table, and the "Post-4d
hardening" section now reflects PR #32's full scope (previously
documented only the atom-exhaustion slice).

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
- OpenFASTER-Standard public governance status: a distinct question from
  Hub curation (§2 disambiguates the org name from the governance model).
  If OpenFASTER-Standard ever becomes a real multi-stakeholder body, that
  governs the *standard itself*, not any one deployment's own content.
- Pattern Hub curation authority: **per-Tenant, not Riptide-internal** —
  corrected this revision (was "Riptide-internal for now" through
  revision ten; see §11 and §6). Each Tenant governs what it publishes/
  shares at Hub scope through its own DedupGate authority; there is no
  central curator role for 6h-i to design authorization around.
- Whether this engine is a separate deployable from Riptide's LDP
  surface: **same OS process**, one deployable (§1).
- Whether the Rule/workflow-graph representation can be constrained to
  the bisimilar-term-graph fragment: **no constraint**; full
  expressiveness is kept, and DedupGate must arbitrate a finite set of
  incomparable generalizations when anti-unification isn't unitary (§8.2,
  §6). The concrete arbitration mechanism is Sub-project 6e-i's own design
  work.

**Still open:**
- Concurrent-effectful-execution coordination (6d-ii's actual subject
  matter) — real design work this project owes directly, not a
  literature gap a further research pass would close.
- Formal versioning/supersedes theory for declarative rules — three
  dedicated passes found no exact fit across five independent directions
  (§8.7, research log Part 1). Bottom-clause-style bounding is a concrete
  actionable tool for 6e-i even without closing the formal gap itself.
- `linkml-datalog`'s dormancy — re-check again immediately before 6c-i-a
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
  concrete representation isn't — 6b-ii builds the shared primitive, but
  a general persistent-Capability grant built from it remains open.
- A threat model for the Pattern Hub's public network surface — now its
  own phase, **6h-i**, decoupled from 6h-ii's implementation (§7). Still
  open in the sense that 6h-i's content hasn't been written yet, not in
  the sense that it might get skipped. Its scope is now the per-Tenant
  publish/share/discover surface (§6, corrected this revision), not a
  central-curator-authorization design — auth/rate-limiting for a
  Tenant's own publish and install actions, not "who is Riptide-internal."

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
- Expanded `PROGRESS.md`'s "Post-4d hardening" section to reflect PR #32's
  full scope (not just the atom-exhaustion slice) and added Sub-project 6
  to its sub-projects table (§8.11).

**This revision (tenth) — a full pairwise dependency/leverage review of
§7's phase breakdown**, done independently of the ninth revision's
cold-context review, using a different method: comparing every phase
against every other phase directly (not just re-checking the existing
DAG), specifically to catch hidden dependencies and bundled-together work
that a top-down pass over the same content would tend to miss:
- Found the flat 6a–6j sequence was hiding real structure: one shared,
  low-dependency foundation feeds one primary spine (the walking
  skeleton and its direct extensions) plus three genuinely independent
  side-tracks (pure QueryInterpretation; blob storage; design spikes).
  6c-ii/6c-iii were never actually prerequisites for 6d/6e/6f/6g/6h/6i —
  the existing walking-skeleton note already implied this, but the flat
  numbering obscured it. §7 is now organized by foundation/track instead
  of by letter alone.
- Found "Ready" (no dependency) is not the same as "highest priority":
  6c-i's Rule/Signature representation has far more downstream consumers
  than 6a or 6b did, despite all three previously reading as equally
  unblocked. Split out as **6c-i-a**, promoted to the single
  highest-leverage phase in the roadmap.
- Found 6j's stated dependency on "6b" was fictional as written — 6b as
  scoped never built the supervised-long-running-process primitive §3.3/
  §8.12 says blob storage needs. Split 6b into **6b-i** (the original
  WASI-substrate scope) and **6b-ii** (the primitive itself, needed only
  by 6j and, later, any persistent-Capability work) — closing a
  dependency that would otherwise have surfaced as a surprise when 6j
  actually started.
- Found 6e was three different kinds of engineering under one name (a
  pure algorithm, a sandboxed-execution harness, and Catalog
  orchestration+human review) — matching a boundary the spec's own §5/§6
  split already drew conceptually. Split into **6e-i/6e-ii/6e-iii**; 6e-i
  now depends only on 6c-i-a instead of waiting on 6d-i for no real
  reason.
- Found 6f's inline OAuth client is Capability-grant infrastructure (§4),
  not LLM-orchestration-specific — extracted as its own **Capability
  grant flow (OAuth)** task, and found it isn't actually required for the
  walking skeleton (9.1's example plausibly uses pre-granted
  Capabilities), narrowing the skeleton's true critical path.
- Found 6c-iii and 6h were each carrying a hedge in their own prior text
  ("additionally depends on 6a for part of its scope"; "needs a spec
  written before implementation starts") — a hedge on one phase is a sign
  of two. Split into **6c-iii-a/6c-iii-b** and **6h-i/6h-ii**
  respectively.
- Checked and explicitly rejected three plausible-looking further splits
  (6c-i-b's single-pattern-vs-join matching; a merge of 6h-i's and the
  OAuth task's "auth" framing; a merge of 6d-ii and 6h-i for both being
  cheap design spikes) — recorded in §7 so they aren't re-litigated
  without new information.
- Net: 14 phases became 21, all single-concern, each carrying its real
  dependencies rather than transitively-implied ones. Re-derived the
  walking skeleton at this finer grain: **6b-i → 6c-i-a → 6c-i-b → 6d-i →
  6e-i → 6e-ii → 6e-iii → {6f, 6g-i}**.
- Moved `linkml-datalog`'s liveness re-check from 6c-iii to 6c-i-a (where
  the rule schema is actually authored — a residual imprecision from the
  ninth revision's fix, corrected while already restructuring this
  section).

**This revision (eleventh) — corrected the Pattern Hub's governance model
from centralized to per-Tenant**, found while brainstorming 6h-i's own
threat model: every prior revision (through the tenth) described Hub
scope as a single, centrally-administered repository with admission
authority "Riptide-internal for now" (§2, §10) — but no design work had
ever concretely defined who "Riptide-internal" referred to, and pressure-
testing candidate authorization mechanisms against that undefined role
kept producing implementations that didn't actually fit the intended
model. The real model: **Tenant is the sovereign unit**, not a central
Riptide-operated authority and not the deployment. A single Riptide
instance can host many Tenants, fully isolated from each other by default
(Sub-project 4, unchanged); any Tenant may choose to publish/share
specific content, reviewed and admitted through that same Tenant's own
already-shipped DedupGate authority (6e-iii) — never a separate
third-party reviewer. Sharing is designed to work identically whether the
receiving Tenant is on the same Riptide deployment or a different,
independently-operated one (federation) — a stated design goal 6h-ii/6i
build the network-reachable protocol shape for now, with actual
cross-instance trust/identity verification explicitly deferred (§10),
following the same "never front-load a bridge" discipline §1 already
states for Traces/CatalogEntries/Crosswalks.
- §2: replaced the OpenFASTER-Standard naming note's governance claim.
- §6: `DedupGate` review, `Pattern`, and `Install` now explicit about
  Tenant-originated curation authority; added the federation-goal
  paragraph.
- §6.5: Crosswalk proposal is Tenant-originated, not a separate curator
  role.
- §7: 6h-ii's entry corrected to match.
- §10: "Riptide-internal for now" moved from Resolved-as-was to
  corrected-and-Resolved as per-Tenant; the Pattern Hub threat model's
  scope note updated to match (auth/rate-limiting for a Tenant's own
  publish/install actions, not central-curator-authorization design).
- No shipped code changes as a result of this revision: 6e-iii's already-
  shipped `scope :: {:tenant, String.t()} | :hub` type and DedupGate
  mechanism are unaffected — this correction is about *who* has authority
  to admit into either scope, not the storage/mechanism shape itself.
