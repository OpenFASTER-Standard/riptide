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
      task's two required tests and out of scope for Tasks 10/11's own later work. *)

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
   THE SHARED WIRING, parameterised by exactly the two things the two entry points differ in:
   how a replica's storage is built ([make_storage]) and what "let in-flight I/O make progress"
   means ([wait_io]).
   --------------------------------------------------------------------------------------------- *)

let with_cluster ~seed ~replica_count ~svc_limit ~net_fault_config ~storage_fault_config
    ~make_storage ~wait_io body =
  let net_seed, storage_seeds = split_seed seed ~replica_count in
  let net =
    Riptide_sim.Network.create ~faults:net_fault_config (Riptide_sim.Prng.create net_seed) ()
  in
  for id = 1 to replica_count do
    Riptide_sim.Network.register net (string_of_int id)
  done;
  let handles = Array.init replica_count (fun i -> Riptide_sim.Sim_transport.create net (i + 1)) in
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
  let storages =
    Array.init replica_count (fun i ->
        make_storage ~index:i ~replication_quorum
          ~prng:(Riptide_sim.Prng.create storage_seeds.(i)))
  in
  let replicas =
    Array.init replica_count (fun i ->
        let my_id = i + 1 in
        let r =
          Riptide_vsr.Replica.create ~storage:storages.(i) ~my_id ~replica_count ~svc_limit
            ~send:(fun ~to_ bytes -> Riptide_sim.Sim_transport.send handles.(i) ~to_ bytes)
        in
        (* Deviation 1 (see this file's own top comment and [cluster.mli]): pin every replica's
           view to 1 so [Primary(1) = 1] and [replicas.(0)] is the primary a caller can [propose]
           against directly, matching [with_cluster_and_storage]'s own pin for the same reason. *)
        Riptide_vsr.Replica.for_test_set_view_number r 1;
        r)
  in
  let settle () =
    (* Two independent budgets, deliberately not one. [delivery_rounds] is the original bound,
       unchanged in meaning: 20 rounds that each actually delivered something, which is the real
       livelock signal (a cluster generating messages forever). [io_waits] bounds only the new
       waiting-for-a-suspended-handler path, which delivers nothing by definition and so would
       never consume the first budget; folding the two together would have meant either weakening
       the livelock detector by an order of magnitude or timing out legitimate real-I/O runs. *)
    let rec loop delivery_rounds io_waits =
      if delivery_rounds <= 0 || io_waits <= 0 then raise Did_not_settle
      else begin
        let delivered = ref false in
        while Riptide_sim.Network.pump_one net do
          delivered := true;
          incr inflight
        done;
        Eio.Fiber.yield ();
        let delivery_rounds = if !delivered then delivery_rounds - 1 else delivery_rounds in
        if !inflight > 0 then begin
          wait_io ();
          loop delivery_rounds (io_waits - 1)
        end
        else if !delivered then loop delivery_rounds io_waits
      end
    in
    loop 20 5000
  in
  try
    Eio.Switch.run (fun sw ->
        Array.iteri
          (fun i replica ->
            Eio.Fiber.fork ~sw (fun () ->
                let rec dispatch_loop () =
                  let msg = Riptide_sim.Sim_transport.receive handles.(i) in
                  (* [decr] in a [Fun.protect]-free tail position is deliberate: [handle_message]
                     is total on adversarial input (replica.mli's own guarantee), so it does not
                     raise, and a counter that leaked on an exception would hang [settle] rather
                     than surface it. *)
                  Riptide_vsr.Replica.handle_message replica msg;
                  decr inflight;
                  dispatch_loop ()
                in
                dispatch_loop ()))
          replicas;
        body ~replicas ~settle;
        Eio.Switch.fail sw Cluster_test_done)
  with Cluster_test_done -> ()

let run ~seed ~replica_count ?(svc_limit = default_svc_limit)
    ?(net_fault_config = Riptide_sim.Network.default_fault_config)
    ?(storage_fault_config = Riptide_storage.Fault_injecting_storage.default_fault_config)
    (body : replicas:Riptide_vsr.Replica.t array -> settle:(unit -> unit) -> unit) =
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
      Riptide_vsr.Replica.storage_of_module
        (module Riptide_storage.Fault_injecting_storage)
        (Riptide_storage.Fault_injecting_storage.create ~prng ~fault_config:storage_fault_config
           ~replication_quorum
           ~underlying:(module Riptide_storage.Memory_storage)
           (Riptide_storage.Memory_storage.create ())))
      (* Under [Eio_mock.Backend.run] every storage operation is synchronous, so there is no I/O to
         wait for; a further [yield] is the strongest "let everything runnable run" this scheduler
         has, and matches the second yield the original loop always performed. *)
    ~wait_io:Eio.Fiber.yield body

let run_on_file_storage ~env ~dir ~seed ~replica_count ?(svc_limit = default_svc_limit)
    ?(ring_capacity = default_ring_capacity)
    ?(net_fault_config = Riptide_sim.Network.default_fault_config)
    ?(storage_fault_config = Riptide_storage.Fault_injecting_storage.default_fault_config)
    (body : replicas:Riptide_vsr.Replica.t array -> settle:(unit -> unit) -> unit) =
  check_storage_fault_config ~replica_count
    ~faults_max:((replica_count - 1) / 2)
    storage_fault_config;
  let fs = Eio.Stdenv.fs env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun storage_sw ->
  with_cluster ~seed ~replica_count ~svc_limit ~net_fault_config ~storage_fault_config
    ~make_storage:(fun ~index ~replication_quorum ~prng ->
      let path = Filename.concat dir (string_of_int (index + 1)) in
      Riptide_vsr.Replica.storage_of_module
        (module Riptide_storage.Fault_injecting_storage)
        (Riptide_storage.Fault_injecting_storage.create ~prng ~fault_config:storage_fault_config
           ~replication_quorum
           ~underlying:(module Riptide_storage.File_storage)
           (Riptide_storage.File_storage.create ~sw:storage_sw ~fs ~ring_capacity path)))
      (* A real, tiny sleep on the REAL clock, not [Eio.Fiber.yield]: a fiber parked on an io_uring
         completion is not runnable, so yielding to it achieves nothing -- eio_linux only reaps
         completions when its run queue empties, which a yield-only loop never lets happen. This is
         the one place this harness genuinely spends wall-clock time; every DECISION in the run
         stays seeded and deterministic (Prng-driven), only the real I/O's timing does not. *)
    ~wait_io:(fun () -> Eio.Time.sleep clock 0.0001)
    body
