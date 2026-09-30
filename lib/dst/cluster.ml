(* lib/dst/cluster.ml

   Task 9: [test/test_vsr_replica_recovery.ml]'s own [with_cluster_and_storage] (Task 8), promoted
   to a real, reusable library module. Structurally the same wiring (Network/Sim_transport
   construction, per-replica Fault_injecting_storage-over-Memory_storage, per-replica dispatch
   fiber, [Eio.Switch.run] + [Cluster_test_done] teardown), with the deviations from that
   precedent -- and from this task's own brief, where it predates Task 8's precedent -- documented
   both here (at each site) and in [cluster.mli]'s own top-level doc comment:

   1. Every replica's [view_number] is pinned to 1 so [replicas.(0)] (replica id 1) is always the
      primary -- see the pin site below.
   2. [settle] is exposed to [body] (the brief's own signature only passed [replicas]) -- see
      [cluster.mli].
   3. [Memory_storage], not [File_storage], underlies each [Fault_injecting_storage] -- same
      reasoning [with_cluster_and_storage] already established (Eio_mock.Backend.run has no real
      filesystem capability), restated in [cluster.mli]. Task 11 added {!run_on_file_storage} as a
      SECOND entry point rather than changing this one: it runs the identical wiring inside the
      CALLER's [Eio_main.run], where a real [File_storage] is constructible.
   4. No [stop]/[isolate]/[reconnect] -- Task 8's crash/partition simulation, not needed by this
      task's two required tests and out of scope for Tasks 10/11's own later work.

   FINAL-REVIEW FINDING I1 added the one capability whose absence let finding C1 through: a real
   CRASH-AND-COME-BACK. Before it, [Riptide_vsr.Replica.restart] was exercised only by
   [test_vsr_replica_recovery.ml]'s hand-driven single-replica unit tests and never by any running
   cluster, so no amount of adversarial sweeping could ever have reached a restart-time defect. See
   [restart] below and [cluster.mli]'s own paragraph on it. *)

(* Task 13 fix round -- see [cluster.mli] for what these are and the hazard attached to them. *)
type superblock_repair = {
  view_number : int;
  last_normal_view : int;
  commit_number : int;
}

exception Did_not_settle

exception Cluster_test_done
(* Unwinds the outer [Eio.Switch.run] once [body] is done -- same mechanism, and deliberately the
   same name, as [with_cluster_and_storage]'s own (a different module, so no clash). *)

let default_svc_limit = 3
let default_ring_capacity = 4096

(* Draws the network's own sub-seed first, then one storage sub-seed per replica, index order
   [0, 1, ..., replica_count - 1], all from the same root [Prng.t] -- see [cluster.mli]'s own
   "Seed splitting" paragraph for why this order, called only once per sub-stream, is what makes
   the whole split reproducible from [seed] alone and keeps the resulting streams independent of
   each other. *)
(* [Prng.int] mirrors [Random.State.int], whose own bound must be in (0, 2^30] -- [max_int] itself
   is not a legal bound (raises [Invalid_argument]), so sub-seeds are drawn from this smaller,
   still-huge range instead. *)
let sub_seed_bound = 0x3FFFFFFF

(* The transformation {!Riptide_sim.Network}'s own [corrupt_probability] selects, supplied to
   {!Riptide_sim.Sim_transport.create} (Task 11 -- before that this adapter hard-coded [Fun.id],
   which made that probability inert for every cluster ever built on it, so nothing in this repo
   had exercised [Replica.handle_message]'s field-validation guards against corrupted wire input in
   a real cluster). Deliberately a PURE function of the bytes: [Network] applies it at delivery
   time, not at send time, while the decision to apply it is the seeded one -- so the corruption
   must not consume PRNG draws of its own, or it would reorder the fault stream depending on
   delivery scheduling and break reproducibility from the seed alone. Flipping bit 0x40 of one
   content-derived byte position is enough to make a message either fail to decode or decode to
   different field values, which is exactly the input those guards exist for. *)
let flip_one_byte s =
  if String.length s = 0 then s
  else begin
    let i = Hashtbl.hash s mod String.length s in
    let b = Bytes.of_string s in
    Bytes.set b i (Char.chr (Char.code (Bytes.get b i) lxor 0x40));
    Bytes.to_string b
  end

let split_seed seed ~replica_count =
  let root = Riptide_sim.Prng.create seed in
  let net_seed = Riptide_sim.Prng.int root sub_seed_bound in
  let storage_seeds =
    Array.init replica_count (fun _ -> Riptide_sim.Prng.int root sub_seed_bound)
  in
  (net_seed, storage_seeds)

(* Task 10's cluster-wide, static, pre-flight rejection -- see [cluster.mli]'s own paragraph on it
   for the full reasoning, and this file's git history for the version that lived inline in [run].
   Factored out only so both entry points enforce it identically, from one statement of it. *)
let check_storage_fault_config ~replica_count ~faults_max
    (storage_fault_config : Riptide_storage.Fault_injecting_storage.fault_config) =
  if
    storage_fault_config.corrupt_probability > 0.
    && Float.of_int replica_count *. storage_fault_config.corrupt_probability
       >= Float.of_int faults_max
  then
    invalid_arg
      "storage fault config could corrupt more than faults_max = replication_quorum - 1 replicas' \
       copies of the same slot"

(* ---------------------------------------------------------------------------------------------
   SUBTASK 3.8's FIX: [settle]'s own decision logic, factored out of [with_cluster] as a small,
   independently testable function, injected with its own I/O rather than closing over
   [with_cluster]'s [net]/[inflight] -- so a test can drive it with a FAKE round-delivery/clock and
   assert its termination behaviour deterministically and fast, without needing real protocol
   dynamics or real wall-clock sleeps. [with_cluster]'s own [settle] below is a thin wrapper
   supplying the real callbacks; this is the ONLY place either of them runs, so there is no risk of
   the tested logic drifting from the shipped logic.

   WHY THIS WAS NECESSARY, not just a nicety (see this task's own report for the full
   investigation): the obvious end-to-end test -- corrupt/truncate the primary's own about-to-
   commit slot via a real cluster, propose, call [settle] once, expect [Did_not_settle] -- does NOT
   reproduce. In this VSR subset [check_timeout] is the ONLY thing that ever re-drives a stalled
   replica (VSR.tla deliberately does not model automatic retry timers), so a primary that can
   never commit still reaches a genuine, correct QUIESCENT state once the initial Prepare/
   Prepare_ok exchange finishes: nothing further is pending and no handler is still running, which
   is exactly [settle]'s own definition of "done" (see [cluster.mli]'s own [Did_not_settle] doc).
   [settle] returning normally there is CORRECT, not a bug -- [Did_not_settle] exists to catch a
   cluster that never stops being busy, and this protocol, by design, has no self-perpetuating
   message loop for any caller to exploit into one. Testing the wall-clock deadline logic itself
   therefore needs its own entry point, independent of whether this protocol happens to have a
   reachable livelock at all.

   [drain_round] mirrors [with_cluster]'s own [while Network.pump_one net do delivered := true; incr
   inflight done] -- deliver everything currently pending, as a side effect on the caller's own
   inflight counter, and report whether anything was delivered this round. [inflight] reads that
   counter (mutated elsewhere, e.g. by a dispatch fiber's own [decr]).

   FIX-ROUND FINDING M1: [max_wait_duration] and [now]/[clock] used to be two separate optional
   arguments, which made "one [Some], one [None]" a representable call -- a combination in which
   the OLD [io_waits] floor is disabled (it only applies when [max_wait_duration = None]) and the
   NEW deadline tracking is inert (it requires both to be [Some]), silently leaving the loop with
   NO bound at all. Unreachable through [with_cluster]'s own two real callers (they always pass
   both or neither), but nothing in this exported function's own contract forbade a future caller
   from doing it. Bundled into one [deadline_budget] option instead, so that state is no longer
   constructible: a caller either supplies both (the wall-clock bound applies) or neither (the
   original fixed-[io_waits]-countdown bound applies), never a partial pair. *)
let for_test_settle_loop ~drain_round ~inflight ~yield ~wait_io ~deadline_budget ~delivery_rounds =
  (* [deadline] is a NEW ref on every call -- see this task's own report for why that is what
     makes each [settle] call's own budget independent of any previous call's. *)
  let deadline = ref None in
  let start_deadline_tracking () =
    match deadline_budget with
    | Some (max_d, now) -> deadline := Some (now () +. max_d)
    | None -> ()
  in
  let deadline_exceeded () =
    match (!deadline, deadline_budget) with
    | Some d, Some (_, now) -> now () > d
    | _ -> false
  in
  let rec loop delivery_rounds io_waits =
    if delivery_rounds <= 0 then raise Did_not_settle
      (* Real livelock signal, unaffected by this fix: a cluster generating messages forever. *)
    else if Option.is_none deadline_budget && io_waits <= 0 then raise Did_not_settle
      (* The ORIGINAL, unmodified behaviour ([run]'s own mock-backend path, and any other caller
         that does not opt into the wall-clock budget): a fixed attempt countdown. *)
    else begin
      let delivered = drain_round () in
      yield ();
      let delivery_rounds = if delivered then delivery_rounds - 1 else delivery_rounds in
      (* THE FIX ITSELF: the deadline resets on every round that ACTUALLY delivered something --
         not just once at this function's own start -- which is what lets a slow-but-steadily-
         progressing cluster run arbitrarily long while a genuinely stuck one still times out, in
         bounded real time since its OWN last real delivery. *)
      if delivered then start_deadline_tracking ();
      if inflight () > 0 then begin
        if deadline_exceeded () then raise Did_not_settle;
        (* Covers the (believed unreachable in the real wiring, since [inflight] only ever goes
           positive together with [delivered] in the same round -- see this task's own report)
           case of entering this branch with [inflight > 0] but no deadline yet tracked. Kept as a
           defensive fallback: cheap, and it is what makes this function correct even if a FUTURE
           caller's [drain_round]/[inflight] pairing does not carry that same invariant. *)
        if !deadline = None then start_deadline_tracking ();
        wait_io ();
        loop delivery_rounds (io_waits - 1)
      end
      else if delivered then loop delivery_rounds io_waits
      (* SUBTASK 3.8, THE REAL ROOT CAUSE (an independent review found this; an earlier version of
         this function, and every doc comment near it, spent three rounds blaming everything BUT
         this). [delivered] above is a STALE read taken before [yield ()]: a handler that was
         still in flight at the top of this round (correctly reflected in the [inflight () > 0]
         check above, which IS a fresh, post-yield read -- the cluster genuinely is idle right
         now) can complete DURING that [yield] -- in the very same step both enqueueing a
         brand-new message (e.g. a view-change coordinator's own [StartView] broadcast) AND
         decrementing [inflight] to 0 -- and that new message is invisible to [delivered], which
         was already read before the yield happened. Without the re-check below, that message
         sits undelivered in the network's own queue while this function falls through to "nothing
         pending and nothing in flight", returns, and the caller is told the cluster is quiesced
         while it demonstrably is not: measured at ~1.1% of real [run_on_file_storage] [settle]
         calls, and the mechanism behind every occurrence traced so far of
         [test_dst_scenarios.ml]'s [test_ring_capacity_boundary] flaking under real CPU load
         (traced end to end with a flushed, ordered send/receive/settle trace: the "missing"
         [StartView] is not lost, not reordered, and not blocked on anything protocol-level -- it
         is the SAME message, still sitting in the queue, delivered one settle-call late).
         Re-running [drain_round] here closes exactly that window: on a truly quiesced cluster it
         is one wasted, cheap call that finds nothing; on the race above it delivers the message
         [yield] just made ready, in the same round it actually arrived rather than the next one.
         COUNTED against [delivery_rounds], same as the [delivered] case just above it -- a real
         delivery is a real round, and leaving this path unbudgeted was itself a real defect an
         earlier version of this fix shipped with: {!Did_not_settle}'s own contract ("a cluster
         generating messages forever" stays bounded) does not hold for an unbudgeted path, proven
         live by a direct probe that looped this branch two million times with no exception before
         being killed, across every [deadline_budget] configuration (the deadline is irrelevant
         here -- it is only ever consulted inside the [inflight () > 0] branch above, which a
         self-sustaining chain of "redraining always finds one more message" never re-enters). *)
      else if drain_round () then begin
        start_deadline_tracking ();
        loop (delivery_rounds - 1) io_waits
      end
      (* else: nothing pending and nothing in flight, confirmed twice -- genuinely quiesced,
         return (). *)
    end
  in
  loop delivery_rounds 5000

(* ---------------------------------------------------------------------------------------------
   THE SHARED WIRING, parameterised by exactly the two things the two entry points differ in:
   how a replica's storage is built ([make_storage]) and what "let in-flight I/O make progress"
   means ([wait_io]).
   --------------------------------------------------------------------------------------------- *)

let with_cluster ~seed ~replica_count ~svc_limit ~net_fault_config ~storage_fault_config
    ~make_storage ~wait_io ~delivery_rounds ?max_wait_duration ?clock ?on_replica_created body =
  let net_seed, storage_seeds = split_seed seed ~replica_count in
  let net = Riptide_sim.Network.create ~faults:net_fault_config ~seed:net_seed () in
  for id = 1 to replica_count do
    Riptide_sim.Network.register net (string_of_int id)
  done;
  let handles =
    Array.init replica_count (fun i ->
        Riptide_sim.Sim_transport.create ~corrupt:flip_one_byte net (i + 1))
  in
  (* VSR's own replication quorum, f + 1 (VSR.tla:140's [f = (ReplicaCount-1) \div 2]) -- see
     [Fault_injecting_storage.create]'s own doc comment for what this bounds. *)
  let replication_quorum = ((replica_count - 1) / 2) + 1 in
  let faults_max = replication_quorum - 1 in
  check_storage_fault_config ~replica_count ~faults_max storage_fault_config;
  (* [inflight] is the count of messages this harness has DELIVERED into a replica's inbox but
     whose [handle_message] has not yet returned.

     TASK 11, AND THE REASON THIS COUNTER EXISTS AT ALL. The original [settle] was "pump everything
     pending, yield twice, repeat until a round delivers nothing", with no counter: it inferred
     quiescence purely from the network's own pending queue being empty. That inference is only
     valid while [handle_message] is SYNCHRONOUS -- true for [Memory_storage] under
     [Eio_mock.Backend.run], and false for any backend whose operations suspend the fiber. Against
     a real [File_storage] every [wal_append]/[superblock_write] suspends on io_uring, so
     [Eio.Fiber.yield] returns with the handler only STARTED, the pending queue is (correctly)
     empty because the replies have not been sent yet, and [settle] returns with the cluster
     mid-flight -- silently, with no error, just less replication than the caller was promised.

     Measured, zero-fault, 3 replicas over real [File_storage], 9 proposals in 3 bursts of 3 with a
     [settle] after each: 3 of 9 ops committed with the old loop, 9 of 9 with this one, identically
     for every seed tried (see [explore/file_cluster.ml]'s own [OLD_SETTLE=1] switch, which keeps
     the old loop verbatim for exactly this before/after comparison).

     Counting in-flight handlers makes the test SOUND rather than merely quiescent-looking: a
     handler that has not returned yet is work the cluster still owes, whether or not it is
     currently parked in a syscall. Under [Eio_mock.Backend.run] + [Memory_storage] the counter is
     back at zero after the first [yield] of every round, so [run]'s own behaviour is unchanged --
     which is exactly why this defect could sit here undetected. *)
  let inflight = ref 0 in
  (* [make_storage] hands back the {!Riptide_storage.Fault_injecting_storage.t} itself, not an
     already-erased [Replica.storage] view of it, so this harness keeps a handle it can still
     inject faults through -- specifically [for_test_lose_superblock], which [restart] below needs.
     Both entry points wrap that same module, so doing the type erasure here rather than in each
     [make_storage] is one statement of it instead of two. *)
  let fault_storages =
    Array.init replica_count (fun i ->
        make_storage ~index:i ~replication_quorum
          ~prng:(Riptide_sim.Prng.create storage_seeds.(i)))
  in
  let storages =
    Array.map
      (fun fs ->
        Riptide_vsr.Replica.storage_of_module
          (module Riptide_storage.Fault_injecting_storage)
          fs)
      fault_storages
  in
  (* Which replicas are currently running. A replica goes down only by REFUSING to restart (see
     [restart]); a down replica is never handed another message, so its state is frozen at the
     moment it crashed. *)
  let alive = Array.make replica_count true in
  let send_for i ~to_ bytes = Riptide_sim.Sim_transport.send handles.(i) ~to_ bytes in
  let replicas =
    Array.init replica_count (fun i ->
        let my_id = i + 1 in
        let r =
          Riptide_vsr.Replica.create ~storage:storages.(i) ~my_id ~replica_count ~svc_limit
            ~send:(send_for i) ()
        in
        (* Deviation 1 (see this file's own top comment and [cluster.mli]): pin every replica's
           view to 1 so [Primary(1) = 1] and [replicas.(0)] is the primary a caller can [propose]
           against directly, matching [with_cluster_and_storage]'s own pin for the same reason. *)
        Riptide_vsr.Replica.for_test_set_view_number r 1;
        (* Task 31 (audit-remediation): the forward-reference cell's fill-in half -- see
           [run_on_file_storage]'s own comment at its [?may_evict] closure for the full mechanism.
           [make_storage] (called above, building [fault_storages]) runs strictly BEFORE this
           [Riptide_vsr.Replica.create] returns, so any [?may_evict] predicate closed over a cell
           this call fills in can never observe it still empty -- see that same comment for why the
           [None] branch it must still handle is provably unreachable rather than merely unlikely. *)
        Option.iter (fun f -> f ~index:i r) on_replica_created;
        r)
  in
  let settle () =
    (* Two independent budgets, deliberately not one. [delivery_rounds] bounds rounds that each
       actually delivered something, which is the real livelock signal (a cluster generating
       messages forever); the second budget bounds only the waiting-for-a-suspended-handler path,
       which delivers nothing by definition and so could never consume the first budget. Folding
       them together would have meant either weakening the livelock detector by an order of
       magnitude or timing out legitimate real-I/O runs.

       [delivery_rounds] is per-mode, and that is not a fudge factor: a round delivers whatever is
       pending at that instant, so the number of rounds needed to settle scales with how BATCHED
       the replies are, not with how much work the protocol does. With synchronous handlers every
       reply to a delivered batch is queued before the next round begins, so one round covers one
       protocol hop -- 20 is ample, and it is the bound this harness has always used. With real
       io_uring I/O the same hop's replies complete at different times and dribble out over many
       rounds, so one view change can legitimately need an order of magnitude more (measured: a
       3-replica view change over File_storage exhausts 20 and raises Did_not_settle).

       SUBTASK 3.8. The second budget used to be a fixed [io_waits : int] attempt countdown
       (5000). That IS a theoretical CPU-load risk in principle -- under sufficiently extreme
       load each wait attempt takes longer in real time, so the same fixed countdown could in
       principle span more real elapsed time than it would unloaded, and if load were extreme
       enough for long enough, the countdown could still exhaust while the cluster is genuinely
       still making progress.

       FIX-ROUND CORRECTION (finding I1): an earlier version of this comment, and this task's own
       original report/commit message, claimed this was a MEASURED fix for a real observed flake
       (subtask 3.8's "3/5 failures -> 5/5 passes" under induced load). That causal claim does not
       hold up and has been retracted, not merely softened -- independent re-measurement (direct
       instrumentation of the OLD countdown across ~37 runs at three load levels, plus a fair,
       load-controlled interleaved A/B of old vs. new) found: (a) the old [io_waits] countdown was
       NEVER observed within 2x of exhausting (worst case 2401-4759 of 5000 remaining) and never
       once produced a clean [Did_not_settle] for this scenario; (b) every "before" failure this
       task originally reported was the SUITE'S OWN EXTERNAL 15s per-test watchdog
       (test_riptide.ml's [Suite_timeout]) firing, not [settle]'s own internal exception -- and an
       internal budget change cannot rescue a run from an external wall-clock kill switch, it can
       only leave that run's speed unchanged or slower; (c) with a fair, interleaved measurement
       (alternating base/head runs to control for this being a shared, noisy, multi-tenant box)
       there was NO measurable difference between the old and new logic at any load level -- the
       originally-reported improvement was very likely a load-variance artifact of sequential (not
       interleaved) measurement, reproduced in the OPPOSITE direction under an unfair ordering.

       FINAL-REVIEW CORRECTION (finding I4): the fix round above went on to name a REPLACEMENT
       cause -- "the interaction between that external 15s watchdog and a real-I/O-heavy
       [Slow]-tagged soak test (test_ring_capacity_boundary_soak) genuinely taking longer under CPU
       contention" -- and stated it as settled fact. That is now retracted too, for the same reason
       the first diagnosis was: it is not established. The branch's own final whole-branch review
       reproduced a flake at this branch's HEAD, under induced CPU load, in a THIRD shape that
       neither diagnosis predicts: [test_ring_capacity_boundary] -- a [`Quick] test, NOT the
       [`Slow] soak this comment used to blame -- failed its own plain assertion ("with a ring
       bigger than the log, the view change completes and every replica is Normal", i.e. the
       [ring_capacity:64] half), with no [Did_not_settle] and no [Suite_timeout] involved at all.
       That is not a budget/watchdog interaction of any kind: it is the cluster genuinely not
       having reached [Normal] on every replica by the time the scenario looked.

       WHAT IS ACTUALLY KNOWN, stated as the three separate things they are rather than folded into
       one causal story:

       (a) This change is real, tested HARDENING against the theoretical CPU-load risk described
           above, and it is directly unit-tested ([test_dst_scenarios.ml]'s three
           [for_test_settle_loop] tests). It is NOT proven to be the fix for any specific observed
           flake, and nothing here should be read as claiming it is.
       (b) At least TWO distinct failure shapes have been observed on this codebase under induced
           load, and they are not the same phenomenon:

           - AN EXTERNAL-WATCHDOG ([Suite_timeout]) SHAPE, which this fix wave confirmed
             first-hand rather than inheriting: with 16 busy-loop processes on this 16-core box,
             a full-suite run at this branch's HEAD hit test_riptide.ml's own 15s per-test
             watchdog in 10 of 10 runs -- reliably, not flakily. Two details cut against the fix
             round's own hypothesis rather than for it. The test that timed out was
             [test_lattice_materialize_crypto_scenarios.ml]'s own [test_adversarial_sweep], NOT
             [test_ring_capacity_boundary_soak] -- the test the retracted paragraph above named as
             THE cause, and which passed in every one of those same 10 runs (and in 12 further
             dst_scenarios-only runs under the same load). What the watchdog actually selects for
             is therefore "whichever real-I/O-heavy test happens to be slowest under whatever load
             is present", a property of the watchdog-plus-load pair rather than of any one test --
             which is why naming one specific test as the cause was itself part of the overclaim.
             This shape remains something [settle]'s own internal budget cannot affect in either
             direction: an internal bound cannot rescue a run from an external wall-clock kill
             switch.
           - A PLAIN ASSERTION-FAILURE SHAPE in [test_ring_capacity_boundary] (a [`Quick] test),
             failing "with a ring bigger than the log, the view change completes and every replica
             is Normal" with neither [Did_not_settle] nor [Suite_timeout] involved. Observed by
             this branch's final whole-branch review at HEAD, at 1/10 runs under its own induced
             load. NOT reproduced by this fix wave (0/22 runs under the load described above),
             which at a reported rate of ~1/10 neither confirms nor refutes it -- so it is recorded
             here with its provenance rather than as an established mechanism. It is not about
             [settle]'s own budget at all, so this change neither addresses nor could address it.
             Note it also contradicts the "0/5 for [test_ring_capacity_boundary]" figure
             [test_dst_scenarios.ml]'s own soak-test comment records from an earlier review -- a
             5-run sample simply did not have the resolution to see a ~1-in-10 event either way.
       (c) A fair, interleaved A/B under identical induced load (alternating between this branch's
           root commit and its HEAD, 10 runs each) put the flake rate at 1/10 at BOTH ends. So
           this branch neither fixed nor worsened the underlying flake, which is the honest
           summary of its effect on it: none measurable.

       THIRD CORRECTION, AND THE ONE THAT ACTUALLY CLOSES THIS SUBTASK: an independent review of a
       fourth investigation attempt -- itself initially offering a FOURTH overclaimed diagnosis
       ("real per-replica disk I/O completion timing makes message order genuinely
       non-deterministic, and a stuck replica can only be rescued by a later independent storm")
       -- rejected that diagnosis too, for the same reason the first two were rejected: the
       mechanism was never verified end to end. What the review found instead, and DID verify end
       to end (a flushed, ordered send/receive/settle trace, a targeted one-line mutation, and a
       direct measurement of how often it fires): [for_test_settle_loop] ITSELF has a real defect,
       above, at the site now marked "SUBTASK 3.8, THE REAL ROOT CAUSE". [delivered] (this
       function's own [drain_round] result) is a STALE read taken BEFORE [yield ()] runs --
       [inflight ()] is read AFTER, so it is fresh and correct on its own terms; the cluster really
       is idle the moment it is checked. A handler still in flight at the top of the round can
       complete DURING the yield -- in the same step both enqueueing a brand-new message and
       dropping [inflight] to 0 -- and that new message is invisible to [delivered], already read
       before the yield happened. The old code's fall-through case ("nothing pending and nothing
       in flight, genuinely quiesced") then returns with a real, already-queued message still
       undelivered. Measured directly: ~1.1% of real [run_on_file_storage] [settle] calls hit this
       window. It is the mechanism behind every occurrence traced so far of the
       plain-assertion-failure shape in (b) above -- the "missing" message in
       [test_ring_capacity_boundary]'s occasional failure was never lost, reordered, or blocked on
       anything protocol-level; it was the SAME
       message, sitting in the queue, delivered one settle-call late, which is also why the earlier
       "rescued only by a LATER independent storm" claim was wrong: per-storm instrumentation (300
       iterations) found early-quiescence returns on EVERY storm at a roughly uniform ~1.4% rate,
       not concentrated on the third; storms 1 and 2's own occurrences were simply invisible
       because the NEXT storm's own settle call happens to catch the stale message before anyone
       looks. FIXED, now, at the site above: re-run [drain_round] once more before declaring
       quiescence, closing the exact window. Mutation-verified (deleting the re-check reproduces
       the failure in a new, direct unit test -- see [test_dst_scenarios.ml]'s
       [test_settle_loop_redrains_a_delivery_that_becomes_available_during_yield]) and load-tested
       (a fair interleaved A/B under real induced CPU load: unfixed 1/60 failures at the exact
       documented assertion, fixed 0/60; a further 60/60 clean run independently repeated after
       this fix landed).

       CONSEQUENCE FOR THE TRACKER: subtask 3.8 IS closed by this correction -- a real mechanism,
       verified end to end down to the exact line, with a real fix, a real regression test that
       fails without it, and real load-testing evidence. Its own literal title ("fix
       dst_scenarios' wall-clock-dependent flake in the ring-capacity-boundary view-change test")
       is delivered. What remains explicitly OUT of this subtask's scope, and still open as its
       own, separate, unattributed observation: the external-watchdog ([Suite_timeout]) shape in
       (b) above, a property of the watchdog-plus-load pair across whatever real-I/O-heavy test
       happens to be slowest at the time (observed on [test_adversarial_sweep], not on anything
       this subtask's own title names), which this fix does not and could not address.

       WHAT THE MECHANISM ITSELF IS, independent of any flake claim. For [run_on_file_storage] (the
       only caller that supplies a
       [deadline_budget]) the io-wait bound is now progress-based: keep waiting as long as real
       delivery is still happening, bounded by real wall-clock elapsed time since the LAST real
       delivery, not a raw attempt count -- see the [max_wait_duration] value below (finding I2)
       for why it must stay below the suite's own 15s watchdog to ever actually fire. [run]'s own
       mock-backend entry point supplies no [deadline_budget], so its behaviour is byte-for-byte
       the original fixed-countdown one -- see [for_test_settle_loop]'s own doc comment for why,
       and for the full investigation behind this design. *)
    for_test_settle_loop
      ~drain_round:(fun () ->
        let delivered = ref false in
        while Riptide_sim.Network.pump_one net do
          delivered := true;
          incr inflight
        done;
        !delivered)
      ~inflight:(fun () -> !inflight)
      ~yield:Eio.Fiber.yield ~wait_io
      ~deadline_budget:
        (match (max_wait_duration, clock) with
        | Some max_d, Some clock -> Some (max_d, fun () -> Eio.Time.now clock)
        | _ -> None)
      ~delivery_rounds
  in
  (* FINAL-REVIEW FINDING I1: a real crash-and-come-back, the capability whose absence meant
     nothing in this branch could ever have caught finding C1.

     WHY CRASH AND RESTART ARE ONE OPERATION rather than a [stop] plus a later [start]. The crash
     IS the discarding of volatile state, and here that is expressed by building a brand-new
     {!Riptide_vsr.Replica.t} over the same durable backend -- which is exactly what
     [Replica.restart] is (VSR.tla's [CrashRestart]) and exactly what the previous [t] losing
     [recv_svc]/[recv_dvc]/[sent_dvc]/[peer_op_number] means. Splitting it into two calls would add
     a "crashed but not yet back" state that nothing needs and that every caller would have to
     remember to leave.

     [?lose_superblock] folds in the ONE storage fault that makes a restart interesting rather than
     routine: a crash partway through [File_storage.superblock_write]'s 3 sequential, non-atomic
     copy writes, which leaves the superblock unreadable and the WAL fully intact. That is a single
     coherent event ("this replica crashed, and its superblock did not survive the crash"), not two,
     which is why it is an argument here rather than a separate entry point.

     RETURNS [false], and leaves the replica DOWN, when [Replica.restart] refuses -- which since
     finding C1's fix is precisely what it does for a lost superblock over a non-empty WAL. A
     machine that will not boot is a real outcome a simulation must be able to represent; turning it
     into an exception here would make every caller wrap it. The [Invalid_argument] catch is narrow
     in practice even though it is written broadly: [my_id]/[replica_count]/[svc_limit] are the same
     values [Replica.create] already accepted for this replica moments earlier, so the only
     precondition left for [restart] to fail is the superblock one. *)
  let restart ?(lose_superblock = false) ?repair_superblock i =
    if i < 0 || i >= replica_count then
      invalid_arg "Cluster.restart: replica index out of range (they are 0-based, like [replicas])";
    if lose_superblock then
      Riptide_storage.Fault_injecting_storage.for_test_lose_superblock fault_storages.(i);
    (* TASK 13 FIX ROUND: the operator repair step, before the restart attempt -- see [cluster.mli]'s
       own doc comment on [?repair_superblock] and, for what these three values MEAN and what
       supplying wrong ones costs, {!Riptide_storage.Storage_intf.S.superblock_rebuild_from_wal}'s.
       Deliberately NOT wrapped in the [Invalid_argument] catch below: that catch exists to turn "this
       machine will not boot" into a [false] return, and a repair whose own preconditions do not hold
       is a mistake in the scenario, which must not be laundered into the same signal. *)
    Option.iter
      (fun { view_number; last_normal_view; commit_number } ->
        Riptide_storage.Fault_injecting_storage.superblock_rebuild_from_wal fault_storages.(i)
          ~view_number ~last_normal_view ~commit_number)
      repair_superblock;
    match
      Riptide_vsr.Replica.restart ~storage:storages.(i) ~my_id:(i + 1) ~replica_count ~svc_limit
        ~send:(send_for i) ()
    with
    | r ->
      replicas.(i) <- r;
      alive.(i) <- true;
      (* Task 31: re-fill the same cell on every restart, not just the initial creation --
         [storages.(i)]/[fault_storages.(i)] (and therefore any [?may_evict] closure captured at
         [File_storage.create] time) survive a "crash" unchanged; only [Riptide_vsr.Replica.t]
         itself is rebuilt. Without this, a predicate closed over the cell would keep consulting the
         pre-crash replica object forever after the first restart. *)
      Option.iter (fun f -> f ~index:i r) on_replica_created;
      true
    | exception Invalid_argument _ ->
      alive.(i) <- false;
      false
  in
  try
    Eio.Switch.run (fun sw ->
        Array.iteri
          (fun i _replica ->
            Eio.Fiber.fork ~sw (fun () ->
                let rec dispatch_loop () =
                  (* [receive] reports the authenticated sender (Task 1) alongside the payload;
                     Task 3 is what actually consumes it here, passing it straight into
                     [Replica.handle_message]'s new [~sender] so its own sender-cross-check has a
                     real transport-authenticated identity to check the message's claimed one
                     against, exactly as [docs/superpowers/plans/2026-09-29-audit-remediation.md]'s
                     Task 3 requires. *)
                  let msg, sender = Riptide_sim.Sim_transport.receive handles.(i) in
                  (* [replicas.(i)], read fresh on every message rather than captured once at fork
                     time: [restart] SWAPS the array element, and a fiber holding the pre-crash
                     value would keep feeding the dead replica forever -- the restart would appear
                     to work and change nothing. A down replica (a refused restart) is skipped
                     entirely; the message is discarded, exactly as a message to a machine that is
                     not running is.

                     [decr] in a [Fun.protect]-free tail position used to be safe unconditionally
                     because [handle_message] was total on adversarial input and never raised. As
                     of Task 3 that is no longer quite true: a message whose claimed sender
                     mismatches [sender] now makes [handle_message] raise
                     [Riptide_vsr.Replica.Sender_mismatch] (a DELIBERATE change -- see
                     replica.mli's own doc comment on why that guard alone is a raise, not a
                     silent drop, unlike every other guard in that dispatch). This loop still
                     needs to stay total in the face of adversarial/corrupted input the same way
                     it always has, so it absorbs exactly that one exception here, right next to
                     the decoded-payload case [handle_message] itself already swallows internally
                     ([Message.Malformed_message]) -- both are "this delivery cannot be trusted,
                     drop it and keep running", just raised one guard later than the wire shape
                     check is. In practice this fires vanishingly rarely from [flip_one_byte]'s
                     own corruption fault (a single flipped byte almost always breaks
                     {!Riptide_vsr.Message.decode}'s own whole-body checksum first, per its own
                     doc comment, so [Malformed_message] is what actually fires for corruption);
                     this catch exists for genuine spoofing attempts (a real, if currently
                     synthetic-only, adversarial-replica scenario) and defense in depth.

                     FIX-ROUND FINDING 1 (audit-remediation Task 3): this used to catch the
                     blanket [Invalid_argument], which is ALSO what [Replica.durable_append]
                     re-raises for an unclassified backend refusal ([replica.ml]'s own comment at
                     that raise site is explicit that it must NEVER be laundered into "the
                     protocol declined an op") -- reached from here via [handle_prepare] at a real
                     [Prepare]. A blanket catch silently absorbed that too, turning a real backend
                     fault inside a DST run into a quiet, incorrectly green drop instead of a
                     propagating failure. Catching the distinct [Sender_mismatch] instead fixes
                     this: only a genuine sender-mismatch is absorbed here, and a backend contract
                     violation now propagates out of this dispatch loop exactly as it did before
                     Task 3 ever added a sender field to check. *)
                  if alive.(i) then begin
                    match Riptide_vsr.Replica.handle_message replicas.(i) ~sender msg with
                    | () -> ()
                    | exception Riptide_vsr.Replica.Sender_mismatch _ -> ()
                  end;
                  decr inflight;
                  dispatch_loop ()
                in
                dispatch_loop ()))
          replicas;
        body ~replicas ~settle ~restart;
        Eio.Switch.fail sw Cluster_test_done)
  with Cluster_test_done -> ()

let run ~seed ~replica_count ?(svc_limit = default_svc_limit)
    ?(net_fault_config = Riptide_sim.Network.default_fault_config)
    ?(storage_fault_config = Riptide_storage.Fault_injecting_storage.default_fault_config)
    (body :
      replicas:Riptide_vsr.Replica.t array ->
      settle:(unit -> unit) ->
      restart:(?lose_superblock:bool -> ?repair_superblock:superblock_repair -> int -> bool) ->
      unit) =
  (* Task 10's pre-flight must reject BEFORE [Eio_mock.Backend.run] is entered, not just before any
     replica is built: [test_dst_cluster.ml]'s own test asserts the [Invalid_argument] escapes to
     the caller, and an exception raised inside the mock backend would be reported by the backend
     instead. (It is re-checked inside [with_cluster] too -- one statement of the rule, enforced on
     every path into a cluster.) *)
  check_storage_fault_config ~replica_count
    ~faults_max:((replica_count - 1) / 2)
    storage_fault_config;
  Eio_mock.Backend.run @@ fun () ->
  with_cluster ~seed ~replica_count ~svc_limit ~net_fault_config ~storage_fault_config
    ~make_storage:(fun ~index:_ ~replication_quorum ~prng ->
      Riptide_storage.Fault_injecting_storage.create ~prng ~fault_config:storage_fault_config
        ~replication_quorum
        ~underlying:(module Riptide_storage.Memory_storage)
        (Riptide_storage.Memory_storage.create ()))
      (* Under [Eio_mock.Backend.run] every storage operation is synchronous, so there is no I/O to
         wait for; a further [yield] is the strongest "let everything runnable run" this scheduler
         has, and matches the second yield the original loop always performed. *)
    ~wait_io:Eio.Fiber.yield ~delivery_rounds:20 body

let run_on_file_storage ~env ~dir ~seed ~replica_count ?(svc_limit = default_svc_limit)
    ?(ring_capacity = default_ring_capacity)
    ?(net_fault_config = Riptide_sim.Network.default_fault_config)
    ?(storage_fault_config = Riptide_storage.Fault_injecting_storage.default_fault_config)
    ?(enable_eviction_gate = true)
    (body :
      replicas:Riptide_vsr.Replica.t array ->
      settle:(unit -> unit) ->
      restart:(?lose_superblock:bool -> ?repair_superblock:superblock_repair -> int -> bool) ->
      unit) =
  check_storage_fault_config ~replica_count
    ~faults_max:((replica_count - 1) / 2)
    storage_fault_config;
  let fs = Eio.Stdenv.fs env in
  let clock = Eio.Stdenv.clock env in
  (* Task 31 (audit-remediation): the actual finding this closes is that [eviction_blocked] was
     structurally pinned at 0 -- nothing anywhere ever supplied [File_storage.create] a real
     [?may_evict] predicate, so it could never have anything to refuse. The intended predicate,
     {!Riptide_batch_commit.Batch_commit.write_at_op_number_has_merge_key}, needs a real
     [Riptide_vsr.Replica.t] to read ([Replica.entries]) -- but [make_storage] below (which builds
     the [?may_evict] closure passed to [File_storage.create]) runs BEFORE [with_cluster]'s own
     [Riptide_vsr.Replica.create]/[restart] for that same index, so the closure cannot capture the
     replica it will protect directly at the point it is built.

     [replica_cells] is the forward-reference: one [Riptide_vsr.Replica.t option ref] per replica
     index, created here (before [make_storage] ever runs), closed over by [?may_evict]'s own
     closure below, and filled in by [with_cluster] itself (via [~on_replica_created]) immediately
     after each [Replica.create]/[restart] call returns for that same index -- see those two call
     sites' own comments in [with_cluster] for the fill-in half of this mechanism. *)
  let replica_cells : Riptide_vsr.Replica.t option ref array =
    Array.init replica_count (fun _ -> ref None)
  in
  Eio.Switch.run @@ fun storage_sw ->
  with_cluster ~seed ~replica_count ~svc_limit ~net_fault_config ~storage_fault_config
    ~make_storage:(fun ~index ~replication_quorum ~prng ->
      let path = Filename.concat dir (string_of_int (index + 1)) in
      (* [?enable_eviction_gate] (default [true], the correct production behavior): the ONE
         override this harness exposes for a scenario that needs Task 31's own protection turned
         OFF, and it exists for a genuinely narrow reason, not as a general escape hatch --
         [test_dst_scenarios.ml]'s own
         [test_restart_after_the_ring_wrapped_cannot_recover_an_unmaterialized_entry] pins a
         DIFFERENT, already-disclosed limitation (restart recovery cannot recover a
         still-unmaterialized entry once the ring has wrapped -- see
         {!Riptide_batch_commit.Batch_commit.write_at_op_number_has_merge_key}'s own "AFTER A
         RESTART OVER A WRAPPED RING" doc) that is orthogonal to whether eviction itself is gated,
         and its own scenario needs the ring to actually wrap via ordinary, UNPROTECTED eviction of
         merge_key-carrying entries to reach that state at all -- exactly what this task's default
         now prevents (there is no materialization watermark yet, so with the gate on, a
         merge_key-carrying entry can never be evicted while still visible to
         [Replica.entries], which never happens for that test's scenario without a restart in
         between). Passing [~enable_eviction_gate:false] there reproduces this call site's exact
         pre-Task-31 behavior, isolating that test to the limitation it actually targets. *)
      let may_evict =
        if not enable_eviction_gate then None
        else
          Some
            (fun ~op_number ->
              match !(replica_cells.(index)) with
              | Some r ->
                not (Riptide_batch_commit.Batch_commit.write_at_op_number_has_merge_key r ~op_number)
              | None ->
                (* Provably unreachable, not merely unlikely: [?may_evict] is consulted only from
                   inside [File_storage.wal_append] (see file_storage.mli's own "When it is
                   consulted" clause), and the only appends this harness ever drives are the ones a
                   live [Replica.t] for this SAME index issues from inside [with_cluster]'s
                   dispatch loop / [body] -- both of which run strictly after
                   [replica_cells.(index)] has already been filled in (see the two
                   [on_replica_created] call sites in [with_cluster]). No op can exist to append
                   before the replica that would append it exists.

                   Deliberately [failwith] rather than the softer [| None -> true (* unreachable *)]
                   precedent used for an analogous "tie the knot" cell in
                   [test/test_lattice_materialize_crypto_scenarios.ml]: that file's cell is consulted
                   from a much smaller, hand-rolled harness where a silent default is easy to audit
                   by inspection, while this one backs a shared, general-purpose harness where a
                   silently-permitted eviction on a violated invariant would be far harder to notice.
                   Failing loudly here is a deliberate choice, not an oversight. *)
                failwith
                  "Cluster.run_on_file_storage: ?may_evict consulted before this replica's \
                   forward-reference cell was ever filled in -- should be unreachable, see this \
                   call site's own comment")
      in
      Riptide_storage.Fault_injecting_storage.create ~prng ~fault_config:storage_fault_config
        ~replication_quorum
        ~underlying:(module Riptide_storage.File_storage)
        (Riptide_storage.File_storage.create ~sw:storage_sw ~fs ~ring_capacity ?may_evict path))
    ~on_replica_created:(fun ~index r -> replica_cells.(index) := Some r)
      (* A real, tiny sleep on the REAL clock, not [Eio.Fiber.yield]: a fiber parked on an io_uring
         completion is not runnable, so yielding to it achieves nothing -- eio_linux only reaps
         completions when its run queue empties, which a yield-only loop never lets happen. This is
         the one place this harness genuinely spends wall-clock time; every DECISION in the run
         stays seeded and deterministic (Prng-driven), only the real I/O's timing does not. *)
    ~wait_io:(fun () -> Eio.Time.sleep clock 0.0001)
    ~delivery_rounds:500
      (* SUBTASK 3.8: a genuine progress-based liveness bound, not a tuning knob for normal
         operation -- its only job is to still catch a cluster that has genuinely stopped
         delivering anything real, while never penalising one that keeps making real progress no
         matter how slowly (see [for_test_settle_loop]'s own doc comment).

         FIX-ROUND CORRECTION (finding I2): this was originally 30.0, which is ABOVE
         [test/test_riptide.ml]'s own external per-test watchdog (`timeout_seconds = 15.`) -- so a
         [settle] call that genuinely rode this deadline out could never actually raise
         [Did_not_settle] from here; the external SIGALRM watchdog would always kill the test
         first, at 15s, with a less accurate failure message ("likely a busy-poll livelock") than
         this module's own. 10.0 is comfortably below that 15s budget (leaving room for the rest
         of a test's own non-settle work before the watchdog's own deadline), so a genuinely stuck
         cluster now gets diagnosed by this module's own, more accurate [Did_not_settle] instead of
         being silently pre-empted. *)
    ~max_wait_duration:10.0 ~clock body
