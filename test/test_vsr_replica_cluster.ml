(* test/test_vsr_replica_cluster.ml -- Task 2 of the VSR normal-case-replica plan: the actual
   point of this plan, per this repo's own CLAUDE.md "no spec without running code" rule.

   Every other VSR test in this suite (test_vsr_replica.ml) drives Replica.handle_message
   directly with hand-constructed, hand-encoded bytes -- useful for pinning down one guard/effect
   at a time, but it never proves that real replica processes, talking over a real transport, can
   actually reach agreement. This file does: three real Riptide_vsr.Replica.t instances, each
   wired to its own Sim_transport.t handle sharing one underlying (reliable-delivery)
   Riptide_sim.Network.t, each running its OWN receive-and-dispatch loop as its own Eio fiber --
   exactly the shape a real replica process's main loop would have. The only thing this test
   drives directly is Replica.propose (the client-facing entry point a real caller would use);
   everything else -- Prepare broadcast, PrepareOk reply, commit-number advancement -- happens
   because the replicas' own fibers received and processed real, encoded, transport-delivered
   messages, not because the test poked internal state.

   Per this plan's own Global Constraints, this cluster runs at Network.default_fault_config
   (reliable, immediate, single delivery) deliberately, NOT a lossy/reordering config: Task 1's
   replica has a known, disclosed gap against out-of-order or dropped Prepare messages (see
   replica.mli's own handle_message doc comment, "This is a real, disclosed liveness gap, not a
   defect") -- exercising that gap is out of this test's scope. *)

open Riptide
open Riptide_vsr
open Riptide_sim

(* Matches spec/tla/VSR.cfg's own ReplicaCount = 3, with a fixed primary = replica 1, matching
   VSR.tla's own Primary(0) = 1 formula (see replica.mli's own top-level comment on why callers
   just pass 1 directly rather than this module computing Primary(v) itself). *)
let replica_count = 3
let primary_id = 1

exception Cluster_test_done
(* Purely a control-flow signal to unwind Eio.Switch.run once a test body is done and its
   replicas' never-ending dispatch fibers (below) need to be torn down -- same pattern
   test_transport_shared.ml's own Tcp glue uses (Eio.Switch.fail + catching a dedicated
   exception) to end a switch whose forked fibers never return on their own. *)

(* A nontrivial Value.value shape (a Record wrapping a Sequence), not a bare scalar -- matching
   how the prior plan's own Task 2 (test_vsr_message.ml) exercised Message round-trips against
   non-trivial payloads rather than only ever proposing e.g. `Value.Scalar (Value.String "x")`. *)
let record_value name =
  Value.Record
    [ ("kind", Value.Scalar (Value.String name));
      ("payload", Value.Sequence [ Value.Scalar (Value.Int 1L); Value.Scalar (Value.Int 2L); Value.Scalar (Value.Int 3L) ])
    ]

(* Builds a fresh 3-replica cluster sharing one Sim_transport network (peer ids "1".."3",
   matching VSR.tla's own 1-indexed replica ids -- deliberately NOT Sim_transport.create_cluster's
   own convenience wrapper, which indexes peers 0..n-1 and would collide with that), starts each
   replica's own receive-and-dispatch fiber, runs [body], then tears the cluster's fibers down.

   [body]'s own [settle] argument is a bounded-round quiescence driver: alternates "delivers
   everything currently scheduled" (Network.pump_one, looped) with "yield so woken
   receive-loop fibers can actually run and, in turn, schedule their own replies"
   (Eio.Fiber.yield) until a round finds nothing left to deliver. This mirrors the
   test_interleaving_with_active_fault_injection_is_deterministic precedent in
   test_sim_network.ml (pump then yield, so genuinely suspended fibers get to run), generalized
   into a loop because that test's driver already knew its own fixed message count where this
   one doesn't. A round budget (not an unconditional loop) is a deliberate safety net against a
   genuine non-termination bug, not a magic number tuned to any one test's message count: normal-
   case VSR traffic in this module's scope is acyclic (Prepare -> PrepareOk, nothing further), so
   real runs converge within 2-3 rounds per proposed value; 20 is generous headroom. *)
let with_cluster (body : replicas:Replica.t array -> settle:(unit -> unit) -> unit) =
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
        Replica.create ~my_id ~replica_count ~primary_id ~send:(fun ~to_ bytes ->
            Sim_transport.send handles.(i) ~to_ bytes))
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
  try
    Eio.Switch.run (fun sw ->
        Array.iteri
          (fun i replica ->
            Eio.Fiber.fork ~sw (fun () ->
                (* This IS a real replica process's main loop, run as a fiber: block for the next
                   message, dispatch it, repeat -- the exact shape replica.mli's own doc comment
                   sketches. Never returns on its own; torn down via Eio.Switch.fail below. *)
                let rec dispatch_loop () =
                  let msg = Sim_transport.receive handles.(i) in
                  Replica.handle_message replica msg;
                  dispatch_loop ()
                in
                dispatch_loop ()))
          replicas;
        body ~replicas ~settle;
        Eio.Switch.fail sw Cluster_test_done)
  with Cluster_test_done -> ()

(* A minimal, test-only pretty-printer -- Value.value has no pp/show of its own (nothing in
   lib/value.mli needs one outside test diagnostics), just enough structure to make an Alcotest
   failure diff actually legible instead of a bare "Expected: true / Received: false". *)
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

(* ---- Step 4: single propose -- replication, primary commit, and the backup-commit-lag question
   ---- *)

(* Answers the brief's own open question empirically rather than guessing at it: does a backup's
   commit_number genuinely need a SECOND Prepare to piggyback on (per ReceivePrepareMsg's own
   k-field-driven advancement, replica.mli:171-178) before it advances past 0, even once the
   value itself is safely replicated to a majority?

   This test proves the answer is YES, by direct observation of running code, not by reasoning
   about the spec in the abstract: after proposing exactly ONE value and letting the cluster fully
   quiesce, every replica's log holds the value (real replication happened) and the PRIMARY's own
   commit_number has advanced to 1 (it learns this itself, from inside ReceivePrepareOkMsg, the
   moment a quorum of PrepareOk replies arrives -- no further Prepare needed for the primary).
   But BOTH backups' commit_number is still 0 at this point -- not because replication failed
   (their log already holds the value), but because the only avenue by which a backup's
   commit_number can ever move at all is a Prepare's own k field (ReceivePrepareMsg,
   replica.mli:171-178), and the one Prepare this test has sent so far necessarily carried k=0
   (the primary's own commit_number at the moment IT was broadcast, which was before any
   PrepareOk had come back). This is Task 1's own explicit, spec-faithful design, not a bug this
   test papers over: VSR's normal-case protocol has no separate "commit" message in this module's
   scope (see spec/tla/README.md) -- commit confirmation ONLY ever piggybacks on a later Prepare's
   k field, so a backup genuinely has no way to learn "op 1 is committed" until either the client
   submits a second request or some other mechanism (heartbeat Prepare, out of this plan's scope)
   sends one.

   The second half of this test resolves the question the other way too: propose a SECOND value,
   whose own Prepare carries k=1 (the primary's now-advanced commit_number) -- and confirm this
   really does advance both backups' commit_number to 1, exactly as the mechanism above predicts,
   not to 2 (the second value's own op-number) -- because ITS OWN commit confirmation has, by the
   same logic, not yet piggybacked onto any further Prepare. *)
let test_single_propose_replicates_then_second_propose_advances_backup_commit () =
  with_cluster (fun ~replicas ~settle ->
      let primary = replicas.(0) and backup2 = replicas.(1) and backup3 = replicas.(2) in
      let v1 = record_value "v1" in
      Replica.propose primary v1;
      settle ();
      (* Real replication: every replica's log -- populated purely by real Prepare messages its
         own dispatch fiber received and processed, not by test-poked state -- holds v1 at op 1. *)
      Array.iteri
        (fun i r -> check_entries (Printf.sprintf "replica %d's log holds v1 at op 1" (i + 1)) [ v1 ] (Replica.entries r))
        replicas;
      Alcotest.(check int) "primary commit_number advances to 1 from PrepareOk replies alone" 1
        (Replica.commit_number primary);
      Alcotest.(check bool) "primary considers v1 committed" true (Replica.is_committed primary v1);
      (* THE FINDING: both backups' commit_number is still 0, even though v1 is safely replicated
         to a real majority (all 3 replicas, well over the f=1 quorum) and the primary itself has
         already committed. This is the legitimate, by-design lag, not a bug -- see this test's
         own doc comment above. *)
      Alcotest.(check int) "backup 2's commit_number has NOT advanced yet -- no second Prepare has \
                             arrived to piggyback k=1 on"
        0 (Replica.commit_number backup2);
      Alcotest.(check int) "backup 3's commit_number has NOT advanced yet, for the same reason" 0
        (Replica.commit_number backup3);
      Alcotest.(check bool) "backup 2 does NOT yet consider v1 committed, despite holding it in its own log"
        false (Replica.is_committed backup2 v1);
      Alcotest.(check bool) "backup 3 does NOT yet consider v1 committed either" false (Replica.is_committed backup3 v1);
      (* Trigger the mechanism directly: propose a second value. Its own Prepare necessarily
         carries k = primary's current commit_number = 1, which is exactly what's needed to
         unstick the backups' commit_number per ReceivePrepareMsg's own k-field logic. *)
      let v2 = record_value "v2" in
      Replica.propose primary v2;
      settle ();
      Array.iteri
        (fun i r ->
          check_entries (Printf.sprintf "replica %d's log now holds v1 then v2, in order" (i + 1)) [ v1; v2 ]
            (Replica.entries r))
        replicas;
      Alcotest.(check int) "primary commit_number now advances to 2 (its own second quorum)" 2
        (Replica.commit_number primary);
      Alcotest.(check int)
        "backup 2's commit_number NOW advances, to 1 -- via v2's own Prepare piggybacking k=1, \
         confirming the mechanism directly, not to 2 (v2's own commit hasn't itself piggybacked \
         onto anything yet)"
        1 (Replica.commit_number backup2);
      Alcotest.(check int) "backup 3's commit_number advances identically, to 1" 1 (Replica.commit_number backup3);
      Alcotest.(check bool) "backup 2 now considers v1 committed" true (Replica.is_committed backup2 v1);
      Alcotest.(check bool) "backup 2 still does NOT consider v2 committed (same lag, one value later)"
        false (Replica.is_committed backup2 v2))

(* ---- Step 5: multiple values in sequence -- log convergence, and the same lag pattern
   generalized ---- *)

(* Proposes 4 values in sequence (settling fully between each, so each step's cause and effect
   stay unambiguous), and confirms two things a single-value test can't: (a) every replica's log
   converges to the SAME content, in the SAME order, not just "contains the right values"; and
   (b) the backup-commit-lag finding from the test above generalizes -- UNDER THIS TEST'S OWN
   settle-after-every-propose PATTERN SPECIFICALLY, not as a general protocol invariant: with N
   values proposed one at a time, each fully settled before the next is proposed, the primary is
   fully committed (commit_number = N) while both backups are exactly ONE behind (commit_number =
   N-1), because the Nth value's own commit confirmation has, by construction, never piggybacked
   onto any (N+1)th Prepare. This "lag by exactly one" shape is an artifact of proposing and
   settling one value at a time -- it is NOT a property of the protocol itself: proposing several
   values in a row BEFORE settling produces a different, larger lag (e.g. batching 4 proposals
   before one settle leaves both backups at commit_number = 0 while the primary reaches 4, since
   none of the intervening Prepares had a chance to be individually observed and piggybacked on
   in turn) -- do not read this test as proving "backups always lag by one" in general. *)
let test_multiple_proposes_converge_with_backups_lagging_by_exactly_one () =
  with_cluster (fun ~replicas ~settle ->
      let primary = replicas.(0) and backup2 = replicas.(1) and backup3 = replicas.(2) in
      let values = List.init 4 (fun i -> record_value (Printf.sprintf "seq-%d" (i + 1))) in
      List.iter
        (fun v ->
          Replica.propose primary v;
          settle ())
        values;
      Array.iteri
        (fun i r -> check_entries (Printf.sprintf "replica %d's log converges to all 4 values, in order" (i + 1)) values (Replica.entries r))
        replicas;
      check_entries "backup 2's log is IDENTICAL to the primary's, not just overlapping" (Replica.entries primary)
        (Replica.entries backup2);
      check_entries "backup 3's log is IDENTICAL to the primary's too" (Replica.entries primary) (Replica.entries backup3);
      Alcotest.(check int) "primary is fully committed: commit_number = 4, all 4 proposed values" 4
        (Replica.commit_number primary);
      Alcotest.(check int)
        "backup 2 lags by exactly one UNDER THIS TEST'S settle-after-every-propose PATTERN, per \
         the mechanism this file's other test isolates: commit_number = 3, not 4 (the 4th value's \
         own commit confirmation never piggybacked onto a 5th Prepare that was never sent) and not \
         some other value (each step only ever advances by exactly what its OWN Prepare's k field \
         carried) -- this specific '-1' lag is a consequence of settling between each propose, not \
         a general protocol property (batching proposals before settling produces a different lag)"
        3 (Replica.commit_number backup2);
      Alcotest.(check int) "backup 3 lags identically, by exactly one, under this same settle-per-propose pattern" 3
        (Replica.commit_number backup3);
      List.iteri
        (fun i v ->
          let n = i + 1 in
          Alcotest.(check bool) (Printf.sprintf "primary considers seq-%d committed" n) true (Replica.is_committed primary v);
          if n <= 3 then begin
            Alcotest.(check bool) (Printf.sprintf "backup 2 considers seq-%d committed" n) true (Replica.is_committed backup2 v);
            Alcotest.(check bool) (Printf.sprintf "backup 3 considers seq-%d committed" n) true (Replica.is_committed backup3 v)
          end
          else begin
            Alcotest.(check bool) (Printf.sprintf "backup 2 does NOT yet consider seq-%d committed" n) false
              (Replica.is_committed backup2 v);
            Alcotest.(check bool) (Printf.sprintf "backup 3 does NOT yet consider seq-%d committed" n) false
              (Replica.is_committed backup3 v)
          end)
        values)

let tests =
  [ ( "single propose: real replication over Sim_transport, primary commits, backup commit-lag \
       finding proven and then resolved by a second propose",
      `Quick,
      test_single_propose_replicates_then_second_propose_advances_backup_commit );
    ( "multiple sequential proposes: logs converge identically across all 3 replicas, backups lag \
       the primary's commit_number by exactly one throughout",
      `Quick,
      test_multiple_proposes_converge_with_backups_lagging_by_exactly_one )
  ]
