(* test/test_vsr_replica.ml -- single-replica-in-isolation tests: handle_message/propose called
   directly with hand-constructed encoded messages, no real transport, no second replica. Real
   multi-replica message exchange over Sim_transport is Task 2's own test file
   (test_vsr_replica_cluster.ml), not this one.

   NOTE on the [Replica.create] signature and [Replica.for_test_set_view_number]: an earlier plan
   built this module against a fixed, configured [primary_id]. The VSR view-change plan's Task 1
   removed that field entirely -- which replica id is primary is now always [Primary(view_number)]
   (VSR.tla:18), a pure function of [view_number], never stored. Since [create] leaves a fresh
   replica at [view_number = 0] (VSR.tla's own [Init]), and [Primary(0) = replica_count] (NOT 1 --
   see replica.mli's own note on Euclidean vs. truncating modulo), most tests below call
   [Replica.for_test_set_view_number t 1] right after [create] to put replica id 1 back in the
   primary role this suite has always conventionally used -- [Primary(1) = 1] holds for ANY
   replica_count, so this is a stable convention, not a per-cluster-size coincidence. Tests that
   deliberately want a VIEW MISMATCH (test_prepare_wrong_view_dropped) or that only need
   [is_primary] to be unconditionally false (test_prepare_ok_is_noop_on_non_primary, which is
   already true at the default view_number = 0 for any my_id <> replica_count) skip that call, with
   a comment explaining why.

   NOTE on Task 2's own additions (check_timeout / handle_message's Start_view_change dispatch /
   the internal SendDVC drive): see the "---- check_timeout ----" and "---- Start_view_change
   dispatch ----" sections near the end of this file. Tests there that need a replica ALREADY in
   [View_change] status use [Replica.for_test_set_view] (NOT [Replica.for_test_set_view_number],
   which is correct only for [status = Normal] -- see that function's own doc comment in
   replica.mli) only where doing so is strictly simpler than driving the transition via a real
   [check_timeout]/[handle_message] call; several of the tests below deliberately drive real
   transitions instead, specifically to double as coverage of check_timeout/ReceiveHigherSVC/
   ReceiveMatchingSVC themselves rather than assuming them. *)
open Riptide
open Riptide_vsr

let v s = Value.Scalar (Value.String s)

(* Captures every [~to_, bytes] pair a replica's [send] closure is given, in call order. *)
let capturing_send () =
  let sent = ref [] in
  let send ~to_ bytes = sent := (to_, bytes) :: !sent in
  (send, fun () -> List.rev !sent)

let decoded_sent sent_fn = List.map (fun (to_, bytes) -> (to_, Message.decode bytes)) (sent_fn ())

(* Creates a replica and immediately pins it to view_number 1 -- see this file's own top-level
   note for why: [Primary(1) = 1] for any replica_count, so this is the standard way this suite
   puts replica id 1 in the primary role. *)
let create_at_view_1 ~my_id ~replica_count ~send =
  let t = Replica.create ~my_id ~replica_count ~svc_limit:3 ~send in
  Replica.for_test_set_view_number t 1;
  t

(* ---- Primary(v) (VSR.tla:18) and view_number/last_normal_view (fix-round findings M2, M3) ----

   Neither `Replica.primary` nor `Replica.view_number` had any direct test before this fix round
   (task-1-review.md's M2 finding): every OTHER test in this file only ever exercises view 1 (via
   create_at_view_1, where Primary(1) = 1 for every replica_count) or view 0 at replica_count = 1
   (where Primary is 1 for every v) -- neither exercises the negative-dividend branch the
   Euclidean-modulo normalization in replica.ml exists for. Concretely, the reviewer confirmed by
   mutation that BOTH the naive, un-normalized formula (which gives the wrong Primary(0) = 0, an
   id outside [1, replica_count]) AND a fully gutted `primary` function pass the full suite without
   these tests. *)

let test_primary_formula_matches_tlc () =
  let primary_of ~replica_count ~view_number =
    let t = Replica.create ~my_id:1 ~replica_count ~svc_limit:3 ~send:(fun ~to_:_ _ -> ()) in
    Replica.for_test_set_view_number t view_number;
    Replica.primary t
  in
  (* TLC 2.19 against VSR.tla:18's own formula at ReplicaCount = 3 -- this session's own
     independently re-verified table (both in the original task-1 report and again by the
     reviewer): Primary(0..4) = 3, 1, 2, 3, 1. The v=0 case is the trap this whole test exists to
     pin: Primary(0) = replica_count = 3, NEITHER 0 (the naive un-normalized-modulo bug) NOR 1
     (the "view 0 means replica 1" assumption replica.mli explicitly warns against). *)
  List.iter2
    (fun view_number expected ->
      Alcotest.(check int)
        (Printf.sprintf "Primary(%d) at replica_count=3 matches TLC" view_number)
        expected
        (primary_of ~replica_count:3 ~view_number))
    [ 0; 1; 2; 3; 4 ] [ 3; 1; 2; 3; 1 ];
  (* A second replica_count generalizes the check beyond n=3 specifically -- TLC's own periodicity
     (Primary(v) = Primary(v + replica_count)) at n=5: Primary(0..5) = 5, 1, 2, 3, 4, 5. *)
  List.iter2
    (fun view_number expected ->
      Alcotest.(check int)
        (Printf.sprintf "Primary(%d) at replica_count=5 matches TLC" view_number)
        expected
        (primary_of ~replica_count:5 ~view_number))
    [ 0; 1; 2; 3; 4; 5 ] [ 5; 1; 2; 3; 4; 5 ];
  (* The trap named explicitly: view 0's primary is replica_count, never 0 (the un-normalized-
     modulo bug) and never 1 (the "view 0 means replica 1" assumption). *)
  Alcotest.(check int) "Primary(0) = replica_count, not 0 or 1"
    3
    (primary_of ~replica_count:3 ~view_number:0)

let test_is_primary_agrees_with_primary_formula () =
  (* is_primary t is documented as exactly [t.my_id = primary t] -- confirm both the true and
     false case at a view where the "natural" (view 0) primary is NOT replica 1. *)
  let t3 = Replica.create ~my_id:3 ~replica_count:3 ~svc_limit:3 ~send:(fun ~to_:_ _ -> ()) in
  Alcotest.(check bool) "replica 3 is primary at the default view_number=0 (Primary(0)=3)" true (Replica.is_primary t3);
  let t1 = Replica.create ~my_id:1 ~replica_count:3 ~svc_limit:3 ~send:(fun ~to_:_ _ -> ()) in
  Alcotest.(check bool) "replica 1 is NOT primary at the default view_number=0" false (Replica.is_primary t1)

let test_view_number_round_trips_for_test_set_view_number () =
  let t = Replica.create ~my_id:1 ~replica_count:3 ~svc_limit:3 ~send:(fun ~to_:_ _ -> ()) in
  Alcotest.(check int) "view_number starts at 0 (VSR.tla's own Init)" 0 (Replica.view_number t);
  Replica.for_test_set_view_number t 7;
  Alcotest.(check int) "view_number round-trips for_test_set_view_number" 7 (Replica.view_number t)

(* ---- M3 fix-round regression test: for_test_set_view_number must keep last_normal_view in sync
   ----

   Before the fix, for_test_set_view_number only moved view_number, leaving last_normal_view
   behind at its Init value of 0. The reviewer proved by a fresh TLC run (264,376 distinct
   reachable states, `NormalImpliesLastNormalViewMatches` added as an invariant, no error found)
   that [status = "Normal" => last_normal_view = view_number] is a genuine invariant of
   spec/tla/VSR.tla -- so the old helper silently built every calling test (both in this file and
   in test_vsr_replica_cluster.ml) on top of a protocol-UNREACHABLE state. Harmless today (nothing
   in this plan's scope reads last_normal_view yet), but load-bearing the moment Task 2/3's
   WinningDVC (VSR.tla:248-255) starts selecting the surviving log by last_normal_view first. This
   test pins the invariant directly against the helper's own output, and would fail against the
   old (pre-fix) version of for_test_set_view_number, which left last_normal_view at 0 here
   instead of advancing it to 5. *)
let test_for_test_set_view_number_keeps_last_normal_view_in_sync () =
  let t = Replica.create ~my_id:1 ~replica_count:3 ~svc_limit:3 ~send:(fun ~to_:_ _ -> ()) in
  Alcotest.(check int) "last_normal_view starts at 0 (VSR.tla's own Init)" 0 (Replica.last_normal_view t);
  Replica.for_test_set_view_number t 5;
  Alcotest.(check int) "view_number advances to 5" 5 (Replica.view_number t);
  Alcotest.(check int)
    "last_normal_view advances IN LOCKSTEP with view_number -- the spec's own \
     NormalImpliesLastNormalViewMatches invariant, status=Normal here, requires last_normal_view = \
     view_number, not the stale 0 an earlier version of this helper left behind"
    5 (Replica.last_normal_view t);
  (* Called again at a different value -- confirms this isn't a one-shot initialization quirk. *)
  Replica.for_test_set_view_number t 12;
  Alcotest.(check int) "last_normal_view tracks a SECOND call too" 12 (Replica.last_normal_view t)

(* ---- propose (ReceiveClientRequest, VSR.tla:91-102) ---- *)

let test_primary_propose_broadcasts_prepare () =
  let send, sent = capturing_send () in
  let t = create_at_view_1 ~my_id:1 ~replica_count:3 ~send in
  Replica.propose t (v "hello");
  Alcotest.(check int) "op_number advances to 1" 1 (Replica.op_number t);
  Alcotest.(check int) "commit_number unchanged by propose alone" 0 (Replica.commit_number t);
  Alcotest.(check bool) "entries now contains the proposed value" true (Replica.entries t = [ v "hello" ]);
  (* every OTHER replica (2, 3) gets a Prepare{view=1; n=1; v; k=0}, primary (1) does not *)
  Alcotest.(check bool) "broadcasts Prepare to both other replicas, not itself" true
    (decoded_sent sent
    = [ (2, Message.Prepare { view = 1; n = 1; v = v "hello"; k = 0 });
        (3, Message.Prepare { view = 1; n = 1; v = v "hello"; k = 0 }) ])

let test_propose_is_noop_on_non_primary () =
  let send, sent = capturing_send () in
  let t = create_at_view_1 ~my_id:2 ~replica_count:3 ~send in
  Alcotest.(check bool) "is_primary is false for a backup" false (Replica.is_primary t);
  Replica.propose t (v "should-not-be-accepted");
  Alcotest.(check int) "op_number unchanged" 0 (Replica.op_number t);
  Alcotest.(check bool) "entries unchanged" true (Replica.entries t = []);
  Alcotest.(check bool) "no message sent" true (sent () = [])

let test_propose_duplicate_value_rejected_second_time () =
  let send, sent = capturing_send () in
  let t = create_at_view_1 ~my_id:1 ~replica_count:3 ~send in
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
  let t = create_at_view_1 ~my_id:2 ~replica_count:3 ~send in
  let prepare = Message.encode (Message.Prepare { view = 1; n = 1; v = v "x"; k = 0 }) in
  Replica.handle_message t prepare;
  Alcotest.(check int) "op_number advances to 1" 1 (Replica.op_number t);
  Alcotest.(check bool) "entries contains the prepared value" true (Replica.entries t = [ v "x" ]);
  Alcotest.(check int) "commit_number stays 0 (k=0 in this Prepare)" 0 (Replica.commit_number t);
  Alcotest.(check bool) "replies with the right PrepareOk, to the primary" true
    (decoded_sent sent = [ (1, Message.Prepare_ok { view = 1; n = 1; i = 2 }) ])

let test_backup_prepare_advances_commit_number_from_k () =
  let send, _sent = capturing_send () in
  let t = create_at_view_1 ~my_id:2 ~replica_count:3 ~send in
  (* op 1 in-order, k=0 *)
  Replica.handle_message t (Message.encode (Message.Prepare { view = 1; n = 1; v = v "a"; k = 0 }));
  (* op 2 in-order, carrying k=1 (the primary's own commit_number from before op 2 was appended) *)
  Replica.handle_message t (Message.encode (Message.Prepare { view = 1; n = 2; v = v "b"; k = 1 }));
  Alcotest.(check int) "commit_number advances to the Prepare's own k" 1 (Replica.commit_number t);
  (* a later Prepare carrying a LOWER k must never regress commit_number *)
  Replica.handle_message t (Message.encode (Message.Prepare { view = 1; n = 3; v = v "c"; k = 0 }));
  Alcotest.(check int) "commit_number never regresses" 1 (Replica.commit_number t)

let test_backup_out_of_order_prepare_dropped () =
  let send, sent = capturing_send () in
  let t = create_at_view_1 ~my_id:2 ~replica_count:3 ~send in
  (* op_number is 0; a Prepare for n=2 (a gap) must not be matched by ReceivePrepareMsg at all *)
  let prepare = Message.encode (Message.Prepare { view = 1; n = 2; v = v "skip"; k = 0 }) in
  Replica.handle_message t prepare;
  Alcotest.(check int) "op_number unchanged" 0 (Replica.op_number t);
  Alcotest.(check bool) "log unchanged" true (Replica.entries t = []);
  Alcotest.(check int) "commit_number unchanged" 0 (Replica.commit_number t);
  Alcotest.(check bool) "no PrepareOk sent" true (sent () = [])

let test_backup_duplicate_prepare_dropped () =
  let send, sent = capturing_send () in
  let t = create_at_view_1 ~my_id:2 ~replica_count:3 ~send in
  Replica.handle_message t (Message.encode (Message.Prepare { view = 1; n = 1; v = v "a"; k = 0 }));
  let sent_after_first = sent () in
  (* the same op_number 1 arriving again (e.g. a duplicated network delivery) is "too low", not
     in-order -- must be dropped just like any other out-of-order arrival *)
  Replica.handle_message t (Message.encode (Message.Prepare { view = 1; n = 1; v = v "a-again"; k = 0 }));
  Alcotest.(check int) "op_number unchanged by the duplicate" 1 (Replica.op_number t);
  Alcotest.(check bool) "log still holds only the first delivery's value" true (Replica.entries t = [ v "a" ]);
  Alcotest.(check bool) "no second PrepareOk sent" true (sent () = sent_after_first)

let test_prepare_wrong_view_dropped () =
  (* Deliberately does NOT call [for_test_set_view_number]: [t] stays at its Init view_number (0),
     and the incoming Prepare carries view=1, a genuine mismatch -- exactly what this test needs to
     exercise the [m.view = View(r)] guard, independent of which replica happens to be primary. *)
  let send, sent = capturing_send () in
  let t = Replica.create ~my_id:2 ~replica_count:3 ~svc_limit:3 ~send in
  let prepare = Message.encode (Message.Prepare { view = 1; n = 1; v = v "wrong-view"; k = 0 }) in
  Replica.handle_message t prepare;
  Alcotest.(check int) "op_number unchanged" 0 (Replica.op_number t);
  Alcotest.(check bool) "log unchanged" true (Replica.entries t = []);
  Alcotest.(check bool) "no reply sent" true (sent () = [])

let test_prepare_addressed_to_primary_itself_dropped () =
  (* IsNormalBackup(r) requires Primary(View(r)) <> r -- a Prepare somehow handed to the primary's
     own handle_message must not be treated as a backup receiving it.

     Fix-round finding M1 (task-1-review.md): this message's [view] MUST match t's real
     view_number (1, from create_at_view_1) -- NOT be left at a mismatched 0 as an earlier version
     of this test did. With a mismatched view, disabling the is_primary guard entirely still left
     the test passing (op_number unchanged, no reply sent), because the SEPARATE view guard
     rejects the message for an unrelated reason and masks the role guard from ever being
     exercised -- the reviewer proved this by mutation (disabling is_primary at the pre-fix parent
     commit failed the suite; the same mutation at this test's own prior version passed). With the
     view matching, a disabled is_primary guard would fall through to accept this as a normal
     backup Prepare (appending to the log and sending a Prepare_ok reply), so this version's
     assertions genuinely fail if that guard is disabled -- confirmed via mutation testing
     (disabling is_primary here makes this test fail; re-enabling it passes again), not just
     asserted. *)
  let send, sent = capturing_send () in
  let t = create_at_view_1 ~my_id:1 ~replica_count:3 ~send in
  let prepare = Message.encode (Message.Prepare { view = 1; n = 1; v = v "x"; k = 0 }) in
  Replica.handle_message t prepare;
  Alcotest.(check int) "op_number unchanged" 0 (Replica.op_number t);
  Alcotest.(check bool) "no reply sent" true (sent () = [])

(* ---- ReceivePrepareOkMsg + IsCommitted/PrimaryExecuteOp (VSR.tla:125-155) ---- *)

let test_primary_prepare_ok_below_quorum_does_not_commit () =
  let send, _sent = capturing_send () in
  let t = create_at_view_1 ~my_id:1 ~replica_count:3 ~send in
  Replica.propose t (v "only-op");
  Alcotest.(check int) "commit_number is 0 before any ack" 0 (Replica.commit_number t);
  (* 3 replicas, f = 1: a single ack from one other replica is already enough -- confirm the
     boundary the other way: with 0 acks, nothing commits *)
  Alcotest.(check bool) "not yet committed" false (Replica.is_committed t (v "only-op"))

let test_primary_prepare_ok_reaches_quorum_and_commits () =
  let send, _sent = capturing_send () in
  let t = create_at_view_1 ~my_id:1 ~replica_count:3 ~send in
  Replica.propose t (v "only-op");
  Replica.handle_message t (Message.encode (Message.Prepare_ok { view = 1; n = 1; i = 2 }));
  Alcotest.(check int) "commit_number advances to 1 once f=1 other replica acks" 1 (Replica.commit_number t);
  Alcotest.(check bool) "is_committed now true" true (Replica.is_committed t (v "only-op"))

let test_primary_prepare_ok_is_cumulative_high_water_mark () =
  let send, _sent = capturing_send () in
  let t = create_at_view_1 ~my_id:1 ~replica_count:5 ~send in
  Replica.propose t (v "a");
  Replica.propose t (v "b");
  (* peer 2 acks n=2 directly (its own high-water mark), never having separately reported n=1 to
     this primary -- PrepareOk is cumulative, so this must still count as an ack for op 1 too *)
  Replica.handle_message t (Message.encode (Message.Prepare_ok { view = 1; n = 2; i = 2 }));
  (* only 1 of the required f=2 other replicas so far -- nothing committed yet *)
  Alcotest.(check int) "commit_number still 0 with only 1 of 2 required acks" 0 (Replica.commit_number t);
  (* a LOWER, stale-looking ack from the same peer must not regress its recorded high-water mark *)
  Replica.handle_message t (Message.encode (Message.Prepare_ok { view = 1; n = 1; i = 2 }));
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
  let t = create_at_view_1 ~my_id:1 ~replica_count:5 ~send in
  Replica.propose t (v "op1");
  Replica.propose t (v "op2");
  Alcotest.(check int) "op_number is 2 after two proposes" 2 (Replica.op_number t);
  Alcotest.(check int) "commit_number starts at 0" 0 (Replica.commit_number t);
  (* replica 2 acks only op 1 *)
  Replica.handle_message t (Message.encode (Message.Prepare_ok { view = 1; n = 1; i = 2 }));
  Alcotest.(check int) "still 0: only 1 of 2 required acks for op 1" 0 (Replica.commit_number t);
  (* replica 3 acks up to op 2 (cumulative) -- this SAME message's contribution is what completes
     op 1's own quorum (replicas 2 and 3 both now >= 1), while op 2's quorum (needs 2 replicas
     with ack >= 2, only replica 3 qualifies) is NOT yet satisfied *)
  Replica.handle_message t (Message.encode (Message.Prepare_ok { view = 1; n = 2; i = 3 }));
  Alcotest.(check int)
    "commit_number advances to EXACTLY 1, not straight to 2, even though this message's own n=2" 1
    (Replica.commit_number t);
  Alcotest.(check bool) "op1 is committed" true (Replica.is_committed t (v "op1"));
  Alcotest.(check bool) "op2 is NOT yet committed" false (Replica.is_committed t (v "op2"));
  (* replica 2 now also acks up to op 2 -- op 2's quorum (replicas 2 and 3, both >= 2) is now met *)
  Replica.handle_message t (Message.encode (Message.Prepare_ok { view = 1; n = 2; i = 2 }));
  Alcotest.(check int) "commit_number now advances to 2" 2 (Replica.commit_number t);
  Alcotest.(check bool) "op2 is now committed too" true (Replica.is_committed t (v "op2"))

let test_prepare_ok_is_noop_on_non_primary () =
  (* Deliberately does NOT call [for_test_set_view_number]: at the default view_number (0), a
     3-replica cluster's primary is Primary(0) = 3 (NOT 1 -- see replica.mli's own note), so
     my_id=2 is already, unconditionally, not the primary -- exactly what this test needs, with no
     view manipulation required. is_primary is checked before the view check in
     handle_prepare_ok, so this message's own [view] field (left at 0) never even gets read. *)
  let send, sent = capturing_send () in
  let t = Replica.create ~my_id:2 ~replica_count:3 ~svc_limit:3 ~send in
  Replica.handle_message t (Message.encode (Message.Prepare_ok { view = 0; n = 1; i = 3 }));
  Alcotest.(check int) "commit_number unchanged" 0 (Replica.commit_number t);
  Alcotest.(check bool) "no messages sent" true (sent () = [])

let test_prepare_ok_wrong_view_dropped () =
  let send, _sent = capturing_send () in
  let t = create_at_view_1 ~my_id:1 ~replica_count:3 ~send in
  Replica.propose t (v "op1");
  (* t's real view_number is 1 (set by create_at_view_1) -- view=2 is a genuine mismatch, chosen
     specifically so this test isolates the view guard from the is_primary guard (both must be
     satisfied to reach the view check; view=1 here would no longer be "wrong" since that's t's
     actual current view). *)
  Replica.handle_message t (Message.encode (Message.Prepare_ok { view = 2; n = 1; i = 2 }));
  Alcotest.(check int) "commit_number unchanged by a wrong-view PrepareOk" 0 (Replica.commit_number t)

(* ---- M1 fix-round regression tests: a PrepareOk's [i] must name a real replica
   (VSR.tla:141's own [p \in replicas] domain restriction on the set IsCommitted counts over) --
   reproduces the reviewer's own live repro from task-1-review.md's M1 finding. ---- *)

let test_prepare_ok_forged_nonexistent_replica_id_does_not_commit () =
  let send, _sent = capturing_send () in
  let t = create_at_view_1 ~my_id:1 ~replica_count:3 ~send in
  Replica.propose t (v "op1");
  (* replica id 42 does not exist in a 3-replica cluster (valid ids are 1..3) -- before the fix,
     a single such forged ack committed op 1 with ZERO real backup acknowledgements *)
  Replica.handle_message t (Message.encode (Message.Prepare_ok { view = 1; n = 1; i = 42 }));
  Alcotest.(check int) "a forged ack from a non-existent replica id does not commit" 0 (Replica.commit_number t);
  Alcotest.(check bool) "op1 is NOT committed" false (Replica.is_committed t (v "op1"))

let test_prepare_ok_out_of_range_id_zero_does_not_commit () =
  let send, _sent = capturing_send () in
  let t = create_at_view_1 ~my_id:1 ~replica_count:3 ~send in
  Replica.propose t (v "op1");
  (* 0 is out of VSR.tla's 1..replica_count range too (ids are 1-indexed) *)
  Replica.handle_message t (Message.encode (Message.Prepare_ok { view = 1; n = 1; i = 0 }));
  Alcotest.(check int) "id 0 (out of the valid 1..replica_count range) does not commit" 0 (Replica.commit_number t)

let test_prepare_ok_forged_ids_do_not_commit_in_larger_cluster () =
  let send, _sent = capturing_send () in
  let t = create_at_view_1 ~my_id:1 ~replica_count:5 ~send in
  Replica.propose t (v "op1");
  (* reviewer's own 5-replica repro: two forged acks (i=0, i=99), neither a real replica id *)
  Replica.handle_message t (Message.encode (Message.Prepare_ok { view = 1; n = 1; i = 0 }));
  Replica.handle_message t (Message.encode (Message.Prepare_ok { view = 1; n = 1; i = 99 }));
  Alcotest.(check int) "two forged acks from non-existent replicas still do not commit" 0 (Replica.commit_number t);
  (* a REAL replica's ack, combined with one forged one, must still need the full quorum of
     genuine acks (f=2 for a 5-replica cluster) -- one real + one forged is not enough *)
  Replica.handle_message t (Message.encode (Message.Prepare_ok { view = 1; n = 1; i = 2 }));
  Alcotest.(check int) "one real ack plus forged ones is still below the required quorum of 2" 0
    (Replica.commit_number t);
  Replica.handle_message t (Message.encode (Message.Prepare_ok { view = 1; n = 1; i = 3 }));
  Alcotest.(check int) "a second REAL ack reaches genuine quorum and commits" 1 (Replica.commit_number t)

(* ---- M2 fix-round regression tests: a Prepare's [k] must never push commit_number past
   op_number -- reproduces the reviewer's own live repro from task-1-review.md's M2 finding. ---- *)

let test_prepare_k_exceeding_op_number_is_rejected () =
  let send, _sent = capturing_send () in
  let t = create_at_view_1 ~my_id:2 ~replica_count:3 ~send in
  (* before the fix: Prepare{n=1; k=9999} yielded op_number=1, commit_number=9999 -- the fix
     rejects the update outright when k > op_number (rather than silently substituting op_number
     for it), so commit_number stays at its last legitimately-established value, here still 0 *)
  Replica.handle_message t (Message.encode (Message.Prepare { view = 1; n = 1; v = v "a"; k = 9999 }));
  Alcotest.(check int) "op_number advances normally" 1 (Replica.op_number t);
  Alcotest.(check int) "commit_number is NOT advanced by the out-of-bound forged k" 0 (Replica.commit_number t)

let test_prepare_k_exceeding_op_number_rejected_across_multiple_prepares () =
  let send, _sent = capturing_send () in
  let t = create_at_view_1 ~my_id:2 ~replica_count:3 ~send in
  Replica.handle_message t (Message.encode (Message.Prepare { view = 1; n = 1; v = v "a"; k = 0 }));
  Replica.handle_message t (Message.encode (Message.Prepare { view = 1; n = 2; v = v "b"; k = 9999 }));
  Alcotest.(check int) "op_number is 2" 2 (Replica.op_number t);
  Alcotest.(check int) "commit_number is NOT advanced by the out-of-bound forged k (9999 > op_number 2)" 0
    (Replica.commit_number t)

let test_prepare_k_within_bound_still_advances_normally () =
  (* a genuinely WELL-FORMED, higher k must still be applied -- the fix must not weaken the
     legitimate case. Well-formed per VSR.tla:106-109's own comment means k < n strictly (the
     primary's commit-number from strictly BEFORE the request carried by this same message was
     appended), not merely k <= op_number -- the implementation's own bound (k <= op_number t,
     i.e. k <= n once this Prepare's append has advanced op_number to n) is intentionally a
     little wider than that, as a defense-in-depth margin against off-by-one edge cases, not
     because k = n is itself a message any correct primary would ever actually send. *)
  let send, _sent = capturing_send () in
  let t = create_at_view_1 ~my_id:2 ~replica_count:3 ~send in
  Replica.handle_message t (Message.encode (Message.Prepare { view = 1; n = 1; v = v "a"; k = 0 }));
  Replica.handle_message t (Message.encode (Message.Prepare { view = 1; n = 2; v = v "b"; k = 1 }));
  Alcotest.(check int) "a valid, in-bound k still advances commit_number" 1 (Replica.commit_number t)

(* ---- M3 fix: a forged Prepare_ok.n from a REAL replica id permanently pre-acks future ops ---- *)

let test_prepare_ok_forged_n_from_real_replica_does_not_preack_future_ops () =
  let send, _sent = capturing_send () in
  let t = create_at_view_1 ~my_id:1 ~replica_count:3 ~send in
  (* Before the fix: a single forged ack, from a REAL replica id, claiming to have acked an
     op-number this primary has never proposed, permanently inflated that peer's recorded
     high-water mark -- so once op_number genuinely caught up, the primary would "commit" future
     ops with only ONE further real ack instead of the two needed for majority in a 3-replica
     cluster (f=1). *)
  Replica.handle_message t (Message.encode (Message.Prepare_ok { view = 1; n = 1_000_000; i = 2 }));
  Replica.propose t (v "op1");
  Alcotest.(check int) "the forged, out-of-range ack does not commit op1 by itself" 0 (Replica.commit_number t);
  Alcotest.(check bool) "op1 is NOT committed" false (Replica.is_committed t (v "op1"))

(* ---- I2 boundary pins: the exact first-REJECTED and last-ACCEPTED value of each of the three
   safety guards (replica.ml's [i < 1 || i > t.replica_count], [k <= op_number t], and
   [n > op_number t]).

   Why these are separate from the M1/M2/M3 regression tests above: every one of those uses an
   obviously-forged value (i = 42, i = 99, k = 9999, n = 1_000_000), and a guard loosened by
   exactly one token still rejects all of them. They therefore pin that each guard EXISTS, not
   WHERE it sits. The final whole-branch review demonstrated this concretely: loosening any single
   guard by one ([i > replica_count + 1], [k <= op_number t + 1], [n > op_number t + 1]) left the
   entire 137-test suite green while fully reopening the original vulnerability it was added for.
   Each test below therefore asserts BOTH directions -- the first illegal value is still rejected
   (so the guard cannot be silently widened) AND the last legal value is still accepted (so it
   cannot be over-tightened into rejecting legitimate traffic either). ---- *)

let test_prepare_ok_i_boundary_is_exactly_replica_count () =
  let send, _sent = capturing_send () in
  let t = create_at_view_1 ~my_id:1 ~replica_count:3 ~send in
  Replica.propose t (v "op1");
  (* i = replica_count + 1 = 4 is the FIRST id past VSR.tla:15's own [replicas == 1..ReplicaCount]
     range -- the exact value [i > t.replica_count] must still reject. Loosened to
     [i > t.replica_count + 1], this single forged ack commits op 1 in a 3-replica cluster
     (f = 1) with zero real backup acknowledgements. *)
  Replica.handle_message t (Message.encode (Message.Prepare_ok { view = 1; n = 1; i = 4 }));
  Alcotest.(check int) "i = replica_count + 1 (the first out-of-range id) does not commit" 0 (Replica.commit_number t);
  Alcotest.(check bool) "op1 is NOT committed by a boundary-adjacent forged id" false (Replica.is_committed t (v "op1"));
  (* The last IN-range id, i = replica_count = 3, must still be accepted: the guard must not be
     over-tightened to [i >= t.replica_count] either. This is a real backup in this cluster, so
     its ack alone reaches the f = 1 quorum. *)
  Replica.handle_message t (Message.encode (Message.Prepare_ok { view = 1; n = 1; i = 3 }));
  Alcotest.(check int) "i = replica_count (the last legal id) is accepted and reaches quorum" 1 (Replica.commit_number t);
  Alcotest.(check bool) "op1 is committed by the genuine boundary-valued ack" true (Replica.is_committed t (v "op1"))

let test_prepare_k_boundary_is_exactly_op_number () =
  let send, _sent = capturing_send () in
  let t = create_at_view_1 ~my_id:2 ~replica_count:3 ~send in
  (* k = 2 on a Prepare with n = 1: after the append, op_number = 1, so this is exactly
     [op_number t + 1] -- the FIRST value [k <= op_number t] must reject. Loosened to
     [k <= op_number t + 1] it is applied, yielding commit_number = 2 > op_number = 1: a direct
     violation of CommitNumberNeverHigherThanOpNumber (VSR.tla:330-331), which replica.mli's own
     [commit_number] doc comment claims holds for EVERY reachable state, adversarial input
     included. *)
  Replica.handle_message t (Message.encode (Message.Prepare { view = 1; n = 1; v = v "a"; k = 2 }));
  Alcotest.(check int) "the Prepare itself is still accepted -- only the k field's effect is dropped" 1
    (Replica.op_number t);
  Alcotest.(check int) "k = op_number + 1 (the first out-of-bound k) is rejected" 0 (Replica.commit_number t);
  Alcotest.(check bool) "commit_number <= op_number still holds" true (Replica.commit_number t <= Replica.op_number t);
  (* The last ACCEPTED value is k = n (== op_number t after this Prepare's own append), NOT
     k = n - 1: the implemented bound is deliberately ONE STEP WIDER than VSR.tla:106-109's own
     [m.k < m.n] precondition (see replica.ml's comment at the bound, and
     test_prepare_k_within_bound_still_advances_normally above for the genuinely well-formed
     k = n - 1 case). k = n is accepted here even though no correct primary ever sends it --
     pinned so the widening stays a visible, deliberate choice rather than drift.
     NOTE for a future plan: if the bound is tightened to [k < op_number t] (the review's
     recommended direction, once view-change makes a backup's commit_number load-bearing via
     DoViewChange.k / HighestCommitNumber, VSR.tla:257-260), THIS expectation is the one to
     update -- it pins a deliberate margin, not a safety property. The k = n + 1 assertion above
     is the safety one and must never be loosened. *)
  Replica.handle_message t (Message.encode (Message.Prepare { view = 1; n = 2; v = v "b"; k = 2 }));
  Alcotest.(check int) "k = op_number (the deliberately widened, still-accepted boundary) advances commit_number" 2
    (Replica.commit_number t);
  Alcotest.(check bool) "commit_number <= op_number still holds at the widened boundary too" true
    (Replica.commit_number t <= Replica.op_number t)

let test_prepare_ok_n_boundary_is_exactly_op_number () =
  let send, _sent = capturing_send () in
  let t = create_at_view_1 ~my_id:1 ~replica_count:3 ~send in
  Alcotest.(check int) "op_number is 0 before anything is proposed" 0 (Replica.op_number t);
  (* With op_number = 0, n = 1 is exactly [op_number t + 1] -- the FIRST value [n > op_number t]
     must reject. Loosened to [n > op_number t + 1] it is recorded, pre-acking an op that does not
     exist yet; the very next propose then commits with zero genuine acks. *)
  Replica.handle_message t (Message.encode (Message.Prepare_ok { view = 1; n = 1; i = 2 }));
  Replica.propose t (v "op1");
  Alcotest.(check int) "n = op_number + 1 (pre-acking the next op) does not commit it" 0 (Replica.commit_number t);
  Alcotest.(check bool) "op1 is NOT committed by the boundary-adjacent forged ack" false (Replica.is_committed t (v "op1"));
  (* The last ACCEPTED value, n = op_number t exactly, must still count -- a genuine ack for the
     op this primary really has assigned is the single most common message in the protocol and
     must not be rejected by the same guard. *)
  Replica.handle_message t (Message.encode (Message.Prepare_ok { view = 1; n = 1; i = 2 }));
  Alcotest.(check int) "n = op_number (a genuine ack for the current op) is accepted and commits" 1
    (Replica.commit_number t);
  Alcotest.(check bool) "op1 is committed by the genuine boundary-valued ack" true (Replica.is_committed t (v "op1"))

(* ---- L1 fix-round regression tests: create validates its numeric arguments ----

   NOTE: the "primary_id out of range is rejected" case from the earlier, fixed-primary plan is
   GONE, not weakened -- [create] no longer takes a [primary_id] parameter at all (Task 1 of the
   view-change plan removed it; which replica is primary is now always computed via [Primary],
   never configured), so there is no longer any argument for that validation to apply to. This is
   a real removal of a test whose own precondition no longer exists, not a loosening of a
   surviving guard -- every other L1 case below (replica_count parity/positivity, my_id range)
   still applies unchanged and is still pinned.

   Fix-round finding L2 (task-1-review.md): [svc_limit] -- the parameter that structurally
   REPLACED [primary_id] in [create]'s signature -- was left completely unvalidated by the
   original Task 1 commit, even though [create] validates every one of its other numeric
   parameters. A non-positive [svc_limit] would silently and permanently disable [TimerSendSVC]
   once Task 2 implements it (VSR.tla:163's own guard, [aux_svc_count[r] < StartViewOnTimerLimit],
   is unsatisfiable at a non-positive limit since [aux_svc_count[r]] starts at 0 and never goes
   negative) -- a "no view change happened" failure mode indistinguishable from "nothing triggered
   one" without this check. [create] now rejects [svc_limit < 1]; the two cases below restore this
   list to having a validated-numeric-argument case for every one of [create]'s parameters, the
   same structural shape the list had before [primary_id] was removed. *)

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
        Replica.create ~my_id:1 ~replica_count:0 ~svc_limit:3 ~send:(fun ~to_:_ _ -> ()));
    expect_invalid_arg "negative replica_count is rejected" (fun () ->
        Replica.create ~my_id:1 ~replica_count:(-3) ~svc_limit:3 ~send:(fun ~to_:_ _ -> ()));
    expect_invalid_arg "even replica_count is rejected" (fun () ->
        Replica.create ~my_id:1 ~replica_count:4 ~svc_limit:3 ~send:(fun ~to_:_ _ -> ()));
    expect_invalid_arg "my_id below 1 is rejected" (fun () ->
        Replica.create ~my_id:0 ~replica_count:3 ~svc_limit:3 ~send:(fun ~to_:_ _ -> ()));
    expect_invalid_arg "my_id above replica_count is rejected" (fun () ->
        Replica.create ~my_id:4 ~replica_count:3 ~svc_limit:3 ~send:(fun ~to_:_ _ -> ()));
    (* L2 fix-round regression tests *)
    expect_invalid_arg "svc_limit = 0 is rejected" (fun () ->
        Replica.create ~my_id:1 ~replica_count:3 ~svc_limit:0 ~send:(fun ~to_:_ _ -> ()));
    expect_invalid_arg "negative svc_limit is rejected" (fun () ->
        Replica.create ~my_id:1 ~replica_count:3 ~svc_limit:(-1) ~send:(fun ~to_:_ _ -> ()));
  ]

(* L2 fix-round regression test: svc_limit = 1 (the smallest LEGAL value) must still be accepted
   -- the fix must not overshoot into rejecting a genuinely valid, if minimal, configuration.
   [svc_limit] itself has no reader in this task's scope (Task 2's [check_timeout] is its first),
   so there is no accessor to assert its stored value against -- the only observable thing this
   test can pin is that [create] does not raise, and that the resulting replica is otherwise a
   perfectly normal, usable [Init] state. *)
let test_svc_limit_boundary_one_is_accepted () =
  let t = Replica.create ~my_id:1 ~replica_count:3 ~svc_limit:1 ~send:(fun ~to_:_ _ -> ()) in
  Alcotest.(check int) "op_number starts at 0, same as any other valid create" 0 (Replica.op_number t)

let test_create_accepts_a_valid_single_replica_cluster () =
  (* replica_count = 1 is odd and >= 1 -- a legitimate (if degenerate) configuration, not to be
     rejected by the same validation that rejects even counts (see L2's own test below). No
     [for_test_set_view_number] call needed: Primary(v) = 1 + ((v-1) mod 1 + 1) mod 1 = 1 for
     EVERY v when replica_count = 1 (mod 1 is always 0), so replica 1 is primary at the default
     view_number = 0 too. *)
  let t = Replica.create ~my_id:1 ~replica_count:1 ~svc_limit:3 ~send:(fun ~to_:_ _ -> ()) in
  Alcotest.(check bool) "is_primary" true (Replica.is_primary t)

(* ---- L2 fix-round regression test: propose must also drive PrimaryExecuteOp (the f=0 case) ---- *)

let test_propose_commits_immediately_in_single_replica_cluster () =
  let send, _sent = capturing_send () in
  (* See test_create_accepts_a_valid_single_replica_cluster above: replica 1 is primary at
     replica_count = 1 regardless of view_number, so no for_test_set_view_number call is needed
     here either. *)
  let t = Replica.create ~my_id:1 ~replica_count:1 ~svc_limit:3 ~send in
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
  let t = Replica.create ~my_id:2 ~replica_count:3 ~svc_limit:3 ~send in
  Replica.handle_message t "\xff\xff\xff not a valid encoding";
  Alcotest.(check int) "op_number unchanged" 0 (Replica.op_number t);
  Alcotest.(check bool) "no messages sent" true (sent () = [])

(* [Start_view_change] is deliberately NOT in this list any more -- Task 2 of the view-change plan
   made it a genuinely in-scope message type (see handle_start_view_change's own tests below,
   "---- Start_view_change dispatch ----"); only [Do_view_change]/[Start_view] (Task 3's own
   [ReceiveDVC]/[SendSV]/[ReceiveSV]) remain out of scope here. *)
let test_handle_message_out_of_scope_types_ignored () =
  let send, sent = capturing_send () in
  let t = Replica.create ~my_id:2 ~replica_count:3 ~svc_limit:3 ~send in
  List.iter
    (fun m -> Replica.handle_message t (Message.encode m))
    [
      Message.Do_view_change { v = 1; log = []; last_normal_view = 0; n = 0; k = 0; i = 3 };
      Message.Start_view { v = 1; log = []; n = 0; k = 0 };
    ];
  Alcotest.(check int) "op_number unchanged" 0 (Replica.op_number t);
  Alcotest.(check int) "commit_number unchanged" 0 (Replica.commit_number t);
  Alcotest.(check bool) "status unchanged (still Normal)" true (Replica.status t = Replica.Normal);
  Alcotest.(check int) "view_number unchanged" 0 (Replica.view_number t);
  Alcotest.(check bool) "no messages sent" true (sent () = [])

(* ---- check_timeout (TimerSendSVC, VSR.tla:161-174) ---- *)

let test_check_timeout_transitions_and_broadcasts_start_view_change () =
  let send, sent = capturing_send () in
  let t = Replica.create ~my_id:1 ~replica_count:3 ~svc_limit:3 ~send in
  Alcotest.(check bool) "starts Normal" true (Replica.status t = Replica.Normal);
  Alcotest.(check int) "starts at view_number 0" 0 (Replica.view_number t);
  Replica.check_timeout t;
  Alcotest.(check bool) "transitions to View_change" true (Replica.status t = Replica.View_change);
  Alcotest.(check int) "view_number advances by exactly one" 1 (Replica.view_number t);
  Alcotest.(check int) "op_number is untouched (UNCHANGED in VSR.tla:173)" 0 (Replica.op_number t);
  Alcotest.(check int) "commit_number is untouched" 0 (Replica.commit_number t);
  (* Broadcast StartViewChange{v=1; i=1} to every OTHER replica (2, 3), never to self *)
  Alcotest.(check bool) "broadcasts StartViewChange to both other replicas, not itself" true
    (decoded_sent sent
    = [ (2, Message.Start_view_change { v = 1; i = 1 }); (3, Message.Start_view_change { v = 1; i = 1 }) ])

let test_check_timeout_noop_when_already_view_change () =
  (* Isolates the [status = "Normal"] guard specifically, independent of the svc_limit bound
     (svc_limit is generous here) -- a naive implementation that dropped this guard would let a
     second, back-to-back check_timeout call bump view_number again and re-broadcast. *)
  let send, sent = capturing_send () in
  let t = Replica.create ~my_id:1 ~replica_count:3 ~svc_limit:5 ~send in
  Replica.check_timeout t;
  Alcotest.(check int) "1st timeout advances view_number to 1" 1 (Replica.view_number t);
  let sent_after_first = sent () in
  Replica.check_timeout t;
  Alcotest.(check bool) "2nd back-to-back call is a no-op: status stays View_change (not bumped further)"
    true
    (Replica.status t = Replica.View_change);
  Alcotest.(check int) "view_number NOT advanced a second time" 1 (Replica.view_number t);
  Alcotest.(check bool) "no additional StartViewChange broadcast for the blocked 2nd call" true
    (sent () = sent_after_first)

let test_check_timeout_bounded_by_svc_limit () =
  (* Isolates the [svc_count < svc_limit] guard. Since nothing in THIS task's own scope can bring
     [status] back to Normal for real (that's Task 3's SendSV/ReceiveSV), [for_test_set_view] is
     used here ONLY to simulate "the replica somehow returned to Normal" between real
     check_timeout calls -- svc_count itself is never touched directly (it has no setter at all;
     only check_timeout's own real firings increment it), so this genuinely exercises svc_count's
     accumulation and bound, not a shortcut around it. *)
  let send, sent = capturing_send () in
  let t = Replica.create ~my_id:2 ~replica_count:3 ~svc_limit:2 ~send in
  Replica.check_timeout t;
  Alcotest.(check bool) "1st timeout (svc_count 0 < 2) fires" true (Replica.status t = Replica.View_change);
  Alcotest.(check int) "view_number advances to 1" 1 (Replica.view_number t);
  Replica.for_test_set_view t ~status:Replica.Normal ~view_number:1 ~last_normal_view:1;
  Replica.check_timeout t;
  Alcotest.(check bool) "2nd timeout (svc_count 1 < 2) fires" true (Replica.status t = Replica.View_change);
  Alcotest.(check int) "view_number advances to 2" 2 (Replica.view_number t);
  Replica.for_test_set_view t ~status:Replica.Normal ~view_number:2 ~last_normal_view:2;
  let sent_before_third = List.length (sent ()) in
  Replica.check_timeout t;
  Alcotest.(check bool) "3rd timeout (svc_count 2 >= svc_limit 2) is blocked: status stays Normal" true
    (Replica.status t = Replica.Normal);
  Alcotest.(check int) "view_number NOT advanced by the blocked 3rd timeout" 2 (Replica.view_number t);
  Alcotest.(check int) "no additional StartViewChange broadcast for the blocked timeout" sent_before_third
    (List.length (sent ()))

let test_check_timeout_resets_recv_svc_across_episodes () =
  (* task-2-review.md's M2: check_timeout's own [recv_svc <- Int_set.empty] reset (VSR.tla:168)
     had zero coverage -- deleting it left the whole suite green. VSR.tla's SendSV (:280) and
     ReceiveSV (:304) both leave [rep_recv_svc] UNCHANGED, so once Task 3 lands, a replica
     returning to Normal still has its PREVIOUS episode's senders in [recv_svc]; without this
     reset, the next check_timeout would start a new view-change episode already "at quorum" and
     fire a premature DoViewChange nobody else has asked for. Simulates that return-to-Normal via
     [for_test_set_view] (matching test_check_timeout_bounded_by_svc_limit's own convention). *)
  let send, sent = capturing_send () in
  let t = Replica.create ~my_id:1 ~replica_count:5 ~svc_limit:5 ~send in
  Replica.check_timeout t;
  Replica.handle_message t (Message.encode (Message.Start_view_change { v = 1; i = 2 }));
  Replica.handle_message t (Message.encode (Message.Start_view_change { v = 1; i = 3 }));
  let n_after_episode1 = List.length (sent ()) in
  Replica.for_test_set_view t ~status:Replica.Normal ~view_number:1 ~last_normal_view:1;
  Replica.check_timeout t;
  Alcotest.(check int)
    "new episode sends only the 4 StartViewChange broadcasts, no premature DoViewChange"
    (n_after_episode1 + 4) (List.length (sent ()))

(* ---- Start_view_change dispatch: ReceiveHigherSVC (VSR.tla:183-194) / ReceiveMatchingSVC
   (VSR.tla:196-205) / SendDVC (VSR.tla:216-228) ---- *)

let test_receive_higher_svc_adopts_view_seeds_recv_svc_and_resets_episode () =
  (* replica_count=3, f=1: a single seed already meets SendDVC's own threshold, so this test
     doubles as proof that ReceiveHigherSVC really does seed recv_svc with the SENDER (not leave
     it empty) -- if seeding were broken, SendDVC could never fire from a single message here. It
     also proves recv_dvc/sent_dvc are genuinely reset on each new higher-view episode: after the
     first DoViewChange fires (sent_dvc -> true), a SECOND, even-higher StartViewChange only
     re-enables SendDVC if sent_dvc was really reset back to false. *)
  let send, sent = capturing_send () in
  let t = Replica.create ~my_id:1 ~replica_count:3 ~svc_limit:3 ~send in
  Alcotest.(check bool) "starts Normal at view 0" true (Replica.status t = Replica.Normal && Replica.view_number t = 0);
  Replica.handle_message t (Message.encode (Message.Start_view_change { v = 5; i = 2 }));
  Alcotest.(check bool) "adopts the higher view: status -> View_change" true (Replica.status t = Replica.View_change);
  Alcotest.(check int) "view_number adopts the message's v (5), not view+1" 5 (Replica.view_number t);
  (* f=1 and recv_svc was just seeded with {2} -- SendDVC's threshold is already met, so exactly
     one DoViewChange should already be in flight, to Primary(5) = 1 + ((5-1) mod 3) = 1 + 1 = 2. *)
  Alcotest.(check bool) "seeding recv_svc with the sender alone already meets f=1's threshold: one DoViewChange sent"
    true
    (decoded_sent sent
    = [ (2, Message.Do_view_change { v = 5; log = []; last_normal_view = 0; n = 0; k = 0; i = 1 }) ]);
  (* A second, EVEN HIGHER StartViewChange starts a fresh episode -- if sent_dvc/recv_svc weren't
     really reset, this could never produce a second DoViewChange. *)
  Replica.handle_message t (Message.encode (Message.Start_view_change { v = 9; i = 3 }));
  Alcotest.(check int) "view_number adopts the newer, even higher view" 9 (Replica.view_number t);
  Alcotest.(check bool) "the new episode's own seed (f=1) fires a SECOND DoViewChange -- proves sent_dvc was reset"
    true
    (decoded_sent sent
    = [
        (2, Message.Do_view_change { v = 5; log = []; last_normal_view = 0; n = 0; k = 0; i = 1 });
        (3, Message.Do_view_change { v = 9; log = []; last_normal_view = 0; n = 0; k = 0; i = 1 });
      ])

let test_receive_matching_svc_unions_and_dedups_send_dvc_fires_once () =
  (* replica_count=5, f=2: a single seed/union is NOT enough on its own, so this discriminates
     real set-union accumulation from a single-message trigger, AND from a naive list-append that
     would double-count a duplicate sender. *)
  let send, sent = capturing_send () in
  let t = Replica.create ~my_id:1 ~replica_count:5 ~svc_limit:3 ~send in
  Replica.check_timeout t;
  Alcotest.(check int) "view_number advances to 1" 1 (Replica.view_number t);
  let sent_after_timeout = List.length (sent ()) in
  (* one matching StartViewChange: cardinality 1 < f=2 -- SendDVC must NOT fire yet *)
  Replica.handle_message t (Message.encode (Message.Start_view_change { v = 1; i = 2 }));
  Alcotest.(check int) "below quorum: no DoViewChange sent yet" sent_after_timeout (List.length (sent ()));
  (* the SAME sender again -- a true set must not let this inflate the count *)
  Replica.handle_message t (Message.encode (Message.Start_view_change { v = 1; i = 2 }));
  Alcotest.(check int) "duplicate sender does not inflate recv_svc's cardinality: still below quorum"
    sent_after_timeout (List.length (sent ()));
  (* a genuinely different sender -- cardinality now 2 >= f=2 -- SendDVC fires exactly once *)
  Replica.handle_message t (Message.encode (Message.Start_view_change { v = 1; i = 3 }));
  Alcotest.(check int) "a second, distinct sender reaches quorum: exactly one DoViewChange sent"
    (sent_after_timeout + 1) (List.length (sent ()));
  (* a THIRD matching sender -- cardinality now 3 >= f=2 (still true), but sent_dvc is already
     true for this episode -- SendDVC must not fire a second time *)
  Replica.handle_message t (Message.encode (Message.Start_view_change { v = 1; i = 4 }));
  Alcotest.(check int) "SendDVC never fires twice for the same episode, even though the guard's \
                        cardinality conjunct is still satisfied"
    (sent_after_timeout + 1) (List.length (sent ()))

let test_send_dvc_message_content_matches_replica_state () =
  (* Builds up genuinely non-trivial log/commit_number/last_normal_view state via the well-tested
     normal-case path (real Prepares), THEN drives it into a view change, to pin that SendDVC's
     own DoViewChange really does carry THIS replica's real state, not placeholder/zero values. *)
  let send, sent = capturing_send () in
  let t = Replica.create ~my_id:3 ~replica_count:3 ~svc_limit:3 ~send in
  Replica.for_test_set_view t ~status:Replica.Normal ~view_number:1 ~last_normal_view:1;
  (* my_id=3 is a backup at view 1 (Primary(1) = 1) -- feed it two in-order Prepares *)
  Replica.handle_message t (Message.encode (Message.Prepare { view = 1; n = 1; v = v "a"; k = 0 }));
  Replica.handle_message t (Message.encode (Message.Prepare { view = 1; n = 2; v = v "b"; k = 1 }));
  Alcotest.(check int) "op_number is 2 after the two Prepares" 2 (Replica.op_number t);
  Alcotest.(check int) "commit_number advanced to 1 (the second Prepare's own k)" 1 (Replica.commit_number t);
  let sent_before_timeout = List.length (sent ()) in
  Replica.check_timeout t;
  Alcotest.(check int) "check_timeout does not touch op_number/commit_number/last_normal_view" 2
    (Replica.op_number t);
  Alcotest.(check int) "check_timeout does not touch commit_number" 1 (Replica.commit_number t);
  Alcotest.(check int) "check_timeout does not touch last_normal_view" 1 (Replica.last_normal_view t);
  Alcotest.(check int) "view_number advances to 2" 2 (Replica.view_number t);
  (* f=1: a single matching StartViewChange from replica 1 meets quorum and fires SendDVC *)
  Replica.handle_message t (Message.encode (Message.Start_view_change { v = 2; i = 1 }));
  (* Primary(2) = 1 + ((2-1) mod 3) = 1 + 1 = 2 *)
  let sent_after = decoded_sent sent in
  Alcotest.(check int) "exactly one new message sent (the DoViewChange)" (sent_before_timeout + 3)
    (List.length sent_after)
  (* (sent_before_timeout messages) + 2 StartViewChange broadcasts from check_timeout + 1 DoViewChange *);
  Alcotest.(check bool) "the DoViewChange carries this replica's real log/n/k/last_normal_view/i, \
                         addressed to Primary(2) = 2"
    true
    (List.nth sent_after (List.length sent_after - 1)
    = (2, Message.Do_view_change { v = 2; log = [ v "a"; v "b" ]; last_normal_view = 1; n = 2; k = 1; i = 3 }))

let test_start_view_change_lower_or_equal_while_normal_dropped () =
  let send, sent = capturing_send () in
  let t = Replica.create ~my_id:1 ~replica_count:3 ~svc_limit:3 ~send in
  Replica.for_test_set_view t ~status:Replica.Normal ~view_number:3 ~last_normal_view:3;
  (* LOWER: v=1 < view_number=3 -- matches neither ReceiveHigherSVC nor ReceiveMatchingSVC *)
  Replica.handle_message t (Message.encode (Message.Start_view_change { v = 1; i = 2 }));
  Alcotest.(check bool) "a lower-view StartViewChange is dropped: status stays Normal" true
    (Replica.status t = Replica.Normal);
  Alcotest.(check int) "view_number unchanged by the lower-view message" 3 (Replica.view_number t);
  (* EQUAL while Normal: v=3=view_number, but status=Normal, so ReceiveMatchingSVC's own
     [status = "ViewChange"] conjunct fails -- no episode is running here to join *)
  Replica.handle_message t (Message.encode (Message.Start_view_change { v = 3; i = 2 }));
  Alcotest.(check bool) "an equal-view StartViewChange while Normal is dropped too" true
    (Replica.status t = Replica.Normal);
  Alcotest.(check int) "view_number unchanged by the equal-view-while-Normal message" 3 (Replica.view_number t);
  Alcotest.(check bool) "neither dropped message produced any outgoing message" true (sent () = [])

let test_start_view_change_forged_out_of_range_i_dropped () =
  (* Defense-in-depth boundary pin, mirroring the I2-style boundary tests above for Prepare_ok's
     own [i] guard: i = replica_count + 1 = 4 is the first out-of-range id and must still be
     rejected wholesale (no state change at all, not even adopting the higher view); i = 2 (a
     genuinely valid id) must still work normally right after. *)
  let send, sent = capturing_send () in
  let t = Replica.create ~my_id:1 ~replica_count:3 ~svc_limit:3 ~send in
  Replica.handle_message t (Message.encode (Message.Start_view_change { v = 5; i = 4 }));
  Alcotest.(check bool) "forged out-of-range i (4, first invalid id for replica_count=3) is dropped wholesale: \
                         status stays Normal"
    true
    (Replica.status t = Replica.Normal);
  Alcotest.(check int) "view_number NOT adopted from a message with a forged i" 0 (Replica.view_number t);
  Alcotest.(check bool) "no message sent for the forged-i StartViewChange" true (sent () = []);
  Replica.handle_message t (Message.encode (Message.Start_view_change { v = 5; i = 2 }));
  Alcotest.(check bool) "a genuinely valid i (2, the last legal id below the forged boundary) is accepted normally"
    true
    (Replica.status t = Replica.View_change && Replica.view_number t = 5)

let test_start_view_change_self_addressed_i_dropped () =
  (* task-2-review.md's M1: unlike the forged-out-of-range case above, a StartViewChange naming
     THIS replica's own id (i = my_id) is not a forgery at all -- VSR.tla's own BroadcastFunc
     (VSR.tla:56) makes m.i = r structurally unreachable for a correct replica's own broadcast,
     but lib/sim/network.ml has no self-delivery special case, so an ordinary broadcast loops
     back into the sender's own dispatch loop in real running code. Without excluding i = my_id,
     that self-addressed message would count toward this replica's own SendDVC quorum for free --
     reproduced here at replica_count=5 (f=2): one genuine other id plus a self-addressed id must
     NOT reach the f=2 threshold, since only one real corroborator exists. *)
  let send, sent = capturing_send () in
  let t = Replica.create ~my_id:1 ~replica_count:5 ~svc_limit:3 ~send in
  Replica.check_timeout t;
  Replica.handle_message t (Message.encode (Message.Start_view_change { v = 1; i = 2 }));
  let sent_after_one_genuine = List.length (sent ()) in
  Replica.handle_message t (Message.encode (Message.Start_view_change { v = 1; i = 1 }));
  Alcotest.(check int) "a self-addressed StartViewChange (i = my_id) sends no DoViewChange: only \
                         one real corroborator exists, below the f=2 threshold"
    sent_after_one_genuine (List.length (sent ()));
  (* a second genuine, distinct other id (i=3) DOES complete real quorum *)
  Replica.handle_message t (Message.encode (Message.Start_view_change { v = 1; i = 3 }));
  Alcotest.(check int) "a second genuine corroborator completes real quorum (one DoViewChange sent)"
    (sent_after_one_genuine + 1) (List.length (sent ()))

(* ---- for_test_set_view (test-support surface) ---- *)

let test_for_test_set_view_round_trips_independently () =
  let t = Replica.create ~my_id:1 ~replica_count:3 ~svc_limit:3 ~send:(fun ~to_:_ _ -> ()) in
  (* Deliberately mismatched view_number/last_normal_view, at status=View_change -- exactly the
     combination for_test_set_view_number cannot produce (it force-syncs the two), and exactly
     the combination a real mid-view-change replica is routinely in. *)
  Replica.for_test_set_view t ~status:Replica.View_change ~view_number:7 ~last_normal_view:2;
  Alcotest.(check bool) "status round-trips" true (Replica.status t = Replica.View_change);
  Alcotest.(check int) "view_number round-trips" 7 (Replica.view_number t);
  Alcotest.(check int) "last_normal_view round-trips independently, NOT forced to match view_number" 2
    (Replica.last_normal_view t)

let tests =
  [
    (* Fix-round M2/M3 (task-1-review.md): Primary(v)/view_number/last_normal_view coverage *)
    ("Fix-round M2: Primary(v) formula matches TLC's own table, at two replica_counts", `Quick, test_primary_formula_matches_tlc);
    ("Fix-round M2: is_primary agrees with the Primary(v) formula", `Quick, test_is_primary_agrees_with_primary_formula);
    ( "Fix-round M2: view_number round-trips for_test_set_view_number",
      `Quick,
      test_view_number_round_trips_for_test_set_view_number );
    ( "Fix-round M3: for_test_set_view_number keeps last_normal_view in sync with view_number",
      `Quick,
      test_for_test_set_view_number_keeps_last_normal_view_in_sync );
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
    (* M3 fix-round regression test *)
    ( "M3: a forged PrepareOk.n from a real replica id does not pre-ack future ops",
      `Quick,
      test_prepare_ok_forged_n_from_real_replica_does_not_preack_future_ops );
    (* I2 boundary pins: the exact first-rejected/last-accepted value of each safety guard *)
    ( "I2 boundary: PrepareOk's i guard sits exactly at replica_count (i+1 rejected, i accepted)",
      `Quick,
      test_prepare_ok_i_boundary_is_exactly_replica_count );
    ( "I2 boundary: Prepare's k guard sits exactly at op_number (k+1 rejected, k accepted)",
      `Quick,
      test_prepare_k_boundary_is_exactly_op_number );
    ( "I2 boundary: PrepareOk's n guard sits exactly at op_number (n+1 rejected, n accepted)",
      `Quick,
      test_prepare_ok_n_boundary_is_exactly_op_number );
    (* L1 fix-round regression tests *)
    ("L1: create accepts a valid, degenerate single-replica cluster", `Quick, test_create_accepts_a_valid_single_replica_cluster);
    (* L2 fix-round regression test *)
    ( "L2: propose alone commits immediately in a single-replica (f=0) cluster",
      `Quick,
      test_propose_commits_immediately_in_single_replica_cluster );
    ("handle_message: malformed bytes are silently dropped, never raise", `Quick, test_handle_message_malformed_bytes_dropped);
    ("handle_message: out-of-scope message types are silently ignored", `Quick, test_handle_message_out_of_scope_types_ignored);
    (* Fix-round L2 (task-1-review.md): svc_limit boundary *)
    ("Fix-round L2: svc_limit = 1 (the smallest legal value) is accepted", `Quick, test_svc_limit_boundary_one_is_accepted);
    (* Task 2: check_timeout (TimerSendSVC) *)
    ( "Task 2: check_timeout transitions to View_change and broadcasts StartViewChange",
      `Quick,
      test_check_timeout_transitions_and_broadcasts_start_view_change );
    ( "Task 2: check_timeout is a no-op when already View_change (status guard)",
      `Quick,
      test_check_timeout_noop_when_already_view_change );
    ("Task 2: check_timeout is bounded by svc_limit", `Quick, test_check_timeout_bounded_by_svc_limit);
    ( "Task 2: check_timeout resets recv_svc across episodes (task-2-review.md's M2)",
      `Quick,
      test_check_timeout_resets_recv_svc_across_episodes );
    (* Task 2: Start_view_change dispatch (ReceiveHigherSVC / ReceiveMatchingSVC / SendDVC) *)
    ( "Task 2: ReceiveHigherSVC adopts the higher view, seeds recv_svc, and resets the episode",
      `Quick,
      test_receive_higher_svc_adopts_view_seeds_recv_svc_and_resets_episode );
    ( "Task 2: ReceiveMatchingSVC unions and dedups recv_svc; SendDVC fires exactly once",
      `Quick,
      test_receive_matching_svc_unions_and_dedups_send_dvc_fires_once );
    ( "Task 2: SendDVC's DoViewChange carries this replica's real log/n/k/last_normal_view/i",
      `Quick,
      test_send_dvc_message_content_matches_replica_state );
    ( "Task 2: a lower or equal-while-Normal StartViewChange is dropped",
      `Quick,
      test_start_view_change_lower_or_equal_while_normal_dropped );
    ( "Task 2: a StartViewChange with a forged out-of-range i is dropped wholesale",
      `Quick,
      test_start_view_change_forged_out_of_range_i_dropped );
    ( "Task 2: a self-addressed StartViewChange (i = my_id) is dropped (task-2-review.md's M1)",
      `Quick,
      test_start_view_change_self_addressed_i_dropped );
    (* Task 2: for_test_set_view (test-support surface) *)
    ( "Task 2: for_test_set_view round-trips status/view_number/last_normal_view independently",
      `Quick,
      test_for_test_set_view_round_trips_independently );
  ]
  @ create_invalid_arg_tests
