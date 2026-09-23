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
   scenario "the two survivors are EXACTLY the f+1 quorum SendSV needs" describes.

   [body] ALSO receives [isolate : int -> unit] / [reconnect : int -> unit] -- the capability
   task-4-review.md's F2 finding says this harness structurally lacked: a way to make survivors'
   logs genuinely DIVERGE before a view change, rather than every survivor holding an identical log
   by construction (the old version's [settle] always drained to full quiescence first, so
   [WinningDVC]/[winning_dvc] (replica.ml:539-551) never had anything real to arbitrate between).
   [isolate i]/[reconnect i] are a TEST-ONLY network PARTITION, orthogonal to [stop]: unlike [stop],
   replica [i] keeps running completely normally while isolated (it can still send -- nothing here
   stops that direction, and nothing in this file's own scenarios ever needs it stopped) -- it
   simply never RECEIVES anything, because every other live replica's own [send] closure (below)
   drops any message addressed to an isolated [to_] at the point of send. Dropped, not buffered:
   [reconnect i] does not replay whatever [i] missed while isolated -- there is nothing queued to
   replay, so whatever divergence [isolate] built (a shorter log, a stale [last_normal_view], or
   both) stays exactly as built until later real traffic changes it.

   ONE PRECONDITION this drops-not-buffers property relies on, worth stating explicitly: it only
   holds for messages sent AFTER [isolate i] is called, not for anything already sitting in [net]'s
   own pending-delivery queue at that moment (those were already scheduled before the drop check
   could apply, and will still be delivered). Every call site in this file calls [isolate] only
   right after a [settle ()] has fully drained the network, so this never bites here -- but it is a
   real precondition of the mechanism, not an incidental fact about how this file happens to use
   it. This is what lets a test build
   a survivor whose [(last_normal_view, n)] genuinely differs from its peers' by literally excluding
   it from some real, running traffic for a while -- not by poking its fields directly (contrast
   [for_test_set_view], which is for hand-built unit-level DVC records, not this file's own
   real-cluster-traffic convention -- see this function's own callers for exactly how it's used to
   build actual divergence rather than assert it). *)
let with_cluster ~replica_count ~svc_limit
    (body :
      replicas:Replica.t array ->
      stop:(int -> unit) ->
      settle:(unit -> unit) ->
      isolate:(int -> unit) ->
      reconnect:(int -> unit) ->
      unit) =
  Eio_mock.Backend.run @@ fun () ->
  let prng = Prng.create 1 in
  let net = Network.create prng () (* faults default to Network.default_fault_config *) in
  for id = 1 to replica_count do
    Network.register net (string_of_int id)
  done;
  let handles = Array.init replica_count (fun i -> Sim_transport.create net (i + 1)) in
  (* [isolated.(id)] -- see {!with_cluster}'s own doc comment above for the full rationale. Indices
     0 and [replica_count + 1..] are simply never read (every real replica id is in
     [1, replica_count]); sized [replica_count + 1] purely so [id] can index it directly without an
     off-by-one. *)
  let isolated = Array.make (replica_count + 1) false in
  let replicas =
    Array.init replica_count (fun i ->
        let my_id = i + 1 in
        let r =
          Replica.create ~storage:(Replica.volatile_storage ()) ~my_id ~replica_count ~svc_limit ~send:(fun ~to_ bytes ->
              if isolated.(to_) then ()
                (* Dropped at the point of send -- see [isolated]'s own doc comment: never queued,
                   so there is nothing left to deliver once [to_] is later reconnected. *)
              else Sim_transport.send handles.(i) ~to_ bytes)
        in
        Replica.for_test_set_view_number r 1;
        r)
  in
  let isolate i = isolated.(i) <- true in
  let reconnect i = isolated.(i) <- false in
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
        body ~replicas ~stop ~settle ~isolate ~reconnect;
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
  with_cluster ~replica_count:3 ~svc_limit:3 (fun ~replicas ~stop ~settle ~isolate:_ ~reconnect:_ ->
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
   ever trying again -- UNLESS completing a view change (SendSV or ReceiveSV -- replica.ml has two
   separate reset sites, one per action, see each one's own doc comment) resets its own svc_count
   back to 0, per replica.mli's own disclosed, deliberate divergence from VSR.tla's literal
   (never-reset) aux_svc_count.

   WHICH OF THE TWO RESET SITES THIS TEST ACTUALLY EXERCISES (corrected per task-4-review.md's own
   F1, which mutation-proved this precisely: deleting the SendSV-path reset at replica.ml:665 left
   BOTH of this file's tests passing, while deleting the ReceiveSV-path reset at replica.ml:807 made
   THIS test fail at the exact assertion below): only ReceiveSV's. The one replica whose episode-1
   reset came via SendSV is episode 1's own new primary (it is the one that actually RUNS SendSV,
   becoming primary) -- and that is exactly the replica this test kills at the top of episode 2
   (`stop primary_2_id` below), so its own reset is never re-exercised by a second check_timeout
   call here. Every replica this test DOES call check_timeout on again in episode 2 is one whose
   episode-1 reset came via ReceiveSV (it adopted episode 1's StartView as a backup). The SendSV
   reset is a real, covered path -- just not by this file: it is exercised directly by
   test_vsr_replica.ml's own unit test (test_send_sv_resets_svc_count, "Task 3: SendSV resets
   svc_count on completing a view change"), which hand-constructs a DoViewChange quorum and
   asserts the reset via a second check_timeout on the same replica without any intervening
   ReceiveSV. Neither svc_count nor svc_limit is exposed on
   Replica.t (see replica.mli's own read-only accessor list -- svc_count itself is deliberately
   test-support-only in a way that isn't even exposed to for_test_* readers), so this test cannot
   assert the counter's own numeric value directly; instead it proves the ReceiveSV reset happened
   the only way observable from outside the module at all: EVERY replica that already fired its one
   check_timeout in episode 1 (and reset via ReceiveSV, not SendSV) successfully fires check_timeout
   AGAIN in episode 2 and a second, genuinely new view change completes. If that reset were missing
   (i.e. if this were a regression back to literally transcribing VSR.tla's own aux_svc_count), every
   one of those second calls would silently no-op (svc_count stuck at 1 >= svc_limit 1 forever), no
   second StartViewChange would ever be broadcast, and this test's own view_number/is_primary
   assertions for episode 2 would fail outright -- a real, falsifiable regression test, not merely a
   demonstration that runs either way. *)
let test_two_sequential_view_changes () =
  with_cluster ~replica_count:5 ~svc_limit:1 (fun ~replicas ~stop ~settle ~isolate:_ ~reconnect:_ ->
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
         ReceiveSV reset genuinely fired at the end of episode 1 (this replica was a BACKUP in \
         episode 1, per survivors_2's own construction above -- it never ran SendSV itself; see \
         this test's own top-of-file doc comment for why the SendSV-path reset is proven \
         elsewhere, not here)"
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

(* ---- Test 3 (F3, task-4-review.md): the permanent liveness wedge when two CONSECUTIVE
   Primary-designates are both dead -- disclosed in spec/tla/README.md's "Known simplifications,
   not omissions" list (point 3) and replica.mli's own check_timeout doc comment; this is that
   disclosure's regression test, reproducing the reviewer's own PROBE-W scenario exactly rather
   than merely asserting the prose is true.

   5 replicas (f = 2, replica_count = 5). Kill BACKUP 2 first -- deliberately, not incidentally: a
   backup dying triggers nothing observable anywhere else in the cluster (no message, no state
   change on any other replica), so at the moment it happens this looks like a complete no-op.
   Then kill the PRIMARY (replica 1). Survivors {3,4,5} are exactly f + 1 = 3, a live quorum, and
   (per test 1/2's own established mechanism) they correctly time out and complete a view change
   into view 2 -- but Primary(2) = 1 + ((2-1) mod 5) = 2, which is EXACTLY the backup killed first.
   The cluster is now permanently wedged: every survivor reaches [status = View_change] and NOTHING
   in this module can move any of them past it, because check_timeout's own guard requires
   [status = Normal] (VSR.tla:164, faithfully transcribed) -- a replica already in [View_change] has
   no mechanism to try yet another, newer view on its own. Real VSR/VRR re-arms the view-change
   timer while already in [View_change] specifically to handle this; this implementation (and the
   spec it transcribes) does not.

   This test proves BOTH halves of the disclosure: (a) the wedge is real and permanent (repeated
   check_timeout calls, across several further rounds with real settling in between, change
   NOTHING), and (b) safety is completely unaffected throughout (the value committed before either
   crash remains committed and present on every survivor the whole time) -- exactly the "liveness-
   only, never a safety violation" framing spec/tla/README.md's disclosure makes, now backed by a
   real, running reproduction rather than prose alone. *)
let test_two_dead_primary_designates_wedge_the_cluster_permanently () =
  with_cluster ~replica_count:5 ~svc_limit:10 (fun ~replicas ~stop ~settle ~isolate:_ ~reconnect:_ ->
      let replica_count = 5 in
      let original_primary = replicas.(0) (* my_id = 1, Primary(1) = 1 *) in
      let x = record_value "committed-before-either-crash-f3" in
      let y = record_value "second-propose-to-fully-commit-x-f3" in
      Replica.propose original_primary x;
      settle ();
      Replica.propose original_primary y;
      settle ();
      Array.iter
        (fun r -> Alcotest.(check bool) "x is committed everywhere before either crash" true (Replica.is_committed r x))
        replicas;

      (* Kill the BACKUP first -- deliberately, per this test's own doc comment: nothing anywhere
         else in the cluster reacts to this at all. No settle() needed to "observe" the effect
         because there is none to observe yet. *)
      stop 2;

      (* Now kill the primary. Survivors: {3,4,5}, exactly f + 1 = 3. *)
      stop 1;
      let survivors = [ replicas.(2); replicas.(3); replicas.(4) ] in
      List.iter (fun r -> fire_check_timeout_repeatedly r ~times:2) survivors;
      settle ();

      let view_2 = 2 in
      let dead_primary_2_id = primary_of_view ~view:view_2 ~replica_count in
      Alcotest.(check int) "Primary(2) = 2 -- exactly the backup killed FIRST, the crux of the wedge" 2
        dead_primary_2_id;

      (* The view change genuinely started (view_number advanced), but cannot possibly complete:
         the one replica everyone's DoViewChange is addressed to never processes anything again. *)
      List.iter
        (fun r ->
          Alcotest.(check int) "every survivor's view_number advanced to 2 (the attempt is real)" view_2
            (Replica.view_number r);
          Alcotest.(check bool) "every survivor is stuck in View_change, never Normal" true
            (Replica.status r = Replica.View_change);
          Alcotest.(check bool) "no survivor considers itself primary (Primary(2) is the dead backup)" false
            (Replica.is_primary r))
        survivors;

      (* THE WEDGE ITSELF: repeated check_timeout calls, across several further rounds with real
         settling in between (so any latent message flow gets a genuine chance to run), change
         NOTHING. This is what makes it a real regression test of the disclosed gap rather than a
         single-snapshot assertion that could vacuously pass for an unrelated reason. *)
      for round = 1 to 4 do
        List.iter (fun r -> fire_check_timeout_repeatedly r ~times:3) survivors;
        settle ();
        List.iter
          (fun r ->
            Alcotest.(check int)
              (Printf.sprintf "round %d: still wedged at view 2, not advancing to view 3 (or beyond) on its own" round)
              view_2 (Replica.view_number r);
            Alcotest.(check bool)
              (Printf.sprintf "round %d: still stuck in View_change, never recovers to Normal on its own" round)
              true
              (Replica.status r = Replica.View_change))
          survivors
      done;

      (* Safety is completely unaffected throughout the wedge -- the whole point of this being a
         disclosed LIVENESS gap, not a safety one. *)
      List.iter
        (fun r ->
          Alcotest.(check bool) "x is STILL committed on every wedged survivor -- nothing lost, nothing corrupted" true
            (Replica.is_committed r x);
          check_entries "every wedged survivor's log is unchanged and intact" [ x; y ] (Replica.entries r))
        survivors)

(* ---- Test 4 (F2, task-4-review.md): winning_dvc's real (last_normal_view, n) selection, proven
   over a REAL cluster with a genuinely divergent survivor log -- not asserted by construction the
   way every earlier test in this file necessarily was (see with_cluster's own doc comment on
   [isolate]/[reconnect]: the OLD harness could only ever settle() to full quiescence before a
   crash, so every survivor's log was identical going into every view change above). This test
   builds ONE survivor (X) with a MUCH longer log but a STALE last_normal_view, and asserts the
   real cluster's adopted log after a view change is NOT X's, proving winning_dvc's own documented
   algorithm (replica.ml:533-551, lexicographic max by (last_normal_view, n), last_normal_view
   FIRST) genuinely composes over real message flow -- not the one with the highest n (a real
   historical VRR safety bug, the exact class the comment at replica.ml:533-535 warns about) and
   not the lexicographic MINIMUM either.

   7 replicas (Replica.create requires an ODD count, 2f + 1 = ReplicaCount -- VSR.tla's own
   assumption; f = 3, f + 1 = 4), TWO sequential crashes (replica 1, then replica 2), and
   [isolate]/[reconnect] to build divergence BEFORE either crash. Five survivors reach crash 2: X
   (the trap, parked at a stale view since before crash 1), and FOUR others -- W, Y, G, H -- who go
   through crash 1 together, end up holding an IDENTICAL log, and stay mutually in sync afterward
   (deliberately identical, not further diverged among themselves -- see this comment's own closing
   paragraph for why trying to ALSO diverge n WITHIN this group turned out to be unreliable to
   construct over real message flow, and unnecessary for what this test needs to prove).

   Why four, not three: X's own view_number is permanently one behind everyone else's (see crash 1
   below), so by the time crash 2 happens, X can only ever ADOPT the current target view
   passively, via [ReceiveHigherSVC] -- and VSR.tla's own [ReceiveHigherSVC] (spec/tla/VSR.tla:
   183-194) does NOT re-broadcast a [StartViewChange] on adopting (only [Discard(m)] and local
   state changes; verified by reading the actual action, not assumed). So X's own participation is
   invisible to everyone else: it can never count toward another replica's own
   [Cardinality(recv_svc) >= f] threshold (f = 3 here). If crash 2's live set were X plus only
   THREE actively-broadcasting replicas (W, Y, G), each of those three would only ever see the
   OTHER TWO as active same-view broadcasters (X contributes nothing to their count) -- cardinality
   2 < f = 3, and [SendDVC] never fires for ANY of them: a real, genuine deadlock, confirmed live
   during this test's own development (the first draft used exactly three actively-broadcasting
   survivors and every one of them got stuck at [status = View_change] forever, never [Normal],
   diagnosed by adding a temporary debug print of each survivor's final view/status). Four actively-
   broadcasting replicas (W, Y, G, H) are self-sufficient on their own: each of the four sees the
   OTHER three as active same-view broadcasters, cardinality 3 = f, exactly enough -- X's own
   passive adoption (which DOES let X send its own bonus DoViewChange once ITS OWN recv_svc
   accumulates to f from listening in) is then a welcome extra, not a requirement. H's own
   (last_normal_view, n) is built to mirror Y's/G's (an also-ran, never a contender to win) rather
   than duplicate any single one of them.

   - Round 1a (before crash 1): only replica 7 (H) is isolated while replica 1 (the original
     primary) proposes 2 more values that reach P2 (2), X (3), AND W/Y/G (4, 5, 6) -- everyone
     except H. P2, X, W, Y, G all grow to n = 4; H alone stays frozen at n = 2. (Deliberately NOT
     "only P2 and X reach n = 4, W/Y/G isolated too" -- see this test's own body for why a MAJORITY
     holding the winning value, not just one replica, is what makes crash 1's own outcome robust to
     arrival-order sensitivity.)

   - Round 1b (still before crash 1): P2, W, Y, G (2, 4, 5, 6) are ALSO isolated, and replica 1
     proposes 8 MORE values that reach ONLY replica 3 (X) -- growing X alone to n = 12 while
     P2/W/Y/G stay frozen at n = 4 (H stays at n = 2, isolated since round 1a, untouched here). This
     is the key move: X's log is now STRICTLY LONGER than anything else in the cluster will ever
     reach again, but X is about to be excluded from the view change that would normally let it
     prove that log "won" anything.

   - Crash 1: replica 3 (X) is isolated (so it hears NONE of this episode's StartViewChange /
     DoViewChange / StartView traffic and stays parked at view 1, last_normal_view = 1, forever,
     with its n = 12 log frozen exactly as built above), replica 2 (P2) and replicas 4/5/6/7 (W, Y,
     G, H) are reconnected, and replica 1 is stopped. Among {P2, W, Y, G, H} -- all still at
     last_normal_view = 1, since none of them has been through a view change yet -- FOUR of the
     five (P2, W, Y, G; only H differs, at n = 2) hold the identical n = 4 log, so P2
     (Primary(2) = 2) wins episode 1 and becomes the new primary regardless of exactly which 4-of-5
     DVCs [try_send_sv] happens to read first; W, Y, G, H all adopt that n = 4 log via ReceiveSV,
     reaching last_normal_view = 2. THIS is exactly why X can never catch up to the others'
     view_number again on its own: X missed the one event ([ReceiveSV]) that would have advanced
     it, and nothing in this module lets a replica already stuck at a stale view skip ahead except
     by living through (or passively adopting) a real episode -- which is precisely what X is
     deliberately excluded from here.

   - Crash 2 (the view change under test): replica 3 (X) is reconnected (Y, G, H are already live,
     reconnected at crash 1 and never re-isolated since) and replica 2 (P2) is stopped, WITHOUT
     ever calling check_timeout on X (see this function's own
     body for why: X's view_number is still 1, so an ACTIVE check_timeout call on X would target
     the WRONG, stale view -- X reaches the real target view purely by PASSIVE adoption instead).
     The five survivors -- X, W, Y, G, H -- now have genuinely different, REAL, verified
     (last_normal_view, n) pairs:

         X:          (last_normal_view = 1, n = 12)  -- the trap: highest n in the whole cluster,
                                                          but the LOWEST last_normal_view
         W, Y, G, H: (last_normal_view = 2, n = 4)    -- identical to each other (all adopted
                                                          episode 1's identical winning log)

     winning_dvc's real algorithm must pick the (last_normal_view = 2, n = 4) log over X's: X's
     last_normal_view (1) loses outright, regardless of its much larger n. This discriminates BOTH
     mutations task-4-review.md's F2 proved the old suite blind to:

       - picking the lexicographic MINIMUM instead of the maximum: min((1,12),(2,4),(2,4),(2,4)) is
         X's (1,12) (last_normal_view alone already settles it) -- wrong.
       - selecting by n ALONE, ignoring last_normal_view (the real historical bug class): max n
         among {12,4,4,4} is X's 12 -- wrong.

     Both mutations converge on the SAME wrong answer, X, for two different reasons -- exactly
     because X was built to be a trap for both at once. Both are confirmed live in
     task-4-fix-2-report.md (temporarily mutating winning_dvc in lib/vsr/replica.ml both ways and
     re-running this test), not merely reasoned about abstractly.

     An earlier version of this test ALSO tried to diverge W's own log further (n = 6, via a THIRD
     "round 2" of isolate/propose after crash 1) so that winning_dvc's within-group n tie-break
     would ALSO be exercised, not just the last_normal_view comparison. That turned out to be
     unreliable over real message flow: with 5 total candidates (X + W/Y/G/H) but [SendSV]'s own
     threshold needing only f + 1 = 4 of them, WHICH specific candidate's vote is excluded from the
     "first f + 1 to arrive" (Task 3's own forward note on [try_send_sv]) is a real property of
     the actual, deterministic delivery order -- confirmed live (via a temporary debug print of
     every [try_send_sv] firing's own evaluated DVC set) that W's own vote, not X's, was the one
     excluded, so the adopted log was Y's (n = 4, the lowest-id tie-break among the three identical
     also-rans), not W's (n = 6) at all. Rather than fight that arrival-order sensitivity (which
     would need exposing raw delivery-order control from {!with_cluster}, well beyond what this
     test needs), this version keeps W/Y/G/H's logs identical after crash 1: the last_normal_view
     comparison alone is sufficient to catch both target mutations (verified above), and a
     dedicated within-group n tie-break is already covered at the unit level by
     test_vsr_replica.ml's own Task 3 tests (e.g. "WinningDVC breaks ties...").

     DURABILITY NOTE, not a defect in what's committed: this test's own mutation-discriminating
     power rests on an unasserted delivery-order property. By this construction there are always
     f + 2 DVC candidates (f + 1 actively-broadcasting replicas are structurally required, plus X)
     against [try_send_sv]'s own [>= f + 1] threshold, so exactly one candidate is excluded from
     the set [winning_dvc] evaluates -- today, empirically, one of W/Y/G/H (never X; see this
     test's own crash-2 assertions, which pin exactly this). If a future change to this file or to
     [replica.ml]'s own delivery-order-sensitive internals ever shifted that exclusion onto X's own
     self-addressed DVC instead, this test would keep PASSING (the remaining four all hold the
     identical (last_normal_view = 2, n = 4) log regardless of who's excluded) while silently no
     longer exercising either target mutation at all -- the exact silent-degradation shape this
     comment's own "dead end 2" paragraph above already ran into once, just relocated to X's vote
     instead of W's. Nothing here currently exposes the evaluated DVC set for a test to assert on
     directly (see replica.mli's own accessor list), so this is left as a known, disclosed
     limitation of this regression test rather than fixed. *)
let test_winning_dvc_selects_by_last_normal_view_then_n_over_a_real_cluster () =
  with_cluster ~replica_count:7 ~svc_limit:3 (fun ~replicas ~stop ~settle ~isolate ~reconnect ->
      let original_primary = replicas.(0) (* my_id = 1 *) in
      let p2 = replicas.(1) (* my_id = 2, episode 1's new primary *) in
      let x = replicas.(2) (* my_id = 3, the trap: excluded from episode 1 entirely *) in
      let w = replicas.(3) (* my_id = 4, one of the four active broadcasters -- NOT specially "the
                               winner": W/Y/G/H end up holding an identical log after episode 1
                               (see this function's own top-of-file comment for why an earlier
                               version tried to diverge W's log further, and why that was dropped)
                             *) in
      let y = replicas.(4) (* my_id = 5 *) in
      let g = replicas.(5) (* my_id = 6, third active broadcaster, mirrors W's/Y's fate *) in
      let h = replicas.(6) (* my_id = 7, fourth active broadcaster, also mirrors W's/Y's fate --
                               see this function's own top-of-file comment for why FOUR (not
                               three) actively-broadcasting survivors are structurally required in
                               crash 2, now that X can only ever adopt passively *) in

      let base1 = record_value "f2-base-1" and base2 = record_value "f2-base-2" in
      let a1 = record_value "f2-a-1" and a2 = record_value "f2-a-2" in
      let b = List.init 8 (fun j -> record_value (Printf.sprintf "f2-b-%d" (j + 1))) in

      (* Baseline: everyone live, everyone converges to n = 2. *)
      Replica.propose original_primary base1;
      settle ();
      Replica.propose original_primary base2;
      settle ();

      (* Round 1a: only H (7) isolated; primary 1 proposes 2 more, reaching P2 (2), X (3), AND W, Y,
         G (4, 5, 6) -- everyone except H. P2, X, W, Y, G: n = 4. H alone: still n = 2.

         Deliberately NOT "only P2 and X reach n = 4" (an earlier version of this test tried
         exactly that, isolating W/Y/G here too): with 5 live candidates going into crash 1's own
         vote (P2 + W, Y, G, H) but [SendSV]'s own threshold needing only f + 1 = 4 of them, P2's
         OWN self-addressed vote is not guaranteed to be among the "first f + 1 to arrive" (Task
         3's own forward note -- see [try_send_dvc]'s own doc comment) -- confirmed live during
         this test's own development: P2's self-vote consistently arrived too late, and crash 1
         converged on n = 2 (one of the n = 2 ties among the OTHER four), not P2's own n = 4,
         exactly the kind of "not necessarily the objectively best log" case that note warns about.
         Making a MAJORITY (4 of 5) hold n = 4 instead of just P2 alone makes the outcome robust to
         that arrival-order sensitivity: ANY 4-of-5 subset of {P2, W, Y, G, H} necessarily includes
         at least 3 of the four n = 4 holders (only H holds n = 2), so [winning_dvc]'s own maximum-
         by-(last_normal_view, n) selection converges on n = 4 regardless of exactly which 4 DVCs
         [SendSV] happens to read first. *)
      isolate 7;
      Replica.propose original_primary a1;
      settle ();
      Replica.propose original_primary a2;
      settle ();

      (* Round 1b: ALSO isolate P2, W, Y, G (2, 4, 5, 6); primary 1 proposes 8 more, reaching ONLY
         X (3). X alone: n = 12. P2, W, Y, G all stay at n = 4 (frozen the moment they were
         isolated); H stays at n = 2 (isolated since round 1a, untouched here). *)
      isolate 2;
      isolate 4;
      isolate 5;
      isolate 6;
      List.iter
        (fun v ->
          Replica.propose original_primary v;
          settle ())
        b;

      (* Crash 1: isolate X (3) so it hears NONE of this episode's view-change traffic and stays
         parked at view 1 / last_normal_view 1 forever; reconnect P2, W, Y, G, H; stop primary 1. *)
      isolate 3;
      reconnect 2;
      reconnect 4;
      reconnect 5;
      reconnect 6;
      reconnect 7;
      stop 1;
      fire_check_timeout_repeatedly p2 ~times:3;
      fire_check_timeout_repeatedly w ~times:3;
      fire_check_timeout_repeatedly y ~times:3;
      fire_check_timeout_repeatedly g ~times:3;
      fire_check_timeout_repeatedly h ~times:3;
      settle ();

      (* Episode 1 genuinely completed -- verified, not assumed. Primary(2) = 1 + ((2-1) mod 7) =
         2 = P2, and among {P2, W, Y, G, H} (all still last_normal_view = 1 at this point) FOUR of
         the five (P2, W, Y, G) hold the identical, majority n = 4 log (only H differs, at n = 2),
         so P2 wins and becomes the new primary regardless of exactly which 4-of-5 DVCs
         [try_send_sv] happens to read first -- see this test's own top-of-file comment for why
         that majority construction, not "P2 alone holds the unique highest n", is what makes this
         outcome robust. *)
      let view_2 = 2 in
      Alcotest.(check int) "Primary(2) = 2 (P2) under a 7-replica cluster" 2
        (primary_of_view ~view:view_2 ~replica_count:7);
      Alcotest.(check bool) "P2 genuinely became the new primary" true (Replica.is_primary p2);
      List.iter
        (fun (name, r) ->
          Alcotest.(check int) (name ^ " reached view 2") view_2 (Replica.view_number r);
          Alcotest.(check bool) (name ^ " is genuinely Normal after episode 1") true (Replica.status r = Replica.Normal))
        [ ("P2", p2); ("W", w); ("Y", y); ("G", g); ("H", h) ];
      Alcotest.(check int) "P2's log was the episode-1 winner: still n = 4" 4 (Replica.op_number p2);
      List.iter
        (fun (name, r) -> Alcotest.(check int) (name ^ " adopted P2's n = 4 log via ReceiveSV") 4 (Replica.op_number r))
        [ ("W", w); ("Y", y); ("G", g); ("H", h) ];

      (* The divergence is built (X vs. everyone else). Verify it for real via the real accessors
         -- per this file's own "don't assume, verify" convention -- before relying on it for the
         crash-2 assertions below. *)
      let expected_x_log = base1 :: base2 :: a1 :: a2 :: b in
      let expected_group_log = [ base1; base2; a1; a2 ] in
      Alcotest.(check int) "X: op_number = 12 (the trap -- highest n in the cluster)" 12 (Replica.op_number x);
      Alcotest.(check int) "X: last_normal_view = 1 (never went through episode 1)" 1 (Replica.last_normal_view x);
      check_entries "X's log matches exactly what round 1's isolation pattern built" expected_x_log (Replica.entries x);
      List.iter
        (fun (name, r) ->
          Alcotest.(check int) (name ^ ": op_number = 4") 4 (Replica.op_number r);
          Alcotest.(check int) (name ^ ": last_normal_view = 2") 2 (Replica.last_normal_view r);
          check_entries (name ^ "'s log matches episode 1's winning log exactly") expected_group_log (Replica.entries r))
        [ ("W", w); ("Y", y); ("G", g); ("H", h) ];

      (* Crash 2, the view change under test: reconnect X (Y, G, H are already live -- reconnected
         at crash 1 above and never re-isolated since, so there is nothing left to reconnect for
         them here); stop P2.

         Deliberately NO [fire_check_timeout_repeatedly x]: X's own view_number is still 1 (it
         never went through episode 1, by design), so an ACTIVE check_timeout call on X here would
         bump it to v = 1 + 1 = 2 -- a STALE target NOBODY else is aiming for (W/Y/G/H are all at
         view_number = 2/Normal already, so THEIR check_timeout targets v = 3). X reaches v = 3 the
         ONLY way it can: PASSIVELY, via [ReceiveHigherSVC], adopting it from W/Y/G/H's own active
         v = 3 broadcasts once reconnected -- exactly the mechanism this function's own top-of-file
         comment explains. An earlier version of this test DID call check_timeout on X here, and
         while X still eventually reached v = 3 (proving the earlier assertions below), the delay
         from first chasing its own wrong v = 2 target shifted X's own DVC send late enough in the
         real delivery order that it was NOT among the first f + 1 = 4 DVCs [SendSV] read --
         confirmed live: the "select by n alone" mutation went completely undetected with that
         version, because [winning_dvc] never even got to see X's (1, 12) vote before firing. *)
      reconnect 3;
      stop 2;
      fire_check_timeout_repeatedly w ~times:3;
      fire_check_timeout_repeatedly y ~times:3;
      fire_check_timeout_repeatedly g ~times:3;
      fire_check_timeout_repeatedly h ~times:3;
      settle ();

      (* Primary(3) = 1 + ((3-1) mod 7) = 3 = X -- the replica holding the WRONG (trap) log ends up
         hosting the correct algorithm's own decision, which makes this a genuine test of the
         SELECTION, not an accident of who happens to already hold the right log. *)
      let view_3 = 3 in
      Alcotest.(check int) "Primary(3) = 3 (X)" 3 (primary_of_view ~view:view_3 ~replica_count:7);
      let survivors = [ ("X", x); ("W", w); ("Y", y); ("G", g); ("H", h) ] in
      List.iter
        (fun (name, r) ->
          Alcotest.(check int) (name ^ ": view_number advanced to 3") view_3 (Replica.view_number r);
          Alcotest.(check bool) (name ^ ": genuinely returned to Normal") true (Replica.status r = Replica.Normal);
          Alcotest.(check int) (name ^ ": last_normal_view advanced to 3") view_3 (Replica.last_normal_view r))
        survivors;
      Alcotest.(check bool) "X is the new primary" true (Replica.is_primary x);
      List.iter
        (fun (name, r) -> Alcotest.(check bool) (name ^ " is not the primary") false (Replica.is_primary r))
        [ ("W", w); ("Y", y); ("G", g); ("H", h) ];

      (* THE assertion this test exists for: every survivor adopted the (last_normal_view = 2,
         n = 4) group's log, exactly -- winning_dvc's own (last_normal_view, n) lexicographic
         maximum, last_normal_view FIRST -- NOT X's (last_normal_view = 1, n = 12) trap, despite
         X's log being three times longer. *)
      List.iter
        (fun (name, r) ->
          check_entries (name ^ "'s adopted log is exactly episode 1's winning log, not X's higher-n trap")
            expected_group_log (Replica.entries r))
        survivors)

let tests =
  [ ( "single primary failure: real view change over Sim_transport, committed data survives, a \
       new primary (verified against Primary(v), not assumed) resumes normal operation",
      `Quick,
      test_single_view_change_survives_primary_failure );
    ( "two sequential primary failures: two real view changes complete in turn, proving \
       svc_count's own reset discipline holds across repeated episodes, not just one",
      `Quick,
      test_two_sequential_view_changes );
    ( "F3 regression: two consecutive dead Primary-designates (a backup, then the primary) \
       permanently wedge a live-quorum cluster in View_change -- disclosed in \
       spec/tla/README.md's known-simplifications list; safety (committed data) unaffected \
       throughout",
      `Quick,
      test_two_dead_primary_designates_wedge_the_cluster_permanently );
    ( "F2 regression: winning_dvc selects by (last_normal_view, n) lexicographically over a REAL \
       cluster with genuinely divergent survivor logs (built via isolate/reconnect, not asserted \
       by construction) -- catches both the lexicographic-minimum mutation and the \
       select-by-n-alone historical bug class in one scenario",
      `Quick,
      test_winning_dvc_selects_by_last_normal_view_then_n_over_a_real_cluster )
  ]
