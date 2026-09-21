open Riptide
open Riptide_vsr
open Riptide_batch_commit

let record_value name = Value.Record [ ("name", Value.Scalar (Value.String name)) ]
let fake_event_id name = Value.content_hash (Value.Scalar (Value.String name))

(* replica_count = 1, f = 0: IsCommitted is vacuously true for every op-number, so
   Replica.propose commits synchronously, with no network/quorum needed at all -- exactly what an
   isolated unit test of the decode side needs. Matches test_vsr_replica.ml's own established use
   of this degenerate cluster size for propose-focused unit tests. *)
let create_solo () =
  let send ~to_:_ (_ : string) = () in
  Replica.create ~my_id:1 ~replica_count:1 ~svc_limit:3 ~send

let w ~actor ~causation ~correlation payload : Batch_commit.write =
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
    (List.length (Batch_commit.committed_envelopes t))

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
  let envelopes = Batch_commit.committed_envelopes t in
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
  let envelopes = Batch_commit.committed_envelopes t in
  Alcotest.(check int) "field order does not prevent decoding" 1 (List.length envelopes);
  Alcotest.(check string) "actor decoded correctly despite field order" actor (List.hd envelopes).actor

let test_malformed_committed_entry_is_zero_envelopes () =
  let t = create_solo () in
  (* A value that never went through Batch_commit at all -- simulates a foreign/corrupted entry
     landing in the committed log. Must not raise. *)
  Replica.propose t (Value.Scalar (Value.Int 42L));
  Alcotest.(check int) "a foreign committed value contributes zero envelopes" 0
    (List.length (Batch_commit.committed_envelopes t))

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
    (List.length (Batch_commit.committed_envelopes t))

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
  let envelopes = Batch_commit.committed_envelopes t in
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
  let envelopes = Batch_commit.committed_envelopes t in
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
  (* Pin all replicas to view 1 so they can communicate -- Primary(1) = 1 for replica_count=3 *)
  List.iter (fun opt -> match opt with Some r -> Replica.for_test_set_view_number r 1 | None -> ()) (Array.to_list replicas);
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
    (List.length (Batch_commit.committed_envelopes primary));
  Alcotest.(check int) "but the entry IS present in the raw, uncommitted log" 1 (List.length (Replica.entries primary))

let test_propose_produces_correct_envelopes () =
  let t = create_solo () in
  let actor = "actor-1" in
  Batch_commit.propose t ~idempotency_key:"k1"
    [
      w ~actor ~causation:(fake_event_id "c1") ~correlation:(fake_event_id "r1") (record_value "first");
      w ~actor ~causation:(fake_event_id "c2") ~correlation:(fake_event_id "r2") (record_value "second");
    ];
  let envelopes = Batch_commit.committed_envelopes t in
  Alcotest.(check int) "propose commits both writes" 2 (List.length envelopes);
  Alcotest.(check bool) "the resulting chain verifies" true (Log.verify_chain_list envelopes)

let test_propose_skips_a_key_already_committed () =
  let t = create_solo () in
  let actor = "actor-1" in
  Batch_commit.propose t ~idempotency_key:"dup"
    [ w ~actor ~causation:(fake_event_id "c") ~correlation:(fake_event_id "r") (record_value "first-call") ];
  Alcotest.(check int) "one write committed after the first call" 1
    (List.length (Batch_commit.committed_envelopes t));
  (* A second call with the SAME key -- must be a genuine no-op on the underlying replicated log,
     not just "produces the same decoded result by coincidence": assert op_number (the raw log
     length) does NOT grow, proving propose itself skipped calling Replica.propose at all, rather
     than proposing again and relying on decode-side dedup to hide it. *)
  let op_number_before = List.length (Replica.entries t) in
  Batch_commit.propose t ~idempotency_key:"dup"
    [ w ~actor ~causation:(fake_event_id "c") ~correlation:(fake_event_id "r") (record_value "second-call") ];
  Alcotest.(check int) "propose did not grow the underlying replicated log for a duplicate key"
    op_number_before (List.length (Replica.entries t));
  Alcotest.(check int) "still exactly one committed envelope, from the first call" 1
    (List.length (Batch_commit.committed_envelopes t))

let test_propose_with_different_keys_both_land () =
  let t = create_solo () in
  let actor = "actor-1" in
  Batch_commit.propose t ~idempotency_key:"key-a"
    [ w ~actor ~causation:(fake_event_id "c") ~correlation:(fake_event_id "r") (record_value "a") ];
  Batch_commit.propose t ~idempotency_key:"key-b"
    [ w ~actor ~causation:(fake_event_id "c") ~correlation:(fake_event_id "r") (record_value "b") ];
  let envelopes = Batch_commit.committed_envelopes t in
  Alcotest.(check int) "two distinct keys both commit" 2 (List.length envelopes);
  Alcotest.(check bool) "the resulting chain verifies" true (Log.verify_chain_list envelopes)

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
    ("propose produces correct, chained envelopes", `Quick, test_propose_produces_correct_envelopes);
    ("propose skips re-proposing an already-committed key", `Quick, test_propose_skips_a_key_already_committed);
    ("propose with two distinct keys: both land", `Quick, test_propose_with_different_keys_both_land);
  ]
