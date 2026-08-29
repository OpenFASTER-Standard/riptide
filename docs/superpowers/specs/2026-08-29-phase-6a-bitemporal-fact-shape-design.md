# Bitemporal Fact Shape — Design

**Status:** Draft, first revision. Implements Sub-project 6, phase **6a**
(Foundation track). Parent spec:
`docs/superpowers/specs/2026-08-27-derivation-and-execution-layer-design.md`
(§7 — 6a's roadmap entry; §8.4 — bitemporal-facts grounding note; §3.1 —
Fact/Event/Tenant core concepts).

## 1. Scope

Per the parent spec's §7 entry: RDF-star `validFrom`/`validTo`, a defined
OWL-Time Allen-relation subset, ValidTime defaulting to TransactionTime.
Applies to Riptide's existing LDP write path, building on the
already-shipped Phase 3a schema-versioning envelope (`PROGRESS.md` §3,
shipped 2026-08-24).

**Exit criterion:** a Fact can carry a ValidTime interval distinct from
its TransactionTime, round-trips through the existing LDP write/read path
unchanged for Facts that don't set one, and is covered by a migration
test against the Phase 3a envelope.

**Depends on:** nothing (per parent spec §7).

## 2. Key findings

Two findings, both verified empirically rather than assumed, collapse
this phase to much less than the parent spec's own framing implied.

**Finding 1 — no duplication is needed for the derivation layer to
reason over ValidTime.** The parent spec's §8.4 grounding note reads:
"Valid-time must be duplicated into ordinary queryable fact form for the
derivation layer to reason over it." Verified directly against a real
`RDF.Graph` and the exact `RDF.Query.BGP` struct `Riptide.Derivation.Matcher`
already uses: a BGP pattern `{{:s, worksAt, :o}, validFrom, :time}` — a
quoted-triple pattern with variables *inside* it — matches a real
RDF-star-annotated fact and correctly binds `time` to the annotation's
literal value. The identical graph, queried with the plain pattern
`{:s, worksAt, :o}` (no annotation awareness), matches every fact
identically whether or not it carries an annotation. The `rdf` 3.0.1
dependency's BGP engine (`deps/rdf/lib/rdf/query/bgp/query_planner.ex`,
`deduplicate_star/2`/`var_info_star/1`) already treats quoted-triple
patterns as first-class, variable-bindable pattern elements. §8.4's
concern appears to have been written without checking this. Consequence:
6a needs no duplication logic; 6c-iii-b's later ValidTime-aware-querying
phase shrinks to widening `Riptide.Derivation.Literal.FactPattern.args`'
type to admit a nested quoted-triple pattern plus a recursive case in
`Matcher.to_pattern_term/3`/`to_triple_pattern/3` (mirroring what the
vendored dependency's own query planner already does) — not a parallel
storage mechanism.

**Finding 2 — the existing write/read/storage path already handles
RDF-star with zero code changes.** Verified in three layers:

- `Riptide.RDF.TurtleCodec.decode/1`/`encode/1` (thin wrappers over
  `RDF.Turtle.read_string/1`/`write_string/1`) already parse and emit
  Turtle-star syntax correctly, including the annotation-sugar form
  `s p o {| pred obj |}` — confirmed by round-tripping a real Turtle-star
  body through both functions.
- `RiptideWeb.LDP.ResourceController` (`lib/riptide_web/ldp/resource_controller.ex`)
  has no SHACL/schema validation layer that could reject RDF-star content
  — `replace/2`, `patch/2`, and `show/2` are pure
  decode-via-TurtleCodec → store-via-StreamServer → fold → encode-via-TurtleCodec,
  untouched by this phase.
- A real `Riptide.RDF.Patch` containing a quoted-triple addition, appended
  via `Riptide.Stream.StreamServer.append/2` to a live Ra-backed stream and
  read back via `get_since/2`, round-trips byte-identical — including
  through `Event.encode/1`/`decode/1` and `Patch.encode/1`/`decode/1`'s
  existing `%{v: 1, ...}` shape, with **no version bump**. Erlang's own
  term encoding (which Ra's log uses internally) is structurally
  transparent to nested tuples; a quoted-triple subject is just another
  nested tuple to it.

Consequence: the only `lib/` change this phase needs is widening
`Riptide.RDF.Patch.triple`'s Dialyzer type annotation — a type-only
change, since runtime behavior was already correct with the old
annotation (Elixir doesn't enforce `@type` at runtime). Everything else
this phase delivers is tests (proving the above claims are real, not
assumed) plus a vocabulary decision documented in this spec.

**A real subtlety, found while verifying Finding 2.** Turtle-star has two
ways to reference a quoted triple, and they behave differently:

- `<<s p o>> pred obj .` (a bare quoted triple written directly as a
  subject) asserts *only* the annotation triple — the base `s p o` fact
  does **not** become independently matchable unless written separately.
  Verified: `RDF.Graph.triples/1` on a graph built this way yields only
  the one annotation-shaped triple.
- `s p o {| pred obj |}` (the annotation-sugar form — also what
  `TurtleCodec.encode/1` already emits on output) asserts **both** the
  base triple and the annotation triple. Verified: `RDF.Graph.triples/1`
  yields both, and the base fact is independently matchable via a plain
  `{s, p, o}` pattern.

This phase documents the sugar form as the only correct way to set
ValidTime; the bare-subject form is a real footgun (technically valid
RDF-star, silently drops the base fact from ordinary matching) that
Riptide does not validate against — callers are expected to use the
sugar form, same as any other Turtle-authoring correctness expectation
already placed on LDP write-path callers.

## 3. Approaches considered

- **A — Adopted.** Simple, literal-valued `validFrom`/`validTo`
  annotations (`urn:riptide:relation:validFrom`/`validTo`, same namespace
  convention `Parser`'s `@relation_ns` already uses), RDF-star-annotated
  via the `{| ... |}` sugar syntax, `xsd:dateTime` literal values. No new
  write API — the existing PUT/PATCH Turtle body is the only mechanism.
- **B — Ruled out.** Full OWL-Time reified `Instant`/`Interval`
  individuals (`time:hasBeginning`/`time:hasEnd` pointing to blank-node
  `time:Instant`s, each carrying `time:inXSDDateTime`). Standards-literal,
  but several extra triples per annotated fact, and doesn't combine
  cleanly with RDF-star annotation (the annotation value would need to be
  a node, not a literal) — no real benefit given nothing implements
  interval comparison yet. Ruled out per this phase's own YAGNI scope;
  revisit only if a future phase's actual querying needs demand it.
- **C — Ruled out.** Duplicate ValidTime into a parallel plain-triple
  reification (e.g., a synthetic fact-node per annotated triple) so the
  derivation layer can query it today. Ruled out by Finding 1 — the
  underlying BGP engine already queries RDF-star annotations natively;
  building a duplication mechanism would be solving an already-solved
  problem.

## 4. Vocabulary (documentation only — no new code)

- `urn:riptide:relation:validFrom` — `xsd:dateTime` literal, ValidTime
  interval start.
- `urn:riptide:relation:validTo` — `xsd:dateTime` literal, ValidTime
  interval end.
- Absence of either means ValidTime = TransactionTime (Riptide's own
  sequence number, per parent spec §3.1) — a semantic default for future
  querying phases, not something this phase's write path materializes as
  extra triples.
- Allen-relation vocabulary subset (named now for 6c-iii-b to implement
  against later; no comparison logic exists yet): `urn:riptide:relation:before`,
  `after`, `meets`, `overlaps`, `during`, `starts`, `finishes`, `equals`
  — Riptide-namespaced, OWL-Time-inspired in naming only (not OWL-Time's
  own IRIs, matching this phase's literal-valued-annotation approach
  rather than full OWL-Time reification, per Approach B being ruled out).

## 5. The one code change

`lib/riptide/rdf/patch.ex`'s `@type triple` widens from:

```elixir
@type triple :: {RDF.IRI.t(), RDF.IRI.t(), RDF.Term.t()}
```

to:

```elixir
@type triple ::
        {RDF.IRI.t() | RDF.Star.Triple.t(), RDF.IRI.t(), RDF.Term.t() | RDF.Star.Triple.t()}
```

Dialyzer-level only — `Patch.apply/2`, `encode/1`, `decode/1` are
byte-for-byte unchanged; runtime behavior was already correct with the
old, narrower annotation.

## 6. Testing

- **Compatibility test 1:** an old-shape `v: 1` `Patch`/`Event` wire map
  (no RDF-star anywhere) still decodes correctly via `Patch.decode/1`/
  `Event.decode/1`, unchanged by this phase.
- **Compatibility test 2:** a new-shape `v: 1` wire map containing a
  quoted-triple addition decodes correctly through the *same* clause —
  no version bump, no upcast branch. Together with test 1, this is the
  phase's "migration test against the Phase 3a envelope": proof that this
  is genuinely not a breaking schema change, mirroring
  `test/riptide/versioned_upcast_test.exs`'s own pattern but proving the
  opposite claim (no upcast needed, not "upcast works").
- **Real Ra round trip:** `StreamServer.append/2` → `get_since/2` with a
  `Patch` containing a quoted-triple addition, survives real Ra
  persistence unchanged (mirrors `test/riptide/stream/stream_server_test.exs`'s
  own conventions).
- **HTTP-level round trip:** PUT a Turtle-star body (annotation-sugar
  syntax) via `RiptideWeb.LDP.ResourceController`, then GET, confirm both
  the base fact and the `validFrom` annotation are present in the
  response Turtle byte-for-byte (mirrors
  `test/riptide_web/ldp/resource_controller_test.exs`'s own conventions).
  This is what "round-trips through the existing LDP write/read path"
  literally asks for, exercised at the HTTP layer the exit criterion
  names, not just the storage layer underneath it.
- **Regression test:** an ordinary un-annotated PUT/GET still round-trips
  identically post-6a — proves zero behavior change for every existing
  caller that never sets a ValidTime.

## 7. Exit criterion (from parent spec §7, restated)

A Fact can carry a ValidTime interval distinct from its TransactionTime
(§4's `validFrom`/`validTo` vocabulary, annotation-sugar syntax),
round-trips through the existing LDP write/read path unchanged for Facts
that don't set one (§6's regression test), and is covered by a migration
test against the Phase 3a envelope (§6's compatibility tests 1 and 2).
Satisfied by §6's testing plan end-to-end.

## 8. Explicitly deferred

- ValidTime-aware querying (widening `FactPattern.args` to admit a
  quoted-triple pattern with variables, plus `Matcher`'s recursive
  pattern translation) — 6c-iii-b's own job, confirmed much smaller than
  the parent spec assumed (Finding 1) since the underlying `RDF.Query.BGP`
  engine already supports it natively.
- Full OWL-Time reified `Instant`/`Interval` individuals — not adopted;
  simple literal-valued annotations only (Approach B, ruled out per §3).
- Actual Allen-relation comparison logic (before/after/overlaps
  semantics) — vocabulary named now (§4), comparison logic implemented
  later, by whichever phase first needs it (per parent spec, likely
  6c-iii-b or a dedicated follow-on).
- Validation rejecting the bare `<<...>>`-as-subject footgun (§2) —
  documented as caller responsibility, not enforced by this phase.
