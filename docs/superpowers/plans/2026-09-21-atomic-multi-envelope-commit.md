# Atomic Multi-Envelope Commit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make VSR-replicated commits produce real, hash-chained `Envelope`s, and let a caller
propose N related writes as one atomic unit — all N land in the replicated log together or none
do — without touching the already-merged, heavily-reviewed VSR implementation at all.

**Architecture:** A new library, `lib/batch_commit/` (module `Batch_commit`), sitting entirely on
top of the unchanged `Riptide.Envelope`/`Riptide.Log` (Task 2) and `Riptide_vsr.Replica` (Task
3.1/3.2). A batch is encoded as one `Riptide.Value.value` and proposed through the existing,
unmodified `Replica.propose`. A pure, fully-recomputed-on-every-call decode function
(`committed_envelopes`) walks the replica's own committed prefix and deterministically reconstructs
real `Envelope.envelope` values, deduplicating by a client-supplied idempotency key.

**Tech Stack:** OCaml 5, dune, Alcotest — same as the rest of this repo. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-09-21-atomic-multi-envelope-commit-design.md`

## Global Constraints

- No changes to `lib/vsr/replica.ml`, `lib/vsr/replica.mli`, `lib/vsr/replica_log.ml`,
  `lib/vsr/replica_log.mli`, `lib/vsr/message.ml`, or `lib/vsr/message.mli` — this plan is
  additive only, in a new library.
- No changes to `lib/envelope.ml`/`.mli` or `lib/log.ml`/`.mli` either — `Envelope.envelope`'s
  fields are already fully public; `Batch_commit` constructs `Envelope.envelope` values directly
  via record literals, it does not need a new `Envelope.of_value`.
- A batch produces N separate, individually hash-chained `Envelope`s (Decision 1 of the spec) —
  never one wrapper `Envelope` holding all N writes.
- The idempotency key lives once per batch, not once per write.
- `committed_envelopes` is a pure function, fully recomputed on every call — no persistent state,
  no background loop, no caching between calls. Any test that calls it twice and expects the
  second call to be cheaper, or expects it to observe anything not already present in `entries
  t`/`commit_number t` at call time, is testing something this plan deliberately does not build.
- A malformed or foreign committed entry (not shaped like a batch) contributes zero envelopes to
  the decode result — it must never raise an exception.
- `Value.value`'s `Record` fields are canonically sorted alphabetically by key on anything that
  went through `Value.canonical_encode`/`decode` (confirmed in `lib/value.ml`), but a value
  proposed locally by the same process never goes through that round-trip before being read back
  via `Replica.entries`. Field lookups inside `Batch_commit` must therefore be by name (e.g.
  `List.assoc_opt`), never by list position.
- No client acknowledgment mechanism (telling a caller their batch committed, or that it was a
  duplicate) — that is task-master Task 9's job, out of scope here. `Batch_commit.propose` returns
  `unit`, matching `Replica.propose`'s own existing fire-and-forget convention.
- No artificial cap on batch size (number of writes, N) — matches this project's established
  tolerance for unbounded-but-simple primitives elsewhere (e.g. `Replica.propose`'s own O(n) dedup
  scan, `Replica.is_committed`'s O(n²) walk, both already disclosed and accepted).

## Review Focus

- **A batch with zero writes** — the spec is silent on whether this is legal. A reasonable person
  would expect it to be accepted as a valid, if useless, batch (contributes zero envelopes) rather
  than rejected or crashing, since nothing about the wire shape requires a non-empty `writes`
  list. Task 1 pins this.
- **The same idempotency key proposed twice with DIFFERENT writes** — the exact scenario
  idempotency keys exist for (a client retries after a perceived timeout, not knowing the first
  attempt already landed). A reasonable person would expect only the FIRST batch's writes to ever
  take effect, not the second, and not a merge of both. Task 1 pins this with genuinely different
  payloads in the two attempts, not just a byte-identical retry.
- **Two SEPARATE batches committing in sequence** — the hash chain must continue correctly ACROSS
  the batch boundary: the second batch's first envelope's `predecessor_hash` must be the FIRST
  batch's LAST envelope's `content_hash`, not `Envelope.genesis_marker` reset per batch. An
  implementation that naively resets chain state per batch instead of threading it through would
  pass every single-batch test and still be wrong. Task 1 pins this explicitly with two multi-write
  batches and a full-list `Log.verify_chain_list` check.
- **A `Record` whose fields are constructed in non-alphabetical order** — since field lookups are
  by name (per Global Constraints), a positional-matching regression would only be caught by a
  test that deliberately constructs a batch value with fields out of the order
  `Value.canonical_encode` would choose. Task 1 pins this directly.
- **An uncommitted (replicated-but-not-yet-committed) tail entry** — must never appear in
  `committed_envelopes`'s output, even though it's already present in `Replica.entries`. This is
  the single most safety-relevant behavior in this plan (exposing an uncommitted entry as if it
  were durable would be a real correctness bug, not a cosmetic one), and it's easy to get right by
  accident with `replica_count = 1` (where everything commits immediately) and wrong without
  anyone noticing. Task 1 pins this with a real multi-replica cluster where a backup's replicated
  tail is deliberately left uncommitted.

---

### Task 1: Batch wire shape and the pure decode side (`committed_envelopes`)

**Files:**
- Create: `lib/batch_commit/dune`
- Create: `lib/batch_commit/batch_commit.ml`
- Create: `lib/batch_commit/batch_commit.mli`
- Create: `test/dune` (modify — add `riptide_batch_commit` to the `libraries` list)
- Create: `test/test_riptide.ml` (modify — add the new test module)
- Create: `test/test_batch_commit.ml`

**Interfaces:**
- Consumes: `Riptide.Value.value`, `Riptide.Envelope.envelope`/`.genesis_marker`/`.content_hash`,
  `Riptide.Log.verify_chain_list` (all already merged); `Riptide_vsr.Replica.t`/`.create`/
  `.propose`/`.entries`/`.commit_number` (all already merged).
- Produces (for Task 2 and Task 3):
  - `type write = { actor : Riptide.Envelope.actor_id; causation : Riptide.Envelope.event_id;
    correlation : Riptide.Envelope.event_id; payload : Riptide.Value.value }`
  - `val committed_envelopes : Riptide_vsr.Replica.t -> Riptide.Envelope.envelope list`

- [ ] **Step 1: Create the library skeleton**

`lib/batch_commit/dune`:

```lisp
(library
 (name riptide_batch_commit)
 (libraries riptide riptide_vsr))
```

- [ ] **Step 2: Write `batch_commit.mli`**

```ocaml
(** Atomic multi-envelope commit: N related writes propose and commit as one indivisible unit
    through VSR, and land as N separate, individually hash-chained {!Riptide.Envelope.envelope}
    values -- not as one Envelope wrapping all N. See
    docs/superpowers/specs/2026-09-21-atomic-multi-envelope-commit-design.md for the full argument
    (why "entity" is not a Layer 0 concept, why this lives as a new module on top of unchanged
    VSR rather than inside it, why decode is lazy/pure rather than eagerly materialized).

    Deliberately does NOT touch {!Riptide_vsr.Replica}, {!Riptide.Envelope}, or {!Riptide.Log} --
    a batch is just a {!Riptide.Value.value}, encoded/decoded entirely inside this module, so
    {!Riptide_vsr.Replica.propose} and {!Riptide_vsr.Replica.entries} need no changes at all. *)

type write = {
  actor : Riptide.Envelope.actor_id;
  causation : Riptide.Envelope.event_id;
  correlation : Riptide.Envelope.event_id;
  payload : Riptide.Value.value;
}
(** One write within a batch -- everything {!Riptide.Envelope.envelope} needs except
    [predecessor_hash]/[sequence], which {!committed_envelopes} computes deterministically from
    each write's position once its batch commits, the same way {!Riptide.Log.append} computes
    them for a locally-appended entry. *)

val committed_envelopes : Riptide_vsr.Replica.t -> Riptide.Envelope.envelope list
(** [committed_envelopes t] is the real, hash-chained Envelope view of everything durably
    committed on [t] so far -- a PURE function, fully recomputed from scratch on every call (no
    persistent state, no caching, no background materialization loop). Reads only
    {!Riptide_vsr.Replica.entries}/{!Riptide_vsr.Replica.commit_number}; never anything beyond the
    committed prefix (an uncommitted, replicated-but-not-yet-agreed tail entry never appears here,
    even though {!Riptide_vsr.Replica.entries} itself includes it).

    Walks the committed prefix in order. A committed entry that isn't shaped like a batch (wrong
    {!Riptide.Value.value} shape, missing or wrong-typed fields) contributes zero envelopes --
    every replica sees byte-identical committed entries by VSR's own safety guarantee, so this is
    deterministic, agreed-upon behavior, not a place to raise. Within a well-formed batch, if its
    own idempotency key already appeared in an EARLIER (lower op-number) batch in the same walk,
    that later batch's writes are skipped entirely (first-wins per key) -- this, not anything on
    the write side, is what makes a retried batch commit safe to apply at most once.

    The result satisfies {!Riptide.Log.verify_chain_list}. *)
```

- [ ] **Step 3: Write `batch_commit.ml`**

```ocaml
open Riptide

type write = {
  actor : Envelope.actor_id;
  causation : Envelope.event_id;
  correlation : Envelope.event_id;
  payload : Value.value;
}

(* ---- write <-> Value.value ----

   Mirrors Envelope.to_value's own field-encoding convention exactly (String for actor, Bytes for
   hash-typed fields) -- see lib/envelope.ml. Field LOOKUP on decode is by name (List.assoc_opt),
   never by list position: a value that went through Value.canonical_encode/decode (e.g. arrived
   over the wire, on a backup) has its Record fields canonically re-sorted alphabetically by key
   (lib/value.ml), but a value this same process proposed locally and is now reading back via
   Replica.entries never took that round-trip -- the two can have DIFFERENT in-memory field
   orders for the exact same logical batch. *)

let write_to_value (w : write) : Value.value =
  Value.Record
    [
      ("actor", Value.Scalar (Value.String w.actor));
      ("causation", Value.Scalar (Value.Bytes w.causation));
      ("correlation", Value.Scalar (Value.Bytes w.correlation));
      ("payload", w.payload);
    ]

let field_opt fields name = List.assoc_opt name fields

let write_of_value (v : Value.value) : write option =
  match v with
  | Value.Record fields -> (
    match
      ( field_opt fields "actor",
        field_opt fields "causation",
        field_opt fields "correlation",
        field_opt fields "payload" )
    with
    | Some (Value.Scalar (Value.String actor)), Some (Value.Scalar (Value.Bytes causation)),
      Some (Value.Scalar (Value.Bytes correlation)), Some payload ->
      Some { actor; causation; correlation; payload }
    | _ -> None)
  | _ -> None

(* ---- batch <-> Value.value ---- *)

(* [@warning "-32"]: unused-value-declaration -- batch_to_value has no caller yet in this task
   (Task 1's own tests construct a batch's wire Value.value by hand, deliberately, to avoid
   depending on Task 2's not-yet-written propose). Task 2 adds propose as a real caller and
   removes this attribute in the same edit. Confirmed live: dune build fails with
   "Error (warning 32 [unused-value-declaration])" without it, since batch_commit.mli (Step 2)
   does not export this name, making it a genuinely private, genuinely unused binding until then. *)
let[@warning "-32"] batch_to_value ~(idempotency_key : string) (writes : write list) : Value.value =
  Value.Record
    [
      ("idempotency_key", Value.Scalar (Value.String idempotency_key));
      ("writes", Value.Sequence (List.map write_to_value writes));
    ]

(* [None] if EITHER the outer shape is wrong OR any single write inside it fails to decode -- a
   batch with one malformed write is a malformed batch as a whole, never a partial batch. *)
let batch_of_value (v : Value.value) : (string * write list) option =
  match v with
  | Value.Record fields -> (
    match (field_opt fields "idempotency_key", field_opt fields "writes") with
    | Some (Value.Scalar (Value.String idempotency_key)), Some (Value.Sequence write_values) ->
      let decoded = List.map write_of_value write_values in
      if List.for_all Option.is_some decoded then Some (idempotency_key, List.filter_map Fun.id decoded)
      else None
    | _ -> None)
  | _ -> None

(* ---- read side ---- *)

let committed_batch_values (t : Riptide_vsr.Replica.t) : Value.value list =
  let all = Riptide_vsr.Replica.entries t in
  let committed_count = Riptide_vsr.Replica.commit_number t in
  List.filteri (fun i _ -> i < committed_count) all

let committed_envelopes (t : Riptide_vsr.Replica.t) : Envelope.envelope list =
  let seen_keys = Hashtbl.create 16 in
  let _final_sequence, _final_predecessor_hash, envelopes_rev =
    List.fold_left
      (fun (sequence, predecessor_hash, acc) batch_value ->
        match batch_of_value batch_value with
        | None -> (sequence, predecessor_hash, acc)
        | Some (idempotency_key, writes) ->
          if Hashtbl.mem seen_keys idempotency_key then (sequence, predecessor_hash, acc)
          else begin
            Hashtbl.add seen_keys idempotency_key ();
            List.fold_left
              (fun (sequence, predecessor_hash, acc) (w : write) ->
                let sequence = Int64.add sequence 1L in
                let envelope : Envelope.envelope =
                  {
                    actor = w.actor;
                    causation = w.causation;
                    correlation = w.correlation;
                    predecessor_hash;
                    sequence;
                    payload = w.payload;
                  }
                in
                (sequence, Envelope.content_hash envelope, envelope :: acc))
              (sequence, predecessor_hash, acc) writes
          end)
      (0L, Envelope.genesis_marker, [])
      (committed_batch_values t)
  in
  List.rev envelopes_rev
```

- [ ] **Step 4: Confirm it builds**

Run: `dune build`
Expected: succeeds.

- [ ] **Step 5: Register the new test file**

Modify `test/dune` — add `riptide_batch_commit` to the `libraries` list (alphabetically, matching
the existing list's own convention):

```lisp
(test
 (name test_riptide)
 (libraries riptide riptide_batch_commit riptide_sim riptide_transport riptide_vsr golden_fixtures
   alcotest qcheck-core qcheck-alcotest eio eio.mock eio_main unix)
 (deps ../spec/golden/vectors.txt))
```

Modify `test/test_riptide.ml` — find the existing `let () = Alcotest.run "riptide" [ ... ]` call
(or equivalent list of test suites) and add this module's own tests to it, following exactly the
same pattern every other test file already uses there (e.g. how `Test_vsr_replica.tests` or
`Test_vsr_replica_cluster.tests` is already listed) — read the current contents of
`test/test_riptide.ml` first and match its existing style precisely; do not guess the exact
surrounding syntax.

- [ ] **Step 6: Write the failing tests**

Write `test/test_batch_commit.ml` as:

```ocaml
open Riptide
open Riptide_vsr

let record_value name = Value.Record [ ("name", Value.Scalar (Value.String name)) ]
let fake_event_id name = Value.content_hash (Value.Scalar (Value.String name))

(* replica_count = 1, f = 0: IsCommitted is vacuously true for every op-number, so
   Replica.propose commits synchronously, with no network/quorum needed at all -- exactly what an
   isolated unit test of the decode side needs. Matches test_vsr_replica.ml's own established use
   of this degenerate cluster size for propose-focused unit tests. *)
let create_solo () =
  let send ~to_:_ (_ : string) = () in
  Replica.create ~my_id:1 ~replica_count:1 ~svc_limit:3 ~send

let w ~actor ~causation ~correlation payload : Riptide_batch_commit.write =
  { actor; causation; correlation; payload }

let test_empty_batch_commits_as_zero_envelopes () =
  let t = create_solo () in
  (* This module's own public propose (Task 2) doesn't exist yet -- Task 1 tests the decode side
     directly against a hand-built batch Value.value, using the SAME wire shape
     Riptide_batch_commit.propose will build in Task 2, proposed straight through the underlying
     Replica.propose. *)
  let batch_value =
    Value.Record
      [ ("idempotency_key", Value.Scalar (Value.String "k-empty")); ("writes", Value.Sequence []) ]
  in
  Replica.propose t batch_value;
  Alcotest.(check int) "zero envelopes from an empty batch" 0
    (List.length (Riptide_batch_commit.committed_envelopes t))

let test_round_trip_multiple_writes () =
  let t = create_solo () in
  let actor = "actor-1" in
  let c1 = fake_event_id "c1" and r1 = fake_event_id "r1" in
  let c2 = fake_event_id "c2" and r2 = fake_event_id "r2" in
  let batch_value =
    Value.Record
      [
        ("idempotency_key", Value.Scalar (Value.String "k1"));
        ("writes",
          Value.Sequence
            [
              Value.Record
                [
                  ("actor", Value.Scalar (Value.String actor));
                  ("causation", Value.Scalar (Value.Bytes c1));
                  ("correlation", Value.Scalar (Value.Bytes r1));
                  ("payload", record_value "first");
                ];
              Value.Record
                [
                  ("actor", Value.Scalar (Value.String actor));
                  ("causation", Value.Scalar (Value.Bytes c2));
                  ("correlation", Value.Scalar (Value.Bytes r2));
                  ("payload", record_value "second");
                ];
            ]);
      ]
  in
  Replica.propose t batch_value;
  let envelopes = Riptide_batch_commit.committed_envelopes t in
  Alcotest.(check int) "two writes produce two envelopes" 2 (List.length envelopes);
  let e1 = List.nth envelopes 0 and e2 = List.nth envelopes 1 in
  Alcotest.(check string) "first envelope's actor" actor e1.actor;
  Alcotest.(check bool) "first envelope's causation matches" true (String.equal e1.causation c1);
  Alcotest.(check bool) "first envelope's predecessor_hash is genesis" true
    (String.equal e1.predecessor_hash Envelope.genesis_marker);
  Alcotest.(check int64) "first envelope's sequence is 1" 1L e1.sequence;
  Alcotest.(check int64) "second envelope's sequence is 2" 2L e2.sequence;
  Alcotest.(check bool) "second envelope's predecessor_hash is first envelope's content_hash" true
    (String.equal e2.predecessor_hash (Envelope.content_hash e1));
  Alcotest.(check bool) "the resulting chain verifies" true (Log.verify_chain_list envelopes)

let test_field_order_independence () =
  (* Deliberately constructs the Record with "writes" BEFORE "idempotency_key" -- the opposite of
     alphabetical order (Value.canonical_encode's own sort key) and the opposite of the order
     Batch_commit's own batch_to_value happens to build them in. If decode ever regresses to
     positional field matching instead of List.assoc_opt-by-name lookup, this is what catches it. *)
  let t = create_solo () in
  let actor = "actor-1" in
  let batch_value =
    Value.Record
      [
        ("writes",
          Value.Sequence
            [
              Value.Record
                [
                  ("payload", record_value "out-of-order");
                  ("correlation", Value.Scalar (Value.Bytes (fake_event_id "r")));
                  ("causation", Value.Scalar (Value.Bytes (fake_event_id "c")));
                  ("actor", Value.Scalar (Value.String actor));
                ]
            ]);
        ("idempotency_key", Value.Scalar (Value.String "k-order"));
      ]
  in
  Replica.propose t batch_value;
  let envelopes = Riptide_batch_commit.committed_envelopes t in
  Alcotest.(check int) "field order does not prevent decoding" 1 (List.length envelopes);
  Alcotest.(check string) "actor decoded correctly despite field order" actor (List.hd envelopes).actor

let test_malformed_committed_entry_is_zero_envelopes () =
  let t = create_solo () in
  (* A value that never went through Batch_commit at all -- simulates a foreign/corrupted entry
     landing in the committed log. Must not raise. *)
  Replica.propose t (Value.Scalar (Value.Int 42L));
  Alcotest.(check int) "a foreign committed value contributes zero envelopes" 0
    (List.length (Riptide_batch_commit.committed_envelopes t))

let test_malformed_write_makes_the_whole_batch_malformed () =
  let t = create_solo () in
  let batch_value =
    Value.Record
      [
        ("idempotency_key", Value.Scalar (Value.String "k-mixed"));
        ("writes",
          Value.Sequence
            [
              Value.Record
                [
                  ("actor", Value.Scalar (Value.String "actor-1"));
                  ("causation", Value.Scalar (Value.Bytes (fake_event_id "c")));
                  ("correlation", Value.Scalar (Value.Bytes (fake_event_id "r")));
                  ("payload", record_value "well-formed");
                ];
              Value.Scalar (Value.Int 0L)
              (* the second "write" isn't even a Record *);
            ]);
      ]
  in
  Replica.propose t batch_value;
  Alcotest.(check int) "one malformed write voids the whole batch, not just that write" 0
    (List.length (Riptide_batch_commit.committed_envelopes t))

let test_repeated_idempotency_key_with_different_writes_keeps_only_the_first () =
  let t = create_solo () in
  let make_batch ~key payload_name =
    Value.Record
      [
        ("idempotency_key", Value.Scalar (Value.String key));
        ("writes",
          Value.Sequence
            [
              Value.Record
                [
                  ("actor", Value.Scalar (Value.String "actor-1"));
                  ("causation", Value.Scalar (Value.Bytes (fake_event_id "c")));
                  ("correlation", Value.Scalar (Value.Bytes (fake_event_id "r")));
                  ("payload", record_value payload_name);
                ];
            ]);
      ]
  in
  Replica.propose t (make_batch ~key:"dup-key" "first-attempt");
  (* Genuinely DIFFERENT writes under the SAME key -- the exact scenario idempotency keys exist
     for: a client retries, believing its first attempt may not have landed, with a payload it
     reconstructed independently (not necessarily byte-identical to the first). *)
  Replica.propose t (make_batch ~key:"dup-key" "second-attempt-should-be-ignored");
  let envelopes = Riptide_batch_commit.committed_envelopes t in
  Alcotest.(check int) "only the first attempt's envelope exists" 1 (List.length envelopes);
  match (List.hd envelopes).payload with
  | Value.Record [ ("name", Value.Scalar (Value.String name)) ] ->
    Alcotest.(check string) "the first attempt's payload, not the second's" "first-attempt" name
  | _ -> Alcotest.fail "unexpected payload shape"

let test_two_separate_batches_chain_across_the_boundary () =
  let t = create_solo () in
  let make_batch ~key names =
    Value.Record
      [
        ("idempotency_key", Value.Scalar (Value.String key));
        ("writes",
          Value.Sequence
            (List.map
               (fun name ->
                 Value.Record
                   [
                     ("actor", Value.Scalar (Value.String "actor-1"));
                     ("causation", Value.Scalar (Value.Bytes (fake_event_id (name ^ "-c"))));
                     ("correlation", Value.Scalar (Value.Bytes (fake_event_id (name ^ "-r"))));
                     ("payload", record_value name);
                   ])
               names));
      ]
  in
  Replica.propose t (make_batch ~key:"batch-a" [ "a1"; "a2" ]);
  Replica.propose t (make_batch ~key:"batch-b" [ "b1" ]);
  let envelopes = Riptide_batch_commit.committed_envelopes t in
  Alcotest.(check int) "3 total envelopes across 2 batches" 3 (List.length envelopes);
  Alcotest.(check bool) "the full chain verifies across the batch boundary" true
    (Log.verify_chain_list envelopes);
  let a2 = List.nth envelopes 1 and b1 = List.nth envelopes 2 in
  Alcotest.(check bool) "batch b's first envelope chains from batch a's LAST envelope, not genesis"
    true
    (String.equal b1.predecessor_hash (Envelope.content_hash a2))

(* A replica_count = 1 replica can never have an uncommitted entry (everything commits
   synchronously, per create_solo's own doc comment above) -- this test needs a real 3-replica
   cluster (f = 1) instead, where a genuine quorum is needed. No network/Eio required: two
   Replica.t values wired directly to each other's handle_message, matching test_vsr_replica.ml's
   own precedent of driving handle_message directly with real, encoded messages rather than
   requiring a full transport.

   Backup 2 and 3's OWN send closures are silent (drop everything) from the very start -- they
   still RECEIVE and process the primary's Prepare (appending to their own log, since the
   PRIMARY's send closure calls handle_message on whichever replica it's addressed to), but their
   own PrepareOk reply can never reach the primary, so nothing beyond the primary's own implicit
   ack ever accumulates -- one short of the f + 1 = 2 quorum committing needs. *)
let test_uncommitted_tail_is_excluded () =
  let replica_count = 3 in
  let replicas = Array.make replica_count None in
  let silent_send ~to_:_ (_ : string) = () in
  let primary_send ~to_ bytes = match replicas.(to_ - 1) with Some r -> Replica.handle_message r bytes | None -> ()  in
  replicas.(0) <- Some (Replica.create ~my_id:1 ~replica_count ~svc_limit:3 ~send:primary_send);
  replicas.(1) <- Some (Replica.create ~my_id:2 ~replica_count ~svc_limit:3 ~send:silent_send);
  replicas.(2) <- Some (Replica.create ~my_id:3 ~replica_count ~svc_limit:3 ~send:silent_send);
  let primary = Option.get replicas.(0) in
  let batch_value =
    Value.Record
      [
        ("idempotency_key", Value.Scalar (Value.String "k-never-commits"));
        ("writes",
          Value.Sequence
            [
              Value.Record
                [
                  ("actor", Value.Scalar (Value.String "actor-1"));
                  ("causation", Value.Scalar (Value.Bytes (fake_event_id "c")));
                  ("correlation", Value.Scalar (Value.Bytes (fake_event_id "r")));
                  ("payload", record_value "uncommitted-write");
                ];
            ]);
      ]
  in
  Replica.propose primary batch_value;
  Alcotest.(check int) "with silent backups, nothing reaches quorum: zero committed envelopes" 0
    (List.length (Riptide_batch_commit.committed_envelopes primary));
  Alcotest.(check int) "but the entry IS present in the raw, uncommitted log" 1 (List.length (Replica.entries primary))

let tests =
  [
    ("empty batch commits as zero envelopes", `Quick, test_empty_batch_commits_as_zero_envelopes);
    ("round-trip: multiple writes produce a correct hash chain", `Quick, test_round_trip_multiple_writes);
    ("field order does not affect decoding", `Quick, test_field_order_independence);
    ("a foreign/malformed committed entry contributes zero envelopes", `Quick,
      test_malformed_committed_entry_is_zero_envelopes);
    ("one malformed write voids the whole batch", `Quick, test_malformed_write_makes_the_whole_batch_malformed);
    ("a repeated idempotency key with different writes keeps only the first", `Quick,
      test_repeated_idempotency_key_with_different_writes_keeps_only_the_first);
    ("two separate batches chain across the boundary", `Quick, test_two_separate_batches_chain_across_the_boundary);
    ("an uncommitted tail entry is excluded", `Quick, test_uncommitted_tail_is_excluded);
  ]
```

- [ ] **Step 7: Run the test suite**

Run: `dune build 2>&1 | tail -50`
Expected: succeeds (this task's `batch_commit.ml`/`.mli` were already written in Steps 2-3).

Run: `dune test --force 2>&1 | tail -40`
Expected: all `test_batch_commit` cases pass, full suite still green (182 previous + these new
ones).

- [ ] **Step 8: Commit**

```bash
git add lib/batch_commit/ test/dune test/test_riptide.ml test/test_batch_commit.ml
git commit -m "batch_commit: batch wire shape and pure decode (committed_envelopes)"
```

---

### Task 2: Write side (`propose`) with duplicate-bloat avoidance

**Files:**
- Modify: `lib/batch_commit/batch_commit.mli`
- Modify: `lib/batch_commit/batch_commit.ml`
- Modify: `test/test_batch_commit.ml`

**Interfaces:**
- Consumes: `write` and `committed_envelopes`/`committed_batch_values`/`batch_to_value`/
  `batch_of_value` from Task 1 (all already in `batch_commit.ml`; `batch_to_value` was written but
  had no caller in Task 1 — this task gives it its first real caller, `propose`, and removes the
  `[@warning "-32"]` attribute that made its temporary unused state build-clean). `batch_to_value`
  stays module-private (not added to `.mli`) — only `write`, `committed_envelopes`, and this task's
  own `propose` are part of the public interface.
- Produces (for Task 3): `val propose : Riptide_vsr.Replica.t -> idempotency_key:string ->
  write list -> unit`

- [ ] **Step 1: Write the failing tests**

Add to `test/test_batch_commit.ml`, after the existing tests (before the `tests` list):

```ocaml
let test_propose_produces_correct_envelopes () =
  let t = create_solo () in
  let actor = "actor-1" in
  Riptide_batch_commit.propose t ~idempotency_key:"k1"
    [
      w ~actor ~causation:(fake_event_id "c1") ~correlation:(fake_event_id "r1") (record_value "first");
      w ~actor ~causation:(fake_event_id "c2") ~correlation:(fake_event_id "r2") (record_value "second");
    ];
  let envelopes = Riptide_batch_commit.committed_envelopes t in
  Alcotest.(check int) "propose commits both writes" 2 (List.length envelopes);
  Alcotest.(check bool) "the resulting chain verifies" true (Log.verify_chain_list envelopes)

let test_propose_skips_a_key_already_committed () =
  let t = create_solo () in
  let actor = "actor-1" in
  Riptide_batch_commit.propose t ~idempotency_key:"dup"
    [ w ~actor ~causation:(fake_event_id "c") ~correlation:(fake_event_id "r") (record_value "first-call") ];
  Alcotest.(check int) "one write committed after the first call" 1
    (List.length (Riptide_batch_commit.committed_envelopes t));
  (* A second call with the SAME key -- must be a genuine no-op on the underlying replicated log,
     not just "produces the same decoded result by coincidence": assert op_number (the raw log
     length) does NOT grow, proving propose itself skipped calling Replica.propose at all, rather
     than proposing again and relying on decode-side dedup to hide it. *)
  let op_number_before = List.length (Replica.entries t) in
  Riptide_batch_commit.propose t ~idempotency_key:"dup"
    [ w ~actor ~causation:(fake_event_id "c") ~correlation:(fake_event_id "r") (record_value "second-call") ];
  Alcotest.(check int) "propose did not grow the underlying replicated log for a duplicate key"
    op_number_before (List.length (Replica.entries t));
  Alcotest.(check int) "still exactly one committed envelope, from the first call" 1
    (List.length (Riptide_batch_commit.committed_envelopes t))

let test_propose_with_different_keys_both_land () =
  let t = create_solo () in
  let actor = "actor-1" in
  Riptide_batch_commit.propose t ~idempotency_key:"key-a"
    [ w ~actor ~causation:(fake_event_id "c") ~correlation:(fake_event_id "r") (record_value "a") ];
  Riptide_batch_commit.propose t ~idempotency_key:"key-b"
    [ w ~actor ~causation:(fake_event_id "c") ~correlation:(fake_event_id "r") (record_value "b") ];
  let envelopes = Riptide_batch_commit.committed_envelopes t in
  Alcotest.(check int) "two distinct keys both commit" 2 (List.length envelopes);
  Alcotest.(check bool) "the resulting chain verifies" true (Log.verify_chain_list envelopes)
```

Add these three to the `tests` list:

```ocaml
    ("propose produces correct, chained envelopes", `Quick, test_propose_produces_correct_envelopes);
    ("propose skips re-proposing an already-committed key", `Quick, test_propose_skips_a_key_already_committed);
    ("propose with two distinct keys: both land", `Quick, test_propose_with_different_keys_both_land);
```

- [ ] **Step 2: Run to verify it fails**

Run: `dune build 2>&1 | tail -30`
Expected: FAIL with `Unbound value Riptide_batch_commit.propose` — `propose` doesn't exist in
`batch_commit.ml`/`.mli` yet.

- [ ] **Step 3: Implement `propose` in `batch_commit.ml`**

Add, directly below `committed_batch_values` (which Task 1 already wrote):

```ocaml
let already_committed (t : Riptide_vsr.Replica.t) ~(idempotency_key : string) : bool =
  List.exists
    (fun v -> match batch_of_value v with Some (key, _) -> String.equal key idempotency_key | None -> false)
    (committed_batch_values t)

let propose (t : Riptide_vsr.Replica.t) ~(idempotency_key : string) (writes : write list) : unit =
  if already_committed t ~idempotency_key then ()
  else Riptide_vsr.Replica.propose t (batch_to_value ~idempotency_key writes)
```

`propose` is now a real caller of `batch_to_value` — change its definition from
`let[@warning "-32"] batch_to_value ...` (Task 1, Step 3) back to a plain `let batch_to_value ...`,
removing the attribute entirely; it's no longer unused.

- [ ] **Step 4: Extend `batch_commit.mli`**

Add, after `committed_envelopes`'s own doc comment:

```ocaml
val propose : Riptide_vsr.Replica.t -> idempotency_key:string -> write list -> unit
(** [propose t ~idempotency_key writes] proposes [writes] as one atomic batch through
    {!Riptide_vsr.Replica.propose} -- matching that function's own fire-and-forget convention: no
    return value, no client acknowledgment. Telling a caller whether/when their batch committed is
    explicitly out of scope here (task-master Task 9's job).

    Checks first whether [idempotency_key] already appears among [t]'s own currently-committed
    batches ({!committed_envelopes}'s own decode, reused) and is a no-op if so -- purely to avoid
    unboundedly bloating the replicated log with duplicate no-op entries from a client that
    retries many times. This check is NOT what makes a duplicate safe to retry: that guarantee
    comes entirely from {!committed_envelopes}'s own first-wins-per-key dedup on the READ side,
    and holds regardless of how many times [propose] is called with the same key -- this check is
    an optimization on top of an already-safe operation, not a precondition for safety. *)
```

- [ ] **Step 5: Run to verify it passes**

Run: `dune build 2>&1 | tail -30`
Expected: succeeds.

Run: `dune test --force 2>&1 | tail -40`
Expected: all `test_batch_commit` cases pass, including the three new ones from Step 1.

- [ ] **Step 6: Commit**

```bash
git add lib/batch_commit/batch_commit.ml lib/batch_commit/batch_commit.mli test/test_batch_commit.ml
git commit -m "batch_commit: propose with duplicate-bloat avoidance"
```

---

### Task 3: Cluster-level proof — atomic under crash-during-commit

**Files:**
- Create: `test/test_batch_commit_cluster.ml`
- Modify: `test/dune` (no change expected — `riptide_batch_commit` was added by Task 1's Step 5,
  and `riptide_sim` was already present before this plan started; confirm both are there, only
  edit if Task 1's own change to this file was somehow incomplete)
- Modify: `test/test_riptide.ml` (register the new test module)

**Interfaces:**
- Consumes: `Riptide_batch_commit.propose`/`.committed_envelopes`/`.write` (Tasks 1-2),
  `Riptide_vsr.Replica`/`Riptide_sim.Network`/`Riptide_sim.Sim_transport` (already merged).
- Produces: nothing further downstream — this is this plan's final task.

- [ ] **Step 1: Write a minimal cluster harness**

This mirrors `test_vsr_replica_view_change.ml`'s own `with_cluster` (already-proven, already-
merged code) trimmed to exactly what this task needs: a real multi-replica cluster over
`Sim_transport`, plus a way to kill one replica's dispatch fiber (`stop`). No `isolate`/
`reconnect` is needed here — this task doesn't need to construct divergent logs, only a clean
primary-crash-before-quorum scenario.

`test/test_batch_commit_cluster.ml`:

```ocaml
open Riptide
open Riptide_vsr
open Riptide_sim

let record_value name = Value.Record [ ("name", Value.Scalar (Value.String name)) ]
let fake_event_id name = Value.content_hash (Value.Scalar (Value.String name))

exception Cluster_test_done
exception Replica_stopped

(* Trimmed version of test_vsr_replica_view_change.ml's own with_cluster: real Sim_transport, real
   per-replica dispatch fibers, a stop mechanism to simulate one replica's process dying. No
   isolate/reconnect -- this file has no need to construct divergent survivor logs. *)
let with_cluster ~replica_count (body : replicas:Replica.t array -> stop:(int -> unit) -> settle:(unit -> unit) -> unit) =
  Eio_mock.Backend.run @@ fun () ->
  let prng = Prng.create 1 in
  let net = Network.create prng () in
  for id = 1 to replica_count do
    Network.register net (string_of_int id)
  done;
  let handles = Array.init replica_count (fun i -> Sim_transport.create net (i + 1)) in
  let replicas =
    Array.init replica_count (fun i ->
        Replica.create ~my_id:(i + 1) ~replica_count ~svc_limit:3 ~send:(fun ~to_ bytes ->
            Sim_transport.send handles.(i) ~to_ bytes))
  in
  let settle () =
    let rec loop rounds_left =
      if rounds_left <= 0 then Alcotest.fail "cluster did not quiesce within the round budget"
      else begin
        let delivered = ref false in
        while Network.pump_one net do
          delivered := true
        done;
        Eio.Fiber.yield ();
        Eio.Fiber.yield ();
        if !delivered then loop (rounds_left - 1)
      end
    in
    loop 20
  in
  let stop_fns = Array.make replica_count None in
  try
    Eio.Switch.run (fun sw ->
        Array.iteri
          (fun i replica ->
            Eio.Fiber.fork ~sw (fun () ->
                try
                  Eio.Switch.run (fun replica_sw ->
                      stop_fns.(i) <- Some (fun () -> Eio.Switch.fail replica_sw Replica_stopped);
                      let rec dispatch_loop () =
                        let msg = Sim_transport.receive handles.(i) in
                        Replica.handle_message replica msg;
                        dispatch_loop ()
                      in
                      dispatch_loop ())
                with Replica_stopped -> ()))
            replicas;
        let stop i =
          match stop_fns.(i - 1) with
          | Some f -> f ()
          | None -> Alcotest.fail (Printf.sprintf "stop %d called before replica %d had registered its stop fn" i i)
        in
        body ~replicas ~stop ~settle;
        Eio.Switch.fail sw Cluster_test_done)
  with Cluster_test_done -> ()

let batch_value ~idempotency_key names =
  Value.Record
    [
      ("idempotency_key", Value.Scalar (Value.String idempotency_key));
      ("writes",
        Value.Sequence
          (List.map
             (fun name ->
               Value.Record
                 [
                   ("actor", Value.Scalar (Value.String "actor-1"));
                   ("causation", Value.Scalar (Value.Bytes (fake_event_id (name ^ "-c"))));
                   ("correlation", Value.Scalar (Value.Bytes (fake_event_id (name ^ "-r"))));
                   ("payload", record_value name);
                 ])
             names));
    ]

let tests = []
```

- [ ] **Step 2: Register the (still-empty) test module**

Read `test/test_riptide.ml`'s current contents and add `Test_batch_commit_cluster.tests` to the
same list Task 1's Step 5 added `Test_batch_commit.tests` to, matching the exact existing style.

Run: `dune build 2>&1 | tail -30`
Expected: succeeds (empty `tests = []` list is valid).

- [ ] **Step 3: Write the failing test — batch survives a primary crash BEFORE quorum**

Add to `test/test_batch_commit_cluster.ml`, replacing `let tests = []`:

```ocaml
let test_batch_commits_fully_despite_primary_crash_before_next_propose () =
  with_cluster ~replica_count:3 (fun ~replicas ~stop ~settle ->
      let primary = replicas.(0) in
      (* First batch: reaches real quorum (2 of 3) before anything crashes -- this is the batch
         under test. Real propose, real 3-node quorum, not the solo-replica shortcut Tasks 1-2's
         own unit tests use. *)
      Replica.propose primary (batch_value ~idempotency_key:"survives" [ "x"; "y" ]);
      settle ();
      (* Now the primary is gone -- exactly like test_vsr_replica_view_change.ml's own crash
         scenario, proving the batch that already reached quorum survives a primary failure,
         not merely that it committed while everything was healthy. *)
      stop 1;
      Array.iter
        (fun r ->
          if not (Replica.is_primary r) then begin
            Replica.check_timeout r;
            Replica.check_timeout r
          end)
        replicas;
      settle ();
      Array.iteri
        (fun i r ->
          if i <> 0 then begin
            let envelopes = Riptide_batch_commit.committed_envelopes r in
            Alcotest.(check int)
              (Printf.sprintf "survivor %d: both writes from the surviving batch are present" (i + 1))
              2 (List.length envelopes);
            Alcotest.(check bool)
              (Printf.sprintf "survivor %d: the chain verifies" (i + 1))
              true (Log.verify_chain_list envelopes)
          end)
        replicas)

let tests =
  [
    ( "a batch that reached quorum survives a primary crash and view change", `Quick,
      test_batch_commits_fully_despite_primary_crash_before_next_propose );
  ]
```

- [ ] **Step 4: Run to verify it fails for the right reason first (sanity check), then passes**

Run: `dune build 2>&1 | tail -50`
Expected: succeeds (no reason for this to fail to compile if Tasks 1-2 are correctly in place).

Run: `dune test --force 2>&1 | tail -40`
Expected: PASS. If it fails, the most likely cause is an insufficient `settle()`/`check_timeout`
budget for the view change to complete — compare against
`test/test_vsr_replica_view_change.ml`'s own `test_single_view_change_survives_primary_failure`,
which this scenario deliberately mirrors, and match its exact `check_timeout` call pattern if this
one under- or over-fires.

- [ ] **Step 5: Add the never-reached-quorum half — a batch that never committed anywhere leaves zero envelopes on every survivor**

Add to `test/test_batch_commit_cluster.ml`:

```ocaml
let test_batch_that_never_reached_quorum_is_absent_everywhere () =
  with_cluster ~replica_count:3 (fun ~replicas ~stop ~settle ->
      let primary = replicas.(0) in
      (* settle () first, with nothing yet proposed -- a harmless no-op on the network, but the
         ONLY thing that gives every forked dispatch fiber a chance to actually start running and
         register its own stop_fns.(i) entry (Eio.Fiber.fork schedules a fiber, it doesn't run it
         synchronously). with_cluster's own stop implementation fails loudly if called before
         that registration has happened -- see its own "stop %d called before replica %d had
         registered its stop fn" message -- so every test in this file must settle (or propose,
         which has the same yielding effect) at least once before its first stop call, even when,
         as here, nothing has been proposed yet for settle to actually deliver. *)
      settle ();
      (* Kill BOTH backups before proposing at all -- the primary's own Prepare broadcast still
         goes out (queued in the network), but with no live backups to ever reply, this can never
         reach the f + 1 = 2 quorum SendSV/normal-case commit needs. Matches this file's own
         top-level convention of using stop (not isolate) for "this replica's process is
         genuinely gone," established in test_vsr_replica_view_change.ml. *)
      stop 2;
      stop 3;
      Replica.propose primary (batch_value ~idempotency_key:"never-commits" [ "z" ]);
      settle ();
      let envelopes = Riptide_batch_commit.committed_envelopes primary in
      Alcotest.(check int) "the primary itself never sees this batch commit either -- no quorum, no commit"
        0 (List.length envelopes);
      Alcotest.(check int) "but the primary's own raw, uncommitted log does have the entry" 1
        (List.length (Replica.entries primary)))

let tests =
  [
    ( "a batch that reached quorum survives a primary crash and view change", `Quick,
      test_batch_commits_fully_despite_primary_crash_before_next_propose );
    ( "a batch that never reaches quorum commits nowhere, not even partially", `Quick,
      test_batch_that_never_reached_quorum_is_absent_everywhere );
  ]
```

Replace the previous `let tests = [ ... ]` (Step 3) with this one — it's the same first entry plus
the new second entry, not a separate list.

- [ ] **Step 6: Run the full suite**

Run: `dune test --force 2>&1 | tail -40`
Expected: all tests pass, including both new cluster-level ones. Full suite green.

- [ ] **Step 7: Commit**

```bash
git add test/test_batch_commit_cluster.ml test/test_riptide.ml
git commit -m "batch_commit: cluster-level proof of atomicity under primary crash"
```
