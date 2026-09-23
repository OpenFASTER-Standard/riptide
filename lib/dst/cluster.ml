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
      filesystem capability), restated in [cluster.mli].
   4. No [stop]/[isolate]/[reconnect] -- Task 8's crash/partition simulation, not needed by this
      task's two required tests and out of scope for Tasks 10/11's own later work. *)

exception Did_not_settle

exception Cluster_test_done
(* Unwinds the outer [Eio.Switch.run] once [body] is done -- same mechanism, and deliberately the
   same name, as [with_cluster_and_storage]'s own (a different module, so no clash). *)

let default_svc_limit = 3

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

let run ~seed ~replica_count ?(svc_limit = default_svc_limit)
    ?(net_fault_config = Riptide_sim.Network.default_fault_config)
    ?(storage_fault_config = Riptide_storage.Fault_injecting_storage.default_fault_config)
    (body :
      replicas:Riptide_vsr.Replica.t array -> settle:(unit -> unit) -> unit) =
  let net_seed, storage_seeds = split_seed seed ~replica_count in
  Eio_mock.Backend.run @@ fun () ->
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
  (* Task 10: a SECOND, cluster-wide line of defense, static and preflight -- distinct from (and
     strictly in addition to) [Fault_injecting_storage]'s own per-instance runtime enforcement of
     [faults_max = replication_quorum - 1] (Tasks 6/8, [fault_injecting_storage.mli]'s own doc
     comment on [create]), which only ever bounds how many DISTINCT op_numbers can be simultaneously
     corrupted WITHIN ONE replica's own WAL, in isolation. That per-instance cap does nothing to
     stop every replica from independently corrupting ITS OWN copy of the SAME op_number: each
     replica's [corrupt_probability] draw is an independent Bernoulli trial (its own freshly-seeded
     [Prng.t], per [split_seed] above), so nothing about the per-instance cap prevents
     [replication_quorum] or more replicas from simultaneously holding a corrupted copy of one
     slot -- which is exactly the case a quorum read cannot recover from (out of [replica_count]
     copies, fewer than [replication_quorum] remain readable/correct).

     This check estimates that cluster-wide risk the only way available at cluster-creation time,
     before any op_number or run length is known: for one arbitrary slot that every replica
     eventually writes its own copy of (VSR's own happy-path replication), the number of replicas
     whose copy gets corrupted is Binomial(replica_count, corrupt_probability), so its EXPECTATION
     is [replica_count * corrupt_probability]. Reject up front, conservatively, whenever that
     expectation alone already reaches or exceeds [faults_max] (the same [>=] boundary
     [Fault_injecting_storage] itself uses: a live-corrupted count of exactly [faults_max] is
     already unsafe, not just "one past safe") -- i.e. whenever a single slot going unrecoverable is
     already the EXPECTED outcome, not merely a tail-probability worth quantifying with an otherwise-
     arbitrary confidence threshold. [corrupt_probability > 0.] is required too, so the safe,
     zero-risk default ([default_fault_config], every existing test's implicit config) is never
     rejected regardless of [replica_count] -- without it, a [faults_max = 0] cluster (a lone
     replica, no redundancy at all to tolerate even one fault) would reject [corrupt_probability =
     0.] itself, which corrupts nothing and is trivially safe. *)
  let faults_max = replication_quorum - 1 in
  if
    storage_fault_config.Riptide_storage.Fault_injecting_storage.corrupt_probability > 0.
    && Float.of_int replica_count *. storage_fault_config.corrupt_probability >= Float.of_int faults_max
  then
    invalid_arg
      "storage fault config could corrupt more than faults_max = replication_quorum - 1 replicas' \
       copies of the same slot";
  let storages =
    Array.init replica_count (fun i ->
        Riptide_storage.Fault_injecting_storage.create
          ~prng:(Riptide_sim.Prng.create storage_seeds.(i))
          ~fault_config:storage_fault_config ~replication_quorum
          ~underlying:(module Riptide_storage.Memory_storage)
          (Riptide_storage.Memory_storage.create ()))
  in
  let replicas =
    Array.init replica_count (fun i ->
        let my_id = i + 1 in
        let r =
          Riptide_vsr.Replica.create
            ~storage:
              (Riptide_vsr.Replica.storage_of_module
                 (module Riptide_storage.Fault_injecting_storage)
                 storages.(i))
            ~my_id ~replica_count ~svc_limit
            ~send:(fun ~to_ bytes -> Riptide_sim.Sim_transport.send handles.(i) ~to_ bytes)
        in
        (* Deviation 1 (see this file's own top comment and [cluster.mli]): pin every replica's
           view to 1 so [Primary(1) = 1] and [replicas.(0)] is the primary a caller can [propose]
           against directly, matching [with_cluster_and_storage]'s own pin for the same reason. *)
        Riptide_vsr.Replica.for_test_set_view_number r 1;
        r)
  in
  let settle () =
    let rec loop rounds_left =
      if rounds_left <= 0 then raise Did_not_settle
      else begin
        let delivered = ref false in
        while Riptide_sim.Network.pump_one net do
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
                let rec dispatch_loop () =
                  let msg = Riptide_sim.Sim_transport.receive handles.(i) in
                  Riptide_vsr.Replica.handle_message replica msg;
                  dispatch_loop ()
                in
                dispatch_loop ()))
          replicas;
        body ~replicas ~settle;
        Eio.Switch.fail sw Cluster_test_done)
  with Cluster_test_done -> ()
