(* test/test_batch_commit_cluster.ml -- Task 3 of the atomic-multi-envelope-commit plan
   (.superpowers/sdd/2026-09-21-atomic-multi-envelope-commit/): the actual point of the whole
   plan, per this repo's own CLAUDE.md "no spec without running code" rule. Tasks 1-2 (already
   merged) built and unit-tested Riptide_batch_commit itself (propose/committed_envelopes)
   against a solo, single-replica cluster (replica_count = 1, f = 0) where IsCommitted is
   vacuously true and no real quorum/network is ever exercised. Neither of those proves that N
   related writes proposed as one batch actually commit atomically over a REAL multi-replica
   cluster, talking over a real (simulated) transport, with a primary crash injected mid-flight --
   that is what this file proves, by running the code, not by re-checking the unit tests again. *)

open Riptide
open Riptide_vsr
open Riptide_sim

let record_value name = Value.Record [ ("name", Value.Scalar (Value.String name)) ]
let fake_event_id name = Value.content_hash (Value.Scalar (Value.String name))

(* [Primary(v) == 1 + ((v-1) % ReplicaCount)] (VSR.tla:18), transcribed INDEPENDENTLY here rather
   than calling {!Replica.primary} -- matching test_vsr_replica_view_change.ml's own
   primary_of_view (and its own doc comment's reasoning): confirming the real cluster's emergent
   new primary against the formula itself, not against the very function under test. Euclidean
   modulo, exactly like replica.ml's own [primary]. *)
let primary_of_view ~view ~replica_count = 1 + (((view - 1) mod replica_count + replica_count) mod replica_count)

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
        let r =
          Replica.create ~my_id:(i + 1) ~replica_count ~svc_limit:3 ~send:(fun ~to_ bytes ->
              Sim_transport.send handles.(i) ~to_ bytes)
        in
        (* A freshly created replica starts at view_number = 0, where Primary(0) = replica_count
           (Euclidean modulo, not 1) -- so without this, replica 1 (my_id = 1) is NOT the primary
           and every test below's `let primary = replicas.(0)` assumption is false, silently
           no-op-ing every propose call. Matches test_vsr_replica_view_change.ml's own established
           convention (this harness is a trimmed copy of that file's with_cluster) of pinning every
           replica to view 1 so Primary(1) = 1 for any replica_count. *)
        Replica.for_test_set_view_number r 1;
        r)
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

let test_batch_commits_fully_despite_primary_crash_before_next_propose () =
  with_cluster ~replica_count:3 (fun ~replicas ~stop ~settle ->
      let primary = replicas.(0) in
      (* First batch: reaches real quorum (2 of 3) before anything crashes -- this is the batch
         under test. Real propose, real 3-node quorum, not the solo-replica shortcut Tasks 1-2's
         own unit tests use. *)
      Replica.propose primary (batch_value ~idempotency_key:"survives" [ "x"; "y" ]);
      settle ();
      (* DEVIATION FROM THE BRIEF (documented in task-3-report.md): a second, throwaway propose is
         needed here before the crash. This is real VSR mechanics, not a timing issue -- matches
         test_vsr_replica_view_change.ml's own established v1/v2 two-propose pattern for exactly
         the same reason its own top-of-file comment gives: a BACKUP's commit_number only ever
         advances via a LATER Prepare's own k field piggybacking on it (handle_prepare's
         [k > t.commit_number && k < op_number t] bound -- k = n is deliberately rejected, see that
         guard's own doc comment), never from the replication of the entry itself. After just the
         "survives" propose + settle above, ONLY the primary (which alone tracks PrepareOk quorum
         acks, see handle_prepare_ok) considers it committed; both backups have it fully replicated
         (op_number = 1) but commit_number still 0. Since the primary is about to be stopped and
         never participates in the view change's DoViewChange quorum, its own commit knowledge
         would be entirely lost -- try_send_sv's new commit_number is highest_commit_number over
         the SURVIVING DVCs only (replica.ml's own [highest_commit_number], fed by each backup's
         own [DoViewChange.k]) -- unless a backup's own commit_number was already advanced to 1
         beforehand via this filler propose's own Prepare (k = 1, piggybacking the primary's
         commit_number as of THIS second op). The filler batch's own writes are deliberately never
         asserted on below: only its side effect (piggybacking k = 1) is under test. *)
      Replica.propose primary (batch_value ~idempotency_key:"filler-to-piggyback-commit" [ "filler" ]);
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

      (* I1 fix (task-3 re-review): without these assertions, this test's own name is a lie --
         everything above (both the batch's commit AND the filler's piggyback) was already true
         BEFORE stop 1 / check_timeout / this settle () ever ran, so a silently no-op view change
         would leave every envelope/chain assertion below passing regardless. Assert the view
         change genuinely completed, matching test_vsr_replica_view_change.ml's own
         test_single_view_change_survives_primary_failure (its lines 336-354) exactly: the new
         primary is verified against Primary(v) recomputed independently, not assumed. *)
      let new_view = 2 in
      let expected_new_primary_id = primary_of_view ~view:new_view ~replica_count:3 in
      Alcotest.(check int)
        "Primary(2) = 2 -- computed independently, matching VSR.tla:18's own formula at v=2, \
         replica_count=3"
        2 expected_new_primary_id;
      let new_primary = replicas.(expected_new_primary_id - 1) in
      let other_survivor_id = List.find (fun id -> id <> 1 && id <> expected_new_primary_id) [ 2; 3 ] in
      let other_survivor = replicas.(other_survivor_id - 1) in
      Alcotest.(check int) "the new primary's own view_number genuinely advanced to 2" new_view
        (Replica.view_number new_primary);
      Alcotest.(check bool) "the replica Primary(2) names actually considers itself primary" true
        (Replica.is_primary new_primary);
      Alcotest.(check bool) "the new primary genuinely returned to Normal, not stuck mid-view-change"
        true (Replica.status new_primary = Replica.Normal);
      Alcotest.(check int) "the OTHER survivor's own view_number advanced to 2 as well" new_view
        (Replica.view_number other_survivor);
      Alcotest.(check bool) "the other survivor does not consider itself primary" false
        (Replica.is_primary other_survivor);
      Alcotest.(check bool) "the other survivor also genuinely returned to Normal" true
        (Replica.status other_survivor = Replica.Normal);

      (* I2 fix (task-3 re-review): a positive check that the crashed primary (replicas.(0))
         genuinely stopped participating -- without this, nothing in this test would fail if
         [stop 1] were a no-op (test 2's own stop 2/stop 3 already gets this strength for free,
         from its own zero-envelope assertion; test 1 needs it asserted explicitly). A replica
         whose dispatch fiber is truly dead cannot have received or reacted to any
         StartViewChange/DoViewChange/StartView traffic, so it must still be exactly where it was
         left: view 1, status Normal (it never even entered View_change itself -- only the
         SURVIVORS' own check_timeout calls did that, and this replica's dispatch fiber never ran
         to see them). *)
      Alcotest.(check int) "the crashed (stopped) old primary's own view_number is frozen at 1 -- \
                             it never processed any view-change traffic"
        1 (Replica.view_number replicas.(0));
      Alcotest.(check bool) "the crashed old primary's own status is still Normal -- it never even \
                              entered View_change, because its dispatch fiber is genuinely dead"
        true (Replica.status replicas.(0) = Replica.Normal);

      Array.iteri
        (fun i r ->
          if i <> 0 then begin
            let envelopes = Riptide_batch_commit.Batch_commit.committed_envelopes r in
            Alcotest.(check int)
              (Printf.sprintf "survivor %d: both writes from the surviving batch are present" (i + 1))
              2 (List.length envelopes);
            Alcotest.(check bool)
              (Printf.sprintf "survivor %d: the chain verifies" (i + 1))
              true (Log.verify_chain_list envelopes);
            (* I3 fix (task-3 re-review): verify_chain_list alone is self-consistent with whatever
               envelopes exist and says nothing about WHICH batch they came from -- combined with
               just a length-2 check, the filler batch's own envelope could in principle masquerade
               as part of the batch under test without this test noticing. Check the actual payload
               content and order, matching this file's own established
               `Value.Record [ ("name", Value.Scalar (Value.String name)) ]` unwrapping convention
               (test/test_batch_commit.ml:66-73/:164-167). *)
            let payload_name (e : Envelope.envelope) =
              match e.payload with
              | Value.Record [ ("name", Value.Scalar (Value.String name)) ] -> name
              | _ -> Alcotest.fail (Printf.sprintf "survivor %d: unexpected payload shape" (i + 1))
            in
            Alcotest.(check (list string))
              (Printf.sprintf "survivor %d: the envelopes are genuinely x then y from the survives \
                                batch, not the filler batch's own write" (i + 1))
              [ "x"; "y" ] (List.map payload_name envelopes)
          end)
        replicas)

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
      let envelopes = Riptide_batch_commit.Batch_commit.committed_envelopes primary in
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
