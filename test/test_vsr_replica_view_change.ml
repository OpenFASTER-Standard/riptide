(* test/test_vsr_replica_view_change.ml -- Task 4 of the VSR view-change plan
   (docs/superpowers/plans/2026-09-18-vsr-view-change.md): the actual point of the whole plan, per
   this repo's own CLAUDE.md "no spec without running code" rule. Tasks 1-3 (already merged) built
   and unit-tested the view-change actions themselves against hand-constructed messages
   (test_vsr_replica.ml) and went through a self-directed TLC verification pass against
   spec/tla/VSR.tla. Neither of those proves that a real CLUSTER of real, running
   Riptide_vsr.Replica.t processes, talking over a real (simulated) transport, actually survives a
   primary failure and resumes normal operation under a new primary -- that is what this file
   proves, by running the code, not by re-checking the TLA+ model again.

   Structurally this is test_vsr_replica_cluster.ml's own harness (Sim_transport +
   Network.default_fault_config, one real receive-and-dispatch fiber per replica, a settle-style
   quiescence pump) plus one new capability that plan's cluster never needed: a way to make one
   specific replica's own dispatch fiber stop consuming messages, so "the primary process is gone"
   can be simulated for real within a single OCaml process, rather than merely "the test stops
   calling propose on it" (which alone would leave the old primary still answering
   StartViewChange/DoViewChange traffic like a live replica, undermining the exact scenario this
   file exists to prove).

   TWO FORWARD NOTES FROM TASK 3'S OWN REVIEW, both load-bearing in this file's own test design
   (see replica.ml's own [try_send_dvc]/[handle_do_view_change] doc comments for the underlying
   mechanism each note is about):

   1. [SendDVC] unicasts to [Primary(View(r))], which can be the sending replica's OWN id (VSR.tla's
      own "f+1 DOVIEWCHANGE from different replicas, INCLUDING ITSELF", VSR.tla:262-263) -- and
      [lib/sim/network.ml] has NO self-delivery special case, so that self-addressed message is
      subject to the SAME fault config as any other message. In a 3-replica cluster with a dead
      primary, the two survivors are EXACTLY the f+1=2 quorum SendSV needs -- worked through in
      detail below (see [test_single_view_change_survives_primary_failure]'s own comment), one
      survivor's DVC is necessarily self-addressed, and losing it would silently stall the view
      change forever, easily misdiagnosed as a threshold bug rather than a fault-injection
      interaction. This file therefore uses [Network.default_fault_config] (all-zero probabilities,
      reliable delivery) throughout, matching the normal-case plan's own cluster test's convention,
      exactly as the brief instructs -- no fault injection is exercised here at all, deliberately.

   2. [SendSV] only ever reads the FIRST f+1 DVCs to arrive (VSR.tla's own [CHOOSE] permits any
      maximal element among what has been received so far, not a global best-of-all-eventual-
      arrivals) -- so this file's own assertions are written as "the committed prefix survives",
      never as "the new primary's adopted log is the objectively best one among all survivors'
      logs". Concretely: a value this file confirms was already committed (via [Replica.is_committed]
      on the replica that committed it) BEFORE the crash is asserted present and (once the dust
      settles) still committed afterward; a value that was only ever REPLICATED but not yet
      committed anywhere among the survivors before the crash is asserted present in the adopted
      log (nothing is silently dropped), but its post-view-change commit status is deliberately left
      unasserted, since [WinningDVC]/[HighestCommitNumber] over a survivor-only quorum need not (and,
      as worked out below, does not) mark it committed immediately. *)

open Riptide
open Riptide_vsr
open Riptide_sim

(* [Primary(v) == 1 + ((v-1) % ReplicaCount)] (VSR.tla:18), transcribed INDEPENDENTLY here rather
   than calling {!Replica.primary} -- the whole point of this file's "don't assume, verify" brief
   requirement is to confirm the real cluster's emergent new primary against the formula itself,
   not against the very function under test. Euclidean modulo, exactly like replica.ml's own
   [primary] (see that function's own doc comment for the Euclidean-vs-truncating trap). *)
let primary_of_view ~view ~replica_count = 1 + (((view - 1) mod replica_count + replica_count) mod replica_count)

(* A nontrivial Value.value shape, matching test_vsr_replica_cluster.ml's own [record_value] --
   deliberately kept file-local rather than shared, matching this suite's existing convention of
   each cluster-level test file being self-contained (test_vsr_replica_cluster.ml does not import
   from test_vsr_replica.ml either). *)
let record_value name =
  Value.Record
    [ ("kind", Value.Scalar (Value.String name));
      ("payload", Value.Sequence [ Value.Scalar (Value.Int 1L); Value.Scalar (Value.Int 2L); Value.Scalar (Value.Int 3L) ])
    ]

let rec pp_value fmt (v : Value.value) =
  match v with
  | Value.Scalar (Value.Bool b) -> Format.fprintf fmt "Bool %b" b
  | Value.Scalar (Value.Int i) -> Format.fprintf fmt "Int %Ld" i
  | Value.Scalar (Value.Float f) -> Format.fprintf fmt "Float %f" f
  | Value.Scalar (Value.String s) -> Format.fprintf fmt "String %S" s
  | Value.Scalar (Value.Bytes b) -> Format.fprintf fmt "Bytes %S" b
  | Value.Record fields ->
    Format.fprintf fmt "Record [%a]"
      (Format.pp_print_list ~pp_sep:(fun fmt () -> Format.fprintf fmt "; ") (fun fmt (k, v) ->
           Format.fprintf fmt "(%S, %a)" k pp_value v))
      fields
  | Value.Sum (tag, v) -> Format.fprintf fmt "Sum (%S, %a)" tag pp_value v
  | Value.Sequence items ->
    Format.fprintf fmt "Sequence [%a]" (Format.pp_print_list ~pp_sep:(fun fmt () -> Format.fprintf fmt "; ") pp_value) items
  | Value.Map entries ->
    Format.fprintf fmt "Map [%a]"
      (Format.pp_print_list ~pp_sep:(fun fmt () -> Format.fprintf fmt "; ") (fun fmt (k, v) ->
           Format.fprintf fmt "(%a, %a)" pp_value k pp_value v))
      entries

let value_testable = Alcotest.testable pp_value (fun a b -> Value.canonical_encode a = Value.canonical_encode b)
let check_entries msg expected actual = Alcotest.(check (list value_testable)) msg expected actual

(* ---- Cluster harness ----

   Deliberately NOT test_vsr_replica_cluster.ml's own [with_cluster]: this file needs one thing
   that harness never had to provide -- a way to make ONE replica's own dispatch fiber genuinely
   stop consuming messages (simulating "this process is gone"), not merely a test that stops
   calling [propose] on it. Everything else (Sim_transport wiring, [settle]'s bounded-round
   quiescence pump) is the same shape, for the same reasons -- see that file's own doc comments. *)

exception Cluster_test_done
(* Unwinds the outer Eio.Switch.run once a test body is done, exactly like
   test_vsr_replica_cluster.ml's own identically-named (but distinct -- different module, no
   clash) exception. *)

exception Replica_stopped
(* Unwinds exactly ONE replica's own inner Eio.Switch.run, the mechanism {!with_cluster}'s [stop]
   callback below uses to simulate that one replica's process dying without tearing down the rest
   of the cluster. *)

(* [with_cluster ~replica_count ~svc_limit body] builds a fresh [replica_count]-replica cluster
   (peer ids "1".."replica_count", Network.default_fault_config -- see this file's own top-level
   doc comment, forward note 1, for why this is not merely "the convenient default" but load-
   bearing here), pins every replica to view_number = 1 (so Primary(1) = 1 for any replica_count,
   matching test_vsr_replica_cluster.ml's own convention: replica 1 is always the initial primary),
   starts each replica's own receive-and-dispatch fiber, runs [body], then tears everything down.

   [body] receives [stop : int -> unit] in addition to the usual [replicas]/[settle]: [stop i]
   permanently ends replica [i]'s own dispatch fiber (its own inner Eio.Switch.run unwinds via
   {!Replica_stopped}, caught locally, so the OTHER replicas' fibers and the outer switch are
   completely unaffected) -- simulating "replica i's process has crashed" for real: after [stop i],
   nothing this cluster's [net] ever delivers to replica [i] is processed by anything, exactly like
   a genuinely dead process, not merely a replica the test has stopped calling [propose] on. This
   is the mechanism this file's own top-level doc comment's forward note 1 depends on: with the old
   primary's dispatch fiber genuinely stopped, it never adopts a higher view, never sends its own
   StartViewChange/DoViewChange, and the survivors are genuinely on their own -- exactly the
   scenario "the two survivors are EXACTLY the f+1 quorum SendSV needs" describes. *)
let with_cluster ~replica_count ~svc_limit
    (body : replicas:Replica.t array -> stop:(int -> unit) -> settle:(unit -> unit) -> unit) =
  Eio_mock.Backend.run @@ fun () ->
  let prng = Prng.create 1 in
  let net = Network.create prng () (* faults default to Network.default_fault_config *) in
  for id = 1 to replica_count do
    Network.register net (string_of_int id)
  done;
  let handles = Array.init replica_count (fun i -> Sim_transport.create net (i + 1)) in
  let replicas =
    Array.init replica_count (fun i ->
        let my_id = i + 1 in
        let r =
          Replica.create ~my_id ~replica_count ~svc_limit ~send:(fun ~to_ bytes ->
              Sim_transport.send handles.(i) ~to_ bytes)
        in
        Replica.for_test_set_view_number r 1;
        r)
  in
  let settle () =
    let rec loop rounds_left =
      if rounds_left <= 0 then
        Alcotest.fail "cluster did not quiesce within the round budget -- possible non-termination"
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
  (* Populated by each replica's own forked fiber, the first thing it does inside its own inner
     switch -- before that assignment runs, [stop i] has nothing to call. Every test in this file
     calls [settle] (or at minimum proposes something, which yields no fibers a turn on its own --
     [settle] is what actually gives forked fibers a chance to run) at least once before ever
     calling [stop], so by the time [stop] is used the assignment below has always already run; the
     [None] branch exists purely as a loud, diagnosable failure instead of a silent no-op if that
     assumption is ever violated by a future test. *)
  let stop_fns = Array.make replica_count None in
  try
    Eio.Switch.run (fun sw ->
        Array.iteri
          (fun i replica ->
            Eio.Fiber.fork ~sw (fun () ->
                try
                  Eio.Switch.run (fun replica_sw ->
                      stop_fns.(i) <- Some (fun () -> Eio.Switch.fail replica_sw Replica_stopped);
                      (* This IS a real replica process's main loop, run as a fiber, exactly like
                         test_vsr_replica_cluster.ml's own dispatch loop -- see that file's own
                         comment. It never returns on its own; it is torn down either by [stop i]
                         (this one replica only, via Replica_stopped) or, for whichever replicas are
                         still running at test end, by the outer switch's own Cluster_test_done. *)
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
          | None ->
            Alcotest.fail
              (Printf.sprintf
                 "stop %d called before replica %d's dispatch fiber had registered its own stop \
                  function -- call settle () at least once before the first stop () in this test"
                 i i)
        in
        body ~replicas ~stop ~settle;
        Eio.Switch.fail sw Cluster_test_done)
  with Cluster_test_done -> ()

(* Calls [Replica.check_timeout r] [times] times in immediate succession (no yields in between --
   see the call sites below for why that matters: it is what guarantees several replicas'
   check_timeout calls are genuinely INDEPENDENT, each one deciding to start a view change without
   having heard anything from the others yet, rather than one adopting a view the other already
   broadcast). Only the FIRST call can ever have an effect (check_timeout's own guard requires
   [status = Normal], and the first successful call moves [status] to [View_change] -- see
   replica.mli's own doc comment); every call after that is a real, guard-enforced no-op, not
   merely "harmless because nothing happens to be listening". Calling it more than once here is
   deliberate, not sloppy: it exercises that no-op guard directly, the same way a real caller would
   -- a real wall-clock timer fires on its own schedule regardless of whether a view change is
   already underway, and check_timeout's whole job is to make every firing beyond the first safe. *)
let fire_check_timeout_repeatedly r ~times =
  for _ = 1 to times do
    Replica.check_timeout r
  done

(* ---- Test 1: a single primary failure, a real view change, committed data survives, the cluster
   resumes ----

   3 replicas (f = 1), matching spec/tla/VSR.cfg's own ReplicaCount = 3 and
   test_vsr_replica_cluster.ml's own convention. Every replica starts at view_number = 1, so
   Primary(1) = 1: replica 1 is the initial primary.

   WHY BOTH SURVIVING BACKUPS MUST CALL check_timeout, NOT JUST ONE (worked out by reading
   replica.ml directly, not assumed): [ReceiveHigherSVC] (a replica ADOPTING a higher view it heard
   about from someone else's StartViewChange) seeds its own [recv_svc] with a SINGLETON -- just the
   sender of that message -- which already meets SendDVC's own [Cardinality(recv_svc) >= f] guard
   for f = 1, so the ADOPTING replica sends its own DoViewChange immediately. But
   [ReceiveHigherSVC] itself never re-broadcasts a StartViewChange of its own -- only
   [check_timeout] (TimerSendSVC) ever broadcasts one. So if only ONE surviving backup calls
   check_timeout, exactly ONE DoViewChange ever reaches the new primary (from whichever OTHER
   backup merely adopted the higher view) -- one short of SendSV's own [>= f + 1 = 2] threshold,
   and the view change would stall forever (a real liveness bug this test would otherwise miss
   entirely). Having BOTH surviving backups call check_timeout independently (before either has
   heard from the other -- see [fire_check_timeout_repeatedly]'s own doc comment on why no yields
   between the two calls matters) means each one's own [recv_svc] starts EMPTY (from its own
   check_timeout's reset) and is populated to a singleton only once the OTHER's StartViewChange
   arrives -- so each independently crosses the same threshold and each sends its own
   DoViewChange to Primary(2). One of those two DoViewChanges is necessarily SELF-addressed (the
   new primary's own), which is exactly the forward note 1 scenario from this file's own top-level
   doc comment: two DoViewChanges reach the new primary, EXACTLY f + 1 = 2, no slack at all. *)
let test_single_view_change_survives_primary_failure () =
  with_cluster ~replica_count:3 ~svc_limit:3 (fun ~replicas ~stop ~settle ->
      let old_primary = replicas.(0) (* my_id = 1, Primary(1) = 1 *) in
      let backup2 = replicas.(1) and backup3 = replicas.(2) in
      let v1 = record_value "committed-before-crash" in
      let v2 = record_value "replicated-but-not-committed-before-crash" in
      (* Two proposes, each fully settled before the next -- test_vsr_replica_cluster.ml's own
         precedent (test_single_propose_replicates_then_second_propose_advances_backup_commit)
         establishes exactly why this specific sequence is what it takes to get v1 genuinely
         committed EVERYWHERE (backups' commit_number only ever advances via a LATER Prepare's own
         k field piggybacking on it, never from the replication of v1 itself): after v1 alone,
         only the primary has committed it; only once v2's own Prepare (carrying k = 1, the
         primary's commit_number at that point) arrives does each backup's own commit_number catch
         up to 1. *)
      Replica.propose old_primary v1;
      settle ();
      Replica.propose old_primary v2;
      settle ();
      check_entries "old primary's log holds v1 then v2 before the crash" [ v1; v2 ] (Replica.entries old_primary);
      Alcotest.(check bool) "old primary considers v1 committed before the crash" true
        (Replica.is_committed old_primary v1);
      Alcotest.(check bool) "old primary considers v2 committed too before the crash (its own quorum acks)" true
        (Replica.is_committed old_primary v2);
      Alcotest.(check bool) "backup 2 considers v1 committed before the crash (v2's Prepare piggybacked k=1)" true
        (Replica.is_committed backup2 v1);
      Alcotest.(check bool) "backup 2 does NOT yet consider v2 committed before the crash (the known backup-lag)"
        false (Replica.is_committed backup2 v2);
      Alcotest.(check bool) "backup 3 considers v1 committed before the crash" true (Replica.is_committed backup3 v1);
      Alcotest.(check bool) "backup 3 does NOT yet consider v2 committed before the crash" false
        (Replica.is_committed backup3 v2);

      (* The primary "crashes": its own dispatch fiber is stopped for real (see with_cluster's own
         doc comment) -- from this point on nothing this cluster's network ever delivers to it is
         processed by anything -- and the test never calls Replica.propose on it again. *)
      stop 1;

      (* Both surviving backups independently decide their primary has gone silent and each fires
         its own timeout -- see this test's own doc comment above for exactly why both, not one,
         are required for the view change to reach quorum at all. 3 calls each, not 1: exercises
         check_timeout's own no-op-after-the-first guard directly (see
         fire_check_timeout_repeatedly's own doc comment) rather than relying on incidentally never
         calling it twice. *)
      fire_check_timeout_repeatedly backup2 ~times:3;
      fire_check_timeout_repeatedly backup3 ~times:3;
      settle ();

      let new_view = 2 in
      let expected_new_primary_id = primary_of_view ~view:new_view ~replica_count:3 in
      Alcotest.(check int) "Primary(2) = 2 -- computed independently, matching VSR.tla:18's own formula \
                             (Primary(v) = 1 + ((v-1) mod ReplicaCount)) at v=2, replica_count=3"
        2 expected_new_primary_id;
      let new_primary = replicas.(expected_new_primary_id - 1) in
      let other_survivor = if expected_new_primary_id = 2 then backup3 else backup2 in

      (* The new primary genuinely emerged -- verified against the real accessors, not assumed. *)
      Alcotest.(check int) "new primary's own view_number advanced to 2" new_view (Replica.view_number new_primary);
      Alcotest.(check bool) "the replica Primary(2) actually names considers itself primary" true
        (Replica.is_primary new_primary);
      Alcotest.(check bool) "Replica.status confirms the new primary genuinely returned to Normal" true
        (Replica.status new_primary = Replica.Normal);
      Alcotest.(check int) "the OTHER survivor's own view_number advanced to 2 as well" new_view
        (Replica.view_number other_survivor);
      Alcotest.(check bool) "the other survivor does NOT consider itself primary" false (Replica.is_primary other_survivor);
      Alcotest.(check bool) "the other survivor also genuinely returned to Normal" true
        (Replica.status other_survivor = Replica.Normal);

      (* The committed prefix survived -- per this file's own top-level doc comment, forward note
         2: assert the COMMITTED value's presence and commit status, not that the adopted log is
         "the best" among survivors (with only 2 survivors here who held identical logs anyway,
         there is no actual divergence to arbitrate -- the interesting claim is that v1's commit
         status specifically is NOT lost). *)
      check_entries "new primary's log still holds v1 then v2 after the view change" [ v1; v2 ] (Replica.entries new_primary);
      check_entries "the other survivor's log matches the new primary's exactly" (Replica.entries new_primary)
        (Replica.entries other_survivor);
      Alcotest.(check bool) "the new primary still considers v1 committed after the view change" true
        (Replica.is_committed new_primary v1);
      Alcotest.(check bool) "the other survivor still considers v1 committed after the view change" true
        (Replica.is_committed other_survivor v1);
      (* v2 was never committed by anything other than the now-dead old primary -- its own
         HighestCommitNumber (VSR.tla:257-260) is a maximum over the SURVIVING DVCs only, neither
         of which had marked v2 committed before the crash, so it is legitimately NOT required to
         come back as committed here. This is the exact "committed prefix preserved, not the whole
         log's commit status" distinction forward note 2 calls for -- v2 is not lost (still present
         in the log, asserted above), it is simply, correctly, not (yet) committed. *)

      (* The cluster resumes accepting AND committing NEW proposals under the new primary --
         proposing is a no-op for anything that isn't a real, Normal, is_primary(r) replica (see
         Replica.propose's own doc comment), so this alone already proves [new_primary] is a real,
         live primary the cluster can be driven through, not just a replica that happens to report
         is_primary = true. *)
      let v3 = record_value "proposed-after-view-change-1" in
      let v4 = record_value "proposed-after-view-change-2" in
      Replica.propose new_primary v3;
      settle ();
      Replica.propose new_primary v4;
      settle ();
      check_entries "new primary's log now holds all four values in order" [ v1; v2; v3; v4 ] (Replica.entries new_primary);
      check_entries "the other survivor's log converges identically" (Replica.entries new_primary)
        (Replica.entries other_survivor);
      Alcotest.(check bool) "the new primary commits v3 (its own quorum ack from the one other live replica)" true
        (Replica.is_committed new_primary v3);
      Alcotest.(check bool) "the other survivor commits v3 too, once v4's Prepare piggybacks the new k" true
        (Replica.is_committed other_survivor v3))

(* ---- Test 2: two SEQUENTIAL view changes -- svc_count's own reset discipline, exercised for
   real, across two independent episodes, not just one ----

   5 replicas (f = 2) so that TWO independent primary failures can both be simulated without ever
   dropping below the minimum quorum a view change needs: after the first crash 4 replicas remain
   (comfortable slack over f + 1 = 3); after the SECOND crash exactly 3 remain -- once again
   EXACTLY f + 1, no slack, the same tight-quorum shape test 1 exercises at replica_count = 3,
   now reached a second time at a different cluster size and (as this test itself will verify) a
   DIFFERENT new primary.

   svc_limit = 1 is the deliberately tight choice this test's whole point depends on: it means each
   replica gets exactly ONE real check_timeout firing before it would be permanently blocked from
   ever trying again -- UNLESS completing a view change (SendSV or ReceiveSV) resets its own
   svc_count back to 0, per replica.mli's own disclosed, deliberate divergence from VSR.tla's
   literal (never-reset) aux_svc_count. Neither of those two accessors is exposed on Replica.t (see
   replica.mli's own read-only accessor list -- svc_count itself is deliberately test-support-only
   in a way that isn't even exposed to for_test_* readers), so this test cannot assert the counter's
   own numeric value directly; instead it proves the reset happened the only way observable from
   outside the module at all: EVERY replica that already fired its one check_timeout in episode 1
   successfully fires check_timeout AGAIN in episode 2 and a second, genuinely new view change
   completes. If the reset were missing (i.e. if this were a regression back to literally
   transcribing VSR.tla's own aux_svc_count), every one of those second calls would silently no-op
   (svc_count stuck at 1 >= svc_limit 1 forever), no second StartViewChange would ever be
   broadcast, and this test's own view_number/is_primary assertions for episode 2 would fail
   outright -- a real, falsifiable regression test, not merely a demonstration that runs either
   way. *)
let test_two_sequential_view_changes () =
  with_cluster ~replica_count:5 ~svc_limit:1 (fun ~replicas ~stop ~settle ->
      let replica_count = 5 in
      let original_primary = replicas.(0) (* my_id = 1, Primary(1) = 1 *) in
      let va = record_value "committed-before-either-crash" in
      let vb = record_value "replicated-under-original-primary-only" in
      Replica.propose original_primary va;
      settle ();
      Replica.propose original_primary vb;
      settle ();
      Alcotest.(check bool) "original primary considers va committed before any crash" true
        (Replica.is_committed original_primary va);
      Array.iter
        (fun r -> Alcotest.(check bool) "every replica considers va committed before any crash" true (Replica.is_committed r va))
        replicas;

      (* ---- Episode 1: the original primary (replica 1) crashes. Survivors: 2, 3, 4, 5. ---- *)
      stop 1;
      let survivors_1 = [ replicas.(1); replicas.(2); replicas.(3); replicas.(4) ] in
      (* All four surviving backups independently time out, back-to-back with no yields in
         between (see test 1's own doc comment for why this independence matters at all: without
         it, replicas that only ADOPT a higher view via ReceiveHigherSVC never re-broadcast their
         own StartViewChange, so fewer independent timeouts than this can leave SendDVC's own
         Cardinality(recv_svc) >= f = 2 threshold unmet on some or all of them). 2 calls each here,
         not 3 -- svc_limit = 1 means a SECOND firing before any reset would itself be the no-op
         under test below, so keeping episode 1's repetition modest (still > 1, still exercising
         the no-op guard once) leaves the interesting "does it still fire post-reset" question
         entirely to episode 2, where it belongs. *)
      List.iter (fun r -> fire_check_timeout_repeatedly r ~times:2) survivors_1;
      settle ();

      let view_2 = 2 in
      let primary_2_id = primary_of_view ~view:view_2 ~replica_count in
      Alcotest.(check int) "Primary(2) = 2 under a 5-replica cluster too" 2 primary_2_id;
      let primary_2 = replicas.(primary_2_id - 1) in
      Alcotest.(check int) "episode 1's new primary genuinely reached view 2" view_2 (Replica.view_number primary_2);
      Alcotest.(check bool) "episode 1's new primary considers itself primary" true (Replica.is_primary primary_2);
      Alcotest.(check bool) "episode 1's new primary is genuinely Normal, not stuck mid-view-change" true
        (Replica.status primary_2 = Replica.Normal);
      List.iter
        (fun r ->
          Alcotest.(check int) "every episode-1 survivor reached view 2" view_2 (Replica.view_number r);
          Alcotest.(check bool) "every episode-1 survivor is genuinely Normal" true (Replica.status r = Replica.Normal))
        survivors_1;
      Alcotest.(check bool) "va (committed before the crash) is still committed at the new primary" true
        (Replica.is_committed primary_2 va);
      List.iter
        (fun r ->
          Alcotest.(check bool) "va is still committed at every episode-1 survivor" true (Replica.is_committed r va);
          check_entries "vb (replicated but never committed by a survivor) is still present, not lost" [ va; vb ]
            (Replica.entries r))
        survivors_1;

      (* The cluster resumes under the episode-1 primary. *)
      let vc = record_value "proposed-during-episode-1-primacy" in
      Replica.propose primary_2 vc;
      settle ();
      check_entries "episode-1 primary's log now holds va, vb, vc" [ va; vb; vc ] (Replica.entries primary_2);
      List.iter (fun r -> check_entries "every episode-1 survivor converges to the same log" (Replica.entries primary_2) (Replica.entries r)) survivors_1;

      (* ---- Episode 2: the EPISODE-1 primary (whichever replica that turned out to be) now also
         crashes. Survivors: whichever 3 of {2,3,4,5} are not primary_2. Exactly f + 1 = 3 -- no
         slack, same tight-quorum shape as test 1. ---- *)
      stop primary_2_id;
      let survivors_2 = List.filter (fun r -> r != primary_2) survivors_1 in
      Alcotest.(check int) "exactly 3 replicas survive episode 2's crash" 3 (List.length survivors_2);
      List.iter (fun r -> fire_check_timeout_repeatedly r ~times:2) survivors_2;
      settle ();

      let view_3 = 3 in
      let primary_3_id = primary_of_view ~view:view_3 ~replica_count in
      Alcotest.(check int) "Primary(3) = 3 -- a genuinely DIFFERENT replica than episode 1's new primary" 3 primary_3_id;
      Alcotest.(check bool) "episode 2's new primary is a different replica id than episode 1's" true
        (primary_3_id <> primary_2_id);
      let primary_3 = replicas.(primary_3_id - 1) in
      Alcotest.(check int)
        "episode 2's new primary reached view 3 -- only possible if its earlier check_timeout \
         firing in episode 1 did NOT permanently exhaust its svc_limit=1 budget, i.e. the \
         SendSV/ReceiveSV reset genuinely fired at the end of episode 1"
        view_3 (Replica.view_number primary_3);
      Alcotest.(check bool) "episode 2's new primary considers itself primary" true (Replica.is_primary primary_3);
      Alcotest.(check bool) "episode 2's new primary is genuinely Normal" true (Replica.status primary_3 = Replica.Normal);
      List.iter
        (fun r ->
          if r != primary_3 then begin
            Alcotest.(check int)
              "every OTHER episode-2 survivor also reached view 3 -- same reset-discipline claim, \
               for a replica that never becomes primary itself"
              view_3 (Replica.view_number r);
            Alcotest.(check bool) "it does not consider itself primary" false (Replica.is_primary r);
            Alcotest.(check bool) "it is genuinely Normal" true (Replica.status r = Replica.Normal)
          end)
        survivors_2;

      (* The committed prefix from BEFORE EITHER crash survived two whole view changes. *)
      Alcotest.(check bool) "va is still committed at episode 2's new primary, after two view changes" true
        (Replica.is_committed primary_3 va);
      List.iter
        (fun r ->
          Alcotest.(check bool) "va is still committed at every episode-2 survivor" true (Replica.is_committed r va))
        survivors_2;
      check_entries "episode 2's new primary's log still contains va, vb, vc -- nothing silently dropped"
        [ va; vb; vc ] (Replica.entries primary_3);

      (* The cluster resumes AGAIN, under this second new primary. *)
      let vd = record_value "proposed-during-episode-2-primacy" in
      let ve = record_value "proposed-during-episode-2-primacy-2" in
      Replica.propose primary_3 vd;
      settle ();
      Replica.propose primary_3 ve;
      settle ();
      check_entries "episode-2 primary's log now holds all five values in order" [ va; vb; vc; vd; ve ]
        (Replica.entries primary_3);
      List.iter
        (fun r ->
          if r != primary_3 then
            check_entries "every remaining episode-2 survivor converges to the same final log" (Replica.entries primary_3)
              (Replica.entries r))
        survivors_2;
      Alcotest.(check bool) "episode-2 primary commits vd (its own quorum acks, real traffic)" true
        (Replica.is_committed primary_3 vd))

let tests =
  [ ( "single primary failure: real view change over Sim_transport, committed data survives, a \
       new primary (verified against Primary(v), not assumed) resumes normal operation",
      `Quick,
      test_single_view_change_survives_primary_failure );
    ( "two sequential primary failures: two real view changes complete in turn, proving \
       svc_count's own reset discipline holds across repeated episodes, not just one",
      `Quick,
      test_two_sequential_view_changes )
  ]
