# Derivation and Execution Layer — Architecture Design

**Status:** Draft, revised after an independent cold review and a targeted
re-verification pass against primary sources. This is an architecture spec
covering the full vision and a phased roadmap — not a single implementation
plan. Each phase gets its own implementation plan (`writing-plans`) when work
on it starts.

**Revision note:** this replaces an earlier draft of the same spec. The
revision fixed two factual errors (§4.1, §4.2), one internally contradictory
concept (§3.4's Generalization), one concept whose stated definition didn't
actually support its own use (§3.2/§3.3), an overclaimed invariant (§3.5's
Generalization Fidelity law), a real security gap (Capability was never
tenant-scoped), and a roadmap that hid its riskiest problem inside a step
labeled "pure wiring." All of this came from treating the first draft as
something to stress-test, not something to defend — see §9 for the itemized
before/after.

## 1. Motivation and vision

Riptide today is an event-sourced fact store (StreamLD's reference
implementation): an append-only, per-resource log of RDF facts, with one
hardcoded derivation (replay a stream's events in order to compute current
state). This spec adds the layer that's structurally missing: a general
**derivation and execution engine**, so that "answer a question about the
facts" and "cause an effect in the world" become two interpretations of the
same declarative object, evaluated by one engine, instead of bespoke
application code per feature.

The organizing idea: **the atomic unit should have a stable identity, and
everything else — labels, presentations, procedures — should be a *view*
derived from that identity, never the identity itself.** Riptide's event log
already does this for facts. This spec extends the same discipline to
*rules*.

**What that does and doesn't settle about deployment.** It settles that this
layer shares Riptide's Fact store, Rule representation, and Signature/Dialect
definitions as one substrate — no second store, no parallel schema, nothing
that needs reconciling with Riptide's own facts. It does **not**, by itself,
settle whether the derivation/execution engine must run in the same OS
process or release as Riptide's existing LDP surface. That's a real,
separate engineering question — particularly once §3.3's Capability grants
are in the picture, which expand the trusted computing base from "evaluates
RDF queries" to "executes arbitrary sandboxed code." Kept open in §8, not
asserted here.

## 2. Scope and explicit non-goals

**In scope:** the conceptual object model (§3), the grounding for each design
decision (§4), a worked example (§5), and the phased build order (§7),
including the concrete, ready-to-plan scope of Phase 1 (§7.1).

**Explicitly out of scope** — flagged as open, not silently assumed:
- Whether this layer becomes a public `OpenFASTER-Standard` module or stays
  Riptide-internal.
- Formal theory for coordinating **concurrent effectful** rule executions
  (two templates racing on the same Kubernetes namespace). Neither the saga
  pattern nor CRDTs were found to establish this — CRDT convergence is about
  merging *data*, not arbitrating *irreversible effects*. This is real,
  currently-unsolved design surface, not deferred paperwork (see §7, Phase
  4b).
- Whether the engine is a separate deployable from Riptide's LDP surface
  (§1).
- Detailed UI design — reuse `graphsheet`'s SHACL-driven pattern for the
  review/discovery/monitoring surfaces this layer needs; screens aren't
  designed here.
- The final human-facing name for a Riptide tenant. Shortlist: **Polity**,
  Enclave, Civitas, Demesne. This document uses **Tenant** as a placeholder.
- Observability and testing strategy for the engine itself, beyond what
  §4.9 requires as a precondition for later phases — Riptide's own
  PROGRESS.md already treats observability (sub-project 5) and
  schema-versioning risk as first-class, ongoing concerns; this layer
  should be planned against that existing discipline when Phase 2 starts,
  not invent a separate one here.

## 3. Core concepts (the T-box)

### 3.1 Fact, Event, Tenant

- **Fact** — an atomic RDF(-star) assertion in the EDB. Carries a
  *TransactionTime* (free, from Riptide's sequence number) and optionally a
  *ValidTime* interval, RDF-star-annotated (§4.4). Produced by one **Event**.
- **Tenant** *(name TBD, §2)* — an isolated administrative/institutional
  space. **Facts, Rules, CatalogEntries, and Capabilities are all
  tenant-partitioned** — Capability is added to this list in this revision;
  its absence in the first draft was a real gap (§9, item 6). A Capability
  grant issued inside one Tenant must never be exercisable by a Rule running
  in another. This has to compose with Riptide's already-shipped Phase 4c
  ACP-based authorization, not duplicate it — Capability is *scoped by* the
  existing tenant/grant model, not a second, parallel permission system.

### 3.2 Signature, Dialect, Rule

- **Signature** — the typed interface of a Rule: its parameters, and which
  predicates it reads/produces. Reuses DOL's `Sign` precisely.
- **Dialect** — which concrete rule language a Rule is expressed in. Two
  candidate targets are being tracked, not one: **SPARQL-RL** and **SHACL
  1.2 Rules** are both live W3C Working Drafts on the Recommendation track
  as of this writing, developed in parallel by the Data Shapes Working
  Group — the first draft of this spec incorrectly described SPARQL-RL as
  SHACL 1.2 Rules' successor; that relationship isn't documented anywhere
  and both documents are actively progressing. Track both; adopt whichever
  reaches sufficient maturity/tooling support first, or both if they serve
  different needs. Reference engine for actual evaluation: Soufflé's
  extended Datalog.
- **Rule** — a declarative IDB definition over a Signature: given a Body,
  conclude a Head. A Body is a conjunction of literals over two kinds:
  ordinary **Fact-pattern literals** (matched against the EDB, as in
  classical Datalog) and, where applicable, a distinguished
  **capability-reference literal** — a reference to a Capability that
  ExecuteInterpretation may invoke. This second literal kind is what closes
  the gap the first draft left open: NativeTemplate's capability-invoking
  behavior is now part of Rule's own definition, not asserted about Rule
  from the outside. QueryInterpretation treats a capability-reference
  literal as inert (unevaluable, contributing nothing to derived facts);
  ExecuteInterpretation is what actually invokes it.

### 3.3 Capability, NativeTemplate, Template

- **Capability** — an explicit, tenant-scoped, grantable permission (spawn a
  process, read a path, reach a host). Backed by WASI Preview 2 (no ambient
  authority, no subprocess spawning by design) plus WASIX where subprocess
  spawning is specifically granted (§4.3). Composes with Riptide's Phase 4c
  ACP model per §3.1 — not a parallel system.
- **NativeTemplate** — a Rule whose Body is exactly one capability-reference
  literal and nothing else: the base case, backed by a real,
  capability-scoped WASI component. **Sequencing note, fixing a real
  ordering ambiguity in the first draft:** Phase 2 (§7) builds the
  capability-scoped WASI *execution substrate* standalone, with no Rule
  representation involved at all — it does not yet produce NativeTemplate
  instances, because NativeTemplate is a Rule, and Rule's own representation
  isn't built until Phase 3. Phase 4 is what wraps the Phase 2 substrate as
  actual NativeTemplate Rule instances. "NativeTemplate is the base case of
  Rule" describes the finished system, not the build order.
- **Template** — `Template ⊑ Rule ⊓ (∃ a reachable step whose
  ExecuteInterpretation invokes a Capability)`. This *is* a structural
  predicate (graph reachability over the Rule's own Body/composition
  structure) — the first draft's claim that Template membership involves
  "no structural difference" from Rule was imprecise and is dropped here.
  The real point, stated correctly: Template is not a *separate primitive*
  requiring its own representation — it's a checkable property of the one
  Rule representation everything already shares.

### 3.4 Trace, Generalization, Provenance

- **Trace ⊑ Rule.** Revised from the first draft, which typed Trace as an
  unrelated primitive and then couldn't consistently type Generalization
  around it (§9, item 2). A Trace is simply a Rule whose Signature has no
  free parameters — every value is already ground, from one concrete run
  (a Rule's ExecuteInterpretation with specific bindings, or an ad hoc
  LLMFallback episode). This makes Trace a degenerate case of Rule, not a
  different kind of thing.
- **Generalization — uniformly `Rule × Rule → Rule`.** Anti-unification
  (Plotkin 1970) computes the least-general-generalization of any two Rules
  — whether both are ground (two Traces), one is ground and one already has
  free parameters (a new Trace against an existing candidate), or neither is
  ground (DedupGate anti-unifying a candidate against a CatalogEntry). One
  operation, one type signature, used identically everywhere it appears in
  §3.6's pipeline. Always accompanied by the substitutions recovering each
  input and by mandatory **Provenance** — the dependency edge back to what
  was generalized, which is what keeps a generalized Rule from becoming an
  ungoverned second source of truth.
- **Consequence for admission, stated explicitly because the first draft
  left it implicit and inconsistent:** a Rule generalized from only one
  Trace (i.e., still ground, zero free parameters) is not admissible as a
  CatalogEntry — a zero-parameter "template" isn't reusable by definition.
  DedupGate's `Admit` path requires at least one real Generalization step
  (at least two distinct Traces or an existing Rule contributing to it).
  Single, unrepeated Traces stay Traces; they don't get promoted to the
  catalog on their own.

### 3.5 Interpretation

A function `(Rule, Bindings, EDB-state) → Outcome`. At least two disjoint
kinds — **QueryInterpretation** (pure, Outcome ⊑ new Facts, treats
capability-reference literals as inert) and **ExecuteInterpretation** (the
same Rule, but capability-reference literals are actually invoked) — with
more expected later (dry-run, cost-estimate, explain/audit). Algebraic
effects/handler theory (Plotkin & Power; Plotkin & Pretnar) is the closest
established formalism for this shape, and tagless-final the closest
established technique for adding interpreters without touching existing code
— both real, well-grounded inspiration, neither a proof this specific design
is correct. (These two citations were re-verified in an earlier pass of this
design process, not in the final re-verification pass behind this revision —
carried forward, not re-checked here.)

**On the Generalization Fidelity requirement — reframed, not just renamed,
from the first draft's "law."** The first draft asserted, as if it followed
from anti-unification's proven properties, that
`ExecuteInterpretation(g, σ₁)` must reproduce a source Trace's effects
exactly. That doesn't follow from anything cited: Plotkin's proof is about
syntactic recoverability of term structure via substitution, not about
semantic reproduction of real-world, potentially non-idempotent effects.
Asserting it as inherited rigor was the exact overclaiming failure mode this
document is otherwise careful to avoid, applied to itself.

The honest version: **fidelity is a requirement this system has to be
engineered to satisfy, not a property that falls out of the math for free.**
Concretely, it needs:
- A defined notion of what "reproduce effects" means per Capability — some
  effects are naturally idempotent (a `kubectl apply` of the same manifest),
  many are not (anything that appends, increments, or has external
  side-state).
- A replay-testing mechanism — running `ExecuteInterpretation(g, σᵢ)` in a
  sandboxed/simulated mode and comparing against the recorded Trace it was
  generalized from — as an actual test oracle for DedupGate's `Merge`
  decisions, not an assumption they satisfy automatically.
- Explicit handling for Capabilities that can't be safely replay-tested at
  all (destructive, non-idempotent operations) — these may need to stay
  ungeneralized, or require the human review step (§3.6) to certify fidelity
  manually rather than mechanically.

This is real, non-trivial engineering scoped to Phase 5 (§7), not resolved
here.

### 3.6 DedupGate, CatalogEntry, Discovery, Task, LLMFallback

- **DedupGate** — anti-unifies a freshly-generalized candidate against the
  Catalog and yields `Reject`, `Merge`, or `Admit`. Both `Admit` and `Merge`
  require human review before the result is live — `Admit` because that's
  `scratch-command-bar`'s and administration-commons' existing precedent
  (review before any commons entry, not scoped to merges); `Merge`
  additionally because graph three-way merge is provably weaker than git's
  line-based merge: RDF's unordered-set structure lets adds/removes combine
  mechanically without ever raising a syntactic conflict, which can silently
  produce a semantically wrong result (Quit Store and Touch Merge's academic
  treatment of exactly this failure mode; re-verified in an earlier pass of
  this process, not the final one). `Reject` skips review — nothing changes.
- **CatalogEntry** — `⊑ Rule`, admitted or merged by DedupGate, subject to
  §3.4's admission consequence (no zero-parameter entries). Carries a
  Description for Discovery.
- **Discovery** — search over CatalogEntry only. Two sub-capabilities with
  different readiness timelines (§7): exact/keyword lookup by name (viable
  as soon as any CatalogEntry exists) and hybrid keyword+embedding
  progressive disclosure (only useful once there's a catalog large enough to
  need it). Conflict resolution when multiple entries match: recency first,
  specificity as tiebreaker (CLIPS's LEX strategy; re-verified in an earlier
  pass, not the final one).
- **Task** — the entry point. Triggers Discovery; a confident match invokes
  that CatalogEntry's ExecuteInterpretation directly; no match triggers
  **LLMFallback**, whose resulting Trace feeds Generalization → DedupGate →
  possibly a new CatalogEntry, subject to the admission consequence above.

## 4. Grounding

**4.1 Rule dialects — corrected.** Institution theory covers Horn Clause
Logic as a genuine sub-institution of first-order logic (Diaconescu 2006,
re-verified against the primary source in this revision's final pass) —
that's real and precise. What's *not* established, and wasn't hedged
carefully enough in the first draft: Soufflé's extended Datalog (aggregation,
stratified negation) and both SPARQL-RL and SHACL 1.2 Rules go beyond pure
Horn Clause Logic. The institution-theoretic grounding for Dialect covers the
Horn-clause *core* of what these dialects express, not their full extent —
stated honestly here, matching the hedging discipline §4.2 already applied
to the anti-unification/institution-theory question. Soufflé's hard
requirement that user-defined functors stay pure and reentrant (re-verified
against Soufflé's own docs in this revision's final pass — a genuine "must,"
execution guarantees void otherwise) remains real, independent validation
that effects belong in a separate interpreter, never a live call inside the
pure evaluator.

**4.2 Anti-unification — corrected, with a real design consequence.**
Plotkin/Reynolds (1970) is correctly the source for flat first-order
syntactic anti-unification, proven unitary (a unique lgg always exists).
It is **not** the source for term-graph anti-unification, and the first
draft's citation was wrong. The actual term-graph result (Baumgartner,
Kutsia, Levy & Villaret, FSCD 2018) proves the *general* term-graph case is
only **finitary** — a finite, minimal, but not necessarily singleton set of
incomparable generalizations can exist. Unitarity (one unique lgg) is proven
only for the narrower special case of **bisimilar term-graphs**.

This has a real consequence the first draft's overclaim was hiding: **the
Rule representation needs to be restricted to the bisimilar-graph fragment
specifically**, not just "the term-graph fragment" generally, if DedupGate is
to assume a single canonical generalization rather than needing to arbitrate
among several incomparable ones. Whether the workflow-graph shape this
system needs (typed steps, branch/loop/call) can be constrained to stay
inside that narrower fragment, or whether DedupGate genuinely needs to
handle a finite set of candidates and let human review pick among them, is
now an explicit open question (§8) rather than a settled fact. Minimizing
generalization variables remains NP-complete in the closest scalable
formalism (Yernaux & Vanhoof 2022, unordered goals — re-verified precisely
in this revision's final pass, confirmed as NP-complete, a stronger result
than the "NP-hard" the first draft stated) — accept a bounded/greedy
generalization regardless of which fragment is chosen.

**4.3 Execution kernel.** WASI Preview 2 excludes fork/exec/subprocess
spawning by design; WASIX is the separate superset restoring it. Kernel
primitive: "execute a capability-scoped WASM component," subprocess
spawning one optional grantable Capability among others. (Re-verified in an
earlier pass, not this revision's final one.)

**4.4 Bitemporal facts.** Datomic is unitemporal; XTDB's two-axis model
(system transaction-time, user-assigned valid-time) is the target shape,
via RDF-star + OWL-Time. Valid-time must be duplicated into ordinary
queryable fact form for the derivation layer to reason over it — XTDB's
indexing alone only controls which document version a query sees. (Re-verified
in an earlier pass, not this revision's final one.)

**4.5 Versioning.** TerminusDB and Fluree implement git's model over graph
data; graph three-way merge is weaker than git's (see §3.6). (Re-verified in
an earlier pass, not this revision's final one — maintenance-status claims
about both projects specifically should be treated as time-sensitive and
worth a fresh check before Phase 6 planning starts, not assumed current
indefinitely.)

**4.6 Parallelism — fully re-confirmed in this revision's final pass, with
more precision than the first draft had.** Soufflé compiles `par...endpar`
blocks to OpenMP-annotated C++ (GCC's OpenMP runtime, threads pinned to
cores) implementing semi-naive evaluation — not runtime interpretation.
Backed by two purpose-built concurrent structures: a concurrent B-tree
(optimistic fine-grained locking extending seqlocks, plus a traversal-reuse
"hints" mechanism) and Brie, a concurrent trie hybridizing trie/B-tree design
with lock-free insertion. This is the adoptable answer for
QueryInterpretation. ExecuteInterpretation concurrency has no equivalent
answer and stays explicitly open (§2, §7 Phase 4b).

**4.7 Conflict resolution.** CLIPS's LEX strategy: recency checked before
specificity, specificity only the final tiebreaker. (Re-verified in an
earlier pass, not this revision's final one.)

**4.8 Authoring.** LinkML isn't a replacement for StreamLD's shipped SHACL
schemas — a safely-deferrable representation choice. Adopted now for the
*new* Phase 3 rule schema specifically: `linkml-datalog` (real, alpha,
dormant since Feb 2024 as of the last check) already demonstrates "author in
LinkML, generate a working Soufflé Datalog program" as a working pattern.
(Re-verified in an earlier pass, not this revision's final one — worth a
fresh liveness check before depending on it in Phase 3 planning, given how
long "dormant since Feb 2024" has now been true.)

**4.9 Human review, UI, and repo integration.** External research on
review-gate placement and generic-shape-driven UI came back empty twice —
treated as a real signal, not bad luck. Uses local precedent instead:
`scratch-command-bar`'s working propose/review loop, administration-commons'
stated review principle, `graphsheet`'s shipped SHACL-driven UI. **Added in
this revision:** this layer is not yet reflected in Riptide's own
PROGRESS.md sub-project table, which the repo treats as the canonical
current-status reference — that should happen no later than Phase 2 start,
not as an afterthought once the whole roadmap is further along.

**4.10 Elixir OAuth.** No Elixir Datalog ecosystem to lean on
(`lambdaclass/datalog` dead stub; `fogfish/datalog` real, dormant since
2019). OAuth needs hand-porting to Elixir, the same scoped cost
`sovereign-ops` already identified for its own agent loop. (Re-verified in
an earlier pass, not this revision's final one.)

## 5. Worked example

Added in this revision — the first draft had none, and the cold review
correctly flagged that as a real source of the ambiguities it found.

1. **Task**: "deploy the billing service." Discovery finds no matching
   CatalogEntry (first time this kind of task has occurred). LLMFallback
   runs: the LLM issues concrete tool calls, producing a ground
   **Trace** — a zero-parameter Rule whose Body is a specific sequence of
   capability-reference literals with concrete arguments
   (`kubectl(apply, "billing.yaml", "prod")`, `kubectl(rollout-status,
   "billing", "prod")`).
2. Per §3.4's admission consequence, this single Trace is **not** admitted —
   it's stored as a Trace with Provenance pointing at nothing (it's the
   first occurrence), and the Task completes by running it directly under
   ExecuteInterpretation.
3. **Weeks later**, a second Task: "deploy the auth service." Discovery again
   finds no CatalogEntry, but this time a Trace-similarity check (a cheap
   prefilter, not full anti-unification, over the stored Trace log) surfaces
   the billing-deploy Trace as a candidate. LLMFallback's new Trace and the
   old Trace go through **Generalization**: anti-unification finds they
   agree on `kubectl(apply, ?, "prod")` and `kubectl(rollout-status, ?,
   "prod")`, diverging only on the manifest/service name — producing a
   genuinely parameterized Rule with one free parameter, plus the
   substitutions recovering each original Trace.
4. This candidate goes to **DedupGate**. The Catalog is empty, so there's
   nothing to anti-unify against for dedup purposes — it's a novel,
   admissible candidate (it has a real parameter, satisfying §3.4). Per §3.6,
   `Admit` requires human review regardless: a reviewer sees the proposed
   Rule, its Description, and — per §3.5's fidelity requirement — evidence
   from a sandboxed replay that specializing it back to each original Trace's
   bindings reproduces each original run.
5. Reviewer approves. It becomes a **CatalogEntry**: `deploy-service-to-prod`,
   one parameter (`service`).
6. **Third occurrence**: Task "deploy the auth service" (again, or a
   different service) now hits Discovery's exact/keyword lookup, finds the
   CatalogEntry directly, and runs `ExecuteInterpretation` with the bound
   parameter — zero LLM calls.

## 6. Diagram

```
  Content / domain           (lattice, MiKaDiv, KaFE — unaffected)
  Extraction / population    (scratch-command-bar's pattern — LLMFallback + review)
  ── new in this spec, abstraction layers — NOT call order; see §5 for call order ──
  Discovery
  Anti-unification / DedupGate
  Interpretation             (Query / Execute)
  Rule (IDB)                 (SPARQL-RL / SHACL 1.2 Rules-targeted, Soufflé-referenced)
  ── existing, unchanged ───────────────────────────────────────
  Execution kernel           (WASI + WASIX capability, tenant-scoped)
  Fact / Event (EDB)         (Riptide today, extended with valid-time)
```

## 7. Phased build order

1. **Bitemporal fact shape.** Changes what a fact looks like; must land
   before anything reads/writes facts downstream. Depends on nothing but
   Riptide as it exists today. Scope detailed in §7.1.
2. **Execution substrate in isolation.** WASI component execution, the
   WASIX capability grant, **tenant-scoped from the start** (§3.1) — tested
   with no Rule representation involved. This phase must also produce the
   integration point with Riptide's Phase 4c ACP model; shipping a
   capability-grant mechanism that doesn't yet compose with existing
   authorization is not acceptable exit criteria for this phase. Add this
   layer's own entry to PROGRESS.md's sub-project table here, not later
   (§4.9).
3. **Pure derivation engine.** Cross-stream joins, recursion, aggregation,
   query interpretation only. Depends on Phase 1.
4. **Wiring — split into two sub-phases, correcting the first draft's single
   "pure wiring" phase that actually hid its hardest problem.**
   - **4a — mechanical wiring.** Connect Phase 2's substrate and Phase 3's
     engine: add the execute interpreter, NativeTemplate instances become
     real (§3.3), `call_template` works for the first time against a small,
     hand-authored set of NativeTemplates. Genuinely low-risk, no open
     research questions.
   - **4b — concurrent-effects design spike.** The problem named in §2 and
     §4.6: no established theory answers how two concurrent
     ExecuteInterpretations should be coordinated when they touch
     overlapping, irreversible resources. This is real, open design work,
     scoped and staffed as such — not a checklist item inside 4a.
5. **Anti-unification: Generalization and DedupGate**, including the
   replay-testing fidelity mechanism from §3.5. Depends on 4a.
6. **LLM fallback loop.** Last among the "core" phases — needs 5's gate to
   have somewhere to put its output.
7. **Discovery — split by readiness, correcting the first draft's
   single-phase, catalog-must-already-be-large framing.**
   - **7a — exact/keyword lookup.** Viable as soon as any CatalogEntry
     exists (as early as Phase 5), giving a real, working walking skeleton
     (§5's example, end to end) well before the full roadmap ships — the
     first draft had no demonstrable milestone before the very last phase.
   - **7b — hybrid keyword+embedding progressive disclosure.** Deferred
     until the catalog is large enough to need it.

**Ongoing, not sequential:** LinkML authoring (§4.8) applied to each new
schema as created.

### 7.1 Phase 1 — ready to plan

- RDF-star `validFrom`/`validTo` annotation convention on individual facts.
- A defined OWL-Time Allen-relation subset for interval comparisons.
- ValidTime defaults to TransactionTime when unspecified (XTDB's default).
- Applies to all new writes in Riptide's existing LDP write path — no new
  engine, no behavior change beyond the annotation.
- Deferred to Phase 3+: making ValidTime queryable/joinable in rule logic.

## 8. Open questions

- OpenFASTER-Standard public governance status.
- Whether this engine is operationally a separate deployable from Riptide's
  LDP surface, given Capability grants expand the trusted computing base
  (§1) — genuinely unresolved, not just undecided by omission.
- Concurrent-effectful-execution coordination — no established answer;
  Phase 4b's actual subject matter, not a footnote.
- Whether the Rule/workflow-graph representation can be constrained to the
  bisimilar-term-graph fragment where anti-unification is proven unitary, or
  whether DedupGate must handle a finite set of incomparable generalizations
  (§4.2) — newly surfaced by this revision, not resolved.
- Formal versioning/supersedes theory for declarative rules — none found;
  pragmatic git/TerminusDB model adopted instead.
- Final Tenant name.
- Fresh liveness checks needed before depending on them operationally:
  `linkml-datalog` (dormant since Feb 2024 at last check) and
  TerminusDB/Fluree's current maintenance status (§4.5, §4.8).

## 9. What changed in this revision, and why

For anyone comparing against the first draft: this is not a copyedit.
- §3.2/§3.3/§3.4: Rule's definition now actually accommodates
  NativeTemplate; Trace is now `⊑ Rule` instead of an incompatible sibling
  type; Generalization has one consistent type signature (`Rule × Rule →
  Rule`) instead of three incompatible ones used in different places.
- §3.5: the Generalization Fidelity "law" is reframed from an inherited
  proof to an engineering requirement this system has to earn, with a
  concrete mechanism (replay-testing) instead of an assumption.
- §4.1: SPARQL-RL is no longer described as succeeding SHACL 1.2 Rules —
  they're two parallel, currently-live drafts. Institution-theoretic
  grounding for Dialect is now scoped to the Horn-clause core, not the full
  extent of the actual target dialects.
- §4.2: anti-unification's term-graph unitarity claim is correctly
  attributed (Baumgartner et al. 2018, not Plotkin/Reynolds) and correctly
  scoped (finitary in general, unitary only for bisimilar graphs) — with a
  real, newly-surfaced open question this creates for DedupGate.
- §3.1: Capability is now tenant-scoped and required to compose with
  Riptide's existing ACP model — a real security gap in the first draft.
- §7: Phase 4 is split into a genuinely-low-risk wiring step and an
  honestly-scoped open-research step, instead of one phase mischaracterized
  as both. Phase 7 is split so a real walking skeleton exists many phases
  before the end of the roadmap, instead of no working demonstration until
  everything ships.
- §5 (worked example) and §1's deployment-scope narrowing are new; both were
  gaps a cold reader flagged, not refinements of something already there.
