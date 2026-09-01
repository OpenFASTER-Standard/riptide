# Derivation and Execution Layer — Research Log

**Purpose.** This file is the archival research trail behind
[`2026-08-27-derivation-and-execution-layer-design.md`](2026-08-27-derivation-and-execution-layer-design.md)
(the current, lean, decision-focused architecture spec for Riptide's
Sub-project 6). That spec states conclusions and links here for full
citations; this file has no normative content of its own — nothing here
overrides anything the design doc says. It exists so the underlying
literature review is checkable and the reasoning behind rejected
approaches isn't lost, without every future reader of the design doc
having to wade through it.

Restructured 2026-08-28 out of the design doc's own revisions 1–8, which
had grown to ~985 lines with the research trail and a full revision-by-
revision changelog interleaved into the current-state content. Nothing
below is new; it's relocated verbatim (or near-verbatim) from that
document's §8.7.1–§8.7.3, §8.12, and §11.

## Part 1: Formal versioning/supersedes theory for declarative rules

Three dedicated research passes, summarized in the design doc's current
§8.7 as: no existing formalism directly answers "rule B (refined)
supersedes rule A (generalized)"; the pragmatic git/TerminusDB-style
model is adopted; bottom-clause-style bounding is the one concrete,
actionable tool that came out of this research, informing Sub-project
6e's DedupGate arbitration mechanism. Full detail below.

### Pass 1 — four angles, 20 primary sources, 25 claims adversarially verified

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
  schema/rule change was found** in this pass — a genuine gap, not proof
  none exists; flagged for a follow-up pass under different terminology.
- **The most promising unexplored angle, surfaced but not itself
  researched yet:** anti-unification's own literature (Plotkin's
  least-general-generalization, ILP's generalization/specialization
  lattices under θ-subsumption) — closer to this spec's actual mechanism
  (Generalization) than either DL/TGD or AGM/KM.

### Pass 2 — chasing pass 1's own named leads (view update problem, schema mapping evolution, fresh 2023–2026 check)

- **The classical view update problem (Bancilhon & Spyratos 1981;
  Cosmadakis & Papadimitriou 1984, JACM; Franconi & Guagliardo 2012) is
  real, rigorous, and decidable in restricted cases** — the "constant
  complement" principle, operationalized as view-mapping invertibility,
  reducing to a decidable polynomial-time dependency-implication test for
  FD+JD-only schemas. **But confirmed, via full-text negative search, to
  answer a different question**: it's about translating a *data* update
  through a *fixed* view/rule, never about changing the rule mapping
  itself — zero occurrences of "evolution" or "compatible" anywhere in
  the primary literature. One transferable hint: extending even the
  propositional-level result to full first-order logic already requires
  structural restrictions (weak stratification, definiteness) — any
  analogous safe-generalization criterion for Riptide's own Rules would
  likely need similar restrictions, not a fully general result.
- **Schema-mapping-evolution literature (Fagin/Kolaitis/Popa/Tan 2011;
  Yu & Popa, VLDB 2005; Velegrakis/Miller/Popa, VLDB 2003) is real,
  foundational, and TGD-based** — directly relevant in substance, since
  it uses the same source-to-target TGD formalism as existential rules.
  Formalizes evolution as mapping composition/inversion, with a hierarchy
  of chase-based inverse notions and a "mapping universe" membership
  test. **But the authors never define an independent
  compatible/breaking predicate** — a change is judged safe only
  operationally, by whether the adaptation procedure succeeds — and a
  stronger reading (that this literature offers a clean two-tier
  validity/consistency breaking-change taxonomy) was explicitly refuted
  on verification. There's also a hard expressiveness ceiling: plain
  source-to-target TGDs aren't closed under composition in general, so
  composing two TGD-level changes can require stepping outside the
  TGD/Datalog language entirely (second-order TGDs) just to stay
  expressible.
- **No 2023–2026 advance was found for any previously-researched
  branch** — not AGM/Katsuno-Mendelzon logic-program update, not TGD
  conservative extension. The Jung/Lutz/Marcinkowski KR 2022 paper
  re-surfaced under this pass's own search is the *same* paper pass 1
  already found, not new information; its undecidability limits for
  linear/guarded TGDs stand unchanged.
- **Horn-theory/Datalog-program revision under database-dependency-theory
  framing (distinct from AGM/KR), and "does classical FD/IND implication
  theory give a safe-extension notion for a whole dependency set"** —
  both came back with zero on-point literature. After two dedicated
  passes searching different terminology for each, these are confirmed
  gaps, not just unsearched corners.

### Pass 3 — chasing the ILP/anti-unification lead directly, capped at 5 subagents

- **Four of five angles confirm the same gap, again, from ILP's own home
  field.** The subsumption lattice itself is a pure ordering, not a
  validity criterion — and θ-subsumption is a *sound but incomplete*
  proxy for logical implication, a gap so real that a widely-cited
  "convenient" special case of the field's own "Subsumption Theorem" was
  later proven **false**, requiring some published inverse-resolution
  results to be reconsidered (Nienhuys-Cheng & de Wolf, ILP-95). Refinement
  operators have precise soundness/completeness properties, but these
  characterize *search-traversal reachability* within an already-fixed
  ordering, not validity of replacing one rule with another — and a
  general **nonexistence** result holds: no "ideal" (locally-finite +
  proper + complete) refinement operator exists for unrestricted clause
  sets under θ-subsumption *or* full logical implication (van der Laag &
  Nienhuys-Cheng). Real ILP theory-revision systems (FORTE, INTHELEX,
  CLINT) uniformly accept a revision by an empirical/heuristic test
  (coverage of a fixed example set, accuracy improvement) — never a
  proof-theoretic guarantee that untouched entailments survive the
  revision. Wrobel (1993) is the one partial exception — formal AGM-style
  "base revision postulates" for *specialization* only, explicitly scoped
  away from generalization. FORTE's own authors independently rediscover
  and state the same AGM/ILP mismatch pass 1 already found from the belief-
  revision side: "this work does not address the inductive problem of
  generalizing a theory... [it] tends to focus on minimal semantic change
  which requires memorizing exceptions" — real corroboration from a
  second, independent lineage.
- **Version spaces (Mitchell 1978/1982; Hirsh 1991) is the one angle that
  gives something new and concretely usable.** Hirsh's theorem is
  domain-independent and rule-language-agnostic: *any* partially-ordered
  hypothesis language is representable by safe generalization/
  specialization boundary sets **if and only if it is convex and
  definite** — a real, checkable, general criterion, not
  attribute-value-specific. Applied honestly to an unrestricted Horn-
  clause/Datalog rule space, this typically **fails** (not definite) —
  the same nonexistence result as above, confirmed concretely: Progol's
  own unbounded hypothesis space is proven **not a lattice** (a
  generalization of two reachable clauses can itself be unreachable).
  **But there's a proven fix, already used in working ILP systems**:
  bounding the hypothesis space below by a "bottom clause" (Muggleton's
  inverse entailment) restores a genuine lattice — lgg and most-general-
  specialization both guaranteed to exist, ideal refinement operators
  provably exist for the *bounded* order even though they don't for the
  unbounded one (Tamaddoni-Nezhad & Muggleton 2009). And: anti-unification
  — the exact mechanism this spec adopted for Generalization — is
  confirmed to be literally the operation that builds the
  generalization/S-boundary side of this lattice for Horn clauses (Golem,
  ProGolem); the specialization/G-boundary side is the half that provably
  breaks down without bounding.
- **The actionable connection to the design doc's Rule-expressiveness
  decision:** this doesn't reverse that decision (Rule expressiveness
  stays unconstrained; DedupGate arbitrates incomparable generalizations)
  — but it gives Sub-project 6e a concrete, well-precedented *tool* for
  that arbitration: bottom-clause-style bounding **per anti-unification
  call** (anchoring a generalization attempt to a maximally-specific
  reference point) can recover a well-defined lgg locally, exactly where
  DedupGate needs one, without a blanket restriction on what a Rule's
  Body can express overall. A genuinely different lever than "constrain
  globally" (rejected) or "arbitrate freely with no structure" (the
  fallback) — a third option worth testing once 6c-i produces a real Rule
  representation to try it against.
- **Modern (2015–2026) work reuses classical machinery or answers a
  different question.** Popper (Cropper & Morel 2021) has a real, modern,
  machine-checked soundness theorem for pruning during search — built
  explicitly on unchanged Plotkin (1971)/Midelfart (1999) subsumption, not
  new theory. Patsantzis & Muggleton (2022) genuinely extend subsumption
  itself (to higher-order metarules) but for *search-procedure* validity,
  not rule-base update. `babble` (Cao et al., POPL 2023) — anti-
  unification-based library learning via e-graphs — has a real 2023
  soundness+completeness theorem for "abstraction validly replaces
  specific code," but the validity notion is semantic/operational
  equivalence (β-reduction), a structurally different tool than logical
  subsumption, answering "is this the same program," not "does this rule
  supersede that rule." The field's own authoritative retrospective ("ILP
  at 30," Cropper/Dumančić/Evans/Muggleton 2022) does not treat rule-
  supersession-for-versioning as either solved or an open problem — it is
  simply not on the mainstream research agenda.

## Part 2: Large objects and persistent capabilities (researched together)

A dedicated pass investigated blob storage and long-running/daemon-shaped
Capabilities as one connected question, since a native blob store and a
long-running capability are plausibly the same underlying problem. 18
underlying claims individually passed adversarial verification (mostly
3-vote, primary sources: official docs, project wikis, peer-reviewed
papers).

- **Blob architecture**: Ra (this project's own Raft library) already
  implements chunked, non-blocking transfer for its *internal* consensus
  snapshots — `ra_snapshot`'s leader-side `begin_read`/`read_chunk` and
  follower-side `begin_accept`/`accept_chunk`/`complete_accept`, with
  integrity validation. Real BEAM-ecosystem precedent, but scoped to Ra's
  own snapshots, not a general blob API — suggestive, not ready-made.
  Content-addressed chunking (git, casync/desync, IPFS/UnixFS) converges
  on one architecture: content-defined chunks named by a strong hash,
  stored as independently-addressable objects, with the pointer/index
  structure that names them deliberately decoupled from chunk storage
  (casync/desync's buzhash with a 16KB/64KB/256KB min/avg/max window).
  Mainstream Raft-based stores (etcd, TiKV, CockroachDB) were checked and
  confirmed to *discourage or hard-limit* large values through consensus
  (etcd's default max request size is 1.5MiB) rather than solving this
  themselves — validating the premise that a genuinely separate mechanism
  is needed, without supplying one ready-made. Riak CS (discontinued;
  historical precedent) is the closest concrete precedent for the *whole*
  shape: fixed blocks keyed by `{UUID, BlockId}`, garbage-collected via an
  explicit manifest state machine (`writing → active → pending_delete →
  scheduled_delete`) plus a dedicated GC bucket scanned by a background
  process. CORFU/Delos confirm the same separation at the consensus
  layer: a lightweight ordering/coordination step (CORFU's sequencer just
  hands out position tokens) stays separate from the bulk data plane
  (clients read/write flash units directly), with garbage collection via
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
  formalism a persistent Capability would also use.
- **Explicitly unresolved by this pass**: whether WASI Preview 2 (or
  later) has any native notion of a persistent/resumable component
  instance, as opposed to strict instantiate-call-terminate — no claim
  survived verification either way; whether the RabbitMQ/Ra maintainer
  team has ever discussed blob co-location with Raft-backed metadata
  beyond Ra's own internal snapshot-chunking — no claim surfaced; a
  concrete garbage-collection scheme for the case Riptide's own EDB
  actually creates (many RDF triples referencing the *same* chunk hash,
  unlike the object-store/shared-log semantics every precedent above was
  built for); and what security boundary governs the privileged
  blob-serving process itself, given it sits outside the general WASI
  sandbox by design.

## Part 3: Full revision history (design doc, revisions 1–8, before this restructuring)

**Eighth revision — third research pass, chasing the ILP/anti-unification
lead directly (capped at 5 subagents to bound token spend):** added the
Part-1-Pass-3 findings above; confirmed the AGM/ILP mismatch independently
from FORTE's own authors; recorded bottom-clause-style bounding as a
concrete tool for Sub-project 6e's arbitration mechanism, informing
(not reopening) the prior revision's Rule-expressiveness decision.

**Seventh revision — resolved the bisimilar-term-graph question:** Rule
expressiveness is not constrained to the bisimilar-term-graph fragment.
Real composability (rule-reference literals sharing values across calls)
wins over guaranteed-unique anti-unification. DedupGate must arbitrate
incomparable generalizations when they arise; the concrete mechanism is
left to Sub-project 6e.

**Sixth revision — second research pass on formal versioning/supersedes
theory:** added the Part-1-Pass-2 findings above; confirmed no 2023–2026
advance exists for either previously-found anchor; confirmed two more
angles (Horn-theory-via-database-dependency-theory, classical FD/IND
theory) as genuine gaps after dedicated passes.

**Fifth revision — large objects and persistent capabilities researched
together, per explicit direction not to treat them as separate:** added
the Part 2 findings above, including the connecting verdict.

**Fourth revision — resolving open decisions plus new research:**
resolved Tenant name ("Tenant," no rename — Polity/Civitas/Demesne
shortlist dropped), governance (Riptide-internal for now), and
deployability (same OS process). Added the Part-1-Pass-1 findings above.
Sketched large-object storage and flagged the daemon-capability gap as
new, unresearched open concerns. Updated the ACP-surface currency note
(security-audit remediation landed on `main` via PR #32).

**Third revision — a currency pass, not new design work:** restructured
phase numbering from independent "Sub-project 1–9" into a single
Sub-project 6 with phases 6a–6i, avoiding a collision with Riptide's own
`PROGRESS.md` table. Corrected the Dialect target (SHACL 1.2 Rules'
current URL redirects to SPARQL 1.2 RL — consolidated into one document,
not two independent drafts). Added the live audit-remediation caveat on
Riptide's ACP/auth surface. Noted 6a's dependency on the already-shipped
Phase 3a schema-versioning envelope. Re-verified liveness of
`linkml-datalog` (dormant), TerminusDB (active), and Fluree (very active).

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

**Restructuring (this file's creation), 2026-08-28:** following an
independent cold-context architecture review (see PR that introduced this
file for the full review), the design doc was substantially reorganized:
this research log was split out to separate archival citation detail from
current-state content; the design doc's own "resolved this revision"
narrative framing was removed in favor of stating current facts plainly;
several real gaps the review caught were fixed (an incomplete phase
dependency graph, a misplaced research note, no WASI resource-metering
requirement despite this project's own history of two separate
resource-exhaustion incidents, no assigned phase for the blob-storage
design, 6c bundling too much scope into one untracked phase, no exit
criteria per phase, and a public/governance terminology collision).

## Part 4: Concurrent-effectful-execution coordination (6d-ii)

The parent spec's §7/§10 carried an informal note — "checked: neither
sagas nor CRDTs establish this" — written during spec-drafting, not from a
dedicated research pass like Parts 1–2 got. A real pass, done while
brainstorming 6d-ii's design (2026-09-01), corrected and substantially
extended that note. Methodology matched Parts 1–2: parallel search across
6 angles, 24 sources fetched (primary docs/papers weighted over
secondary), 98 claims extracted, top 25 by centrality taken through 3-vote
adversarial verification (≥2/3 refutes kills a claim) — 20 confirmed, 5
refuted (all 5 were overreach/mis-citation on a true underlying point, not
claims that were simply wrong; detail below).

- **Sagas: the spec's dismissal is correct, and stronger than "checked
  informally" — it's definitional.** Garcia-Molina & Salem's original
  paper (ACM SIGMOD 1987, verified against the primary source, DOI
  10.1145/38713.38742): *"a LLT is a saga if it can be written as a
  sequence of transactions that can be interleaved with other
  transactions."* Permitting interleaving with other, unrelated
  transactions is sagas' explicit design goal, not an oversight — a saga
  guarantees atomicity (all-or-compensated) of *its own* steps, nothing
  about serializing two different sagas against each other. Sagas are the
  wrong tool category for this problem, not a tool that falls short of it.
- **CRDTs: also correctly dismissed, with one adjacent technique checked
  and found not to transfer.** Canonical op-based CRDT correctness
  (Baquero, Almeida & Shoker, arXiv:1710.04469 — verified via direct PDF
  extraction) is *defined* in terms of operations proven to commute
  (`f(g(σ))=g(f(σ))`) — foundational, not incidental, so it doesn't extend
  to arbitrary/opaque WASM effects whose commutativity can't be
  established. One genuinely adjacent technique was found and checked:
  LSCRDT (Saquib, Krintz & Wolski, IEEE IC2E 2022) achieves consistency
  for *non-commutative* operations without locking, by having all
  replicas converge on one total log order — the authors explicitly
  liken this to Raft's own replicated-state-machine model. But it
  requires detecting conflicts and **rolling back and replaying**
  operations on divergence, which is fundamentally incompatible with
  one-shot, irreversible external effects (a real-world charge or
  deployment can't be rolled back and replayed). Confirmed dead end, not
  assumed.
- **Idempotency keys solve a different, narrower problem than the one
  6d-ii needs solved.** Stripe's idempotency layer (docs.stripe.com,
  stripe.com/blog/idempotency) validates that a *reused* key's parameters
  match the original request and replays the first response — it's bound
  to one specific request payload, not an independent resource identity,
  so it cannot serialize two *different* concurrent requests targeting
  the same underlying resource. Temporal's own engineering blog
  independently demonstrates the exact gap with a worked example: a
  check-then-create pattern (`UserExists()` then `CreateUser()`) still
  races between two different concurrent callers even with idempotency
  logic present, because idempotency and mutual exclusion are different
  properties. Idempotency keys remain valuable as a complementary,
  retry-safety layer — just not as the primary mechanism.
- **Distributed locks built as a client library on top of existing Raft
  consensus are real, established precedent, directly transferable to
  `:ra`.** etcd's `clientv3/concurrency` package builds distributed mutual
  exclusion (session/lease-bound key + a fair queue ordered by etcd's own
  monotonic `CreateRevision`) entirely on top of etcd's existing
  Raft-backed KV store — not a bespoke lock service. (One claim here was
  refuted on a narrow technical point: the `Mutex` type's methods take a
  `context.Context` and return an `error`, so it doesn't *literally*
  satisfy Go's zero-argument `sync.Locker` interface as its own doc
  comment loosely suggests — the underlying pattern, a lock recipe layered
  on existing consensus, stands.) This is direct precedent for building on
  `:ra` rather than inventing new consensus, though — see the design
  doc's own conclusion below — the recommended mechanism turned out not
  to need an explicit lock object at all.
- **Fencing tokens exist to patch a specific failure mode that doesn't
  apply once execution is routed through the leader itself.** A fencing
  token (a monotonically increasing number issued with each lock grant)
  defends against a paused/GC'd/partitioned lock holder waking up after
  its lease has already been reassigned and still acting — but it only
  works if the *protected resource* checks the token, which requires the
  resource to cooperate. Riptide's Capabilities are opaque, external,
  and can't be made to check anything Riptide issues. This is a genuine
  limitation of any design based on "acquire a lock, then separately go
  invoke the effect" — motivating (see design doc) a mechanism where the
  code path that invokes the effect only ever runs *as a direct
  consequence of currently being the leader*, so there's no window for a
  stale holder to act after the fact in the first place.
- **Real production workflow orchestrators solve this exact problem, and
  confirm resource identity must be caller-supplied.** Temporal's actual
  guarantee — after the adversarial pass caught and corrected an initial
  mis-citation (five independent votes confirmed the *default*
  `WorkflowIdReusePolicy` is `ALLOW_DUPLICATE`, not `REJECT_DUPLICATE` as
  first drafted, per docs.temporal.io and a temporalio/sdk-java GitHub
  issue on this exact confusion) — is that **at most one Workflow
  Execution with a given Workflow Id can be open at any time,
  unconditionally, regardless of reuse policy**; the reuse policy only
  governs whether a *new* execution may reuse an id after a *prior* one
  has closed. Workflow Id is explicitly caller-supplied and
  business-meaningful (Temporal's own docs: "use the record ID as the
  Workflow Id"). Argo Workflows has a first-class `mutex` synchronization
  primitive scoped to a Template or Workflow for the same purpose. Both
  independently confirm: resource identity has to come from the caller,
  not be inferred or declared by the effect itself — consistent with
  Riptide's Capabilities being opaque to the host.
- **Actor-model "single owner per key" is the closest architectural
  analogue to what 6l already built, with one caveat that cuts in
  Riptide's favor.** Akka Cluster Sharding guarantees at most one
  instance per entity id, cluster-wide, via deterministic
  hash(id)→shard. Confirmed caveat, not assumed: this guarantee is
  conditional on the operator choosing a safe cluster-downing strategy —
  Akka's own docs warn that an unsafe one under partition/long-GC-pause
  can split the cluster and start the same entity twice, a documented
  unsafe window. `:ra`'s own Raft implementation doesn't share this
  weakness: a leader requires an actual quorum majority to be elected,
  so split-brain is structurally impossible rather than avoided by
  correct configuration. 6l's `RaCluster.stream_leader?/1` already gives
  Riptide this property for Job-stream execution ownership; 6d-ii's
  design reuses it directly rather than building a parallel mechanism.

**Sources** (24 fetched; primary/official docs and peer-reviewed papers
weighted over blogs): Martin Kleppmann's "How to do distributed locking"
and the antirez Redlock rebuttal it responds to; `pkg.go.dev` and GitHub
source for `go.etcd.io/etcd/client/v3/concurrency`; two independent
fencing-token engineering write-ups; Temporal's official docs
(`docs.temporal.io`, `ruby.temporal.io`) and engineering blog; AWS Step
Functions and Argo Workflows official docs; Stripe's idempotency docs and
engineering blog, plus Brandur Ortiz's independent write-up; the Sagas
paper itself (ACM DL) and the `microservices.io` secondary summary;
Baquero/Almeida/Shoker's pure op-based CRDTs paper and the LSCRDT paper
(IC2E 2022), plus Wikipedia's CRDT overview for corroboration; Akka's
official Cluster Sharding, Kubernetes-lease, and split-brain-resolver
docs; and the `rabbitmq/ra` GitHub repository itself for `:ra`'s own
documented primitives.

**Connecting verdict, informing the design doc's 6d-ii decision:** no
literature gap remains unaddressed the way Part 1's versioning question
did — every angle either confirms a usable, precedented pattern
(Raft-backed exclusivity, caller-supplied resource identity) or
confirms a genuine dead end (sagas, CRDTs, idempotency-alone) with a
citable reason why. The one design idea that emerged from synthesizing
these findings against Riptide's own existing architecture — routing
resource-key exclusion through 6l's already-elected per-tenant Job-stream
leader as purely local, in-memory state, rather than any new distributed
primitive — isn't itself drawn from external precedent; it's the
recognition that 6l's own mechanism, applied consistently, already
provides everything this problem needs. See the design doc for the full
argument.
