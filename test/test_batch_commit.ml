open Riptide
open Riptide_vsr
open Riptide_batch_commit
open Riptide_crypto

let () = Mirage_crypto_rng_unix.use_default ()

let record_value name = Value.Record [ ("name", Value.Scalar (Value.String name)) ]
let fake_event_id name = Value.content_hash (Value.Scalar (Value.String name))

(* replica_count = 1, f = 0: IsCommitted is vacuously true for every op-number, so
   Replica.propose commits synchronously, with no network/quorum needed at all -- exactly what an
   isolated unit test of the decode side needs. Matches test_vsr_replica.ml's own established use
   of this degenerate cluster size for propose-focused unit tests. *)
let create_solo () =
  let send ~to_:_ (_ : string) = () in
  Replica.create ~storage:(Replica.volatile_storage ()) ~my_id:1 ~replica_count:1 ~svc_limit:3 ~send ()

let w ~actor ~causation ~correlation ?(merge_key = None) payload : Batch_commit.write =
  { actor; causation; correlation; payload; merge_key }

(* Batch_commit.propose now takes a Batch_commit.t handle (task-master subtask 5.3), not a bare
   Riptide_vsr.Replica.t -- see batch_commit.mli's own [create]/[t] doc comments. Every test in
   this file that only needs propose's pre-existing per-call ?require_encryption override (not
   the new handle-level policy itself, which gets its own dedicated tests below) can build a
   plain, default-policy handle inline via this helper rather than repeating
   [Batch_commit.create ~replica ~authorize:Batch_commit.allow_all ()] at every call site.
   [~authorize:Batch_commit.allow_all] is this file's own explicit, visible "no real policy yet"
   choice (task-master Task 5, subtask 5) -- every test below that needs to exercise a real
   [Deny] decision builds its own handle directly instead of going through this helper. *)
let bc ?require_encryption replica = Batch_commit.create ~replica ~authorize:Batch_commit.allow_all ?require_encryption ()

(* Real encryption_sink construction against a real Redaction_store, for the
   require_encryption tests below -- reusing test_redaction.ml's own with_tmp_dir/with_store/
   sink_of pattern rather than inventing a new one (this file has no other need for a real
   keystore, so the helpers live here rather than being shared/exported). *)
let with_tmp_dir f =
  let dir = Filename.temp_file "riptide_batch_commit_test" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o700;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () -> f dir)

let with_store f =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let kv =
        Riptide_storage.File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:Redaction_store.owner_tag
          dir
      in
      let kek = Kek.of_raw (Mirage_crypto_rng.generate 32) in
      f (Redaction_store.create ~kv ~kek))

let sink_of store : Batch_commit.encryption_sink =
  { encrypt = (fun ~event_id v -> Redaction_store.encrypt_value store ~event_id v) }

let test_empty_batch_commits_as_zero_envelopes () =
  let t = create_solo () in
  (* Exercises the decode side directly against a hand-built batch Value.value, proposed straight
     through the underlying Replica.propose -- the SAME wire shape Batch_commit.propose (see the
     propose-focused tests further down this file) builds internally. *)
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

let test_wrong_length_causation_makes_the_whole_batch_malformed () =
  let t = create_solo () in
  (* Envelope.event_id = Value.hash, documented in lib/value.mli as "Raw 32-byte SHA-256 digest" --
     Value.hash_to_hex raises Invalid_argument on anything else. A committed entry is arbitrary
     VSR-replicated bytes with no payload-integrity guarantee, so a wrong-length causation/
     correlation must void the whole batch, exactly like any other malformed-write shape, rather
     than producing a well-typed envelope whose fields silently violate their own contract. *)
  let batch_value =
    Value.Record
      [
        ("idempotency_key", Value.Scalar (Value.String "k-bad-hash-length"));
        ("writes",
          Value.Sequence
            [
              Value.Record
                [
                  ("actor", Value.Scalar (Value.String "actor-1"));
                  ("causation", Value.Scalar (Value.Bytes "abc"));
                  (* 3 bytes, not the required 32 *)
                  ("correlation", Value.Scalar (Value.Bytes (fake_event_id "r")));
                  ("payload", record_value "bad-causation-length");
                ];
            ]);
      ]
  in
  Replica.propose t batch_value;
  Alcotest.(check int) "a wrong-length causation voids the whole batch, not just that write" 0
    (List.length (Batch_commit.committed_envelopes t))

let test_malformed_batch_does_not_burn_its_idempotency_key () =
  let t = create_solo () in
  let key = "k-malformed-then-retry" in
  (* A malformed batch under [key]: batch_of_value returns None for it, so its key is never added
     to committed_envelopes's dedup set -- it contributed nothing, so a later, well-formed batch
     under the same key is a genuine first attempt from the read side's perspective, not a
     duplicate. *)
  let malformed_batch =
    Value.Record
      [
        ("idempotency_key", Value.Scalar (Value.String key));
        ("writes", Value.Sequence [ Value.Scalar (Value.Int 0L) (* not even a Record *) ]);
      ]
  in
  Replica.propose t malformed_batch;
  Alcotest.(check int) "the malformed attempt itself contributes zero envelopes" 0
    (List.length (Batch_commit.committed_envelopes t));
  let actor = "actor-1" in
  Batch_commit.propose (bc t) ~idempotency_key:key
    [ w ~actor ~causation:(fake_event_id "c") ~correlation:(fake_event_id "r") (record_value "real-retry") ];
  let envelopes = Batch_commit.committed_envelopes t in
  Alcotest.(check int)
    "a later well-formed batch under the SAME key DOES materialize -- the malformed attempt never \
     burned the key -- as its own real write plus its synthetic authorization-decision write \
     (task-master Task 5, subtask 5)"
    2 (List.length envelopes);
  match (List.hd envelopes).payload with
  | Value.Record [ ("name", Value.Scalar (Value.String name)) ] ->
    Alcotest.(check string) "the well-formed retry's own payload lands" "real-retry" name
  | _ -> Alcotest.fail "unexpected payload shape"

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
   cluster (f = 1) instead, where a genuine quorum is needed. No network/Eio required: three
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
  (* Only ever installed as replica 1's (the primary's) own [~send], so every delivery through it
     really did come from replica 1 -- [~sender:1] here is a real transport-authenticated identity
     in miniature, not a placeholder, matching [handle_message]'s new cross-check (Task 3). *)
  let primary_send ~to_ bytes =
    match replicas.(to_ - 1) with Some r -> Replica.handle_message r ~sender:1 bytes | None -> ()
  in
  replicas.(0) <- Some (Replica.create ~storage:(Replica.volatile_storage ()) ~my_id:1 ~replica_count ~svc_limit:3 ~send:primary_send ());
  replicas.(1) <- Some (Replica.create ~storage:(Replica.volatile_storage ()) ~my_id:2 ~replica_count ~svc_limit:3 ~send:silent_send ());
  replicas.(2) <- Some (Replica.create ~storage:(Replica.volatile_storage ()) ~my_id:3 ~replica_count ~svc_limit:3 ~send:silent_send ());
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
  Batch_commit.propose (bc t) ~idempotency_key:"k1"
    [
      w ~actor ~causation:(fake_event_id "c1") ~correlation:(fake_event_id "r1") (record_value "first");
      w ~actor ~causation:(fake_event_id "c2") ~correlation:(fake_event_id "r2") (record_value "second");
    ];
  let envelopes = Batch_commit.committed_envelopes t in
  (* 2 real writes + 1 synthetic authorization-decision write (task-master Task 5, subtask 5) --
     see test_propose_appends_a_synthetic_authorization_decision_write below for a test dedicated
     to that write's own shape. *)
  Alcotest.(check int) "propose commits both writes, plus the synthetic authorization-decision write"
    3 (List.length envelopes);
  Alcotest.(check bool) "the resulting chain verifies" true (Log.verify_chain_list envelopes)

let test_propose_skips_a_key_already_committed () =
  let t = create_solo () in
  let h = bc t in
  let actor = "actor-1" in
  Batch_commit.propose h ~idempotency_key:"dup"
    [ w ~actor ~causation:(fake_event_id "c") ~correlation:(fake_event_id "r") (record_value "first-call") ];
  Alcotest.(check int) "one write plus its synthetic authorization-decision write committed after \
                        the first call"
    2 (List.length (Batch_commit.committed_envelopes t));
  (* A second call with the SAME key -- must be a genuine no-op on the underlying replicated log,
     not just "produces the same decoded result by coincidence": assert op_number (the raw log
     length) does NOT grow, proving propose itself skipped calling Replica.propose at all, rather
     than proposing again and relying on decode-side dedup to hide it. *)
  let op_number_before = List.length (Replica.entries t) in
  Batch_commit.propose h ~idempotency_key:"dup"
    [ w ~actor ~causation:(fake_event_id "c") ~correlation:(fake_event_id "r") (record_value "second-call") ];
  Alcotest.(check int) "propose did not grow the underlying replicated log for a duplicate key"
    op_number_before (List.length (Replica.entries t));
  Alcotest.(check int) "still exactly the first call's two envelopes, none from the second call" 2
    (List.length (Batch_commit.committed_envelopes t))

(* This test used to pin the OPPOSITE behaviour, under the name
   [test_empty_batch_permanently_burns_its_key_via_propose]: an empty batch was well-formed, so
   [batch_of_value] decoded it, it claimed its key in [committed_envelopes]'s own first-wins dedup
   set while contributing zero envelopes, and propose's already-in-the-log check then made every
   later call under that key a silent no-op -- so a real batch proposed afterwards was never
   committed, never materialized, and nothing raised. Task 9's review (2026-09-23) judged that a
   silent, permanent data-loss path rather than a curiosity worth pinning, especially once
   batch_commit.mli began recommending the empty-[writes] call shape as the way for a replica to
   drive its own commit stream into its own materializer. [propose] now refuses to write an empty
   batch at all, and this test pins the guard instead. *)
let test_an_empty_batch_is_never_proposed_and_never_burns_its_key () =
  let t = create_solo () in
  let h = bc t in
  let key = "k-empty-burns-key" in
  (* No writes and no ~materialize sink: the call could not have had any effect even before the
     guard, so it raises rather than silently doing nothing. *)
  Alcotest.check_raises "an empty batch with no sink is a caller error"
    (Invalid_argument
       "Batch_commit.propose: an empty writes list with no ~materialize sink cannot do anything -- \
        an empty batch is never proposed (it would permanently claim this idempotency key while \
        contributing no envelopes, silently swallowing any later real batch under it), and with no \
        sink there is nothing to materialize either. Pass the batch's writes, or pass ~materialize \
        to drive an already-committed batch into a materializer.")
    (fun () -> Batch_commit.propose h ~idempotency_key:key []);
  Alcotest.(check int) "nothing reached the replicated log" 0 (List.length (Replica.entries t));
  (* The same shape WITH a sink is the supported drain idiom, so it does not raise -- and it still
     must not write an empty batch. Nothing is committed under this key yet, so it is simply
     inert. *)
  Batch_commit.propose h ~idempotency_key:key ~materialize:{ write = (fun ~merge_key:_ _ -> assert false) } [];
  Alcotest.(check int) "the drain idiom against an unknown key proposes nothing either" 0
    (List.length (Replica.entries t));
  (* And the key is still free: a real batch under it lands normally. *)
  let actor = "actor-1" in
  Batch_commit.propose h ~idempotency_key:key
    [ w ~actor ~causation:(fake_event_id "c") ~correlation:(fake_event_id "r") (record_value "lands-fine") ];
  Alcotest.(check int) "a real batch under the same key is committed, not swallowed -- its own real \
                        write plus its synthetic authorization-decision write"
    2 (List.length (Batch_commit.committed_envelopes t));
  Alcotest.(check int) "and it is the log's first and only entry" 1 (List.length (Replica.entries t))

let test_propose_with_different_keys_both_land () =
  let t = create_solo () in
  let h = bc t in
  let actor = "actor-1" in
  Batch_commit.propose h ~idempotency_key:"key-a"
    [ w ~actor ~causation:(fake_event_id "c") ~correlation:(fake_event_id "r") (record_value "a") ];
  Batch_commit.propose h ~idempotency_key:"key-b"
    [ w ~actor ~causation:(fake_event_id "c") ~correlation:(fake_event_id "r") (record_value "b") ];
  let envelopes = Batch_commit.committed_envelopes t in
  (* 2 distinct keys x (1 real write + 1 synthetic authorization-decision write each) = 4. *)
  Alcotest.(check int) "two distinct keys both commit, each with its own synthetic \
                        authorization-decision write"
    4 (List.length envelopes);
  Alcotest.(check bool) "the resulting chain verifies" true (Log.verify_chain_list envelopes)

(* Deployment-level policy primitive (task-master subtask 4.5): a deployment that wants to
   enforce "every write through this path must be encrypted" previously had no way to do so --
   ~encryption was purely opt-in per call, so a caller that simply omitted it silently produced a
   plaintext-in-the-log write with no error anywhere. *)
let test_require_encryption_rejects_a_plaintext_propose () =
  let t = create_solo () in
  let actor = "actor-1" in
  Alcotest.check_raises "require_encryption:true with no ~encryption sink raises"
    (Invalid_argument
       "Batch_commit.propose: require_encryption is true but no ~encryption sink was supplied")
    (fun () ->
      Batch_commit.propose (bc t) ~idempotency_key:"k1" ~require_encryption:true
        [ w ~actor ~causation:(fake_event_id "c") ~correlation:(fake_event_id "r") (record_value "hello") ])

let test_require_encryption_true_with_a_real_sink_succeeds () =
  with_store (fun store ->
      let t = create_solo () in
      let actor = "actor-1" in
      Batch_commit.propose (bc t) ~idempotency_key:"k2" ~require_encryption:true ~encryption:(sink_of store)
        [ w ~actor ~causation:(fake_event_id "c") ~correlation:(fake_event_id "r") (record_value "hello") ];
      Alcotest.(check int) "the batch committed: the encrypted write plus its own (unencrypted) \
                            synthetic authorization-decision write"
        2 (List.length (Batch_commit.committed_envelopes t)))

(* Review Focus: require_encryption must not mask or confuse the pre-existing merge_key +
   ~encryption rejection (from the just-merged plan's own Task 6) -- one clear failure, not two
   competing ones. Here require_encryption's own check can't even fire (~encryption IS supplied),
   so the ORIGINAL merge_key rejection must still be the one that raises, verbatim. *)
let test_require_encryption_true_still_raises_for_the_pre_existing_merge_key_reason () =
  with_store (fun store ->
      let t = create_solo () in
      let actor = "actor-1" in
      let bad_write =
        {
          (w ~actor ~causation:(fake_event_id "c") ~correlation:(fake_event_id "r") (record_value "hello"))
          with
          merge_key = Some "mk";
        }
      in
      Alcotest.check_raises "merge_key + encryption is still rejected, unchanged by require_encryption"
        (Invalid_argument
           "Batch_commit.propose: a write with merge_key = Some _ cannot also be encrypted \
            (~encryption): the materialized accumulator is outside the redaction keystore, so \
            deleting the DEK would not erase it")
        (fun () ->
          Batch_commit.propose (bc t) ~idempotency_key:"k3" ~require_encryption:true ~encryption:(sink_of store)
            [ bad_write ]))

(* Task-master subtask 5.3 (audit-remediation Decision 5.3): require_encryption moves from a
   purely per-call flag to a construction-time policy stored on the new Batch_commit.t handle,
   precisely because the tests above show the mitigation and the gap it exists to catch living at
   the EXACT SAME call site -- a call site careless enough to forget ~encryption was, by
   construction, equally likely to forget ~require_encryption:true too. A handle-level policy lets
   a deployment set it once, centrally, at the one place that builds the handle, so every propose
   call site inherits it without having to remember anything itself. This test proves the handle's
   own stored policy alone -- no per-call ~require_encryption at all -- is what catches a call site
   that forgot ~encryption. *)
let test_handle_level_require_encryption_catches_a_call_site_that_forgot_it () =
  let t = create_solo () in
  let h = Batch_commit.create ~replica:t ~authorize:Batch_commit.allow_all ~require_encryption:true () in
  let actor = "actor-1" in
  Alcotest.check_raises
    "a propose call with no ~encryption sink is refused by the handle's own stored policy, with no \
     ~require_encryption passed at the call site at all"
    (Invalid_argument
       "Batch_commit.propose: require_encryption is true but no ~encryption sink was supplied")
    (fun () ->
      Batch_commit.propose h ~idempotency_key:"k-handle-policy"
        [ w ~actor ~causation:(fake_event_id "c") ~correlation:(fake_event_id "r") (record_value "hello") ])

(* The other half of the same contract (batch_commit.mli's own [propose] doc comment): a per-call
   ~require_encryption, when supplied, OVERRIDES the handle's stored policy for that one call --
   including turning it off, an intentional, deliberate opt-out an operator might need for a single
   call site even under a deployment-wide encrypt-everything policy. *)
let test_per_call_require_encryption_override_still_works_against_a_true_handle_policy () =
  let t = create_solo () in
  let h = Batch_commit.create ~replica:t ~authorize:Batch_commit.allow_all ~require_encryption:true () in
  let actor = "actor-1" in
  Batch_commit.propose h ~idempotency_key:"k-handle-override" ~require_encryption:false
    [ w ~actor ~causation:(fake_event_id "c") ~correlation:(fake_event_id "r") (record_value "hello") ];
  Alcotest.(check int) "the plaintext batch committed despite the handle's own require_encryption:true \
                        -- the write plus its synthetic authorization-decision write"
    2 (List.length (Batch_commit.committed_envelopes (Batch_commit.replica h)))

(* Task-master Task 5, subtask 5: the universal, mandatory authorization checkpoint. See
   batch_commit.mli's own [create]/[propose] doc comments for the full contract this and the two
   tests below pin. *)
let test_propose_refuses_the_whole_batch_when_any_write_is_denied () =
  let t = create_solo () in
  let deny_second = ref false in
  let authorize (w : Batch_commit.write) =
    if !deny_second && w.merge_key = Some "b" then Batch_commit.Deny "test denial" else Batch_commit.Allow
  in
  let h = Batch_commit.create ~replica:t ~authorize () in
  let actor = "actor-1" in
  Batch_commit.propose h ~idempotency_key:"k1"
    [
      w ~actor ~causation:(fake_event_id "c1") ~correlation:(fake_event_id "c1") ~merge_key:(Some "a")
        (record_value "1");
      w ~actor ~causation:(fake_event_id "c1") ~correlation:(fake_event_id "c1") ~merge_key:(Some "b")
        (record_value "2");
    ];
  deny_second := true;
  let before = Batch_commit.authorization_denials () in
  Batch_commit.propose h ~idempotency_key:"k2"
    [
      w ~actor ~causation:(fake_event_id "c2") ~correlation:(fake_event_id "c2") ~merge_key:(Some "a")
        (record_value "3");
      w ~actor ~causation:(fake_event_id "c2") ~correlation:(fake_event_id "c2") ~merge_key:(Some "b")
        (record_value "4");
    ];
  Alcotest.(check int) "denial counted" (before + 1) (Batch_commit.authorization_denials ());
  (* k1's own 2 writes plus its own synthetic authorization-decision write = 3. k2 was denied on
     its second write, so NONE of k2's writes -- not even the first, allowed one -- ever reached
     the log: a batch is one atomic, indivisible unit, so a single denied write refuses the whole
     batch, not just itself. *)
  Alcotest.(check int) "the whole batch was refused, not just the denied write" 3
    (List.length (Batch_commit.committed_envelopes t))

(* Directly pins the synthetic authorization-decision write's own shape (batch_commit.mli's own
   [propose] "Authorization" section) -- the count-only assertions elsewhere in this file (and
   across the rest of this codebase's test suite, migrated by this same task) only prove ONE extra
   envelope appears per successfully-proposed batch; this test proves what that envelope actually
   IS. *)
let test_propose_appends_a_synthetic_authorization_decision_write () =
  let t = create_solo () in
  let h = Batch_commit.create ~replica:t ~authorize:Batch_commit.allow_all () in
  let actor = "actor-1" in
  let c = fake_event_id "c" and r = fake_event_id "r" in
  Batch_commit.propose h ~idempotency_key:"k-authz-write"
    [ w ~actor ~causation:c ~correlation:r (record_value "real-write") ];
  let envelopes = Batch_commit.committed_envelopes t in
  Alcotest.(check int) "one real write plus one synthetic authorization-decision write" 2
    (List.length envelopes);
  let real_envelope = List.nth envelopes 0 and authz_envelope = List.nth envelopes 1 in
  Alcotest.(check string) "the real write's own actor is unaffected" actor real_envelope.actor;
  Alcotest.(check string) "the synthetic write's actor identifies it as the authz module"
    "riptide.module.authz" authz_envelope.actor;
  Alcotest.(check bool)
    "the synthetic write is causally linked to the batch's own first write, not freestanding" true
    (String.equal authz_envelope.causation c && String.equal authz_envelope.correlation r);
  Alcotest.(check bool) "the resulting chain, including the synthetic write, verifies end to end" true
    (Log.verify_chain_list envelopes);
  match authz_envelope.payload with
  | Value.Record fields -> (
    match (List.assoc_opt "idempotency_key" fields, List.assoc_opt "decision" fields) with
    | Some (Value.Scalar (Value.String key)), Some (Value.Scalar (Value.String decision)) ->
      Alcotest.(check string) "the decision payload records this batch's own idempotency_key"
        "k-authz-write" key;
      Alcotest.(check string) "the decision payload records the allow decision" "allow" decision
    | _ -> Alcotest.fail "unexpected authorization-decision payload field shape")
  | _ -> Alcotest.fail "unexpected authorization-decision payload shape"

let test_allow_all_is_the_explicit_no_policy_choice () =
  (* Every existing test/call site's own use of ~authorize:Batch_commit.allow_all continues to
     behave exactly as it did before this task, modulo the one synthetic
     authorization-decision write every successfully-proposed batch now earns (its own shape
     pinned once, directly, by test_propose_appends_a_synthetic_authorization_decision_write
     above -- not re-pinned at every migrated call site). *)
  let t = create_solo () in
  let h = Batch_commit.create ~replica:t ~authorize:Batch_commit.allow_all () in
  let actor = "actor-1" in
  Batch_commit.propose h ~idempotency_key:"k"
    [ w ~actor ~causation:(fake_event_id "c") ~correlation:(fake_event_id "c") (record_value "1") ];
  Alcotest.(check int) "committed: the real write plus its synthetic authorization-decision write" 2
    (List.length (Batch_commit.committed_envelopes t))

let tests =
  [
    ("empty batch commits as zero envelopes", `Quick, test_empty_batch_commits_as_zero_envelopes);
    ("round-trip: multiple writes produce a correct hash chain", `Quick, test_round_trip_multiple_writes);
    ("field order does not affect decoding", `Quick, test_field_order_independence);
    ("a foreign/malformed committed entry contributes zero envelopes", `Quick,
      test_malformed_committed_entry_is_zero_envelopes);
    ("one malformed write voids the whole batch", `Quick, test_malformed_write_makes_the_whole_batch_malformed);
    ("a wrong-length causation voids the whole batch", `Quick,
      test_wrong_length_causation_makes_the_whole_batch_malformed);
    ("a malformed batch does not burn its idempotency key -- a later well-formed retry lands", `Quick,
      test_malformed_batch_does_not_burn_its_idempotency_key);
    ("a repeated idempotency key with different writes keeps only the first", `Quick,
      test_repeated_idempotency_key_with_different_writes_keeps_only_the_first);
    ("two separate batches chain across the boundary", `Quick, test_two_separate_batches_chain_across_the_boundary);
    ("an uncommitted tail entry is excluded", `Quick, test_uncommitted_tail_is_excluded);
    ("propose produces correct, chained envelopes", `Quick, test_propose_produces_correct_envelopes);
    ("propose skips re-proposing an already-committed key", `Quick, test_propose_skips_a_key_already_committed);
    ("an empty batch is never proposed and never burns its key", `Quick,
      test_an_empty_batch_is_never_proposed_and_never_burns_its_key);
    ("propose with two distinct keys: both land", `Quick, test_propose_with_different_keys_both_land);
    ("require_encryption:true rejects a plaintext propose", `Quick,
      test_require_encryption_rejects_a_plaintext_propose);
    ("require_encryption:true with a real ~encryption sink succeeds", `Quick,
      test_require_encryption_true_with_a_real_sink_succeeds);
    ("require_encryption:true still raises for the pre-existing merge_key + encryption reason", `Quick,
      test_require_encryption_true_still_raises_for_the_pre_existing_merge_key_reason);
    ("handle-level require_encryption:true catches a call site that forgot ~encryption", `Quick,
      test_handle_level_require_encryption_catches_a_call_site_that_forgot_it);
    ("a per-call require_encryption:false override still works against a true handle policy", `Quick,
      test_per_call_require_encryption_override_still_works_against_a_true_handle_policy);
    ("a denied write refuses the whole batch, not just itself", `Quick,
      test_propose_refuses_the_whole_batch_when_any_write_is_denied);
    ("an allowed batch's own synthetic authorization-decision write has the expected shape", `Quick,
      test_propose_appends_a_synthetic_authorization_decision_write);
    ("allow_all is the explicit, visible no-policy-yet choice", `Quick,
      test_allow_all_is_the_explicit_no_policy_choice);
  ]
