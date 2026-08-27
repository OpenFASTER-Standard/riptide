# Derivation and Execution Layer — Architecture Design

**Status:** Draft, pending review. This is an architecture spec covering the full
vision and a phased roadmap — not a single implementation plan. Each phase below
gets its own implementation plan (via the `writing-plans` process) when work on it
starts, per the usual decomposition discipline for a project too large for one plan.

## 1. Motivation and vision

Riptide today is an event-sourced fact store (StreamLD's reference implementation):
an append-only, per-resource log of RDF facts, with one hardcoded derivation (replay
a stream's events in order to compute current state). This spec adds the layer that
was structurally missing: a general **derivation and execution engine**, so that
"answer a question about the facts" and "cause an effect in the world" become two
interpretations of the same declarative object, evaluated by one engine, rather than
bespoke application code per feature.

The organizing idea, carried through every layer of this design: **the atomic unit
should have a stable identity, and everything else — labels, presentations,
procedures — should be a *view* derived from that identity, never the identity
itself.** Riptide's event log already does this for facts (an IRI, never a label,
is what anything actually references). This spec extends the same discipline to
*rules* and *capabilities*, so the whole system stays one substrate that things are
derived from, not several substrates that need reconciling.

This is why the work in this document lives inside Riptide rather than as a
separate service: once "querying" and "doing" are understood as the same kind of
operation (two interpretations of one rule, evaluated by one engine — see §3.5),
there is no natural seam to split into two systems. A separate service calling
Riptide over an API would reintroduce exactly the two-sources-of-truth problem this
design exists to avoid.

## 2. Scope and explicit non-goals

**In scope:** the conceptual object model (the T-box, §3), the phased build order
(§6), and the concrete, ready-to-plan scope of Phase 1 (§7).

**Explicitly out of scope for this document** — flagged as open, not silently
assumed:
- Whether this layer ever becomes a public `OpenFASTER-Standard` module (like
  StreamLD itself) or stays Riptide-internal. Nothing in the roadmap forces this
  decision before there's something substantial enough to be worth standardizing.
- Formal theory for coordinating **concurrent effectful** rule executions (e.g. two
  templates racing on the same Kubernetes namespace). Research specifically
  checked whether the saga pattern or CRDTs answer this and found neither
  established for this case — CRDT convergence theory is about merging *data*, not
  arbitrating *irreversible real-world effects*. This needs its own design spike
  when Phase 4 is reached, not a borrowed citation.
- Detailed UI design. `graphsheet` already solves generic-UI-from-shape for SHACL
  data in this same ecosystem; the review/discovery/monitoring surfaces this layer
  needs should reuse that pattern rather than be designed from scratch, but the
  actual screens are not designed here.
- The final human-facing name for a Riptide tenant. Shortlist from brainstorming:
  **Polity**, Enclave, Civitas, Demesne. This document uses **Tenant** as a
  placeholder term throughout; find-and-replace once decided.

## 3. Core concepts (the T-box)

Every concrete technology choice in §4 is an instance of one of these concepts.
This section is deliberately technology-agnostic.

### 3.1 Fact, Event, Tenant

- **Fact** — an atomic RDF(-star) assertion in the EDB. Carries a *TransactionTime*
  (free, from Riptide's existing per-stream sequence number) and optionally a
  *ValidTime* interval, RDF-star-annotated (see §4.4). Produced by exactly one
  **Event** (an append to a stream).
- **Tenant** *(name TBD, see §2)* — an isolated administrative/institutional space.
  Facts, Rules, and CatalogEntries are partitioned by Tenant. A person may hold
  exactly one "institutional" Tenant plus any number of private Tenants (the
  long-term ambition motivating the naming question) — this spec does not design
  the multi-tenancy mechanics themselves, which are Riptide's existing phase-4a
  work; it only adds Tenant as a T-box concept that Facts and Rules are scoped by.

### 3.2 Signature, Dialect, Rule

- **Signature** — the typed interface of a Rule: its parameters, and which
  predicates it reads/produces. This is the one piece of literal
  institution-theoretic vocabulary reused here — precisely, not by analogy,
  matching DOL's `Sign`.
- **Dialect** — which concrete rule language a Rule is expressed in (target:
  SPARQL-RL; reference engine: Soufflé's extended Datalog). This is where real
  heterogeneity lives, and it is the part institution theory actually, rigorously
  covers (Horn Clause Logic as a sub-institution of first-order logic).
- **Rule** — a declarative IDB definition over a Signature: given a Body (a
  pattern over Facts, possibly self-referential), conclude a Head.

### 3.3 Capability, NativeTemplate, Template

- **Capability** — an explicit, grantable permission (spawn a process, read a
  path, reach a host) that only a NativeTemplate consumes. Backed by WASI
  Preview 2 (no ambient authority, no subprocess spawning by design) plus WASIX
  where subprocess spawning is specifically granted (see §4.3).
- **NativeTemplate** — a Rule with no further Body — the base case, backed by a
  real, capability-scoped WASI component. The bootstrapping kernel.
- **Template** — precisely: `Template ⊑ Rule ⊓ (∃ a reachable step whose
  ExecuteInterpretation invokes a Capability)`. Not a separate primitive from
  Rule — a Rule becomes a Template exactly when it does something, not by any
  structural difference.

### 3.4 Trace, Generalization, Provenance

- **Trace** — a record of one concrete run: a Rule's ExecuteInterpretation with
  specific bindings, or an ad hoc LLMFallback episode.
- **Generalization** — `Trace × Trace → Rule`, computed via anti-unification
  (Plotkin 1970): the least-general-generalization of two concrete instances,
  always accompanied by the substitutions that recover each original and by
  mandatory **Provenance** recording what it was generalized from.
- **Provenance** is what keeps a generalized Rule from becoming an ungoverned,
  independently-asserted second source of truth — the same discipline a
  materialized view needs: a dependency edge back to what it was derived from.

### 3.5 Interpretation

A function `(Rule, Bindings, EDB-state) → Outcome`. At least two disjoint kinds:
- **QueryInterpretation** — pure, Outcome ⊑ new Facts, no side effects. Classical
  Datalog derivation.
- **ExecuteInterpretation** — the same Rule, but a designated step may invoke a
  Capability.

More modes (dry-run/simulate, cost-estimate, explain/audit) are expected later —
this is deliberately an open, extensible set, not a hardcoded pair. Algebraic
effects/handler theory (Plotkin & Power; Plotkin & Pretnar) is the closest
rigorously-established formalism for "one program, many interpretations," and
tagless-final is the closest established technique for adding new interpreters
without touching existing code (the expression problem) — both are real,
well-grounded inspirations for this concept, and neither is a proof that this
system's specific design is correct. That distinction is intentional and should
stay explicit in any future writing about this layer, not get smoothed over.

**The Generalization Fidelity law** — the one cross-cutting invariant, earned by
this design rather than inherited from elsewhere: for any Generalization
producing Rule `g` from Traces `t₁, t₂` with substitutions `σ₁, σ₂`,
`ExecuteInterpretation(g, σ₁)` must reproduce `t₁`'s effects exactly, and
likewise for `t₂`. Generalizing and specializing back must commute with actually
running the thing. This is the concrete, checkable property any test suite for
the DedupGate (§3.6) must verify before trusting a merge.

### 3.6 DedupGate, CatalogEntry, Discovery, Task, LLMFallback

- **DedupGate** — takes a freshly-generalized candidate Rule, anti-unifies it
  against the existing Catalog, and yields `Reject`, `Merge`, or `Admit`. Both
  `Admit` and `Merge` require human review before the result becomes a live
  CatalogEntry — `Admit`, because that's `scratch-command-bar`'s and
  administration-commons' existing precedent (mandatory review before commons
  entry, full stop, not scoped to merges only); `Merge` additionally because
  of §4.6's finding on graph merge specifically — it is not safe to
  auto-resolve, the same way TerminusDB/Fluree's real merge strategies flag
  rather than silently combine overlapping subgraphs. Only `Reject` skips
  review, since nothing changes.
- **CatalogEntry** — `⊑ Rule`, admitted or merged by DedupGate. Carries a
  Description for Discovery's retrieval.
- **Discovery** — search over CatalogEntry only (progressive disclosure, hybrid
  keyword+embedding), never over un-admitted Rules. Conflict resolution when
  multiple entries match: recency first, specificity as tiebreaker, per the
  CLIPS LEX precedent (§4.7) — not specificity-first, which was the more
  intuitive but unverified assumption going in.
- **Task** — the entry point. Triggers Discovery; a confident match invokes that
  CatalogEntry's ExecuteInterpretation directly (zero LLM calls); no match
  triggers **LLMFallback**, whose resulting Trace feeds Generalization →
  DedupGate → possibly a new CatalogEntry.

## 4. Grounding — what's established vs. what's this design's own synthesis

Condensed from the research this spec is built on; kept here so the rationale
travels with the design rather than living only in conversation history.

**4.1 Rule dialects.** Institution theory legitimately covers this axis (HCL as a
sub-institution of FOL, Diaconescu 2006). SPARQL-RL (the W3C's emerging successor
to what would have been "SHACL 1.2 Rules") is the target dialect to track. Soufflé
is the reference engine — and its hard requirement that foreign functors stay pure
is independent, real-world validation that effects must be a *separate
interpreter*, never a live call inside the pure evaluator.

**4.2 Anti-unification.** Plotkin/Reynolds 1970. Proven "unitary" (a unique
least-general-generalization always exists) in the term-graph fragment — this is
why the Rule representation must stay inside that fragment, not drift into
unrestricted higher-order structure, where the guarantee provably collapses.
Minimizing the number of generalization variables is NP-hard in the closest
scalable formalism (Yernaux & Vanhoof 2022) — accept a bounded/greedy
generalization, not a promised-minimal one. No established literature connects
anti-unification to institution theory or to rule-specificity ordering — both
would be novel contributions of this design, not citations.

**4.3 Execution kernel.** WASI Preview 2 deliberately excludes fork/exec/subprocess
spawning (security-by-default). WASIX is the real, separate superset that restores
it. The kernel's one true primitive is "execute a capability-scoped WASM
component"; subprocess spawning is one optional, explicitly-granted capability
among others — present on this box (so `git`/`kubectl`/`terraform` keep working
unmodified), absent by default anywhere that shouldn't need it.

**4.4 Bitemporal facts.** Datomic is unitemporal (transaction-time only) — not a
positive precedent, despite earlier treatment as one. XTDB's two-axis model
(system-assigned transaction-time, user-assigned valid-time defaulting to
transaction-time) is the target shape, encoded via RDF-star annotations using
OWL-Time's Allen-relation vocabulary for interval comparisons. Important limit:
valid-time must be duplicated into ordinary queryable fact form for the
derivation layer to reason over it — XTDB's own bitemporal indexing only
controls *which document version* a query sees, it doesn't make valid-time a
first-class joinable relation for free.

**4.5 Versioning.** TerminusDB and Fluree are real, current, git-modeled graph
databases. Graph three-way merge is provably weaker than git's text merge (RDF's
unordered-set structure lets adds/removes combine mechanically without ever
raising a syntactic conflict, which can silently produce a semantically wrong
result) — hence §3.6's rule that `Merge` always requires human review.

**4.6 Parallelism.** Soufflé's mechanism is real and specific: compile-time
`par...endpar` blocks lowered to OpenMP-annotated C++, backed by purpose-built
concurrent data structures (a concurrent B-tree, a concurrent trie called
"Brie"). This is the adoptable answer for QueryInterpretation. ExecuteInterpretation
concurrency (§2) has no equivalent answer and is explicitly open.

**4.7 Conflict resolution.** CLIPS's LEX strategy checks recency before
specificity, specificity only as the final tiebreaker — informs Discovery's
ordering (§3.6).

**4.8 Authoring.** LinkML is not a replacement for StreamLD's already-shipped
SHACL schemas (a safely-deferrable representation choice, since generated SHACL
is equivalent to hand-written SHACL). It *is* adopted now for the **new** Phase 3
rule/template schema specifically, because `linkml-datalog` (real, if alpha and
dormant since Feb 2024) already demonstrates "author in LinkML, generate a
working Soufflé Datalog program" as a working pattern, not a hypothesis.

**4.9 Human review and UI.** External research on review-gate placement and
generic-shape-driven UI came back with zero verified coverage across two
independent attempts — treated as a real signal, not bad luck, that these are
softer practice questions than the rest of this document's grounding. This spec
uses local precedent instead: `scratch-command-bar`'s working propose/review
loop and administration-commons' stated principle for *where* human review
sits (before commons entry), and `graphsheet`'s shipped SHACL-driven UI for
*how* review/discovery/monitoring surfaces should be built.

**4.10 Elixir OAuth.** No existing LinkML-Elixir or general Elixir Datalog
ecosystem to lean on (`lambdaclass/datalog` is a dead stub; `fogfish/datalog`
is real but dormant since 2019 — worth studying, not a dependency to trust
blindly). The Claude subscription OAuth flow needs porting by hand to Elixir,
the same real, scoped cost `sovereign-ops` already identified for its own
agent loop — not a new unknown.

## 5. Diagram (informal — one substrate, six layers, only two of them new)

```
  Content / domain           (lattice, MiKaDiv, KaFE — unaffected by this spec)
  Extraction / population    (scratch-command-bar's pattern — LLMFallback + review)
  ── new in this spec ──────────────────────────────────────────
  Discovery                  (§3.6 — catalog search)
  Anti-unification / DedupGate (§3.4, §3.6 — generalize, dedup, human-reviewed merge)
  Interpretation             (§3.5 — Query / Execute, algebraic-effects-inspired)
  Rule (IDB)                 (§3.2 — SPARQL-RL-targeted, Soufflé-referenced)
  ── existing, unchanged ───────────────────────────────────────
  Execution kernel           (§4.3 — WASI + WASIX capability)
  Fact / Event (EDB)         (Riptide today, extended with valid-time — §4.4)
```

## 6. Phased build order

Each phase exists because the next one needs it, not because it's a natural
checklist item — see the dependency reasoning, not just the sequence.

1. **Bitemporal fact shape** (§7, detailed below). First because it changes what a
   fact *looks like* — every later phase reads/writes facts, so retrofitting this
   after Rules exist means touching everything downstream. Depends on nothing but
   Riptide as it exists today.
2. **Execution kernel in isolation.** WASI component execution, the WASIX
   capability grant, the native/leaf template set — tested with no rule language
   involved at all. Independent of Phase 3; only needs to exist before Phase 4.
3. **Pure derivation engine.** Cross-stream joins, recursion, aggregation, moving
   toward SPARQL-RL syntax, evaluated with the query interpreter only — no effects.
   Isolated from Phase 2 so derivation bugs and effect bugs are never tangled
   together. Depends on Phase 1 (needs the final fact shape).
4. **Wire Phases 2 and 3 together.** Add the execute interpreter; `call_template`
   becomes real for the first time. Pure wiring, no new logic — but this is also
   where §2's concurrent-effects question has to actually get answered, not
   deferred further.
5. **Anti-unification: generalization and the DedupGate.** Only meaningful once
   real rules exist in the engine's own representation (Phase 4).
6. **LLM fallback loop.** Deliberately last among the "core" phases — the escape
   hatch for the unknown, with somewhere coherent (Phase 5's gate) to put its
   output. Starting here, as originally conceived, would have meant a harness with
   nowhere for its distillations to land.
7. **Discovery.** Only relevant once Phases 4–6 have produced a catalog worth
   searching.

**Ongoing, not sequential:** LinkML authoring (§4.8) applied to each new schema as
it's created (Phase 1's bitemporal envelope, Phase 3/4's rule schema).

## 7. Phase 1 — ready to plan

Concrete, bounded scope for the first implementation plan:

- Define the RDF-star `validFrom`/`validTo` annotation convention for individual
  facts (quoted-triple syntax, per §4.4).
- Adopt a defined subset of OWL-Time's Allen-relation vocabulary for interval
  comparisons (before/after/meets/overlaps/during/starts/finishes/equals, at
  minimum).
- ValidTime defaults to TransactionTime when unspecified, matching XTDB's
  documented default.
- This becomes the fact-writing convention for all new writes going forward, in
  Riptide's existing LDP write path — no new engine, no new derivation, no
  behavior change beyond the added annotation.
- Explicitly deferred to Phase 3+: making ValidTime queryable/joinable inside
  rule logic. Phase 1 only establishes that the field exists on facts.

## 8. Open questions (tracked, not blocking)

- OpenFASTER-Standard public governance status for this layer (§2).
- Concurrent-effectful-execution coordination theory — no established saga/CRDT
  answer found; needs a dedicated design spike at Phase 4 (§2, §4.6).
- Formal versioning/supersedes theory for declarative rules — adopted the
  pragmatic git/TerminusDB model instead of a formal criterion, since none was
  found (§4.5).
- Final Tenant name (§2).
