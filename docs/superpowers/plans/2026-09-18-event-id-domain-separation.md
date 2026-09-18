# Implementation plan: `event_id` domain separation

Implements Decision 5 of `docs/superpowers/specs/2026-09-16-distributed-consensus-design.md`,
carried forward from Task 2's final review (`.taskmaster/tasks/task_003.md:17`). This is a
prerequisite for the rest of Task 3, not a subtask of its own in task-master — Decision 5's own
text says to implement it "as an early step of Task 3's work... before deferred further," before
`event_id`/`content_hash` becomes a real vote/reference target inside the consensus protocol
(subtask 3.2 onward).

## Goal

Today, `Envelope.content_hash e = Value.content_hash (Envelope.to_value e)` (`lib/envelope.ml:26`,
`lib/value.ml:111`) — an envelope is hashed as a plain `Value.Record`, through the exact same
encoding path used for any arbitrary payload `Value.value`. A crafted payload value with the same
shape (a `Record` with keys `"actor"`, `"causation"`, `"correlation"`, `"predecessor_hash"`,
`"sequence"`, `"payload"`) collides with a real envelope's `event_id`. Harmless today (nothing
treats `event_id` as security-relevant yet), but Task 3 is exactly where that stops being true.

**Fix:** prefix the hash preimage with a domain tag distinguishing "this is an envelope" from
"this is a plain value," so the two hash spaces can never collide by construction.

## Chosen mechanism

`lib/value.ml`'s `value` type already has a `Sum of string * value` variant with a tested,
existing encoding: a 1-byte constructor tag (`tag_sum = '\x06'`), then the tag string
length-prefixed (8-byte big-endian) and encoded, then the wrapped value recursively encoded
(`lib/value.ml:30-38` for tags, `encode_into`'s `Sum` case for the shape). This is the "leading
domain-tag byte in the preimage" mechanism Decision 5 asks for, and reusing it means zero new
encoding logic to write or independently verify — the collision-freedom argument reduces to
"`Sum` and `Record` already have distinct leading tag bytes," which `Value`'s own existing
`canonical_encode` tests already establish.

**Do not change `Envelope.to_value`'s return shape.** It stays a bare `Record` — it has its own
existing callers/tests (`spec/golden/generate.ml:15`, `test/test_golden.ml:65`, both hash
`Envelope.to_value` results directly to pin the *value-encoding* golden vector for that
particular Record shape, independent of envelope-hashing semantics) and changing its shape would
needlessly perturb those. Instead, add the domain wrap only inside `content_hash`'s own
computation:

```ocaml
(* lib/envelope.ml, near content_hash *)
let domain_tag = "Envelope"

let content_hash e = Value.content_hash (Value.Sum (domain_tag, to_value e))
```

This changes `Envelope.content_hash`'s output (intentional — this is the whole point) but leaves
`Envelope.to_value`'s output, and therefore the golden fixtures that hash it directly, untouched.
Confirmed safe against every existing `Envelope.content_hash` test
(`test/test_envelope.ml`): all of them are relative/property-based (determinism, per-field
sensitivity) with no hardcoded hex fixtures, so none breaks from the hash value itself changing.

## Global Constraints

- `Value.content_hash` and `Value.canonical_encode` themselves are NOT modified — the fix is
  entirely inside `Envelope.content_hash`, reusing existing `Value.Sum` encoding.
- `Envelope.to_value`'s return shape and its `.mli` signature are unchanged.
- No new opam dependency; `Digestif` continues to be reached only via `Value.content_hash`, not
  called directly from `envelope.ml`.
- The domain tag string (`"Envelope"`) must be a value no legitimate payload `Value.Sum` tag can
  plausibly coincide with in practice, but collision-freedom must not rely on that — it must hold
  by construction (distinct `Value` constructors have distinct leading encoding bytes, per
  `Value`'s own existing tag-byte scheme) even if a caller deliberately chooses a payload of
  `Sum ("Envelope", <arbitrary Record>)`. Task 1's test must prove this, not just assert it.

## Task 1: Implement the domain separation and prove it closes the collision

**Files:**
- Modify: `lib/envelope.ml`, `lib/envelope.mli` (if the domain tag or a helper needs exposing —
  your judgment; `content_hash`'s signature itself does not change)
- Modify: `test/test_envelope.ml`
- Modify: `.taskmaster/tasks/task_003.md` (mark the carried-forward domain-separation note as
  resolved, pointing at this plan/PR)

**Steps:**

1. Implement the fix exactly as described above in "Chosen mechanism."

2. Add a test that directly proves the collision this fix closes is actually closed — not just
   that unrelated fields still change the hash (already covered). Concretely: construct a
   `Value.value` shaped as `Value.Sum ("Envelope", Envelope.to_value some_envelope)` — i.e., a
   *plain payload value* that an attacker fully controls, deliberately mimicking the exact wire
   shape `Envelope.content_hash` now produces internally — and assert that
   `Value.content_hash` of that crafted value equals `Envelope.content_hash some_envelope`
   (it must, since that's now definitionally the same preimage — this is what proves the fix
   didn't just move the collision surface, it made it an intentional, checked equivalence: a
   value hash and an envelope hash coincide if and only if the value is literally
   `Sum ("Envelope", to_value e)`, which is exactly what "domain-separated by construction"
   means. The remaining, actually-important property to test is the negative case: a crafted
   value shaped as a bare `Record` with the envelope's exact field set (the OLD collision) must
   now hash differently from `Envelope.content_hash` of the real envelope with the same field
   values. Write both: the positive equivalence (documents the mechanism precisely) and the
   negative case (the actual regression test for the vulnerability Decision 5 describes).

3. Add a property test (QCheck2, matching `test/test_value.ml`'s existing style — check that file
   for the arbitrary-value generator to reuse rather than writing a new one) that for any
   generated `Value.value` shaped as a `Record` and any generated `envelope` whose `to_value`
   produces a `Record` with the same keys/values, `Value.content_hash` of the bare Record and
   `Envelope.content_hash` of the envelope are never equal. (This generalizes step 2's negative
   case beyond hand-picked examples.)

4. Update `.taskmaster/tasks/task_003.md`'s carried-forward note (the one quoting the old
   collision-risk text) to state this is now fixed, citing this plan file and the commit that
   closes it once known.

5. Run the full test suite (`dune test` or whatever this repo's existing test-invocation
   convention is — check `dune-project`/CI config/existing plan reports for the exact command)
   and confirm everything passes, including the untouched golden-fixture tests (they must be
   byte-for-byte unaffected, since `Envelope.to_value`'s shape didn't change — if they DO change,
   something in this implementation deviated from "Chosen mechanism" above and must be fixed, not
   the golden fixtures).

6. Commit.

## Self-Review Notes

- **Spec coverage:** implements Decision 5 in full — domain separation "by construction," not by
  convention (the property test in Step 3 is what makes this a proof rather than an assertion).
- **Blast radius check:** `Value.content_hash`/`canonical_encode` untouched (used by far more than
  envelopes — Task 2's whole content-addressed value universe). `Envelope.to_value` untouched
  (golden fixtures depend on its exact shape). Only `Envelope.content_hash`'s own output changes,
  which is the intended, minimal-blast-radius fix.
- **Downstream callers of `Envelope.content_hash`:** grep the codebase before finishing — if
  `test_log.ml`'s use of `content_hash` for `causation`/`correlation`/`predecessor_hash` chaining
  relies on any *absolute* hash value (rather than "whatever `content_hash` returns, chained
  consistently"), that would be a second thing to check. Based on the research pass for this
  plan, all such uses are relative/relational, not fixed-value, but verify this directly rather
  than trust the plan text — this is exactly the kind of claim this project's standing rule
  ("back every claim with real evidence") exists for.
