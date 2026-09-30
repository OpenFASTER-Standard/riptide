(* test/test_dst_scenarios.ml

   Task 11 of the storage-fault-tolerant-recovery plan: the permanent, CI-runnable residue of a
   real adversarial hunt across Tasks 1-10, not a scripted demonstration. Eight tests, each
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
   8. [torn-superblock crash] -- the deterministic counterpart of finding C1's coverage: a replica
      that crashes partway through a superblock write must REFUSE to come back rather than
      resurrect at op_number = 0, and the committed data on its disk must survive that refusal.

   FINAL-REVIEW FINDING I1 CHANGED WHAT TESTS 1 AND 2 CAN REACH, which is worth understanding
   before reading them. Until this wave, this suite's only crash was "stop a replica and never
   recover it" -- [Riptide_vsr.Replica.restart] was exercised nowhere but
   [test_vsr_replica_recovery.ml]'s hand-driven single-replica unit tests, and never by any running
   cluster. Every defect living in the act of coming BACK was therefore structurally unreachable no
   matter how many seeds were swept, which is exactly where the wave's one critical finding (C1)
   turned out to live. The sweep now performs real crash-and-come-backs (measured: 584 over test
   1's 200 seeds, 897 over test 2's 100), and the storage fault config now includes torn superblock
   writes, so a fraction of those restarts find no usable superblock over a non-empty WAL -- C1's
   exact condition (measured: 16 and 18 times respectively, asserted as non-vacuity).

   That this closes the gap is shown rather than claimed: with C1's guard disabled, these sweeps
   report 40+ safety-property violations, every one of the shape "replica N commit_number regressed
   K -> 0" at an [after-restart] phase -- a replica resurrecting as if it had never held the
   committed ops it durably held. With the guard in place there are none.

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
     itself (replica.ml:688-690 records a TLC run of exactly that invariant over a copy of VSR.tla
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
     what keeps view changes completing and keeps real committed state accumulating to compare.
     (Audit-remediation Task 32 changed a below-quorum replica's check_timeout from a bare no-op
     into a retry of its own broadcast -- see replica.ml's own [try_forfeit_or_retry_view_change]
     -- which narrows point 4's gap somewhat: a replica that only ever ADOPTED a higher view
     passively now DOES eventually broadcast its own StartViewChange for it, on its own next
     check_timeout call. This comment's own "within a round or two, for the remainder of the run"
     claim has NOT been re-verified against that change -- a random-subset variant of this sweep
     has never actually been run, before or after Task 32, so this remains the same
     un-exercised design rationale it always was, not a pinned regression test; it is not asserted
     that the claim is still exactly accurate at either boundary, only that it is not part of this
     task's own scope to re-derive.) *)

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
  down : bool array;
      (** Which replicas are DOWN — they crashed and then REFUSED to come back, which since
          final-review finding C1's fix is exactly what a replica does when its superblock did not
          survive the crash while its WAL did. [Riptide_dst.Cluster.restart] leaves such a replica's
          array slot holding its pre-crash value, frozen at the moment it crashed, and stops
          delivering messages to it; the scenario below stops driving it too. See [check] for the
          one place a down replica still counts. *)
  restarted : bool array;
      (** Which replicas have come back from a crash at least once. Read by exactly one check —
          see the [commit_number] vs log-length check in [check] — because a restart is the only
          thing in this harness that can legitimately make a replica's in-memory log SHORTER than
          its own durable commit_number. *)
  mutable restarts : int;  (** How many restarts actually happened, so a test can assert they did. *)
  mutable refused_restarts : int;  (** ...and how many of those refused to come back. *)
}

let make_checker ~seed ~replica_count =
  {
    seed;
    violations = [];
    committed = Hashtbl.create 64;
    last_commit = Array.make replica_count 0;
    prev_view = Array.make replica_count (-1);
    excused_regressions = 0;
    down = Array.make replica_count false;
    restarted = Array.make replica_count false;
    restarts = 0;
    refused_restarts = 0;
  }

let note c fmt = Printf.ksprintf (fun s -> c.violations <- s :: c.violations) fmt
let status_str = function Replica.Normal -> "Normal" | Replica.View_change -> "View_change"

let contains ~needle s =
  let n = String.length needle and m = String.length s in
  let rec at i = i + n <= m && (String.sub s i n = needle || at (i + 1)) in
  at 0

(* A DOWN replica is a machine that will not boot. It reports nothing: its array slot still holds
   the pre-crash [Replica.t], but that value's in-memory state died with the process, so crediting
   it would let a dead replica satisfy a safety property for a live cluster. Its DISK is a
   different matter and is still counted — see the durability check below. *)
let check c ~phase (replicas : Replica.t array) =
  Array.iteri
    (fun i r ->
      if c.down.(i) then ()
      else
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
      (* [commit_number] must never exceed what this replica holds. For a replica that has NEVER
         restarted that means its in-memory log, which storage corruption cannot shorten (the
         in-memory log is a separate copy; corruption only shows up through [wal_read]).

         A RESTARTED replica is the one documented exception, and it is the spec's own, not a
         concession made here: [restart] rebuilds the in-memory log only as far as the first
         unreadable slot while [op_number] keeps its full durable value (replica.mli's [op_number]
         doc), so a replica that came back over a corrupt slot below its commit point legitimately
         has [commit_number > List.length (entries r)] and declines new work until a StartView
         repairs it. For those, the invariant that still must hold — and is checked — is VSR's own
         [CommitNumberNeverHigherThanOpNumber] against the durable op_number. *)
      let bound, bound_name =
        if c.restarted.(i) then (Replica.op_number r, "durable op_number")
        else (Array.length entries, "own log length")
      in
      if cn > bound then
        note c "seed %d [%s]: replica %d commit_number %d exceeds its %s %d" c.seed phase (i + 1)
          cn bound_name bound;
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
      Array.iteri
        (fun i r ->
          let e = Array.of_list (Replica.entries r) in
          (* IN MEMORY: live replicas only — a down machine's RAM is gone.
             ON DISK: every replica, down ones included, and that asymmetry is the point rather
             than a loophole. A replica that refused to restart did so precisely BECAUSE its WAL
             was intact (finding C1's guard fires only for a lost superblock over a NON-EMPTY WAL),
             and its refusal is a total no-op on durable state. The data really is still on that
             disk, recoverable by whatever rebuilds the superblock; "committed data was destroyed"
             would be a false claim about it. What the fix buys is exactly this — a stopped machine
             with its log intact, instead of a running one that proves its own log never existed. *)
          if (not c.down.(i)) && Array.length e >= n && Value.canonical_encode e.(n - 1) = enc then
            in_memory := true;
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

let scenario ?restart ?(restart_prob = 0.0) ~c ~rounds ~ops_per_round ~timeout_prob ~replicas
    ~settle () =
  (* Scenario decisions get their own Prng, seeded from the run's own seed: they must be
     reproducible, and they must not perturb the network's or any storage's own fault stream. *)
  let p = Riptide_sim.Prng.create (((c.seed * 7919) + 13) land 0x3FFFFFFF) in
  let next_val = ref 0 in
  (* A DOWN replica must not be DRIVEN either, not just not delivered to: [Riptide_dst.Cluster]
     stops feeding it incoming messages, but its pre-crash [Replica.t] is still a perfectly
     functional object that would happily append to its own log and send messages if this scenario
     called [propose]/[check_timeout] on it. A dead machine does neither. *)
  let live i = not c.down.(i) in
  let find_primary () =
    let primary = ref None in
    Array.iteri
      (fun i r ->
        if live i && Replica.is_primary r && Replica.status r = Replica.Normal then primary := Some i)
      replicas;
    !primary
  in
  let storm () =
    Array.iteri (fun i r -> if live i then Replica.check_timeout r) replicas;
    settle ()
  in
  (* FINAL-REVIEW FINDING I1: real crash-and-come-back, inside the sweep. Before this, the only
     crash this suite could express was "stop a replica and never recover it", so every defect
     living in the act of coming BACK -- which is where finding C1 lived -- was structurally
     unreachable no matter how many seeds were swept. At most one restart per round, so a run's
     restarts stay countable and a wedged run stays diagnosable. *)
  let maybe_restart () =
    match restart with
    | Some restart when Riptide_sim.Prng.bool p restart_prob ->
        let i = Riptide_sim.Prng.int p (Array.length replicas) in
        if live i then begin
          c.restarts <- c.restarts + 1;
          c.restarted.(i) <- true;
          if not (restart i) then begin
            c.down.(i) <- true;
            c.refused_restarts <- c.refused_restarts + 1
          end;
          settle ();
          check c ~phase:"after-restart" replicas
        end
    | _ -> ()
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
    end;
    maybe_restart ()
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
  {
    Riptide_storage.Fault_injecting_storage.corrupt_probability = 0.1;
    drop_probability = 0.05;
    (* FINAL-REVIEW FINDING I1. A torn superblock write -- the crash-partway-through-3-sequential-
       non-atomic-copy-writes fault -- is INERT while a replica keeps running: nothing reads the
       superblock except [Replica.create] and [Replica.restart]. It only becomes visible when a
       replica comes back, which is exactly why this knob and the restart wiring below had to
       arrive together, and exactly why the defect they jointly reach (finding C1) survived a whole
       branch of adversarial sweeping. Kept low: a LATER untorn write repairs a torn one, so what
       actually matters is landing a torn write as the last one before a restart. Measured at this
       setting over the 200-seed sweep -- see the [sweep_refused] assertion, which fails if this
       config ever stops reaching the condition at all. *)
    superblock_loss_probability = 0.02;
  }

(* At most one restart attempt per round per run. High enough that a 200-seed sweep performs
   hundreds of real crash-and-come-backs, low enough that a 5-replica cluster is not spending most
   of its rounds recovering rather than replicating. *)
let sweep_restart_prob = 0.3

type sweep_result = {
  sweep_violations : string list;
  sweep_committed : int;  (** total committed slots observed, summed over seeds *)
  sweep_max_view : int;
  sweep_excused : int;  (** how many commit regressions the SendSV exception excused *)
  sweep_restarts : int;  (** how many real crash-and-come-backs the sweep performed (I1) *)
  sweep_refused : int;
      (** ...and how many of those REFUSED to come back, i.e. crashed with a torn superblock over a
          non-empty WAL. Non-zero is what proves the sweep actually reaches finding C1's condition
          rather than merely being able to in principle. *)
}

(* One sweep body, parameterised only by seed count and horizon, so that the two tests below
   differ in exactly one dimension (how long each run goes on for) and nothing else. *)
let run_sweep ~seeds ~rounds =
  let replica_count = 5 in
  let all_violations = ref [] in
  let total_committed = ref 0 and total_views = ref 0 and total_excused = ref 0 in
  let total_restarts = ref 0 and total_refused = ref 0 in
  for seed = 1 to seeds do
    let c = make_checker ~seed ~replica_count in
    Riptide_dst.Cluster.run ~seed ~replica_count ~net_fault_config:sweep_net_faults
      ~storage_fault_config:sweep_storage_faults (fun ~replicas ~settle ~restart ->
        scenario ~restart ~restart_prob:sweep_restart_prob ~c ~rounds ~ops_per_round:3
          ~timeout_prob:0.5 ~replicas ~settle ();
        total_committed := !total_committed + Hashtbl.length c.committed;
        Array.iter (fun r -> total_views := max !total_views (Replica.view_number r)) replicas);
    total_excused := !total_excused + c.excused_regressions;
    total_restarts := !total_restarts + c.restarts;
    total_refused := !total_refused + c.refused_restarts;
    all_violations := !all_violations @ List.rev c.violations
  done;
  {
    sweep_violations = !all_violations;
    sweep_committed = !total_committed;
    sweep_max_view = !total_views;
    sweep_excused = !total_excused;
    sweep_restarts = !total_restarts;
    sweep_refused = !total_refused;
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
  (* FINAL-REVIEW FINDING I1's OWN NON-VACUITY, asserted for the same reason every other
     non-vacuity claim in this file is: a capability nothing exercises is not coverage. Measured at
     this config: 584 restarts, 16 of them refused.

     [sweep_refused > 0] is the load-bearing one. A refusal is a replica that crashed with a torn
     superblock over a NON-EMPTY WAL -- finding C1's exact condition, the state that used to make a
     replica come back proving absent every op it had durably held. If this ever drops to zero, the
     sweep has stopped reaching that condition and this whole restart-wiring is decoration, no
     matter how many restarts it still performs. *)
  Alcotest.(check bool)
    (Printf.sprintf "the sweep actually crashed and recovered replicas (restarts = %d)"
       r.sweep_restarts)
    true
    (r.sweep_restarts > 100);
  Alcotest.(check bool)
    (Printf.sprintf
       "the sweep actually reached finding C1's condition -- a crash with a torn superblock over a \
        non-empty WAL, which a correct replica REFUSES to come back from (refused = %d)"
       r.sweep_refused)
    true
    (r.sweep_refused > 0);
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
  (* Same two I1 non-vacuity claims as test 1, over the longer horizon. Measured: 897 restarts,
     18 refused. *)
  Alcotest.(check bool)
    (Printf.sprintf "the long-horizon sweep actually crashed and recovered replicas (restarts = %d)"
       r.sweep_restarts)
    true
    (r.sweep_restarts > 100);
  Alcotest.(check bool)
    (Printf.sprintf
       "...and actually reached finding C1's condition, a crash with a torn superblock over a \
        non-empty WAL (refused = %d)"
       r.sweep_refused)
    true
    (r.sweep_refused > 0);
  fail_on_violations ~what:"long-horizon sweep" r.sweep_violations

(* THE NEGATIVE CONTROL for the two tests above, and the direct reason the exception is phrased as
   a transition rather than a state.

   The previous version of this exception was [is_primary && status = Normal && last_normal_view =
   view_number]. That last conjunct is VACUOUS: [status = Normal => last_normal_view =
   view_number] is an invariant of the protocol itself -- every action that (re-)enters Normal
   sets both in the same step, and replica.ml:688-690 records a TLC run of that exact invariant
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
  Riptide_dst.Cluster.run ~seed:1 ~replica_count:3 (fun ~replicas ~settle ~restart:_ ->
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
        (fun ~replicas ~settle ~restart:_ ->
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
        (fun ~replicas ~settle ~restart:_ ->
          scenario ~c ~rounds:4 ~ops_per_round:2 ~timeout_prob:0.5 ~replicas ~settle ();
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
    (fun ~replicas ~settle ~restart:_ ->
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

(* REGRESSION TEST, subtask 3.8: this scenario (same hardcoded seed:1 as [run_until_view_change]
   above) exercises the ring-capacity boundary and view-change path against real [File_storage] I/O,
   run repeatedly to catch flakes in that code path. This test's scenario itself has zero injected
   fault probabilities on both network and storage (see the seed config in line 641-649 below),
   so it does not exercise or prove anything about [lib/sim/network.ml]'s fault-decision keying
   (whether per-sender or shared stream). Its value is purely as a real-I/O soak of the
   ring-capacity/view-change mechanism itself, running the identical scenario N times in one
   process each against a fresh real [File_storage] directory, catching any nondeterministic
   flakes that may emerge from that path's interaction with File_storage timing or wall-clock
   budget behavior.

   ITERATION COUNT AND SPEED, both reduced from this test's first form after it was measured
   rather than guessed. It first ran 20 iterations and was registered [`Quick]. At 20 it cost
   ~6.3s of the suite's ~20s idle wall-clock -- roughly a third of the whole suite for one test --
   against test_riptide.ml's own 15s PER-TEST watchdog, which is far less headroom than that ratio
   makes it sound: the cost here is real [Eio.Time.sleep]-based I/O waiting, so it stretches under
   CPU contention rather than staying put, and a review reproduced 4 watchdog failures out of 4
   runs under induced load (against 0/5 for [test_ring_capacity_boundary], the single-iteration
   test it soaks). Worse, the watchdog's own message blames "a busy-poll livelock," which is
   exactly the wrong diagnosis for a test that is legitimately waiting on I/O -- the failure mode
   test_riptide.ml's own TASK 11 CORRECTION note already calls the worst possible one for a
   watchdog, since it discredits the suite instead of finding a bug.

   So: 5 iterations, and [`Slow], following this repo's existing convention for adversarial/soak-
   shaped tests (test_lattice_materialize_crypto_scenarios.ml registers its multi-seed sweeps and
   its real-TLS test that way). 5 still soaks -- it is 5 independent real-[File_storage]
   directories and 5 independent full view-change storms, i.e. still 5x the coverage of the
   single-iteration test next to it, which is the actual regression-catching property this test
   exists for -- while costing ~1.6s instead of ~6.3s and leaving an order-of-magnitude margin
   under the watchdog rather than a 2.4x one. A genuine nondeterministic flake in this path is
   caught by repetition across RUNS as much as within one; buying the last few iterations at the
   price of being the suite's most load-fragile test was not a good trade. *)
let soak_iterations = 5

let test_ring_capacity_boundary_soak () =
  for iteration = 1 to soak_iterations do
    Eio_main.run @@ fun env ->
    with_tmp_dir (fun dir ->
        let ok, views = run_until_view_change ~env ~dir ~ring_capacity:small_ring in
        Alcotest.(check bool)
          (Printf.sprintf
             "soak iteration %d/%d: with a log of %d ops in a ring of %d, no view change can ever \
              complete -- the cluster is permanently in View_change (views reached: %s)"
             iteration soak_iterations ops_past_ring small_ring
             (String.concat "," (List.map string_of_int views)))
          false ok;
        Alcotest.(check bool)
          (Printf.sprintf "soak iteration %d/%d: views kept climbing as each attempt forfeited"
             iteration soak_iterations)
          true
          (List.exists (fun v -> v >= 3) views))
  done

(* ---------------------------------------------------------------------------------------------
   Test 5: on-the-wire payload corruption must be detected and dropped, not silently accepted as
   a legitimately different committed value. See the long note on the test function itself for
   the full history (this used to be a pinned reproduction of a real, then-open gap; it is now a
   positive assertion that subtask 3.6's fix closes it).
   --------------------------------------------------------------------------------------------- *)
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

let test_wire_corruption_is_detected_and_dropped_not_accepted () =
  (* Formerly [test_wire_corruption_diverges_committed_state], pinned-failing-by-design: this
     note used to document a real, then-open gap where [Message.encode]/[decode] carried no
     integrity field at all, so a corrupted wire byte could make the cluster retroactively accept
     a corrupted value as if it had been legitimately proposed. It said explicitly that if this
     test ever started passing without a divergence, something real had changed and it should be
     turned into the positive assertion below -- this is that change.

     WHAT THE GAP WAS AND HOW IT WAS FOUND. Until Task 11, Network.fault_config's
     corrupt_probability was INERT for every cluster in this repo: Sim_transport hard-coded
     Fun.id as Network.send's corruption function, so a "corrupted" delivery was byte-identical
     to a clean one and the knob could be set to any value in any test and change nothing.
     Sim_transport was changed to take the transformation as a parameter (still defaulting to
     Fun.id), with Cluster supplying a deterministic one-byte flip -- the first time any cluster
     in this repo was ever handed a genuinely corrupted message. Before this task's fix, at 3
     replicas with NO other fault of any kind (no drops, no duplicates, no delays, no storage
     faults), the result was worse than disagreement between replicas: the corrupted value won
     EVERYWHERE. An already-committed, already-acknowledged clean value was reported committed at
     some op_number, and by the end of the run that value was held by NO replica in memory and
     was durably readable on NO replica -- while all three replicas held the corrupted value in
     its place, in memory and on disk. This was not "two replicas disagree"; it was silent,
     total, retroactive destruction of an acknowledged write, cluster-wide, from a single flipped
     bit.

     WHY IT MATTERED. [Message.encode] was [Value.canonical_encode] with no integrity field of
     any kind, so a flipped payload byte produced a perfectly well-formed [Prepare] carrying a
     different value. [replica.ml] validates every INTEGER field off the wire with real care --
     its own doc comments cite "a corrupted/forged network delivery" as the reason each guard
     exists -- but the value payload was the one field that could not be range-checked, and it
     was the one whose corruption directly diverged committed state. This was not outside the
     codebase's stated threat model; it was a hole inside it. It also directly contradicted
     sim_transport.mli's own claim that code working against the shared Transport_intf.S contract
     is fine with "corrupted payload bytes": the VSR layer was not. (Fixing it required adding
     redundancy to the message encoding -- a wire-format change to the consensus protocol, i.e.
     Layer 0, hence deferred to its own task rather than patched in unilaterally where found.)

     2026-09-24, layer0-followup-hardening Task 2 (subtask 3.6) is exactly that change:
     [Message.encode] now appends an 8-byte wire-integrity checksum (see message.mli's own
     "Wire-integrity checksum" section) and [Message.decode] verifies it before accepting the
     bytes, raising [Malformed_message] on a mismatch -- which [Replica.handle_message] already
     catches unconditionally and silently drops (VSR's own retry/timeout machinery recovers from
     there, the same as any other malformed/dropped message). The two assertions below are now
     flipped from asserting the bug's presence to asserting its absence: a corrupted [Prepare] must
     be dropped, never accepted as a legitimately different committed value.

     [seed] re-picked (was 4) after subtask 3.8's fix keyed Network.send's fault decisions
     per-sender instead of drawing them from one send-order-consumed stream (lib/sim/network.ml):
     that changed which seed happens to land a corrupting flip on the one decisive message this
     test's assertions need, since it is a genuinely different derivation from the same integer,
     not a compatible re-seeding. Re-searched by sweeping seeds 1-160 for one that still reproduces
     both pinned facts (a divergence AND a cluster-wide erasure) under the new derivation; this
     scenario runs on Eio_mock.Backend (no real I/O), so it was never the source of the flake this
     fix closes and is fully deterministic for a fixed seed both before and after. This seed was
     chosen to reproduce the PRE-fix bug; it is kept as-is post-fix specifically because the same
     seed now demonstrating a clean run (no divergence, no erasure) IS the evidence the fix works,
     rather than picking a new seed that never exercised the bug in the first place. *)
  let seed = 71 and replica_count = 3 in
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
    (fun ~replicas ~settle ~restart:_ ->
      scenario ~c ~rounds:8 ~ops_per_round:3 ~timeout_prob:0.5 ~replicas ~settle ();
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
  (* Guard against a vacuous pass: [divergences = []] and [erased = []] both hold trivially if
     the cluster never committed anything at all -- e.g. if [decode] regressed to rejecting EVERY
     message (not just corrupted ones), if [corrupt_probability] got silently zeroed somewhere, or
     if Sim_transport's corruption function regressed to the inert [Fun.id] default this same test
     already lived through once (see the history note above). Proving real work happened closes
     that path directly; it does not prove corruption specifically fired (that would need a
     "corruption genuinely fired N times" counter threaded through Cluster/Network, which is
     outside this task's file scope -- named here as a known, accepted limitation, not fixed). *)
  Alcotest.(check bool)
    (Printf.sprintf "seed %d: the run actually committed real ops (not a vacuous pass)" seed)
    true
    (Hashtbl.length c.committed > 0);
  Alcotest.(check bool)
    (Printf.sprintf
       "seed %d, 3 replicas, one flipped payload byte and nothing else: the wire-integrity \
        checksum (subtask 3.6) catches it, so replicas never report different values committed \
        at the same op_number"
       seed)
    true
    (divergences = []);
  (* THE SEVERITY, checked separately and deliberately: this is not merely "no disagreement
     between replicas". No acknowledged, committed clean value may end up erased cluster-wide
     (held by no replica in memory and readable off no replica's disk) either -- a corrupted
     [Prepare] must be dropped outright by the receiving replica, the same as any other
     malformed/dropped message, never accepted as a legitimately different committed value. If a
     fix ever makes THIS assertion fail while the divergence one still passes, the failure mode
     has genuinely changed character and both assertions need revisiting together. *)
  Alcotest.(check bool)
    (Printf.sprintf
       "no acknowledged write is destroyed cluster-wide -- every committed value remains held by \
        at least one replica in memory or durably readable on at least one replica (count of \
        erased = %d)"
       (List.length erased))
    true
    (erased = [])

(* ---------------------------------------------------------------------------------------------
   Test 8: the DETERMINISTIC counterpart of the sweep's statistical coverage of finding C1.
   --------------------------------------------------------------------------------------------- *)

(* THE SWEEP ABOVE reaches finding C1's condition 16-18 times per run, but only statistically: it
   depends on a torn superblock write landing as the last one before a restart. This test forces
   exactly that state, on exactly the replicas it chooses, with no probability anywhere -- so the
   mechanism is pinned rather than sampled, and a future change that makes the sweep stop reaching
   the condition cannot also quietly remove the coverage.

   THE SCENARIO IS THE REVIEWER'S OWN REPRODUCTION. Three replicas commit a value. Two of them then
   crash in the ordinary way -- partway through a superblock write, so the superblock does not come
   back while the WAL does. Both are asked to restart.

   WHAT MUST HAPPEN, and what used to: both must REFUSE, and the committed value must still be
   durably readable on the disks of all three. Before finding C1's fix they came back instead, at
   op_number = 0 with their WALs truncated to match, whereupon each of them proved absent -- through
   [sender_proves_absent]'s [op_number > n] disjunct -- every op it had itself durably held. Two of
   three is a nack quorum.

   MEASURED AGAINST THE PRE-FIX BEHAVIOUR, not asserted: with finding C1's guard disabled and both
   assertions below instrumented to report rather than stop at the first failure, this exact
   scenario produced

     outcomes = 1:true, 2:true        (both came back instead of refusing)
     durable  = present, GONE, GONE   (op 1's committed value, per replica, read off its own disk)

   -- an ordinary crash, no injected fault beyond the torn superblock write a crash produces on its
   own, destroying two of three durable copies of a committed, client-acknowledged write. Both
   halves of that are what the two assertions below pin. *)
let test_a_crash_with_a_torn_superblock_refuses_to_come_back () =
  let replica_count = 3 in
  let c = make_checker ~seed:99 ~replica_count in
  let outcomes = ref [] and durable_after = ref [] in
  Riptide_dst.Cluster.run ~seed:99 ~replica_count (fun ~replicas ~settle ~restart ->
      Replica.propose replicas.(0) (v "committed-before-the-crash");
      settle ();
      Alcotest.(check int) "precondition: the value really is committed at the primary" 1
        (Replica.commit_number replicas.(0));
      Alcotest.(check bool) "precondition: and durable on every replica" true
        (Array.for_all
           (fun r -> Replica.for_test_wal_read r ~op_number:1 = Some (v "committed-before-the-crash"))
           replicas);
      check c ~phase:"before-the-crash" replicas;
      (* The crash: two replicas go down partway through a superblock write. Their WALs are
         untouched -- that combination is the whole point, and an ordinary crash produces it. *)
      List.iter
        (fun i ->
          let came_back = restart ~lose_superblock:true i in
          if not came_back then c.down.(i) <- true;
          c.restarted.(i) <- true;
          outcomes := (i, came_back) :: !outcomes)
        [ 1; 2 ];
      settle ();
      check c ~phase:"after-the-crash" replicas;
      (* Give the cluster every chance to do the damage: three timeout storms, which is what drove
         the destructive view change in the pre-fix reproduction. Only live replicas are driven. *)
      for _ = 1 to 3 do
        Array.iteri (fun i r -> if not c.down.(i) then Replica.check_timeout r) replicas;
        settle ()
      done;
      check c ~phase:"after-the-storms" replicas;
      durable_after :=
        Array.to_list
          (Array.map (fun r -> Replica.for_test_wal_read r ~op_number:1) replicas));
  Alcotest.(check (list (pair int bool)))
    "both replicas that crashed with a torn superblock REFUSED to come back"
    [ (1, false); (2, false) ]
    (List.sort compare !outcomes);
  (* The refusal is what PRESERVES the data, not what loses it: every replica's disk still holds
     the committed value, down ones included. A stopped machine with an intact log is recoverable;
     a running one that proves its own log never existed is not. *)
  Alcotest.(check (list (option string)))
    "the committed value is still durably readable on all three replicas' disks"
    (List.init replica_count (fun _ -> Some "committed-before-the-crash"))
    (List.map (Option.map (function Value.Scalar (Value.String x) -> x | _ -> "?")) !durable_after);
  fail_on_violations ~what:"torn-superblock crash scenario" c.violations

(* ---------------------------------------------------------------------------------------------
   Test 8b (Task 13 fix round): the OTHER half of test 8 -- getting those two permanently-down
   replicas back.
   ---------------------------------------------------------------------------------------------

   Test 8 above proves the fail-stop refusal is right, and stops there, because when it was written
   there was nothing to do next: a replica that refused stayed down forever with a fully intact log.
   Task 13 added the repair; this fix round made it take real operator-supplied values (review
   finding 1) and made it actually work through the fault-injection wrapper the whole DST harness
   runs on (review finding 3 -- it previously raised [Invalid_argument] unconditionally in exactly
   this state, so the scenario below could not have been written at all).

   Same crash as test 8, then the recovery an operator would actually perform: read the real
   view/commit state off the ONE replica that never crashed, hand those values to the repair, and
   restart. WHAT MUST HAPPEN: both replicas come back for real, the committed value is still durably
   on every disk, every safety check still passes, and the cluster keeps serving -- a further
   proposal commits normally.

   This is deliberately the OPERATIONALLY FAITHFUL sequence rather than the convenient one:
   [restart ~lose_superblock:true] alone first (asserting the [false] refusal), and only then
   [restart ~repair_superblock:...] as a separate act. Folding both into one call would hide the
   refusal that is the whole reason the repair exists. *)
let test_the_superblock_repair_brings_a_refusing_replica_back () =
  let replica_count = 3 in
  let c = make_checker ~seed:101 ~replica_count in
  let refusals = ref [] and recoveries = ref [] and durable_after = ref [] in
  let committed_again = ref false in
  Riptide_dst.Cluster.run ~seed:101 ~replica_count (fun ~replicas ~settle ~restart ->
      Replica.propose replicas.(0) (v "committed-before-the-crash");
      settle ();
      Alcotest.(check int) "precondition: the value really is committed at the primary" 1
        (Replica.commit_number replicas.(0));
      check c ~phase:"before-the-crash" replicas;
      (* THE OPERATOR'S OUT-OF-BAND KNOWLEDGE of the CRASHING replicas' OWN prior durable state --
         the step that has no analogue inside the storage layer, and the reason the repair cannot be
         an automatic self-heal.

         WHY READING IT OFF replicas.(0) IS LEGITIMATE *HERE* SPECIFICALLY, now that "read a live
         peer's current values" has been retracted as a general procedure (Task 13 re-review finding
         1 -- see [Riptide_dst.Cluster.superblock_repair]'s own doc comment): this scenario never
         performs a view change at all. Every replica is still in view 0 with
         [last_normal_view = 0], so the surviving replica's view pair DEMONSTRABLY coincides with the
         crashing replicas' own -- asserted below rather than assumed, precisely because the general
         procedure is unsafe and this exception has to carry its own proof. The commit-number is NOT
         taken from the peer for exactly that reason (see the next comment). *)
      let truth =
        { Riptide_dst.Cluster.view_number = Replica.view_number replicas.(0);
          last_normal_view = Replica.last_normal_view replicas.(0);
          commit_number = 0
          (* The backups' OWN commit_number, which is what their own superblock must carry: neither
             backup ever learned the commit (no later Prepare carried the raised [k] to them before
             the crash), so supplying the primary's 1 would be inventing durable state this replica
             never had -- and [commit_number <= op_number] is checked, not assumed. Asserted rather
             than hardcoded, just below. *)
        }
      in
      (* BOTH crashing replicas, not just one (review finding M6): the SAME [truth] record is applied
         to replicas 1 and 2 alike, so the proof that it is really THEIR own state has to cover both
         of them for every field it carries -- otherwise the assertion pair below proves the view
         pair symmetrically while the commit-number rests on a single replica's value. *)
      Alcotest.(check int) "crashing replica 2's own commit_number really is 0, not the primary's 1" 0
        (Replica.commit_number replicas.(1));
      Alcotest.(check int) "and crashing replica 3's is too" 0 (Replica.commit_number replicas.(2));
      (* The proof the view pair really may be read off replicas.(0) here: no view change has
         happened, so the crashing replicas' OWN view/last_normal_view are identical to it. If a
         future edit to this scenario introduces a view change, these assertions fail and the
         value-sourcing above has to change with it -- which is the point of asserting them. *)
      Alcotest.(check (pair int int)) "crashing replica 2's own view pair matches the survivor's"
        (Replica.view_number replicas.(0), Replica.last_normal_view replicas.(0))
        (Replica.view_number replicas.(1), Replica.last_normal_view replicas.(1));
      Alcotest.(check (pair int int)) "and crashing replica 3's does too"
        (Replica.view_number replicas.(0), Replica.last_normal_view replicas.(0))
        (Replica.view_number replicas.(2), Replica.last_normal_view replicas.(2));
      (* THE CRASH, exactly test 8's: two replicas go down with torn superblocks. Both must refuse. *)
      List.iter
        (fun i ->
          let came_back = restart ~lose_superblock:true i in
          if not came_back then c.down.(i) <- true;
          c.restarted.(i) <- true;
          refusals := (i, came_back) :: !refusals)
        [ 1; 2 ];
      settle ();
      check c ~phase:"after-the-crash" replicas;
      (* THE REPAIR, as a separate operator act. *)
      List.iter
        (fun i ->
          let came_back = restart ~repair_superblock:truth i in
          if came_back then c.down.(i) <- false;
          recoveries := (i, came_back) :: !recoveries)
        [ 1; 2 ];
      settle ();
      check c ~phase:"after-the-repair" replicas;
      (* AND THE CLUSTER STILL WORKS: a further proposal commits normally through the repaired
         replicas, which is what makes this a recovery rather than merely three processes running. *)
      Replica.propose replicas.(0) (v "committed-after-the-repair");
      settle ();
      committed_again := Replica.is_committed replicas.(0) (v "committed-after-the-repair");
      check c ~phase:"after-committing-again" replicas;
      durable_after :=
        Array.to_list (Array.map (fun r -> Replica.for_test_wal_read r ~op_number:1) replicas));
  Alcotest.(check (list (pair int bool)))
    "precondition: both replicas REFUSED to come back before the repair"
    [ (1, false); (2, false) ]
    (List.sort compare !refusals);
  Alcotest.(check (list (pair int bool)))
    "THE POINT: the repair brings both of them back for real"
    [ (1, true); (2, true) ]
    (List.sort compare !recoveries);
  Alcotest.(check bool) "and the cluster commits a new value afterwards" true !committed_again;
  Alcotest.(check (list (option string)))
    "the originally committed value is still durably readable on all three disks"
    (List.init replica_count (fun _ -> Some "committed-before-the-crash"))
    (List.map (Option.map (function Value.Scalar (Value.String x) -> x | _ -> "?")) !durable_after);
  fail_on_violations ~what:"torn-superblock repair scenario" c.violations

(* ---------------------------------------------------------------------------------------------
   REGRESSION TESTS, subtask 3.8: [Cluster.for_test_settle_loop] itself, exercised directly with a
   FAKE round-delivery/clock rather than through a real cluster.

   WHY NOT A REAL CLUSTER, per this task's own report. The obvious end-to-end test -- corrupt or
   truncate the primary's own about-to-commit slot via a real [run_on_file_storage] cluster,
   propose one op, call the exposed [settle] once, expect [Did_not_settle] -- was tried first and
   does NOT reproduce: this VSR subset has no self-perpetuating message loop ([check_timeout] is
   the only thing that ever re-drives a stalled replica, and it is purely caller-driven, never
   automatic), so a primary that can never commit still reaches a genuine, CORRECT quiescent state
   once its initial Prepare/Prepare_ok exchange finishes -- nothing further pending, no handler
   still running, which is exactly what [settle] is defined to recognise as "done". [settle]
   returning normally there is right, not a gap. Testing the wall-clock deadline mechanism itself
   -- that it still fires for a cluster that genuinely never stops needing to wait, and still
   tolerates one that keeps making real progress no matter how slowly -- needs an entry point
   independent of whether this protocol happens to have a reachable livelock at all, which is
   exactly what [for_test_settle_loop] is for (see its own doc comment in [cluster.mli]).

   Driving the loop directly like this is also what makes both properties checkable in a few
   milliseconds with zero real sleeping, rather than needing minutes of real wall-clock time (or a
   flaky small [max_wait_duration]) to prove a "runs arbitrarily long without a reset" claim. *)

(* GENUINELY, PERMANENTLY STUCK: real delivery happens exactly once (round 1), and the simulated
   in-flight handler never completes after that -- [inflight] stays at 1 forever, with no further
   round ever delivering anything to reset the deadline. This is what a truly hung handler (an I/O
   operation that never completes at all, not merely a slow one) looks like from [settle]'s own
   perspective, and it must still raise [Did_not_settle] -- proving the fix does not silently
   disable the harness's own livelock detection. The fake clock advances by a small, realistic
   step per wait (mirroring [run_on_file_storage]'s own real [wait_io]'s tiny real sleep), so the
   deadline is crossed by many small steps accumulating past [max_wait_duration], not by one giant
   jump -- the same way it would happen for real. *)
let test_settle_loop_still_raises_did_not_settle_when_genuinely_stuck () =
  let round = ref 0 in
  let inflight_val = ref 0 in
  let clock_t = ref 0.0 in
  let drain_round () =
    incr round;
    if !round = 1 then begin
      inflight_val := 1;
      true
    end
    else false
  in
  Alcotest.check_raises
    "a cluster whose in-flight handler never completes again still raises Did_not_settle, bounded \
     by real wall-clock time since its last real delivery"
    Riptide_dst.Cluster.Did_not_settle (fun () ->
      Riptide_dst.Cluster.for_test_settle_loop ~drain_round
        ~inflight:(fun () -> !inflight_val)
        ~yield:(fun () -> ())
        ~wait_io:(fun () -> clock_t := !clock_t +. 0.05)
        ~deadline_budget:(Some (1.0, fun () -> !clock_t))
        ~delivery_rounds:500);
  (* Non-vacuity: this must have taken many real wait_io iterations to cross the deadline, not
     raised immediately for some unrelated reason (e.g. [delivery_rounds] exhausting instead). *)
  Alcotest.(check bool)
    (Printf.sprintf "the deadline was crossed by real accumulated wait time (clock reached %f)"
       !clock_t)
    true (!clock_t > 1.0 && !clock_t < 2.0)

(* SLOW BUT GENUINELY, STEADILY PROGRESSING: every one of 200 rounds delivers something real, and
   each round's simulated wait_io jumps the fake clock forward by 1000 "seconds" -- a jump that
   would trivially blow through [max_wait_duration] if the deadline were only ever set once, at
   [settle]'s own start. Requirement (a) of subtask 3.8's fix is that the deadline resets on EVERY
   real delivery, not just once: this is what lets a cluster that keeps making real progress run
   arbitrarily long in wall-clock terms. Total simulated elapsed time here (~200,000 "seconds") is
   many orders of magnitude past [max_wait_duration] (1.0), and this must still return normally. *)
let test_settle_loop_tolerates_unbounded_real_time_between_deliveries_while_progressing () =
  let round = ref 0 in
  let progress_rounds = 200 in
  let inflight_val = ref 0 in
  let clock_t = ref 0.0 in
  let drain_round () =
    incr round;
    if !round <= progress_rounds then begin
      inflight_val := 1;
      true
    end
    else begin
      inflight_val := 0;
      false
    end
  in
  Riptide_dst.Cluster.for_test_settle_loop ~drain_round
    ~inflight:(fun () -> !inflight_val)
    ~yield:(fun () -> ())
    ~wait_io:(fun () ->
      clock_t := !clock_t +. 1000.0;
      inflight_val := 0)
    ~deadline_budget:(Some (1.0, fun () -> !clock_t))
    ~delivery_rounds:(progress_rounds + 10);
  (* Reached here at all means it did not raise -- and non-vacuously exercised a total elapsed
     time far past [max_wait_duration], not a trivially short run. *)
  Alcotest.(check bool)
    (Printf.sprintf
       "settled normally despite %d rounds of real progress spanning far more simulated \
        wall-clock time (%f) than max_wait_duration (1.0) would tolerate between two deliveries"
       progress_rounds !clock_t)
    true
    (!clock_t > 1.0 *. Float.of_int progress_rounds)

(* NOTHING DELIVERED ON THE VERY FIRST ROUND, WITH A HANDLER ALREADY IN FLIGHT -- the one scenario
   that reaches [for_test_settle_loop]'s [if !deadline = None then start_deadline_tracking ()]
   fallback, and the only thing keeping the loop bounded in it (final-review finding I3).

   WHY THIS SHAPE. The deadline is normally armed by the [if delivered then start_deadline_tracking
   ()] line, which only runs on a round that actually delivered something. A caller supplying
   [deadline_budget = Some _] has the OLD fixed [io_waits] countdown disabled by that very fact
   (it applies only when [deadline_budget = None]), so if the first round delivers nothing while
   [inflight () > 0] and the fallback did not arm the deadline, [deadline_exceeded ()] would stay
   [false] forever and this loop would spin without any bound at all: [delivery_rounds] is never
   decremented either, because nothing is ever delivered.

   Both existing direct tests above miss this branch entirely -- the stuck one delivers on round 1
   (so the deadline is armed by the normal path), and the progressing one delivers on every round.
   Deleting the fallback line leaves the whole suite green, which is exactly the untested-rule
   liability this repo's own CLAUDE.md treats as a defect; hence this test.

   [max_fake_waits] is what makes the mutation test fail FAST instead of hanging the suite: with
   the fallback line removed, the loop never terminates, so the fake [wait_io] itself raises a
   distinct exception once it has been called absurdly more times than the real deadline needs
   (21). [Alcotest.check_raises] then reports the wrong exception rather than the run wedging. *)
exception Settle_loop_ran_unbounded

let max_fake_waits = 10_000

let test_settle_loop_bounds_a_first_round_that_delivers_nothing_while_inflight () =
  let rounds = ref 0 in
  let waits = ref 0 in
  let clock_t = ref 0.0 in
  (* Never delivers anything, not even on the first round -- while a handler is reported in flight
     from the very start. *)
  let drain_round () =
    incr rounds;
    false
  in
  let wait_io () =
    incr waits;
    if !waits > max_fake_waits then raise Settle_loop_ran_unbounded;
    clock_t := !clock_t +. 0.05
  in
  Alcotest.check_raises
    "a first round that delivers nothing while a handler is in flight is still bounded: the \
     deadline engages from that very round and Did_not_settle fires"
    Riptide_dst.Cluster.Did_not_settle (fun () ->
      Riptide_dst.Cluster.for_test_settle_loop ~drain_round
        ~inflight:(fun () -> 1)
        ~yield:(fun () -> ())
        ~wait_io
        ~deadline_budget:(Some (1.0, fun () -> !clock_t))
        ~delivery_rounds:500);
  (* Non-vacuity, three ways. (1) It really was the wall-clock deadline that stopped this, crossed
     by accumulated small waits, not some unrelated budget. *)
  Alcotest.(check bool)
    (Printf.sprintf "the deadline was crossed by real accumulated wait time (clock reached %f)"
       !clock_t)
    true
    (!clock_t > 1.0 && !clock_t < 2.0);
  (* (2) It stopped nowhere near the guard above -- i.e. the deadline, not the guard, is the bound
     being demonstrated. *)
  Alcotest.(check bool)
    (Printf.sprintf "...far below the test's own runaway guard (%d waits of %d)" !waits
       max_fake_waits)
    true
    (!waits < max_fake_waits / 10);
  (* (3) Every single round of this run delivered nothing, so [delivery_rounds] (500) was never
     consumed and cannot be what raised: rounds and waits track each other one-for-one, with the
     final round raising before it waits. *)
  Alcotest.(check int) "every round waited exactly once, the last one raising instead" (!waits + 1)
    !rounds

(* SUBTASK 3.8, THE REAL ROOT CAUSE, FOUND BY AN INDEPENDENT REVIEW AFTER THREE ROUNDS OF THIS
   PLAN'S OWN OVERCLAIMED DIAGNOSES: [drain_round]'s result ([delivered]) is a STALE read taken
   BEFORE [yield ()] runs -- [inflight ()] is read AFTER and is fresh, so the cluster really is
   idle the instant it is checked. A handler that is still in flight at the top of the round can
   complete DURING the yield -- in the very same step both making a new delivery available (e.g. a
   coordinator's own broadcast, once its own handler finally returns) and dropping [inflight] to
   0 -- and that new delivery is invisible to the already-stale [delivered]. Without a re-check,
   [cluster.ml]'s own loop used to fall straight to "nothing pending and nothing in flight,
   genuinely quiesced" on exactly this round, silently leaving a real, already-queued message
   undelivered. This is not a hypothetical: it is the measured mechanism behind every occurrence
   traced so far of [test_ring_capacity_boundary]'s real-load flake (see [cluster.ml]'s own doc
   comment at the fix for the full trace), reproduced here with zero real I/O and zero real time.

   The scenario: round 1 delivers nothing while a handler is already "in flight" ([inflight = 1]).
   [yield] simulates that handler completing mid-yield exactly as described above -- dropping
   [inflight] to 0 and arming a delivery that only becomes visible on the NEXT [drain_round] call,
   never on this one. The old code's stale [delivered = false] plus the now-zero [inflight ()]
   together satisfy "genuinely quiesced" immediately, without the armed delivery ever being drained
   -- this test's own non-vacuity check ([armed] still [true] at the end) is exactly that failure,
   caught live: deleting the fix's re-check reproduces it. *)
let test_settle_loop_redrains_a_delivery_that_becomes_available_during_yield () =
  let round = ref 0 in
  let inflight_val = ref 1 in
  let armed = ref false in
  let drain_round () =
    incr round;
    if !armed then begin
      armed := false;
      true
    end
    else false
  in
  let yield () =
    if !round = 1 then begin
      inflight_val := 0;
      armed := true
    end
  in
  Riptide_dst.Cluster.for_test_settle_loop ~drain_round
    ~inflight:(fun () -> !inflight_val)
    ~yield ~wait_io:(fun () -> ())
    ~deadline_budget:(Some (1.0, fun () -> 0.0))
    ~delivery_rounds:10;
  Alcotest.(check bool)
    "the message that became available during yield -- after inflight had already dropped to 0 -- \
     was actually re-drained before settle declared quiescence, not silently missed"
    true (not !armed)

(* ---------------------------------------------------------------------------------------------
   Test 12 (task-master subtask 3.7, Task 6 of the ring-eviction-watermark plan): RESTART RECOVERY
   for the ring-eviction materialization watermark needs NO new durable state of its own.

   WHY THIS TEST IS HERE AND NOT IN test_lattice_materialize_crypto_scenarios.ml, where the rest of
   that mechanism's end-to-end proof lives: that file's own header states, as a deliberate design
   boundary, that it does no view changes and no restarts, because its harness is hand-rolled (real
   [Eio_linux] io_uring cannot nest inside the fiber-based [Riptide_dst.Cluster] transport) and
   because restarts are "exhaustively covered by the prior plan's own Task 11 over this same
   [Replica.t] code" -- i.e. by this file. Respecting that boundary rather than overriding it means
   the one piece of Task 6 that needs a real crash-and-come-back lands here, on the harness that
   already has one ([Riptide_dst.Cluster.run_on_file_storage]'s own [restart], used by tests 1, 2
   and 8 above).

   WHAT THE DESIGN CLAIMS, and it is a claim worth testing precisely because it is a claim about
   something NOT existing. The watermark a ring-eviction consumer keeps
   ({!Riptide_batch_commit.Batch_commit.materialize_up_to}'s own doc: "the caller owns any watermark
   it wants to keep") is pure in-memory state, and this plan's Decision 2 says a restarted consumer
   needs no persisted copy of it: it re-primes itself by reading the replica's own recovered
   {!Riptide_vsr.Replica.commit_number} and re-running [materialize_up_to] once at construction.
   That is sound only if re-materializing an already-materialized range is genuinely inert, which is
   a property of the lattice join rather than of any bookkeeping -- so the durable footprint of the
   whole mechanism stays exactly (a) the replica's own WAL/superblock and (b) the materializer's own
   KV directory, with nothing new added by restart recovery.

   EXACTLY HOW FAR THAT CLAIM REACHES, narrowed in fix round 1 after a review (finding C1) found this
   test's original framing overclaimed it. This test runs at the harness's DEFAULT [ring_capacity]
   (4096) over 2 committed ops, so its ring never wraps and nothing is ever evicted: the restarted
   replica's log rebuild recovers the WHOLE log from disk. What the re-prime recovers is therefore
   exactly what the RESTARTED REPLICA'S OWN REBUILT LOG still holds -- and that log is
   {!Riptide_vsr.Replica.restart}'s [readable_prefix], a strictly CONTIGUOUS scan up from op 1, not
   every slot the ring happens to still hold. It cannot recover a still-unmaterialized entry once the
   ring has evicted anything at all, and the correct statement of Decision 2's guarantee is therefore
   "no new durable watermark state is needed for whatever the rebuilt log still holds", NOT "restart
   is loss-proof regardless of how far behind the consumer was". That boundary is a real, disclosed
   limitation of this mechanism rather than something it claims to solve, and it is pinned as a
   running test of its own: see [test_restart_after_the_ring_wrapped_cannot_recover_an_unmaterialized_entry]
   (test 13) below, which runs the same re-prime at a [ring_capacity] small enough that the ring
   genuinely wraps and proves what actually survives.

   Both halves are asserted, and the second is the one that makes this more than a re-run of
   [test_materialize_up_to_is_idempotent] (test_batch_commit_materialize.ml): the materialized value
   must be IDENTICAL across a real crash-and-come-back of the replica that produced it, AND the
   materializer's whole on-disk directory must be byte-identical afterwards -- so the claim "no new
   durable watermark state" is evidence about real bytes on a real disk rather than an argument about
   what the code appears to write. Non-vacuity is asserted in both directions too: the value must be
   genuinely non-[bottom] before the restart (otherwise "identical afterwards" is trivially true of
   two empty accumulators), and the snapshot must be genuinely non-empty.

   WHAT IS DELIBERATELY *NOT* WIRED HERE, stated because it is a real, disclosed gap rather than an
   oversight: [Riptide_dst.Cluster]'s own [restart] rebuilds a replica with
   {!Riptide_vsr.Replica.restart} and does not (and has no parameter to) re-attach
   [?on_commit_advanced], nor does [run_on_file_storage] have a way to pass
   {!Riptide_storage.File_storage.create}'s [?may_evict] at all. This test needs neither: it drives
   [materialize_up_to] directly, which is exactly the construction-time re-prime Decision 2
   specifies, and it is that re-prime -- not the hook -- that restart recovery rests on. Closing
   that harness gap belongs with a real caller (there is still no [bin/] entrypoint in this repo);
   see this task's own report. *)

module Lww_materializer =
  Riptide_materialize.Materializer.Make (Riptide_lattice.Last_write_wins)
    (Riptide_storage.File_kv_store)

(* The same real codec convention test_materializer.ml and test_batch_commit_materialize.ml already
   establish for [Last_write_wins]: the lattice value as a two-field [Value.Record], then
   [Value.canonical_encode]/[canonical_decode] -- this repo's own wire-encoding primitive, not a
   placeholder and not a new format invented here. Used twice over, exactly as in that file: as the
   materializer's own KV codec ([string <-> t]) and as the [Value.value -> t] payload decoder
   {!Riptide_batch_commit.Batch_commit.materialize_sink} needs. *)
let lww_to_value (w : Riptide_lattice.Last_write_wins.t) =
  Value.Record [ ("value", w.value); ("timestamp", Value.Scalar (Value.Int w.timestamp)) ]

let lww_of_value = function
  | Value.Record fields ->
      let value = List.assoc "value" fields in
      let timestamp =
        match List.assoc "timestamp" fields with
        | Value.Scalar (Value.Int i) -> i
        | _ -> invalid_arg "Last_write_wins codec: malformed timestamp field"
      in
      Riptide_lattice.Last_write_wins.{ value; timestamp }
  | _ -> invalid_arg "Last_write_wins codec: expected a Record"

(* Every byte of every regular file under [root], keyed by path -- the evidence behind "no new
   durable state", read off the filesystem directly rather than through the API of the module that
   wrote it (the same technique test_lattice_materialize_crypto_scenarios.ml's own [raw_bytes_under]
   uses for its no-plaintext-on-disk property). *)
let durable_snapshot root =
  let rec walk acc d =
    Array.fold_left
      (fun acc name ->
        let p = Filename.concat d name in
        if Sys.is_directory p then walk acc p
        else begin
          let ic = open_in_bin p in
          Fun.protect
            ~finally:(fun () -> close_in ic)
            (fun () -> (p, really_input_string ic (in_channel_length ic)) :: acc)
        end)
      acc (Sys.readdir d)
  in
  List.sort compare (walk [] root)

(* [durable_snapshot] in the form Alcotest can print and compare: one line per file, its length and
   its digest. Shared by both restart tests below. *)
let fingerprint snapshot =
  List.map
    (fun (p, s) -> Printf.sprintf "%s:%d:%s" p (String.length s) (Digest.to_hex (Digest.string s)))
    snapshot

(* The one [merge_key] every write in both restart tests below carries. *)
let restart_merge_key = "mk"

(* ONE real [File_kv_store]-backed materializer, living in its OWN directory outside every replica's
   [File_storage] directory, so it survives a [restart] untouched -- which is what a real crash looks
   like from its point of view: only in-memory state (the [Replica.t] and the watermark ref) is
   discarded, everything durable stays. Returned together with the {!Batch_commit.materialize_sink}
   pre-applied over it, since no caller here ever wants one without the other. *)
let make_lww_materializer ~env ~sw dir =
  let materializer =
    Lww_materializer.create
      ~kv:
        (Riptide_storage.File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"materializer" dir)
      ~owner:"materializer"
      ~decode:(fun s -> lww_of_value (Value.canonical_decode s))
      ~encode:(fun w -> Value.canonical_encode (lww_to_value w))
  in
  let sink : Riptide_batch_commit.Batch_commit.materialize_sink =
    {
      write =
        (fun ~merge_key payload ->
          Lww_materializer.write materializer ~merge_key (lww_of_value payload));
    }
  in
  (materializer, sink)

let propose_lww_write replica ~idempotency_key ~timestamp ~value_str =
  Riptide_batch_commit.Batch_commit.propose
    (Riptide_batch_commit.Batch_commit.create ~replica ~authorize:Riptide_batch_commit.Batch_commit.allow_all ())
    ~idempotency_key
    [
      {
        Riptide_batch_commit.Batch_commit.actor = "actor-1";
        causation = Value.content_hash (v (idempotency_key ^ "-c"));
        correlation = Value.content_hash (v (idempotency_key ^ "-r"));
        payload = lww_to_value { Riptide_lattice.Last_write_wins.value = v value_str; timestamp };
        merge_key = Some restart_merge_key;
      };
    ]

let test_restart_recovery_needs_no_new_durable_watermark_state () =
  Eio_main.run @@ fun env ->
  with_tmp_dir @@ fun dir ->
  with_tmp_dir @@ fun mat_dir ->
  Eio.Switch.run @@ fun sw ->
  let materializer, sink = make_lww_materializer ~env ~sw mat_dir in
  let merge_key = restart_merge_key in
  let propose_write = propose_lww_write in
  let first : Riptide_lattice.Last_write_wins.t =
    { value = v "materialized-before-the-crash"; timestamp = 7L }
  in
  let second : Riptide_lattice.Last_write_wins.t =
    { value = v "committed-but-not-yet-materialized"; timestamp = 9L }
  in
  Riptide_dst.Cluster.run_on_file_storage ~env ~dir ~seed:1 ~replica_count:3
    (fun ~replicas ~settle ~restart ->
      (* ---- PART 1: a consumer that was fully CAUGHT UP when it crashed. The brief's own core
         claim: the value comes back identical, and the re-prime adds nothing durable. ---- *)
      let watermark = ref 0 in
      propose_write replicas.(0) ~idempotency_key:"k1" ~timestamp:7L
        ~value_str:"materialized-before-the-crash";
      settle ();
      Alcotest.(check int) "precondition: the batch really did commit across the cluster" 1
        (Replica.commit_number replicas.(0));
      (* The pre-crash consumer: drain the committed prefix, record the watermark. No
         [?on_commit_advanced] is involved -- this test is about the construction-time re-prime
         Decision 2 specifies, which is what a restart actually depends on. *)
      Riptide_batch_commit.Batch_commit.materialize_up_to replicas.(0) ~materialize:sink
        ~through_commit_number:(Replica.commit_number replicas.(0));
      watermark := Replica.commit_number replicas.(0);
      let before_restart = Lww_materializer.read materializer ~merge_key in
      (* NON-VACUITY, first direction: there is a real, non-bottom materialized value to compare. *)
      Alcotest.(check bool) "precondition: the write really was materialized before the crash" true
        (before_restart = first);
      let snapshot_before = durable_snapshot mat_dir in
      Alcotest.(check bool) "precondition: the materializer really did put bytes on disk" true
        (snapshot_before <> []);
      (* THE CRASH. In-memory [Replica.t] and this test's own watermark ref are both discarded;
         the durable [File_storage] survives, per [restart]'s own contract. No [~lose_superblock],
         so this is the ordinary restart every consumer must handle, not finding C1's torn-superblock
         case (test 8 above owns that one). *)
      Alcotest.(check bool) "the replica came back from the crash" true (restart 0);
      Alcotest.(check int) "...and recovered its own committed prefix from its superblock" 1
        (Replica.commit_number replicas.(0));
      (* THE WHOLE OF RESTART RECOVERY: a fresh watermark ref, re-primed from the replica's own
         recovered [commit_number], plus one re-materialize. Nothing is read back from any durable
         store of the consumer's own, because there is none to read. *)
      let fresh_watermark = ref 0 in
      Riptide_batch_commit.Batch_commit.materialize_up_to replicas.(0) ~materialize:sink
        ~through_commit_number:(Replica.commit_number replicas.(0));
      fresh_watermark := Replica.commit_number replicas.(0);
      let after_restart = Lww_materializer.read materializer ~merge_key in
      Alcotest.(check bool)
        "restart recovery converges to the identical materialized value, with no new durable \
         watermark state"
        true (before_restart = after_restart);
      Alcotest.(check int)
        "the fresh watermark re-primed to exactly its pre-crash value, from the replica's own \
         recovered commit_number alone"
        !watermark !fresh_watermark;
      (* THE "NO NEW DURABLE STATE" HALF, as bytes rather than as an argument: the crash, the
         restart and the re-materialize together added, removed and changed nothing on disk under
         the materializer -- so there is no watermark file, no checkpoint, and no bookkeeping entry
         anywhere for a future change to accidentally start depending on. (The re-materialize does
         re-[put] the key; that its bytes are identical is the lattice join's idempotence showing up
         directly in the durable layer.) *)
      Alcotest.(check (list string))
        "the materializer's durable directory is byte-identical after the restart and re-prime"
        (fingerprint snapshot_before)
        (fingerprint (durable_snapshot mat_dir));

      (* ---- PART 2: a consumer that crashed BEHIND -- which is what makes the re-prime
         load-bearing rather than decorative, and is the case Part 1 alone cannot distinguish.
         Part 1's "identical value" holds even if the re-prime were deleted entirely: the
         materializer is durable, so its READ was always going to return the same bytes. The
         question restart recovery actually has to answer is what happens to a write that committed
         durably but whose materialize step the crash interrupted (batch_commit.mli's own
         crash-between-commit-and-materialize case) -- with no watermark on disk to tell the new
         process how far it got. ---- *)
      propose_write replicas.(0) ~idempotency_key:"k2" ~timestamp:9L
        ~value_str:"committed-but-not-yet-materialized";
      settle ();
      Alcotest.(check int) "the second batch committed too" 2 (Replica.commit_number replicas.(0));
      Alcotest.(check bool)
        "...and is deliberately NOT materialized yet: this is the crash-between-commit-and-\
         materialize state, reproduced rather than imagined"
        true
        (Lww_materializer.read materializer ~merge_key = first);
      Alcotest.(check bool) "the second crash-and-come-back also succeeded" true (restart 0);
      Alcotest.(check int) "...recovering commit_number 2 from its own superblock" 2
        (Replica.commit_number replicas.(0));
      (* The identical re-prime as in Part 1 -- same two lines, no extra recovery path -- and it
         legitimately lands the watermark ABOVE where the previous process left it (2, not 1),
         precisely because it is derived from the replica rather than from consumer-side state. *)
      let recovered_watermark = ref 0 in
      Riptide_batch_commit.Batch_commit.materialize_up_to replicas.(0) ~materialize:sink
        ~through_commit_number:(Replica.commit_number replicas.(0));
      recovered_watermark := Replica.commit_number replicas.(0);
      Alcotest.(check bool)
        "the construction-time re-prime alone recovered the committed-but-unmaterialized write"
        true
        (Lww_materializer.read materializer ~merge_key = second);
      Alcotest.(check int)
        "...and the re-primed watermark legitimately sits ABOVE the crashed process's own last \
         value, being derived from the replica's commit_number and nothing else"
        2 !recovered_watermark;
      Alcotest.(check bool) "...which is strictly ahead of where the crashed consumer had got to"
        true
        (!recovered_watermark > !fresh_watermark);
      (* And the re-prime is still inert once it has caught up: running it a second time changes
         no byte on disk. This is the "no new durable state" claim taken around a re-prime that is
         genuinely a no-op, which is the only place the claim is falsifiable. *)
      let snapshot_caught_up = durable_snapshot mat_dir in
      Riptide_batch_commit.Batch_commit.materialize_up_to replicas.(0) ~materialize:sink
        ~through_commit_number:(Replica.commit_number replicas.(0));
      Alcotest.(check (list string))
        "a second, redundant re-prime writes no new durable state at all"
        (fingerprint snapshot_caught_up)
        (fingerprint (durable_snapshot mat_dir)))

(* ---------------------------------------------------------------------------------------------
   Test 13 (fix round 1, review finding C1): THE BOUNDARY of test 12's claim -- what restart recovery
   actually does once the ring has genuinely WRAPPED, pinned rather than left implied.

   WHY THIS EXISTS. Test 12 above runs at [run_on_file_storage]'s DEFAULT [ring_capacity] (4096, see
   [Riptide_dst.Cluster.default_ring_capacity]) over 2 committed ops. That is the regime in which the
   ring never wraps, nothing is ever evicted, and [Replica.restart] rebuilds the WHOLE log from disk
   -- so test 12 proves Decision 2's "no new durable watermark state" claim only where ring eviction,
   the entire subject of this plan, has NOT happened. This test is the same mechanism in the regime
   that matters, at a [ring_capacity] deliberately smaller than the number of ops committed (the same
   technique [test_ring_capacity_boundary] above already uses to make eviction real rather than
   hypothetical), with the consumer deliberately BEHIND when the crash lands.

   WHAT IT FINDS, and it is the honest, narrower behaviour rather than the one the design's own prose
   invited. Two facts about the real code, read rather than assumed:

   1. [Replica.restart]'s log rebuild is [readable_prefix], a CONTIGUOUS scan up from op 1 that stops
      at the first slot that does not read back [Present]. Eviction always destroys the LOWEST live
      op-number first (File_storage's slot assignment is [(op_number - 1) mod ring_capacity], so
      appending [n] overwrites [n - ring_capacity]). Therefore: once the ring has wrapped even ONCE,
      that scan stops immediately at op 1 and the rebuilt in-memory log is EMPTY -- not merely
      missing the evicted entries, but missing the later ones the ring genuinely does still hold,
      because a prefix scan cannot skip a hole. (That is the same [Replica_log.length <> op_number]
      state [propose]/[handle_prepare] already decline to serve from, and the protocol-level
      consequence -- no view change can ever complete past the ring -- is already pinned by
      [test_ring_capacity_boundary] above.)
   2. [materialize_up_to] walks [Replica.entries], i.e. that rebuilt log. So the construction-time
      re-prime recovers NOTHING at all here, for any op, however high the replica's own recovered
      [commit_number] is.

   THE CONSEQUENCE, stated as the disclosed limitation it is: an entry that was BOTH evicted from the
   ring AND never materialized before the crash is genuinely, permanently lost after the restart.
   Nothing in this plan claims otherwise, and nothing in [lib/] is changed to "fix" it -- the raw
   bytes are gone, and no amount of consumer-side bookkeeping can reconstruct them. What Decision 2
   actually guarantees is narrower than its original wording: no new durable watermark state is
   needed for whatever the REBUILT LOG still holds. The safe way for a real consumer to re-prime is
   therefore NOT [watermark := Replica.commit_number r] -- which would falsely claim coverage of
   every op the rebuilt log can no longer see -- but the bound this test asserts,
   [min (Replica.commit_number r) (List.length (Replica.entries r))], which is exactly how far
   [materialize_up_to] can have got and needs no durable state of its own either.

   AND THE SECOND-ORDER EFFECT, asserted here too because a reader will ask: after such a restart the
   eviction gate stops protecting those entries, since
   [Batch_commit.write_at_op_number_has_merge_key] reads the same rebuilt log and answers [false] for
   every op it can no longer see. In this state that costs nothing -- the entries it would have been
   protecting are already gone -- but it is the reason this boundary must be documented rather than
   left for a future caller to discover: the gate is not a second line of defence for a backlog this
   deep, it is inert.
   --------------------------------------------------------------------------------------------- *)

(* Small enough that 4 committed ops wrap it twice, so ops 1 and 2 are physically destroyed while
   ops 3 and 4 are still readable -- which is what makes finding (1) above observable as more than
   "everything was evicted". *)
let wrapped_ring_capacity = 2
let wrapped_ring_ops = 4

let test_restart_after_the_ring_wrapped_cannot_recover_an_unmaterialized_entry () =
  Eio_main.run @@ fun env ->
  with_tmp_dir @@ fun dir ->
  with_tmp_dir @@ fun mat_dir ->
  Eio.Switch.run @@ fun sw ->
  let materializer, sink = make_lww_materializer ~env ~sw mat_dir in
  let read () = Lww_materializer.read materializer ~merge_key:restart_merge_key in
  let value_of n = Printf.sprintf "v%d" n in
  (* Timestamps rise with the op-number, so op [n]'s value STRICTLY WINS [Last_write_wins]' join
     against every earlier op's. That is what makes "the accumulator still holds op 1's value" a
     discriminating assertion rather than a vacuous one: folding in ANY of ops 2..4, at any point,
     would necessarily have changed it. *)
  let lww n : Riptide_lattice.Last_write_wins.t =
    { value = v (value_of n); timestamp = Int64.of_int n }
  in
  (* Task 31 (audit-remediation): [~enable_eviction_gate:false]. [run_on_file_storage] now wires a
     real [?may_evict] by default (see cluster.mli's own doc on that parameter), and this scenario's
     every write DOES carry [restart_merge_key] -- exactly what that gate protects, and with no
     materialization watermark yet implemented (Task 6, not this task), it would never let ops
     1 and 2 be evicted at all, so the ring could never reach the WRAPPED state this test exists to
     study. This test targets a DIFFERENT, already-disclosed limitation (restart recovery losing
     visibility of a still-unmaterialized entry once the ring has wrapped -- see
     [Batch_commit.write_at_op_number_has_merge_key]'s own "AFTER A RESTART OVER A WRAPPED RING"
     doc), which is orthogonal to whether eviction itself is gated; disabling the gate here
     reproduces this call site's exact pre-Task-31 behavior so that limitation stays reachable. *)
  Riptide_dst.Cluster.run_on_file_storage ~env ~dir ~seed:1 ~replica_count:3
    ~ring_capacity:wrapped_ring_capacity ~enable_eviction_gate:false
    (fun ~replicas ~settle ~restart ->
      let r = replicas.(0) in
      (* op 1: committed AND materialized. The only op this consumer ever gets to. *)
      propose_lww_write r ~idempotency_key:"k1" ~timestamp:1L ~value_str:(value_of 1);
      settle ();
      Alcotest.(check int) "precondition: op 1 committed" 1 (Replica.commit_number r);
      Riptide_batch_commit.Batch_commit.materialize_up_to r ~materialize:sink
        ~through_commit_number:1;
      let watermark = ref 1 in
      Alcotest.(check bool) "precondition: op 1 really was materialized before the crash" true
        (read () = lww 1);
      (* ops 2..4: committed, and deliberately NEVER materialized -- the consumer is genuinely
         behind, which is the whole point of this regime. *)
      for n = 2 to wrapped_ring_ops do
        propose_lww_write r
          ~idempotency_key:(Printf.sprintf "k%d" n)
          ~timestamp:(Int64.of_int n) ~value_str:(value_of n);
        settle ()
      done;
      Alcotest.(check int) "precondition: all 4 batches committed" wrapped_ring_ops
        (Replica.commit_number r);
      Alcotest.(check bool)
        "precondition: the consumer is still behind -- ops 2..4 committed, none materialized" true
        (read () = lww 1);
      Alcotest.(check int) "...with its watermark still at 1" 1 !watermark;
      (* THE REGIME, asserted rather than assumed: the ring genuinely wrapped, and op 2 -- committed,
         never materialized -- is among the slots it physically destroyed. *)
      Alcotest.(check bool) "precondition: op 1's slot was destroyed by op 3's append" true
        (Replica.for_test_wal_read r ~op_number:1 = None);
      Alcotest.(check bool)
        "precondition: op 2's slot -- committed AND never materialized -- was destroyed by op 4's \
         append"
        true
        (Replica.for_test_wal_read r ~op_number:2 = None);
      Alcotest.(check bool)
        "...while the two most recent slots ARE still physically readable, which is what makes the \
         prefix-scan finding below distinguishable from 'the whole ring was lost'"
        true
        (Replica.for_test_wal_read r ~op_number:3 <> None
        && Replica.for_test_wal_read r ~op_number:4 <> None);
      let snapshot_before = durable_snapshot mat_dir in
      Alcotest.(check bool) "precondition: the materializer really did put bytes on disk" true
        (snapshot_before <> []);
      (* THE CRASH. Same ordinary restart as test 12's -- no [~lose_superblock]. *)
      Alcotest.(check bool) "the replica came back from the crash" true (restart 0);
      let r = replicas.(0) in
      Alcotest.(check int)
        "...and recovered its commit_number IN FULL from its own superblock, which is exactly what \
         makes the naive re-prime tempting"
        wrapped_ring_ops (Replica.commit_number r);
      (* FINDING (1): the rebuilt log is EMPTY, even though two of its four slots are still readable
         on disk -- [readable_prefix] is a contiguous scan from op 1 and op 1 is gone. *)
      Alcotest.(check int)
        "the restarted replica's rebuilt in-memory log is EMPTY: readable_prefix stops at op 1, so \
         the still-readable ops 3 and 4 are not recovered either"
        0
        (List.length (Replica.entries r));
      (* THE WHOLE OF RESTART RECOVERY, byte-for-byte the same two lines test 12's part 2 runs. *)
      Riptide_batch_commit.Batch_commit.materialize_up_to r ~materialize:sink
        ~through_commit_number:(Replica.commit_number r);
      (* FINDING (2), stated honestly: it recovered NOTHING. Ops 2, 3 and 4 each carry a strictly
         higher LWW timestamp than op 1, so folding any single one of them in would have moved this
         value -- this assertion cannot pass by accident. *)
      Alcotest.(check bool)
        "the construction-time re-prime recovered NOTHING: ops 2..4 stay unmaterialized, and op 2 \
         (evicted AND never materialized) is permanently lost -- a real, disclosed limitation"
        true
        (read () = lww 1);
      (* Not a one-shot timing artefact: re-running the re-prime does not help, and never will,
         because the bytes it would need are gone. *)
      Riptide_batch_commit.Batch_commit.materialize_up_to r ~materialize:sink
        ~through_commit_number:(Replica.commit_number r);
      Alcotest.(check bool) "...and a second re-prime recovers nothing either" true
        (read () = lww 1);
      (* THE HONEST WATERMARK, and the reason the naive one is wrong. *)
      let honest_watermark =
        min (Replica.commit_number r) (List.length (Replica.entries r))
      in
      Alcotest.(check int)
        "the honest re-primed watermark -- how far materialize_up_to can actually have got -- is 0"
        0 honest_watermark;
      Alcotest.(check bool)
        "...and it is STRICTLY BELOW the replica's own recovered commit_number, so the naive \
         [watermark := Replica.commit_number r] would falsely claim coverage of 4 ops it recovered \
         none of"
        true
        (honest_watermark < Replica.commit_number r);
      (* THE SECOND-ORDER EFFECT: the eviction gate reads the same rebuilt log, so it is now inert
         for every one of these op-numbers. Nothing is being wrongly destroyed (the entries are
         already gone) -- but the gate is not protecting them either, and that must be disclosed
         rather than discovered later. *)
      List.iter
        (fun op_number ->
          Alcotest.(check bool)
            (Printf.sprintf
               "after this restart the eviction gate sees no merge_key write at op %d, so it would \
                freely permit that slot's reuse"
               op_number)
            false
            (Riptide_batch_commit.Batch_commit.write_at_op_number_has_merge_key r ~op_number))
        [ 1; 2; 3; 4 ];
      (* THE PART OF DECISION 2 THAT DOES STILL HOLD, kept as real bytes: even here, restart recovery
         added no durable state of its own. The claim that needed narrowing was about COVERAGE, not
         about footprint. *)
      Alcotest.(check (list string))
        "the materializer's durable directory is byte-identical across the crash and both re-primes: \
         still no watermark file, no checkpoint, nothing new"
        (fingerprint snapshot_before)
        (fingerprint (durable_snapshot mat_dir)))

(* ---------------------------------------------------------------------------------------------
   Task 31 (audit-remediation): [eviction_blocked] is no longer structurally pinned at 0.

   Before this task, nothing in this codebase's real (non-test-only) code ever supplied
   [File_storage.create] a [?may_evict] predicate -- [Riptide_dst.Cluster.run_on_file_storage]'s own
   call site (the one every DST scenario in this file goes through) simply never passed the
   argument, so [Riptide_vsr.Replica.append_refusals]'s own [eviction_blocked] bucket had no way to
   ever become nonzero anywhere this suite could reach, no matter how a scenario was written. This
   test is the real, end-to-end proof that the gap is closed: it drives a [run_on_file_storage]
   cluster (the SAME production-shaped call site every other scenario in this file uses, not a
   hand-rolled one), commits [merge_key]-carrying batches (via [Riptide_batch_commit.Batch_commit],
   the intended real caller of this mechanism -- see [cluster.mli]'s own doc on
   [run_on_file_storage]'s [?may_evict] wiring) past a deliberately tiny [ring_capacity], and checks
   [append_refusals] directly. *)
let test_eviction_blocked_actually_increments_when_may_evict_is_wired () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      let tiny_ring_capacity = 2 in
      Riptide_dst.Cluster.run_on_file_storage ~env ~dir ~seed:1 ~replica_count:3
        ~ring_capacity:tiny_ring_capacity
        (fun ~replicas ~settle ~restart:_ ->
          let r = replicas.(0) in
          let eviction_blocked replica =
            List.assoc "eviction_blocked" (Replica.append_refusals replica)
          in
          Alcotest.(check int) "precondition: eviction_blocked starts at 0" 0
            (eviction_blocked r);
          (* Every write below carries a merge_key, so
             [Batch_commit.write_at_op_number_has_merge_key] answers [true] for every op-number it
             commits -- meaning NONE of them is ever evictable under this task's wiring (there is no
             materialization watermark yet; see cluster.mli's own doc on this half-a-predicate
             limitation). Committing more of them than [tiny_ring_capacity] holds therefore drives
             real backpressure rather than silent eviction: op [tiny_ring_capacity + 1] cannot be
             durably appended anywhere without evicting op 1, which the predicate refuses. *)
          for n = 1 to tiny_ring_capacity + 3 do
            Riptide_batch_commit.Batch_commit.propose
              (Riptide_batch_commit.Batch_commit.create ~replica:r
                 ~authorize:Riptide_batch_commit.Batch_commit.allow_all ())
              ~idempotency_key:(Printf.sprintf "k%d" n)
              [
                {
                  Riptide_batch_commit.Batch_commit.actor = "actor-1";
                  causation = Value.content_hash (v (Printf.sprintf "k%d-c" n));
                  correlation = Value.content_hash (v (Printf.sprintf "k%d-r" n));
                  payload = v (Printf.sprintf "v%d" n);
                  merge_key = Some "mk";
                };
              ];
            settle ()
          done;
          Alcotest.(check bool)
            "eviction_blocked > 0 on the primary -- not structurally pinned at 0 any more" true
            (eviction_blocked r > 0);
          Alcotest.(check int)
            "backpressure, not silent progress: the log never advanced past what the ring can \
             actually hold"
            tiny_ring_capacity (Replica.commit_number r)))

(* ---------------------------------------------------------------------------------------------
   Task 32 (audit-remediation): "a stranded replica keeps retrying its view-change broadcast" --
   a real VSR liveness bug the audit found by live reproduction: a replica whose own
   [StartViewChange] broadcast is dropped by a transient partition never retries it, even after
   the partition heals, and is stranded in [View_change] status forever.

   ROOT CAUSE (confirmed by reading [lib/vsr/replica.ml] directly, not assumed): [has_dvc_quorum]
   requires BOTH [is_primary t] for the NEW view AND an f+1 DVC-sender quorum, so before this
   task's fix, [try_forfeit_view_change]'s own [if not (has_dvc_quorum t dvcs) then ()] branch was
   a bare no-op for EVERY backup replica in [View_change] status, unconditionally -- not merely
   "when short of a DVC quorum". [check_timeout]'s own [View_change] branch only ever calls
   [try_forfeit_view_change], so a replica below that quorum -- primary-elect or plain backup --
   had no mechanism to ever retry a dropped broadcast, no matter how many more timeouts fired.

   HAND-DRIVEN, not Cluster/Sim_transport/Eio-based: this reproduction needs one precise, targeted
   fault ("replica 2's own StartViewChange broadcast, specifically, is dropped for a while, then
   heals") that the file's own randomized [Network.fault_config]/[Cluster.run] machinery has no
   deterministic way to express, and no real transport or dispatch fiber is needed to exercise it
   -- matching test_vsr_replica.ml's and test_vsr_replica_view_change.ml's own established
   convention of driving real protocol actions via direct [Replica.check_timeout]/
   [Replica.handle_message] calls instead. The 3-replica setup (replica 1 the initial primary,
   pinned to view 1, then silently "crashes"; both surviving backups independently fire
   check_timeout) mirrors test_vsr_replica_view_change.ml's own
   [test_single_view_change_survives_primary_failure] -- see that test's own doc comment for
   exactly why BOTH surviving backups, not one, are required for any view change to ever reach a
   DVC quorum at all -- with exactly one new fault layered on top: replica 2's own broadcast never
   arrives anywhere the first time. *)
let test_a_dropped_start_view_change_broadcast_is_retried_not_abandoned () =
  let replica_count = 3 in
  let svc_limit = 10 (* generous: this test is about the retry MECHANISM, not the budget bound --
                         see test_vsr_replica.ml's own test_check_timeout_bounded_by_svc_limit for
                         that separate property. *) in
  (* [mailbox.(to_)] queues every [(sender, bytes)] pair currently addressed to replica [to_], in
     send order. Delivery is driven explicitly by this test's own [deliver_all] below -- there is
     no dispatch fiber and no real (simulated) transport here, unlike
     test_vsr_replica_view_change.ml's Eio-based harness. *)
  let mailbox = Array.make (replica_count + 1) [] in
  (* Replica 2's own outbound [Start_view_change] broadcast is dropped for as long as this is
     [true] -- simulating a transient partition on replica 2's own outbound link, the audit's own
     framing. Nothing else is affected: messages TO replica 2, and every OTHER message type FROM
     replica 2 (its own later DoViewChange/StartView), are delivered normally even while this is
     [true]. Deliberately this narrow, rather than a general partition, so the reproduction
     isolates exactly the one liveness gap this task fixes and nothing else. *)
  let drop_r2_svc_broadcast = ref true in
  let route ~from ~to_ bytes =
    let is_r2_svc =
      from = 2 && match Message.decode bytes with Message.Start_view_change _ -> true | _ -> false
    in
    if not (!drop_r2_svc_broadcast && is_r2_svc) then mailbox.(to_) <- (from, bytes) :: mailbox.(to_)
  in
  let replicas =
    Array.init replica_count (fun i ->
        let my_id = i + 1 in
        let r =
          Replica.create ~storage:(Replica.volatile_storage ()) ~my_id ~replica_count ~svc_limit
            ~send:(fun ~to_ bytes -> route ~from:my_id ~to_ bytes) ()
        in
        Replica.for_test_set_view_number r 1 (* Primary(1) = 1, matching this suite's own convention *);
        r)
  in
  (* Drains every mailbox, including messages newly enqueued BY the very deliveries this same call
     makes, until a full pass over [1..replica_count] adds nothing new -- i.e. until the cluster is
     fully quiescent given whatever has been sent so far. Replica 1 (the "dead" primary below) is
     never handed to [Replica.handle_message] -- messages addressed to it simply accumulate
     unread and are dropped here, exactly matching test_vsr_replica_view_change.ml's own
     [stop]'d-replica convention for "this process is gone", just without a real fiber to stop. *)
  let deliver_all () =
    let progressed = ref true in
    while !progressed do
      progressed := false;
      for to_ = 1 to replica_count do
        match List.rev mailbox.(to_) with
        | [] -> ()
        | msgs ->
          mailbox.(to_) <- [];
          List.iter
            (fun (sender, bytes) ->
              progressed := true;
              if to_ <> 1 then Replica.handle_message replicas.(to_ - 1) ~sender bytes)
            msgs
      done
    done
  in
  let backup2 = replicas.(1) and backup3 = replicas.(2) in
  (* Both surviving backups fire check_timeout independently, BEFORE any delivery -- each one's own
     [recv_svc] starts genuinely empty from its own check_timeout's reset, so each decision is
     independent rather than one adopting the other's already-broadcast view. *)
  Replica.check_timeout backup2
  (* Normal -> View_change, view 1 -> 2 (Primary(2) = 2, so replica 2 is primary-elect of the view
     it is about to try for); broadcasts StartViewChange{v=2;i=2} to peers 1 and 3 -- DROPPED to 3
     (and irrelevantly to dead replica 1) by [drop_r2_svc_broadcast] above. *);
  Replica.check_timeout backup3
  (* Normal -> View_change, view 1 -> 2; broadcasts StartViewChange{v=2;i=3} to peers 1 (dead) and
     2 -- delivered normally: only replica 2's OWN broadcasts are dropped. *);
  deliver_all ();
  (* Replica 3's own broadcast reached replica 2: [ReceiveMatchingSVC] adds 3 to replica 2's own
     [recv_svc], crossing SendDVC's [>= f] threshold (f = 1 at replica_count 3), so replica 2 sends
     itself a DoViewChange (VSR.tla's own "f+1 ... INCLUDING ITSELF", VSR.tla:262-263) -- landing
     exactly ONE distinct DVC sender (itself) in its own [recv_dvc]. Replica 3 never received
     replica 2's own broadcast, so replica 3 has no reason to send ITS OWN DoViewChange to replica
     2 -- replica 2 is one short of the f+1 = 2 [has_dvc_quorum] needs. *)
  Alcotest.(check bool) "replica 2 holds exactly its own self-addressed DVC, none from replica 3" true
    (Replica.for_test_recv_dvc_senders backup2 = [ 2 ]);
  Alcotest.(check bool) "replica 2 has not completed its view change yet" true
    (Replica.status backup2 = Replica.View_change);

  (* THE BUG, reproduced RED against pre-fix code: [drive_n_more_timeouts_after_the_drop] in the
     brief's own pseudocode. Before this task's fix, NOTHING below ever unsticks replica 2 again,
     even once its outbound link heals -- [try_forfeit_view_change]'s own
     [if not (has_dvc_quorum t dvcs) then ()] branch was a bare no-op regardless of [status]/
     [is_primary], so a below-quorum replica had no mechanism to ever retry a dropped broadcast.
     Bounded at 5 more check_timeout calls (an explicit, generous retry budget, not "until it
     works") and stopped the instant replica 2 genuinely returns to Normal -- calling
     [check_timeout] again on an already-Normal replica would start a genuinely NEW,
     unrelated view-change episode (TimerSendSVC's own [status = Normal] guard), which would
     defeat this test's own final assertion that [view_number] lands on exactly 2. *)
  drop_r2_svc_broadcast := false (* the partition heals *);
  let rec drive_until_normal_or_budget_exhausted budget =
    if budget > 0 && Replica.status backup2 <> Replica.Normal then begin
      Replica.check_timeout backup2;
      deliver_all ();
      drive_until_normal_or_budget_exhausted (budget - 1)
    end
  in
  drive_until_normal_or_budget_exhausted 5;
  Alcotest.(check bool) "the replica rejoins the cluster once the partition heals: status back to Normal"
    true
    (Replica.status backup2 = Replica.Normal);
  Alcotest.(check bool) "it is the primary of the view it was trying to reach (Primary(2) = 2)" true
    (Replica.is_primary backup2);
  Alcotest.(check int)
    "view_number landed on exactly 2 -- never bumped past it by a spurious extra episode" 2
    (Replica.view_number backup2);
  Alcotest.(check bool) "the other survivor converged too: also Normal, also at view 2" true
    (Replica.status backup3 = Replica.Normal && Replica.view_number backup3 = 2)

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
    ("wire payload corruption is detected and dropped, not accepted (subtask 3.6)", `Quick,
      test_wire_corruption_is_detected_and_dropped_not_accepted);
    ( "C1/I1: a crash with a torn superblock refuses to come back, and the data survives", `Quick,
      test_a_crash_with_a_torn_superblock_refuses_to_come_back );
    (* Appended, not inserted earlier in this list, so every other test's index (several of which
       are cited by number in doc comments and shell commands elsewhere in this file) stays
       stable. *)
    (Printf.sprintf "ring capacity boundary soak (subtask 3.8 regression coverage, %d iterations)"
       soak_iterations,
      `Slow, test_ring_capacity_boundary_soak);
    ( "settle's wall-clock budget (subtask 3.8) still raises Did_not_settle when genuinely, \
       permanently stuck", `Quick,
      test_settle_loop_still_raises_did_not_settle_when_genuinely_stuck );
    ( "settle's wall-clock budget (subtask 3.8) tolerates unbounded real time between deliveries \
       while the cluster keeps genuinely progressing", `Quick,
      test_settle_loop_tolerates_unbounded_real_time_between_deliveries_while_progressing );
    ( "settle's wall-clock budget (final-review finding I3) still bounds a FIRST round that \
       delivers nothing while a handler is in flight", `Quick,
      test_settle_loop_bounds_a_first_round_that_delivers_nothing_while_inflight );
    ( "subtask 3.8, THE REAL ROOT CAUSE: settle re-drains a delivery that becomes available \
       during yield, after inflight already read 0, instead of silently missing it", `Quick,
      test_settle_loop_redrains_a_delivery_that_becomes_available_during_yield );
    ( "subtask 3.7: the ring-eviction materialization watermark survives a real crash-and-come-back \
       with no durable state of its own", `Slow,
      test_restart_recovery_needs_no_new_durable_watermark_state );
    ( "subtask 3.7, fix round 1 (finding C1): once the ring has WRAPPED, restart recovery cannot \
       recover a still-unmaterialized entry -- the real, narrower boundary of that claim", `Slow,
      test_restart_after_the_ring_wrapped_cannot_recover_an_unmaterialized_entry );
    ( "Task 13 fix round: the superblock repair brings a refusing replica back, with the crashed \
       replicas' own real prior view/commit values", `Quick,
      test_the_superblock_repair_brings_a_refusing_replica_back );
    ( "Task 31 (audit-remediation): eviction_blocked actually increments once ?may_evict is really \
       wired through run_on_file_storage's real File_storage.create call site", `Quick,
      test_eviction_blocked_actually_increments_when_may_evict_is_wired );
    ( "Task 32 (audit-remediation): a dropped StartViewChange broadcast is retried, not abandoned, \
       once the partition heals", `Quick,
      test_a_dropped_start_view_change_broadcast_is_retried_not_abandoned );
  ]
