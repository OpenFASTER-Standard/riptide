(* test/test_dst_scenarios.ml

   Task 11 of the storage-fault-tolerant-recovery plan: the permanent, CI-runnable residue of a
   real adversarial hunt across Tasks 1-10, not a scripted demonstration. Seven tests, each
   pinning something the hunt actually established:

   1. [adversarial multi-seed sweep] -- the hunt itself, shrunk to a CI-sized, deterministic
      budget: many seeds, combined network and storage faults, five replicas, repeated view
      changes, checking the real cross-replica safety properties after every phase of every run.
   2. [same sweep, longer horizon] -- the same faults over three times the horizon, reaching much
      higher views and much longer logs. This is where the commit-regression exception below is
      exercised at scale rather than on a handful of observations.
   3. [commit-regression guard rejects a steady-state regression] -- the negative control for that
      exception, proving it actually discriminates rather than excusing everything.
   4. [File_storage cluster commits what it settles] -- the regression test for the defect the
      hunt found (Cluster.run's settle returning while message handlers were still parked on real
      io_uring I/O). It fails against the pre-fix settle and passes against the current one.
   5. [File_storage cluster's committed entries are durable] -- the same safety properties against
      the real persistence layer rather than Memory_storage.
   6. [ring capacity boundary] -- a running reproduction of a real, currently-unfixed limitation
      the hunt demonstrated for the first time: a File_storage-backed cluster whose log passes
      [ring_capacity] can never complete another view change, with zero injected faults. Pinned
      the same way test_vsr_replica_view_change.ml already pins this project's known liveness
      gaps: as a test that will fail loudly if the behaviour ever changes, in either direction.
   7. [wire payload corruption] -- a running reproduction of the most severe gap the hunt found: a
      single flipped payload byte retroactively destroys an acknowledged write cluster-wide. Also
      pinned rather than fixed, for the governance reason stated at the test itself.

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
     plain monotonicity, which would fail (measured: 3 real regressions across test 1's own 200
     seeds); it asserts the exception is CONFINED. Confining it is what makes this a regression
     test rather than a known-failure suppression: a regression anywhere else fails these tests.

     HOW THE EXCEPTION IS PHRASED, and why it was rephrased (Task 11 review follow-up). It used to
     read [is_primary && status = Normal && last_normal_view = view_number]. That last conjunct is
     VACUOUS -- [status = Normal => last_normal_view = view_number] is an invariant of the protocol
     itself (replica.ml:389-391 records a TLC run of exactly that invariant over a copy of VSR.tla
     with ZERO violations across 264,376 distinct reachable states), so the condition reduced to
     "any primary in Normal", i.e. that primary's ORDINARY STEADY STATE rather than the narrow
     post-view-change window it claimed to describe. It is now a TRANSITION test instead -- the
     replica must have become primary of a strictly NEWER view than it had at the previous check --
     which a steady-state primary never satisfies. Test 3 is the negative control that proves the
     distinction is real (it fails against the old condition), and tests 1 and 2 both assert the
     exception actually FIRED, so it can never silently rot back into a guard that documents a
     property nothing exercises.

   WHAT THE SWEEP DELIBERATELY DOES NOT DO, both learned by running it:

   - It does not set Network.fault_config's [corrupt_probability]. That knob used to be INERT for
     anything built on Sim_transport (which hard-coded [Fun.id] as Network.send's corruption
     function), but is not any more: Sim_transport now takes the transformation as a parameter and
     Cluster supplies a real one-byte flip, so setting it here would inject genuine on-the-wire
     corruption. It is left at 0 because that corruption breaks agreement outright -- it is not a
     fault this protocol tolerates, so mixing it into a sweep whose job is to hunt for UNKNOWN
     safety violations would just drown the sweep in one known one. It gets its own test (7).
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
  prev_view : int array;
      (** Each replica's view_number as of the PREVIOUS call to [check] ([-1] before the first).
          This is what makes the commit-regression exception below a real transition test rather
          than a state test — see this file's header. *)
  mutable excused_regressions : int;
      (** How many times the exception actually fired. Every caller asserts on this, in one
          direction or the other, so the exception can never silently become dead code again. *)
}

let make_checker ~seed ~replica_count =
  {
    seed;
    violations = [];
    committed = Hashtbl.create 64;
    last_commit = Array.make replica_count 0;
    prev_view = Array.make replica_count (-1);
    excused_regressions = 0;
  }

let note c fmt = Printf.ksprintf (fun s -> c.violations <- s :: c.violations) fmt
let status_str = function Replica.Normal -> "Normal" | Replica.View_change -> "View_change"

let contains ~needle s =
  let n = String.length needle and m = String.length s in
  let rec at i = i + n <= m && (String.sub s i n = needle || at (i + 1)) in
  at 0

let check c ~phase (replicas : Replica.t array) =
  Array.iteri
    (fun i r ->
      let cn = Replica.commit_number r in
      let view = Replica.view_number r in
      (* BOUNDED COMMIT REGRESSION, see this file's own header. The exception is a TRANSITION
         test: this replica must have BECOME the primary of a strictly newer view since the
         previous check, which is exactly what completing SendSV means and what an ordinary
         steady-state primary never does. *)
      if cn < c.last_commit.(i) then begin
        let just_completed_send_sv =
          Replica.is_primary r && Replica.status r = Replica.Normal && view > c.prev_view.(i)
        in
        if just_completed_send_sv then c.excused_regressions <- c.excused_regressions + 1
        else
          note c
            "seed %d [%s]: replica %d commit_number regressed %d -> %d somewhere OTHER than a \
             just-completed SendSV (is_primary=%b status=%s view=%d prev_view=%d)"
            c.seed phase (i + 1) c.last_commit.(i) cn (Replica.is_primary r)
            (status_str (Replica.status r))
            view c.prev_view.(i)
      end;
      c.prev_view.(i) <- view;
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

type sweep_result = {
  sweep_violations : string list;
  sweep_committed : int;  (** total committed slots observed, summed over seeds *)
  sweep_max_view : int;
  sweep_excused : int;  (** how many commit regressions the SendSV exception excused *)
}

(* One sweep body, parameterised only by seed count and horizon, so that the two tests below
   differ in exactly one dimension (how long each run goes on for) and nothing else. *)
let run_sweep ~seeds ~rounds =
  let replica_count = 5 in
  let all_violations = ref [] in
  let total_committed = ref 0 and total_views = ref 0 and total_excused = ref 0 in
  for seed = 1 to seeds do
    let c = make_checker ~seed ~replica_count in
    Riptide_dst.Cluster.run ~seed ~replica_count ~net_fault_config:sweep_net_faults
      ~storage_fault_config:sweep_storage_faults (fun ~replicas ~settle ->
        scenario ~c ~rounds ~ops_per_round:3 ~timeout_prob:0.5 ~replicas ~settle;
        total_committed := !total_committed + Hashtbl.length c.committed;
        Array.iter (fun r -> total_views := max !total_views (Replica.view_number r)) replicas);
    total_excused := !total_excused + c.excused_regressions;
    all_violations := !all_violations @ List.rev c.violations
  done;
  {
    sweep_violations = !all_violations;
    sweep_committed = !total_committed;
    sweep_max_view = !total_views;
    sweep_excused = !total_excused;
  }

let fail_on_violations ~what = function
  | [] -> ()
  | vs ->
      Alcotest.fail
        (Printf.sprintf "%d safety violation(s) across the %s:\n%s" (List.length vs) what
           (String.concat "\n" vs))

let test_adversarial_multi_seed_sweep () =
  let r = run_sweep ~seeds:200 ~rounds:10 in
  (* Non-vacuity, asserted rather than assumed: a sweep that wedged every cluster immediately, or
     never committed anything, would satisfy every safety property above trivially. *)
  Alcotest.(check bool)
    (Printf.sprintf "the sweep actually committed real state (total committed slots = %d)"
       r.sweep_committed)
    true
    (r.sweep_committed > 1500);
  Alcotest.(check bool)
    (Printf.sprintf "the sweep actually completed view changes (highest view reached = %d)"
       r.sweep_max_view)
    true
    (r.sweep_max_view >= 3);
  (* The commit-regression exception must be LIVE code, not an inert guard: assert that it
     actually fired, so it can never silently degrade into a branch documenting a property this
     sweep does not exercise. Measured: 3 regressions across these 200 seeds, every one of them
     confined (the [fail_on_violations] below is what asserts the confinement). *)
  Alcotest.(check bool)
    (Printf.sprintf
       "the sweep actually produced commit regressions, so the SendSV exception is live code and \
        not an inert guard (excused = %d)"
       r.sweep_excused)
    true
    (r.sweep_excused > 0);
  fail_on_violations ~what:"sweep" r.sweep_violations

(* THE SAME SWEEP, SAME FAULTS, THREE TIMES THE HORIZON. This is not a duplicate of test 1: a
   10-round run reaches view ~10 with logs of a few dozen ops and produces only small regressions,
   while a 30-round run reaches view ~19 with logs past 70 ops and produces regressions an order of
   magnitude larger (measured at neighbouring configs: 26 -> 16, 48 -> 42, 71 -> 68). The
   confinement property is asserted against that much wider regime here, on several times as many
   samples as test 1 has -- which is what makes "every regression is a just-completed SendSV" an
   evidenced claim rather than a claim resting on three observations.

   Both halves are asserted, which is the whole point: the exception must FIRE (otherwise it is
   dead code documenting a property nothing checks -- exactly the defect this test was added to
   fix), and every regression it excuses must be CONFINED to a replica that just became primary of
   a strictly newer view. A regression anywhere else fails this test. *)
let test_confined_commit_regression () =
  let r = run_sweep ~seeds:100 ~rounds:30 in
  Alcotest.(check bool)
    (Printf.sprintf
       "the long-horizon sweep actually produced commit regressions, so the SendSV exception is \
        live code and not an inert guard (excused = %d)"
       r.sweep_excused)
    true
    (r.sweep_excused > 0);
  fail_on_violations ~what:"long-horizon sweep" r.sweep_violations

(* THE NEGATIVE CONTROL for the two tests above, and the direct reason the exception is phrased as
   a transition rather than a state.

   The previous version of this exception was [is_primary && status = Normal && last_normal_view =
   view_number]. That last conjunct is VACUOUS: [status = Normal => last_normal_view =
   view_number] is an invariant of the protocol itself -- every action that (re-)enters Normal
   sets both in the same step, and replica.ml:389-391 records a TLC run of that exact invariant
   over a copy of VSR.tla finding ZERO violations across 264,376 distinct reachable states. So the
   old condition reduced to "any primary in Normal", i.e. that primary's ordinary steady state,
   and would have excused a commit regression at ANY moment of a primary's life rather than the
   narrow post-view-change window it claimed to describe.

   The current condition adds [view_number > prev_view], which a steady-state primary never
   satisfies. This test proves that distinction is real rather than asserting it: it drives a real
   cluster to a quiet steady state, checks twice (so the second check sees an unchanged view),
   then forces a regression by claiming each replica had previously reported a much higher
   commit_number. No view changed, so the guard must REFUSE to excuse it. Against the old
   condition this test fails -- the regression is excused and no violation is reported. *)
let test_commit_regression_guard_rejects_steady_state () =
  let c = make_checker ~seed:1 ~replica_count:3 in
  Riptide_dst.Cluster.run ~seed:1 ~replica_count:3 (fun ~replicas ~settle ->
      Replica.propose replicas.(0) (v "op-0");
      settle ();
      check c ~phase:"baseline" replicas;
      (* Second check at the same view: from here on [prev_view = view_number] for every replica,
         which is what "steady state" means to the guard. *)
      check c ~phase:"steady" replicas;
      Alcotest.(check bool)
        "precondition: the cluster really is quiet and really did commit something" true
        (Array.for_all (fun r -> Replica.status r = Replica.Normal) replicas
        && Replica.commit_number replicas.(0) > 0);
      Array.iteri (fun i _ -> c.last_commit.(i) <- 99) replicas;
      check c ~phase:"forced-steady-state-regression" replicas);
  Alcotest.(check int) "the guard excused nothing at all" 0 c.excused_regressions;
  let regressions = List.filter (contains ~needle:"regressed") c.violations in
  Alcotest.(check int)
    "every steady-state commit regression is reported as a violation, one per replica" 3
    (List.length regressions)

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


(* ---------------------------------------------------------------------------------------------
   Test 5: on-the-wire payload corruption breaks cross-replica agreement. A running reproduction of
   a real, currently-unfixed gap, pinned rather than fixed -- see the long note below for why.
   --------------------------------------------------------------------------------------------- *)

(* WHAT THIS PINS, and why it is reported rather than fixed here.

   Until Task 11, Network.fault_config's corrupt_probability was INERT for every cluster in this
   repo: Sim_transport hard-coded Fun.id as Network.send's corruption function, so a "corrupted"
   delivery was byte-identical to a clean one and the knob could be set to any value in any test
   and change nothing. Sim_transport now takes the transformation as a parameter (still defaulting
   to Fun.id), and Cluster supplies a deterministic one-byte flip -- so this is the first time any
   cluster in this repo has ever been handed a genuinely corrupted message.

   The result, at 3 replicas with NO other fault of any kind (no drops, no duplicates, no delays,
   no storage faults), is worse than disagreement between replicas, and the test prints its own
   evidence for that claim rather than asking anyone to take it on trust (see [print_evidence]
   below; run it with `dune exec test/test_riptide.exe -- test dst_scenarios 6 -v`).

   What actually happens is that the corrupted value wins EVERYWHERE. An already-committed,
   already-acknowledged clean value is reported committed at some op_number, and by the end of the
   run that value is held by NO replica in memory and is durably readable on NO replica -- while
   all three replicas hold the corrupted value in its place, in memory and on disk. This is not
   "two replicas disagree"; it is silent, total, retroactive destruction of an acknowledged write,
   cluster-wide, from a single flipped bit. Both facts are asserted below: the divergence, and the
   erasure.

   WHY: Message.encode is Value.canonical_encode with no integrity field of any kind, so a flipped
   payload byte produces a perfectly well-formed Prepare carrying a different value. replica.ml
   validates every INTEGER field off the wire with real care -- its own doc comments cite "a
   corrupted/forged network delivery" as the reason each guard exists -- but the value payload is
   the one field that cannot be range-checked, and it is the one whose corruption directly
   diverges committed state. So this is not outside the codebase's stated threat model; it is a
   hole inside it. It also directly contradicts sim_transport.mli's own claim that code working
   against the shared Transport_intf.S contract is fine with "corrupted payload bytes": the VSR
   layer is not.

   NOT FIXED HERE, deliberately. Any real fix must let a receiver DETECT the corruption, which
   means adding redundancy to the message encoding -- a wire-format change to the consensus
   protocol, i.e. Layer 0, which this repo's own CLAUDE.md says is decided by a small group of
   people who have implemented against the change, not unilaterally by whoever finds the problem.
   It is also not obvious that a checksum is the right answer rather than stating outright that
   VSR requires an integrity-preserving transport (Riptide_transport.Tcp already is one), since a
   checksum only defends against random corruption, which is what this injector models and what a
   real transport already handles. That choice is the task report's top recommendation.

   This test therefore asserts the CURRENT, broken behaviour, so the gap is a CI-visible fact
   rather than folklore: if it ever starts passing without a divergence, something real changed and
   this test should be turned into the positive assertion. *)
(* Every value this scenario ever proposes is [v "op-<k>"], so "clean" is decidable exactly, with
   no decoding and no guessing: an encoding is clean iff it is one of those. Anything else a
   replica reports committed was manufactured by the one-byte flip. *)
let clean_encodings =
  let h = Hashtbl.create 128 in
  for k = 0 to 199 do
    Hashtbl.replace h (Value.canonical_encode (v (Printf.sprintf "op-%d" k))) ()
  done;
  h

let is_clean enc = Hashtbl.mem clean_encodings enc

let test_wire_corruption_diverges_committed_state () =
  let seed = 4 and replica_count = 3 in
  let c = make_checker ~seed ~replica_count in
  (* Final state, captured inside the run because [replicas] does not outlive it: per replica, for
     each op_number it holds, what it has in memory and what it can actually read back off its own
     durable storage. This is what makes the erasure claim checkable rather than rhetorical. *)
  let final = ref [||] in
  Riptide_dst.Cluster.run ~seed ~replica_count
    ~net_fault_config:
      Riptide_sim.Network.
        {
          drop_probability = 0.0;
          duplicate_probability = 0.0;
          corrupt_probability = 0.2;
          min_delay = 0.0;
          max_delay = 0.0;
        }
    (fun ~replicas ~settle ->
      scenario ~c ~rounds:8 ~ops_per_round:3 ~timeout_prob:0.5 ~replicas ~settle;
      final :=
        Array.map
          (fun r ->
            Array.mapi
              (fun k e ->
                ( Value.canonical_encode e,
                  Option.map Value.canonical_encode
                    (Replica.for_test_wal_read r ~op_number:(k + 1)) ))
              (Array.of_list (Replica.entries r)))
          replicas);
  let final = !final in
  let at_op n r = if Array.length r >= n then Some r.(n - 1) else None in
  let divergences = List.filter (contains ~needle:"DIVERGENCE") (List.rev c.violations) in
  (* Every op_number whose FIRST-reported-committed value was a clean one that, by the end of the
     run, no replica holds in memory and no replica can read off disk: an acknowledged write
     destroyed cluster-wide, in both places, with nothing left to recover it from. *)
  let erased =
    Hashtbl.fold
      (fun n enc acc ->
        if not (is_clean enc) then acc
        else
          let held_in_memory =
            Array.exists (fun r -> match at_op n r with Some (m, _) -> m = enc | None -> false) final
          in
          let on_disk =
            Array.exists
              (fun r -> match at_op n r with Some (_, d) -> d = Some enc | None -> false)
              final
          in
          if held_in_memory || on_disk then acc else (n, enc) :: acc)
      c.committed []
    |> List.sort compare
  in
  (* The evidence, printed by the test itself so that what a report quotes and what a reader
     reproduces are the same bytes. Alcotest captures this per test; see the header comment for
     the exact command that shows it. *)
  Printf.printf
    "\n\
     === wire-corruption evidence: seed %d, %d replicas, corrupt_probability 0.2, no other fault \
     of any kind\n\
     === %d violation(s) total: %d divergence(s), %d op(s) whose committed value is now held by \
     NO replica in memory, %d durably readable on NO replica\n"
    seed replica_count (List.length c.violations) (List.length divergences)
    (List.length (List.filter (contains ~needle:"NO replica in memory") c.violations))
    (List.length (List.filter (contains ~needle:"durably readable on NO replica") c.violations));
  List.iteri (fun i s -> if i < 4 then print_endline ("    " ^ s)) divergences;
  Printf.printf "=== %d acknowledged write(s) destroyed cluster-wide (in memory AND on disk):\n"
    (List.length erased);
  List.iter
    (fun (n, enc) ->
      Printf.printf "    op %d: originally committed %S -- now, on every replica:\n" n enc;
      Array.iteri
        (fun i r ->
          match at_op n r with
          | None -> Printf.printf "        replica %d: (no entry at this op_number)\n" (i + 1)
          | Some (m, d) ->
              Printf.printf "        replica %d: in memory %S, on disk %s\n" (i + 1) m
                (match d with None -> "(unreadable)" | Some d -> Printf.sprintf "%S" d))
        final)
    erased;
  print_newline ();
  Alcotest.(check bool)
    "seed 4, 3 replicas, one flipped payload byte and nothing else: replicas report different \
     values committed at the same op_number (see this test's own comment -- pinned, not endorsed)"
    true
    (divergences <> []);
  (* THE SEVERITY, pinned separately and deliberately: this is not merely disagreement between
     replicas. An acknowledged, committed clean value ends up held by no replica in memory and
     readable off no replica's disk -- erased cluster-wide, with the corrupted value in its place.
     If a fix ever makes THIS assertion fail while the divergence one still passes, the failure
     mode has genuinely changed character and both assertions need revisiting together. *)
  Alcotest.(check bool)
    (Printf.sprintf
       "at least one acknowledged write is destroyed cluster-wide -- held by no replica in memory \
        AND durably readable on no replica (count = %d)"
       (List.length erased))
    true
    (erased <> [])

let tests =
  [
    ("adversarial multi-seed sweep, combined network and storage faults", `Quick,
      test_adversarial_multi_seed_sweep);
    ("same sweep, longer horizon: commit regression occurs and is confined to SendSV", `Quick,
      test_confined_commit_regression);
    ("the commit-regression guard rejects a steady-state regression (negative control)", `Quick,
      test_commit_regression_guard_rejects_steady_state);
    ("File_storage cluster commits what it settles", `Quick,
      test_file_storage_cluster_commits_what_it_settles);
    ("File_storage cluster's committed entries are durable", `Quick,
      test_file_storage_cluster_committed_entries_are_durable);
    ("ring capacity boundary: past it, no view change can complete", `Quick,
      test_ring_capacity_boundary);
    ("wire payload corruption diverges committed state (pinned, unfixed)", `Quick,
      test_wire_corruption_diverges_committed_state);
  ]
