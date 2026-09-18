(* test/test_vsr_replica.ml -- single-replica-in-isolation tests: handle_message/propose called
   directly with hand-constructed encoded messages, no real transport, no second replica. Real
   multi-replica message exchange over Sim_transport is Task 2's own test file
   (test_vsr_replica_cluster.ml), not this one. *)
open Riptide
open Riptide_vsr

let v s = Value.Scalar (Value.String s)

(* Captures every [~to_, bytes] pair a replica's [send] closure is given, in call order. *)
let capturing_send () =
  let sent = ref [] in
  let send ~to_ bytes = sent := (to_, bytes) :: !sent in
  (send, fun () -> List.rev !sent)

let decoded_sent sent_fn = List.map (fun (to_, bytes) -> (to_, Message.decode bytes)) (sent_fn ())

(* ---- propose (ReceiveClientRequest, VSR.tla:91-102) ---- *)

let test_primary_propose_broadcasts_prepare () =
  let send, sent = capturing_send () in
  let t = Replica.create ~my_id:1 ~replica_count:3 ~primary_id:1 ~send in
  Replica.propose t (v "hello");
  Alcotest.(check int) "op_number advances to 1" 1 (Replica.op_number t);
  Alcotest.(check int) "commit_number unchanged by propose alone" 0 (Replica.commit_number t);
  Alcotest.(check bool) "entries now contains the proposed value" true (Replica.entries t = [ v "hello" ]);
  (* every OTHER replica (2, 3) gets a Prepare{view=0; n=1; v; k=0}, primary (1) does not *)
  Alcotest.(check bool) "broadcasts Prepare to both other replicas, not itself" true
    (decoded_sent sent
    = [ (2, Message.Prepare { view = 0; n = 1; v = v "hello"; k = 0 });
        (3, Message.Prepare { view = 0; n = 1; v = v "hello"; k = 0 }) ])

let test_propose_is_noop_on_non_primary () =
  let send, sent = capturing_send () in
  let t = Replica.create ~my_id:2 ~replica_count:3 ~primary_id:1 ~send in
  Alcotest.(check bool) "is_primary is false for a backup" false (Replica.is_primary t);
  Replica.propose t (v "should-not-be-accepted");
  Alcotest.(check int) "op_number unchanged" 0 (Replica.op_number t);
  Alcotest.(check bool) "entries unchanged" true (Replica.entries t = []);
  Alcotest.(check bool) "no message sent" true (sent () = [])

let test_propose_duplicate_value_rejected_second_time () =
  let send, sent = capturing_send () in
  let t = Replica.create ~my_id:1 ~replica_count:3 ~primary_id:1 ~send in
  Replica.propose t (v "dup");
  Alcotest.(check int) "op_number after first propose" 1 (Replica.op_number t);
  Alcotest.(check int) "two Prepares sent after first propose" 2 (List.length (sent ()));
  (* same value again -- VSR.tla's own dedup guard (v \notin log) makes this a no-op *)
  Replica.propose t (v "dup");
  Alcotest.(check int) "op_number NOT advanced by the duplicate propose" 1 (Replica.op_number t);
  Alcotest.(check bool) "entries still just the one value" true (Replica.entries t = [ v "dup" ]);
  Alcotest.(check int) "no additional messages sent for the rejected duplicate" 2 (List.length (sent ()));
  (* a genuinely different value is still accepted *)
  Replica.propose t (v "not-a-dup");
  Alcotest.(check int) "op_number advances for a distinct value" 2 (Replica.op_number t);
  Alcotest.(check int) "four Prepares sent in total now" 4 (List.length (sent ()))

(* ---- ReceivePrepareMsg (VSR.tla:104-123) ---- *)

let test_backup_in_order_prepare_appends_and_replies () =
  let send, sent = capturing_send () in
  let t = Replica.create ~my_id:2 ~replica_count:3 ~primary_id:1 ~send in
  let prepare = Message.encode (Message.Prepare { view = 0; n = 1; v = v "x"; k = 0 }) in
  Replica.handle_message t prepare;
  Alcotest.(check int) "op_number advances to 1" 1 (Replica.op_number t);
  Alcotest.(check bool) "entries contains the prepared value" true (Replica.entries t = [ v "x" ]);
  Alcotest.(check int) "commit_number stays 0 (k=0 in this Prepare)" 0 (Replica.commit_number t);
  Alcotest.(check bool) "replies with the right PrepareOk, to the primary" true
    (decoded_sent sent = [ (1, Message.Prepare_ok { view = 0; n = 1; i = 2 }) ])

let test_backup_prepare_advances_commit_number_from_k () =
  let send, _sent = capturing_send () in
  let t = Replica.create ~my_id:2 ~replica_count:3 ~primary_id:1 ~send in
  (* op 1 in-order, k=0 *)
  Replica.handle_message t (Message.encode (Message.Prepare { view = 0; n = 1; v = v "a"; k = 0 }));
  (* op 2 in-order, carrying k=1 (the primary's own commit_number from before op 2 was appended) *)
  Replica.handle_message t (Message.encode (Message.Prepare { view = 0; n = 2; v = v "b"; k = 1 }));
  Alcotest.(check int) "commit_number advances to the Prepare's own k" 1 (Replica.commit_number t);
  (* a later Prepare carrying a LOWER k must never regress commit_number *)
  Replica.handle_message t (Message.encode (Message.Prepare { view = 0; n = 3; v = v "c"; k = 0 }));
  Alcotest.(check int) "commit_number never regresses" 1 (Replica.commit_number t)

let test_backup_out_of_order_prepare_dropped () =
  let send, sent = capturing_send () in
  let t = Replica.create ~my_id:2 ~replica_count:3 ~primary_id:1 ~send in
  (* op_number is 0; a Prepare for n=2 (a gap) must not be matched by ReceivePrepareMsg at all *)
  let prepare = Message.encode (Message.Prepare { view = 0; n = 2; v = v "skip"; k = 0 }) in
  Replica.handle_message t prepare;
  Alcotest.(check int) "op_number unchanged" 0 (Replica.op_number t);
  Alcotest.(check bool) "log unchanged" true (Replica.entries t = []);
  Alcotest.(check int) "commit_number unchanged" 0 (Replica.commit_number t);
  Alcotest.(check bool) "no PrepareOk sent" true (sent () = [])

let test_backup_duplicate_prepare_dropped () =
  let send, sent = capturing_send () in
  let t = Replica.create ~my_id:2 ~replica_count:3 ~primary_id:1 ~send in
  Replica.handle_message t (Message.encode (Message.Prepare { view = 0; n = 1; v = v "a"; k = 0 }));
  let sent_after_first = sent () in
  (* the same op_number 1 arriving again (e.g. a duplicated network delivery) is "too low", not
     in-order -- must be dropped just like any other out-of-order arrival *)
  Replica.handle_message t (Message.encode (Message.Prepare { view = 0; n = 1; v = v "a-again"; k = 0 }));
  Alcotest.(check int) "op_number unchanged by the duplicate" 1 (Replica.op_number t);
  Alcotest.(check bool) "log still holds only the first delivery's value" true (Replica.entries t = [ v "a" ]);
  Alcotest.(check bool) "no second PrepareOk sent" true (sent () = sent_after_first)

let test_prepare_wrong_view_dropped () =
  let send, sent = capturing_send () in
  let t = Replica.create ~my_id:2 ~replica_count:3 ~primary_id:1 ~send in
  let prepare = Message.encode (Message.Prepare { view = 1; n = 1; v = v "wrong-view"; k = 0 }) in
  Replica.handle_message t prepare;
  Alcotest.(check int) "op_number unchanged" 0 (Replica.op_number t);
  Alcotest.(check bool) "log unchanged" true (Replica.entries t = []);
  Alcotest.(check bool) "no reply sent" true (sent () = [])

let test_prepare_addressed_to_primary_itself_dropped () =
  (* IsNormalBackup(r) requires Primary(view) <> r -- a Prepare somehow handed to the primary's
     own handle_message must not be treated as a backup receiving it *)
  let send, sent = capturing_send () in
  let t = Replica.create ~my_id:1 ~replica_count:3 ~primary_id:1 ~send in
  let prepare = Message.encode (Message.Prepare { view = 0; n = 1; v = v "x"; k = 0 }) in
  Replica.handle_message t prepare;
  Alcotest.(check int) "op_number unchanged" 0 (Replica.op_number t);
  Alcotest.(check bool) "no reply sent" true (sent () = [])

(* ---- ReceivePrepareOkMsg + IsCommitted/PrimaryExecuteOp (VSR.tla:125-155) ---- *)

let test_primary_prepare_ok_below_quorum_does_not_commit () =
  let send, _sent = capturing_send () in
  let t = Replica.create ~my_id:1 ~replica_count:3 ~primary_id:1 ~send in
  Replica.propose t (v "only-op");
  Alcotest.(check int) "commit_number is 0 before any ack" 0 (Replica.commit_number t);
  (* 3 replicas, f = 1: a single ack from one other replica is already enough -- confirm the
     boundary the other way: with 0 acks, nothing commits *)
  Alcotest.(check bool) "not yet committed" false (Replica.is_committed t (v "only-op"))

let test_primary_prepare_ok_reaches_quorum_and_commits () =
  let send, _sent = capturing_send () in
  let t = Replica.create ~my_id:1 ~replica_count:3 ~primary_id:1 ~send in
  Replica.propose t (v "only-op");
  Replica.handle_message t (Message.encode (Message.Prepare_ok { view = 0; n = 1; i = 2 }));
  Alcotest.(check int) "commit_number advances to 1 once f=1 other replica acks" 1 (Replica.commit_number t);
  Alcotest.(check bool) "is_committed now true" true (Replica.is_committed t (v "only-op"))

let test_primary_prepare_ok_is_cumulative_high_water_mark () =
  let send, _sent = capturing_send () in
  let t = Replica.create ~my_id:1 ~replica_count:5 ~primary_id:1 ~send in
  Replica.propose t (v "a");
  Replica.propose t (v "b");
  (* peer 2 acks n=2 directly (its own high-water mark), never having separately reported n=1 to
     this primary -- PrepareOk is cumulative, so this must still count as an ack for op 1 too *)
  Replica.handle_message t (Message.encode (Message.Prepare_ok { view = 0; n = 2; i = 2 }));
  (* only 1 of the required f=2 other replicas so far -- nothing committed yet *)
  Alcotest.(check int) "commit_number still 0 with only 1 of 2 required acks" 0 (Replica.commit_number t);
  (* a LOWER, stale-looking ack from the same peer must not regress its recorded high-water mark *)
  Replica.handle_message t (Message.encode (Message.Prepare_ok { view = 0; n = 1; i = 2 }));
  Alcotest.(check int) "commit_number unaffected by the stale lower ack" 0 (Replica.commit_number t)

(* The single highest-risk scenario per this plan's own self-review: with a cluster large enough
   that a single Prepare_ok isn't already enough to satisfy quorum by itself (replica_count=5,
   f=2), construct a delivery order where the message that completes op 1's OWN quorum happens to
   carry n=2 (a different, higher op-number than the one it makes newly committed) and confirm
   commit_number advances to exactly 1 -- not straight to 2 -- until op 2's own, independent
   quorum is separately satisfied.

   What this actually discriminates (corrected after independent review, see task-1-review.md
   section 1c): because IsCommitted(n) provably implies IsCommitted(n-1) for ANY threshold
   (rep_peer_op_number is a single cumulative high-water mark per peer, so the set of peers
   satisfying ">= n" is always a subset of those satisfying ">= n-1"), an implementation that
   jumped straight to the HIGHEST quorum-satisfied op-number would be extensionally IDENTICAL to
   the incremental loop -- that specific "skip ahead" shape is not a real, distinguishable bug,
   and no test can catch it because it isn't wrong. What this test genuinely catches is the
   family of bugs that check ONLY the arriving message's own n instead of walking from
   commit_number+1: e.g. "if IsCommitted(m.n) then commit_number := m.n" would incorrectly stay
   at 0 after the second message below (m.n=2 doesn't itself have quorum yet, so it never notices
   op 1 became committed); "commit_number := m.n unconditionally" would incorrectly jump to 2.
   Only replica_count=5 (f>=2) can discriminate any of this -- at f=1 (3 replicas) a single ack
   already satisfies every op-number's quorum simultaneously, so every variant agrees. *)
let test_primary_advances_commit_number_by_exactly_one_never_skips () =
  let send, _sent = capturing_send () in
  let t = Replica.create ~my_id:1 ~replica_count:5 ~primary_id:1 ~send in
  Replica.propose t (v "op1");
  Replica.propose t (v "op2");
  Alcotest.(check int) "op_number is 2 after two proposes" 2 (Replica.op_number t);
  Alcotest.(check int) "commit_number starts at 0" 0 (Replica.commit_number t);
  (* replica 2 acks only op 1 *)
  Replica.handle_message t (Message.encode (Message.Prepare_ok { view = 0; n = 1; i = 2 }));
  Alcotest.(check int) "still 0: only 1 of 2 required acks for op 1" 0 (Replica.commit_number t);
  (* replica 3 acks up to op 2 (cumulative) -- this SAME message's contribution is what completes
     op 1's own quorum (replicas 2 and 3 both now >= 1), while op 2's quorum (needs 2 replicas
     with ack >= 2, only replica 3 qualifies) is NOT yet satisfied *)
  Replica.handle_message t (Message.encode (Message.Prepare_ok { view = 0; n = 2; i = 3 }));
  Alcotest.(check int)
    "commit_number advances to EXACTLY 1, not straight to 2, even though this message's own n=2" 1
    (Replica.commit_number t);
  Alcotest.(check bool) "op1 is committed" true (Replica.is_committed t (v "op1"));
  Alcotest.(check bool) "op2 is NOT yet committed" false (Replica.is_committed t (v "op2"));
  (* replica 2 now also acks up to op 2 -- op 2's quorum (replicas 2 and 3, both >= 2) is now met *)
  Replica.handle_message t (Message.encode (Message.Prepare_ok { view = 0; n = 2; i = 2 }));
  Alcotest.(check int) "commit_number now advances to 2" 2 (Replica.commit_number t);
  Alcotest.(check bool) "op2 is now committed too" true (Replica.is_committed t (v "op2"))

let test_prepare_ok_is_noop_on_non_primary () =
  let send, sent = capturing_send () in
  let t = Replica.create ~my_id:2 ~replica_count:3 ~primary_id:1 ~send in
  Replica.handle_message t (Message.encode (Message.Prepare_ok { view = 0; n = 1; i = 3 }));
  Alcotest.(check int) "commit_number unchanged" 0 (Replica.commit_number t);
  Alcotest.(check bool) "no messages sent" true (sent () = [])

let test_prepare_ok_wrong_view_dropped () =
  let send, _sent = capturing_send () in
  let t = Replica.create ~my_id:1 ~replica_count:3 ~primary_id:1 ~send in
  Replica.propose t (v "op1");
  Replica.handle_message t (Message.encode (Message.Prepare_ok { view = 1; n = 1; i = 2 }));
  Alcotest.(check int) "commit_number unchanged by a wrong-view PrepareOk" 0 (Replica.commit_number t)

(* ---- M1 fix-round regression tests: a PrepareOk's [i] must name a real replica
   (VSR.tla:141's own [p \in replicas] domain restriction on the set IsCommitted counts over) --
   reproduces the reviewer's own live repro from task-1-review.md's M1 finding. ---- *)

let test_prepare_ok_forged_nonexistent_replica_id_does_not_commit () =
  let send, _sent = capturing_send () in
  let t = Replica.create ~my_id:1 ~replica_count:3 ~primary_id:1 ~send in
  Replica.propose t (v "op1");
  (* replica id 42 does not exist in a 3-replica cluster (valid ids are 1..3) -- before the fix,
     a single such forged ack committed op 1 with ZERO real backup acknowledgements *)
  Replica.handle_message t (Message.encode (Message.Prepare_ok { view = 0; n = 1; i = 42 }));
  Alcotest.(check int) "a forged ack from a non-existent replica id does not commit" 0 (Replica.commit_number t);
  Alcotest.(check bool) "op1 is NOT committed" false (Replica.is_committed t (v "op1"))

let test_prepare_ok_out_of_range_id_zero_does_not_commit () =
  let send, _sent = capturing_send () in
  let t = Replica.create ~my_id:1 ~replica_count:3 ~primary_id:1 ~send in
  Replica.propose t (v "op1");
  (* 0 is out of VSR.tla's 1..replica_count range too (ids are 1-indexed) *)
  Replica.handle_message t (Message.encode (Message.Prepare_ok { view = 0; n = 1; i = 0 }));
  Alcotest.(check int) "id 0 (out of the valid 1..replica_count range) does not commit" 0 (Replica.commit_number t)

let test_prepare_ok_forged_ids_do_not_commit_in_larger_cluster () =
  let send, _sent = capturing_send () in
  let t = Replica.create ~my_id:1 ~replica_count:5 ~primary_id:1 ~send in
  Replica.propose t (v "op1");
  (* reviewer's own 5-replica repro: two forged acks (i=0, i=99), neither a real replica id *)
  Replica.handle_message t (Message.encode (Message.Prepare_ok { view = 0; n = 1; i = 0 }));
  Replica.handle_message t (Message.encode (Message.Prepare_ok { view = 0; n = 1; i = 99 }));
  Alcotest.(check int) "two forged acks from non-existent replicas still do not commit" 0 (Replica.commit_number t);
  (* a REAL replica's ack, combined with one forged one, must still need the full quorum of
     genuine acks (f=2 for a 5-replica cluster) -- one real + one forged is not enough *)
  Replica.handle_message t (Message.encode (Message.Prepare_ok { view = 0; n = 1; i = 2 }));
  Alcotest.(check int) "one real ack plus forged ones is still below the required quorum of 2" 0
    (Replica.commit_number t);
  Replica.handle_message t (Message.encode (Message.Prepare_ok { view = 0; n = 1; i = 3 }));
  Alcotest.(check int) "a second REAL ack reaches genuine quorum and commits" 1 (Replica.commit_number t)

(* ---- M2 fix-round regression tests: a Prepare's [k] must never push commit_number past
   op_number -- reproduces the reviewer's own live repro from task-1-review.md's M2 finding. ---- *)

let test_prepare_k_exceeding_op_number_is_rejected () =
  let send, _sent = capturing_send () in
  let t = Replica.create ~my_id:2 ~replica_count:3 ~primary_id:1 ~send in
  (* before the fix: Prepare{n=1; k=9999} yielded op_number=1, commit_number=9999 -- the fix
     rejects the update outright when k > op_number (rather than silently substituting op_number
     for it), so commit_number stays at its last legitimately-established value, here still 0 *)
  Replica.handle_message t (Message.encode (Message.Prepare { view = 0; n = 1; v = v "a"; k = 9999 }));
  Alcotest.(check int) "op_number advances normally" 1 (Replica.op_number t);
  Alcotest.(check int) "commit_number is NOT advanced by the out-of-bound forged k" 0 (Replica.commit_number t)

let test_prepare_k_exceeding_op_number_rejected_across_multiple_prepares () =
  let send, _sent = capturing_send () in
  let t = Replica.create ~my_id:2 ~replica_count:3 ~primary_id:1 ~send in
  Replica.handle_message t (Message.encode (Message.Prepare { view = 0; n = 1; v = v "a"; k = 0 }));
  Replica.handle_message t (Message.encode (Message.Prepare { view = 0; n = 2; v = v "b"; k = 9999 }));
  Alcotest.(check int) "op_number is 2" 2 (Replica.op_number t);
  Alcotest.(check int) "commit_number is NOT advanced by the out-of-bound forged k (9999 > op_number 2)" 0
    (Replica.commit_number t)

let test_prepare_k_within_bound_still_advances_normally () =
  (* a well-formed, genuinely higher k that stays within [0, op_number] must still be applied --
     the fix must not weaken the legitimate case *)
  let send, _sent = capturing_send () in
  let t = Replica.create ~my_id:2 ~replica_count:3 ~primary_id:1 ~send in
  Replica.handle_message t (Message.encode (Message.Prepare { view = 0; n = 1; v = v "a"; k = 0 }));
  Replica.handle_message t (Message.encode (Message.Prepare { view = 0; n = 2; v = v "b"; k = 2 }));
  Alcotest.(check int) "a valid, in-bound k still advances commit_number" 2 (Replica.commit_number t)

(* ---- L1 fix-round regression tests: create validates its numeric arguments ---- *)

let expect_invalid_arg name (f : unit -> Replica.t) =
  ( name,
    `Quick,
    fun () ->
      match f () with
      | (_ : Replica.t) -> Alcotest.failf "%s: expected Invalid_argument, but create succeeded" name
      | exception Invalid_argument _ -> ()
      | exception exn -> Alcotest.failf "%s: expected Invalid_argument, got %s" name (Printexc.to_string exn) )

let create_invalid_arg_tests =
  [
    expect_invalid_arg "replica_count = 0 is rejected" (fun () ->
        Replica.create ~my_id:1 ~replica_count:0 ~primary_id:1 ~send:(fun ~to_:_ _ -> ()));
    expect_invalid_arg "negative replica_count is rejected" (fun () ->
        Replica.create ~my_id:1 ~replica_count:(-3) ~primary_id:1 ~send:(fun ~to_:_ _ -> ()));
    expect_invalid_arg "even replica_count is rejected" (fun () ->
        Replica.create ~my_id:1 ~replica_count:4 ~primary_id:1 ~send:(fun ~to_:_ _ -> ()));
    expect_invalid_arg "my_id below 1 is rejected" (fun () ->
        Replica.create ~my_id:0 ~replica_count:3 ~primary_id:1 ~send:(fun ~to_:_ _ -> ()));
    expect_invalid_arg "my_id above replica_count is rejected" (fun () ->
        Replica.create ~my_id:4 ~replica_count:3 ~primary_id:1 ~send:(fun ~to_:_ _ -> ()));
    expect_invalid_arg "primary_id out of range is rejected" (fun () ->
        Replica.create ~my_id:1 ~replica_count:3 ~primary_id:9 ~send:(fun ~to_:_ _ -> ()));
  ]

let test_create_accepts_a_valid_single_replica_cluster () =
  (* replica_count = 1 is odd and >= 1 -- a legitimate (if degenerate) configuration, not to be
     rejected by the same validation that rejects even counts (see L2's own test below) *)
  let t = Replica.create ~my_id:1 ~replica_count:1 ~primary_id:1 ~send:(fun ~to_:_ _ -> ()) in
  Alcotest.(check bool) "is_primary" true (Replica.is_primary t)

(* ---- L2 fix-round regression test: propose must also drive PrimaryExecuteOp (the f=0 case) ---- *)

let test_propose_commits_immediately_in_single_replica_cluster () =
  let send, _sent = capturing_send () in
  let t = Replica.create ~my_id:1 ~replica_count:1 ~primary_id:1 ~send in
  Replica.propose t (v "solo");
  (* f = (1-1)/2 = 0, so IsCommitted is vacuously true for every op-number -- before the fix,
     nothing but a (nonexistent, since there are no other replicas) Prepare_ok could ever drive
     primary_execute_op, so commit_number stayed 0 forever even though VSR.tla's own Next would
     let PrimaryExecuteOp fire immediately after ReceiveClientRequest here *)
  Alcotest.(check int) "commit_number advances to 1 immediately, with zero other replicas to ack" 1
    (Replica.commit_number t);
  Alcotest.(check bool) "the proposed value is committed" true (Replica.is_committed t (v "solo"))

(* ---- handle_message robustness: malformed bytes and out-of-scope message types ---- *)

let test_handle_message_malformed_bytes_dropped () =
  let send, sent = capturing_send () in
  let t = Replica.create ~my_id:2 ~replica_count:3 ~primary_id:1 ~send in
  Replica.handle_message t "\xff\xff\xff not a valid encoding";
  Alcotest.(check int) "op_number unchanged" 0 (Replica.op_number t);
  Alcotest.(check bool) "no messages sent" true (sent () = [])

let test_handle_message_out_of_scope_types_ignored () =
  let send, sent = capturing_send () in
  let t = Replica.create ~my_id:2 ~replica_count:3 ~primary_id:1 ~send in
  List.iter
    (fun m -> Replica.handle_message t (Message.encode m))
    [
      Message.Start_view_change { v = 1; i = 3 };
      Message.Do_view_change { v = 1; log = []; last_normal_view = 0; n = 0; k = 0; i = 3 };
      Message.Start_view { v = 1; log = []; n = 0; k = 0 };
    ];
  Alcotest.(check int) "op_number unchanged" 0 (Replica.op_number t);
  Alcotest.(check int) "commit_number unchanged" 0 (Replica.commit_number t);
  Alcotest.(check bool) "no messages sent" true (sent () = [])

let tests =
  [
    ("primary propose broadcasts Prepare to every other replica", `Quick, test_primary_propose_broadcasts_prepare);
    ("propose is a no-op on a non-primary replica", `Quick, test_propose_is_noop_on_non_primary);
    ("a duplicate client value is rejected the second time", `Quick, test_propose_duplicate_value_rejected_second_time);
    ("backup: in-order Prepare appends and replies with PrepareOk", `Quick, test_backup_in_order_prepare_appends_and_replies);
    ("backup: Prepare's k field advances commit_number, monotonically", `Quick, test_backup_prepare_advances_commit_number_from_k);
    ("backup: out-of-order Prepare is silently dropped", `Quick, test_backup_out_of_order_prepare_dropped);
    ("backup: duplicate (too-low) Prepare is silently dropped", `Quick, test_backup_duplicate_prepare_dropped);
    ("backup: Prepare with a mismatched view is silently dropped", `Quick, test_prepare_wrong_view_dropped);
    ("Prepare addressed to the primary's own handle_message is dropped", `Quick, test_prepare_addressed_to_primary_itself_dropped);
    ("primary: PrepareOk below quorum does not commit", `Quick, test_primary_prepare_ok_below_quorum_does_not_commit);
    ("primary: PrepareOk reaching quorum commits", `Quick, test_primary_prepare_ok_reaches_quorum_and_commits);
    ("primary: PrepareOk high-water mark is cumulative and never regresses", `Quick, test_primary_prepare_ok_is_cumulative_high_water_mark);
    ( "primary: commit_number advances by exactly one, never skips ahead (op 2 quorum-acked before op 1)",
      `Quick,
      test_primary_advances_commit_number_by_exactly_one_never_skips );
    ("PrepareOk is a no-op on a non-primary replica", `Quick, test_prepare_ok_is_noop_on_non_primary);
    ("primary: PrepareOk with a mismatched view is silently dropped", `Quick, test_prepare_ok_wrong_view_dropped);
    (* M1 fix-round regression tests *)
    ( "M1: a forged PrepareOk from a non-existent replica id does not commit",
      `Quick,
      test_prepare_ok_forged_nonexistent_replica_id_does_not_commit );
    ("M1: PrepareOk with id 0 (out of range) does not commit", `Quick, test_prepare_ok_out_of_range_id_zero_does_not_commit);
    ( "M1: forged ids do not count toward quorum in a larger cluster (reviewer's own repro)",
      `Quick,
      test_prepare_ok_forged_ids_do_not_commit_in_larger_cluster );
    (* M2 fix-round regression tests *)
    ("M2: Prepare with k exceeding op_number is rejected, not applied verbatim", `Quick, test_prepare_k_exceeding_op_number_is_rejected);
    ( "M2: an out-of-bound k is rejected across multiple Prepares too",
      `Quick,
      test_prepare_k_exceeding_op_number_rejected_across_multiple_prepares );
    ("M2: a valid, in-bound k still advances commit_number normally", `Quick, test_prepare_k_within_bound_still_advances_normally);
    (* L1 fix-round regression tests *)
    ("L1: create accepts a valid, degenerate single-replica cluster", `Quick, test_create_accepts_a_valid_single_replica_cluster);
    (* L2 fix-round regression test *)
    ( "L2: propose alone commits immediately in a single-replica (f=0) cluster",
      `Quick,
      test_propose_commits_immediately_in_single_replica_cluster );
    ("handle_message: malformed bytes are silently dropped, never raise", `Quick, test_handle_message_malformed_bytes_dropped);
    ("handle_message: out-of-scope message types are silently ignored", `Quick, test_handle_message_out_of_scope_types_ignored);
  ]
  @ create_invalid_arg_tests
