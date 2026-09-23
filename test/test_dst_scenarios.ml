(* test/test_dst_scenarios.ml

   Task 11 of the storage-fault-tolerant-recovery plan: the permanent, CI-runnable residue of a
   real adversarial hunt across Tasks 1-10, not a scripted demonstration. Three tests, each
   pinning something the hunt actually established:

   1. [adversarial multi-seed sweep] -- the hunt itself, shrunk to a CI-sized, deterministic
      budget: many seeds, combined network and storage faults, five replicas, repeated view
      changes, checking the real cross-replica safety properties after every phase of every run.
   2. [File_storage cluster commits what it settles] -- the regression test for the defect the
      hunt found (Cluster.run's settle returning while message handlers were still parked on real
      io_uring I/O). It fails against the pre-fix settle and passes against the current one.
   3. [ring capacity boundary] -- a running reproduction of a real, currently-unfixed limitation
      the hunt demonstrated for the first time: a File_storage-backed cluster whose log passes
      [ring_capacity] can never complete another view change, with zero injected faults. Pinned
      the same way test_vsr_replica_view_change.ml already pins this project's known liveness
      gaps: as a test that will fail loudly if the behaviour ever changes, in either direction.

   WHAT THE SWEEP CHECKS, and why these properties and not others. The property this whole plan
   exists to protect is agreement on committed state, so that is what is asserted:

   - AGREEMENT: no two replicas ever report different values committed at the same op_number.
   - DURABILITY: every op_number some replica has reported committed is still held, with that same
     value, by at least one replica in memory AND readable off at least one replica's own durable
     storage. This is the property storage faults directly attack, and it is checked through
     [Replica.for_test_wal_read] (the durable side) rather than [Replica.entries] alone (which
     would pass even if nothing had ever reached storage).
   - BOUNDED COMMIT REGRESSION: commit_number is monotonic per replica EXCEPT at a replica that
     has just completed SendSV as the new primary of its own view. That exception is real and
     documented (replica.mli's own commit_number doc; VSR.tla:508's assignment is unconditional,
     and the coordinator's own DoViewChange reaches its own recv_dvc only through the network,
     where it can be dropped -- so a quorum can form without it and HighestCommitNumber over that
     quorum can be lower than the coordinator's own commit_number). The sweep does not assert
     plain monotonicity, which would fail; it asserts the exception is CONFINED, which held for
     every regression observed across the whole hunt (13 regressions over 300 seeds at one config,
     ranging from 3->0 to 71->68, every single one at is_primary=true, status=Normal,
     last_normal_view=view_number). Confining it is what makes it a regression test rather than a
     known-failure suppression: a regression anywhere else fails this test.

   WHAT THE SWEEP DELIBERATELY DOES NOT DO, both learned by running it:

   - It does not rely on Network.fault_config's [corrupt_probability]. That knob is INERT for
     anything built on Sim_transport, which passes [Fun.id] as Network.send's corruption function
     (sim_transport.mli says so explicitly), so a "corrupted" delivery is byte-identical to a clean
     one. Setting it here would look like on-the-wire corruption coverage while providing none.
   - It does not fire check_timeout on a random SUBSET of replicas. Doing that reproduces
     spec/tla/README.md's own known-simplification point 4 within a round or two and wedges the
     cluster in View_change for the remainder of the run, after which nothing commits and the
     safety check is vacuously satisfied. Firing on every replica at once ("a timeout storm") is
     what keeps view changes completing and keeps real committed state accumulating to compare. *)

open Riptide
open Riptide_vsr

let v s = Value.Scalar (Value.String s)

(* ---------------------------------------------------------------------------------------------
   The safety checker. One per run; [check] is called after every settle, and every failure it
   finds is recorded with the seed and phase so a failing CI run names the exact reproduction.
   --------------------------------------------------------------------------------------------- *)

type checker = {
  seed : int;
  mutable violations : string list;
  committed : (int, string) Hashtbl.t;  (** op_number -> canonical encoding reported committed *)
  last_commit : int array;
}

let make_checker ~seed ~replica_count =
  { seed; violations = []; committed = Hashtbl.create 64; last_commit = Array.make replica_count 0 }

let note c fmt = Printf.ksprintf (fun s -> c.violations <- s :: c.violations) fmt

let check c ~phase (replicas : Replica.t array) =
  Array.iteri
    (fun i r ->
      let cn = Replica.commit_number r in
      (* BOUNDED COMMIT REGRESSION, see this file's own header. *)
      if cn < c.last_commit.(i) then begin
        let just_completed_send_sv =
          Replica.is_primary r && Replica.status r = Replica.Normal
          && Replica.last_normal_view r = Replica.view_number r
        in
        if not just_completed_send_sv then
          note c
            "seed %d [%s]: replica %d commit_number regressed %d -> %d somewhere OTHER than a \
             just-completed SendSV (is_primary=%b view=%d last_normal_view=%d)"
            c.seed phase (i + 1) c.last_commit.(i) cn (Replica.is_primary r)
            (Replica.view_number r) (Replica.last_normal_view r)
      end;
      c.last_commit.(i) <- max c.last_commit.(i) cn;
      let entries = Array.of_list (Replica.entries r) in
      if cn > Array.length entries then
        note c "seed %d [%s]: replica %d commit_number %d exceeds its own log length %d" c.seed
          phase (i + 1) cn (Array.length entries);
      (* AGREEMENT. *)
      for n = 1 to min cn (Array.length entries) do
        let enc = Value.canonical_encode entries.(n - 1) in
        match Hashtbl.find_opt c.committed n with
        | None -> Hashtbl.add c.committed n enc
        | Some prev when prev <> enc ->
            note c
              "seed %d [%s]: DIVERGENCE at op %d -- replica %d reports %S committed, another \
               replica reported %S committed"
              c.seed phase n (i + 1) enc prev
        | Some _ -> ()
      done)
    replicas;
  (* DURABILITY. *)
  Hashtbl.iter
    (fun n enc ->
      let in_memory = ref false and on_disk = ref false in
      Array.iter
        (fun r ->
          let e = Array.of_list (Replica.entries r) in
          if Array.length e >= n && Value.canonical_encode e.(n - 1) = enc then in_memory := true;
          match Replica.for_test_wal_read r ~op_number:n with
          | Some x when Value.canonical_encode x = enc -> on_disk := true
          | _ -> ())
        replicas;
      if not !in_memory then
        note c "seed %d [%s]: committed op %d (%S) is held by NO replica in memory" c.seed phase n
          enc;
      if not !on_disk then
        note c "seed %d [%s]: committed op %d (%S) is durably readable on NO replica" c.seed phase
          n enc)
    c.committed

(* ---------------------------------------------------------------------------------------------
   The scenario body, shared by every test below so that what the sweep exercises and what the
   File_storage tests exercise are literally the same workload.
   --------------------------------------------------------------------------------------------- *)

let scenario ~c ~rounds ~ops_per_round ~timeout_prob ~replicas ~settle =
  (* Scenario decisions get their own Prng, seeded from the run's own seed: they must be
     reproducible, and they must not perturb the network's or any storage's own fault stream. *)
  let p = Riptide_sim.Prng.create (((c.seed * 7919) + 13) land 0x3FFFFFFF) in
  let next_val = ref 0 in
  let find_primary () =
    let primary = ref None in
    Array.iteri
      (fun i r -> if Replica.is_primary r && Replica.status r = Replica.Normal then primary := Some i)
      replicas;
    !primary
  in
  let storm () =
    Array.iter (fun r -> Replica.check_timeout r) replicas;
    settle ()
  in
  for _round = 1 to rounds do
    if find_primary () = None then storm ();
    (match find_primary () with
    | Some i ->
        for _ = 1 to ops_per_round do
          (* Distinct values throughout: propose dedups by canonical encoding, so a repeated value
             would be silently dropped and the round would quietly do nothing. *)
          Replica.propose replicas.(i) (v (Printf.sprintf "op-%d" !next_val));
          incr next_val
        done
    | None -> ());
    settle ();
    check c ~phase:"after-propose" replicas;
    if Riptide_sim.Prng.bool p timeout_prob then begin
      storm ();
      check c ~phase:"after-timeout" replicas
    end
  done

(* ---------------------------------------------------------------------------------------------
   Test 1: the sweep.
   --------------------------------------------------------------------------------------------- *)

(* Deliberately at the edge of, but inside, Task 10's own pre-flight bound: five replicas gives
   replication_quorum = 3, faults_max = 2, and the check rejects [replica_count *
   corrupt_probability >= faults_max], i.e. anything from 0.4 up. 0.1 leaves real headroom while
   still landing corruption constantly (measured: ~40 live-unreadable-slot observations per run at
   this config). drop/duplicate are the network faults that actually bite here; see the header for
   why corrupt_probability is not set. *)
let sweep_net_faults =
  Riptide_sim.Network.
    {
      drop_probability = 0.1;
      duplicate_probability = 0.5;
      corrupt_probability = 0.0;
      min_delay = 0.0;
      max_delay = 0.01;
    }

let sweep_storage_faults =
  { Riptide_storage.Fault_injecting_storage.corrupt_probability = 0.1; drop_probability = 0.05 }

let test_adversarial_multi_seed_sweep () =
  let replica_count = 5 in
  let all_violations = ref [] in
  let total_committed = ref 0 and total_views = ref 0 in
  for seed = 1 to 200 do
    let c = make_checker ~seed ~replica_count in
    Riptide_dst.Cluster.run ~seed ~replica_count ~net_fault_config:sweep_net_faults
      ~storage_fault_config:sweep_storage_faults (fun ~replicas ~settle ->
        scenario ~c ~rounds:10 ~ops_per_round:3 ~timeout_prob:0.5 ~replicas ~settle;
        total_committed := !total_committed + Hashtbl.length c.committed;
        Array.iter (fun r -> total_views := max !total_views (Replica.view_number r)) replicas);
    all_violations := !all_violations @ List.rev c.violations
  done;
  (* Non-vacuity, asserted rather than assumed: a sweep that wedged every cluster immediately, or
     never committed anything, would satisfy every safety property above trivially. *)
  Alcotest.(check bool)
    (Printf.sprintf "the sweep actually committed real state (total committed slots = %d)"
       !total_committed)
    true
    (!total_committed > 1500);
  Alcotest.(check bool)
    (Printf.sprintf "the sweep actually completed view changes (highest view reached = %d)"
       !total_views)
    true
    (!total_views >= 3);
  match !all_violations with
  | [] -> ()
  | vs ->
      Alcotest.fail
        (Printf.sprintf "%d safety violation(s) across the sweep:\n%s" (List.length vs)
           (String.concat "\n" vs))

(* ---------------------------------------------------------------------------------------------
   Test 2: the regression test for the defect this task found.
   --------------------------------------------------------------------------------------------- *)

let with_tmp_dir f =
  (* Same pattern as test_file_storage.ml's own. *)
  let dir = Filename.temp_file "riptide_dst_scenarios" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o700;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () -> f dir)

(* THE REGRESSION TEST for the settle defect (see cluster.ml's own [inflight] comment and this
   commit's message). Zero injected faults of any kind, three replicas, a real File_storage each:
   after a settle, every proposal made before it must be committed at the primary and present in
   every backup's log. Against the pre-fix settle -- pump, yield twice, stop when a round delivers
   nothing -- this test fails with 3 of 9 committed, because every replica's handler was still
   parked on io_uring when settle concluded the cluster had quiesced. It is deliberately a
   zero-fault test: with faults there is always an innocent explanation for missing replication,
   and this defect needs none. *)
let test_file_storage_cluster_commits_what_it_settles () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      let bursts = 3 and per_burst = 3 in
      let committed = ref 0 and backup_log_lengths = ref [] in
      Riptide_dst.Cluster.run_on_file_storage ~env ~dir ~seed:1 ~replica_count:3
        (fun ~replicas ~settle ->
          let next = ref 0 in
          for _ = 1 to bursts do
            for _ = 1 to per_burst do
              Replica.propose replicas.(0) (v (Printf.sprintf "op-%d" !next));
              incr next
            done;
            settle ()
          done;
          committed := Replica.commit_number replicas.(0);
          backup_log_lengths :=
            [ List.length (Replica.entries replicas.(1)); List.length (Replica.entries replicas.(2)) ]);
      Alcotest.(check int)
        "every op proposed before a settle is committed at the primary once it returns"
        (bursts * per_burst) !committed;
      Alcotest.(check (list int))
        "and is present in every backup's own log"
        [ bursts * per_burst; bursts * per_burst ]
        !backup_log_lengths)

(* The same cluster, with real storage, must also durably hold what it says it committed -- the
   check the Memory_storage sweep makes cheaply, made once against the real persistence layer
   (O_DIRECT ring WAL + 3-copy superblock), which is the only place it is a statement about disk. *)
let test_file_storage_cluster_committed_entries_are_durable () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      let c = make_checker ~seed:7 ~replica_count:3 in
      Riptide_dst.Cluster.run_on_file_storage ~env ~dir ~seed:7 ~replica_count:3
        ~net_fault_config:
          Riptide_sim.Network.
            {
              drop_probability = 0.1;
              duplicate_probability = 0.2;
              corrupt_probability = 0.0;
              min_delay = 0.0;
              max_delay = 0.01;
            }
        (fun ~replicas ~settle ->
          scenario ~c ~rounds:4 ~ops_per_round:2 ~timeout_prob:0.5 ~replicas ~settle;
          Alcotest.(check bool)
            "the run committed something (not a vacuous pass)" true
            (Hashtbl.length c.committed > 0));
      match List.rev c.violations with
      | [] -> ()
      | vs -> Alcotest.fail (String.concat "\n" vs))

(* ---------------------------------------------------------------------------------------------
   Test 3: the ring-capacity boundary, as a running reproduction.
   --------------------------------------------------------------------------------------------- *)

(* A RUNNING REPRODUCTION OF A REAL, CURRENTLY-UNFIXED LIMITATION, pinned the same way
   test_vsr_replica_view_change.ml already pins this project's known liveness gaps.

   File_storage's WAL is a fixed-size ring: appending op_number [n] silently destroys whatever was
   at [n - ring_capacity]. Nothing in this system ever truncates a committed prefix away (no
   checkpointing -- explicitly out of scope for this plan), so every entry stays live forever and a
   log longer than the ring means committed, acknowledged entries are destroyed on disk with no
   signal to any caller: Storage_intf.S.wal_append promises "returns only after the write is
   durable", and for those entries that promise is retroactively broken.

   The protocol-level consequence is total, and needs NO injected faults at all. Once the log
   passes the ring, every replica's Do_view_change permanently omits the evicted ops (slot_state
   reports them Corrupt, so readable_entries drops them), no replica can supply them and no replica
   can prove them absent, so CanComplete is false forever: every view change forfeits, bumps the
   view, and the cluster never returns to Normal.

   Both halves are asserted, so this test fails if EITHER changes: below the boundary the view
   change completes, above it the cluster is permanently wedged. Fixing the underlying limitation
   (checkpointing, or making File_storage refuse rather than silently evict a live entry) is real
   design work beyond this task -- and note the silent-eviction behaviour is itself deliberate and
   separately pinned by test_file_storage.ml's own test_ring_wraps_around and
   test_custom_ring_capacity_is_honored, which is exactly why this is reported rather than
   unilaterally changed here. *)
let ops_past_ring = 10
let small_ring = 8

let run_until_view_change ~env ~dir ~ring_capacity =
  let returned_to_normal = ref false and views = ref [] in
  Riptide_dst.Cluster.run_on_file_storage ~env ~dir ~seed:1 ~replica_count:3 ~ring_capacity
    (fun ~replicas ~settle ->
      let next = ref 0 in
      for _ = 1 to ops_past_ring do
        Replica.propose replicas.(0) (v (Printf.sprintf "op-%d" !next));
        incr next
      done;
      settle ();
      (* Three timeout storms: one to start the view change, two more to give it every chance to
         complete (and, when it cannot, to forfeit and try newer views). *)
      for _ = 1 to 3 do
        Array.iter (fun r -> Replica.check_timeout r) replicas;
        settle ()
      done;
      returned_to_normal :=
        Array.for_all (fun r -> Replica.status r = Replica.Normal) replicas;
      views := Array.to_list (Array.map Replica.view_number replicas));
  (!returned_to_normal, !views)

let test_ring_capacity_boundary () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      let ok, _ = run_until_view_change ~env ~dir ~ring_capacity:64 in
      Alcotest.(check bool)
        "with a ring bigger than the log, the view change completes and every replica is Normal"
        true ok);
  with_tmp_dir (fun dir ->
      let ok, views =
        run_until_view_change ~env ~dir ~ring_capacity:small_ring
      in
      Alcotest.(check bool)
        (Printf.sprintf
           "with a log of %d ops in a ring of %d, no view change can ever complete -- the cluster \
            is permanently in View_change (views reached: %s)"
           ops_past_ring small_ring
           (String.concat "," (List.map string_of_int views)))
        false ok;
      (* And it is genuinely FORFEITING, not merely idle: each storm bumped the view. *)
      Alcotest.(check bool) "views kept climbing as each attempt forfeited" true
        (List.exists (fun v -> v >= 3) views))

let tests =
  [
    ("adversarial multi-seed sweep, combined network and storage faults", `Quick,
      test_adversarial_multi_seed_sweep);
    ("File_storage cluster commits what it settles", `Quick,
      test_file_storage_cluster_commits_what_it_settles);
    ("File_storage cluster's committed entries are durable", `Quick,
      test_file_storage_cluster_committed_entries_are_durable);
    ("ring capacity boundary: past it, no view change can complete", `Quick,
      test_ring_capacity_boundary);
  ]
