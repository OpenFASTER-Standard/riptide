(** Task 9 (task-master subtask 3.4): the reusable deterministic-simulation-testing (DST) harness
    that stands up a full cluster of real {!Riptide_vsr.Replica.t}s over the existing, unmodified
    {!Riptide_sim.Network}/{!Riptide_sim.Sim_transport} fabric, one
    {!Riptide_storage.Fault_injecting_storage.t} per replica, driven by {!Eio_mock.Clock} (via
    {!Eio_mock.Backend.run}) -- everything reproducible from one root seed.

    This is [test/test_vsr_replica_recovery.ml]'s own [with_cluster_and_storage] (Task 8, test-file
    scope) promoted to a real library module, so Tasks 10/11 and any future caller can reuse it
    without re-deriving the same wiring. See this module's [.ml] for the exact ways this
    implementation had to diverge from that precedent (and from this task's own brief, which
    predates it) and why. *)

exception Did_not_settle
(** Raised by the [settle] function passed to a [run] body if the cluster has not quiesced (no
    message pumped, nothing new delivered) within a generous, bounded number of rounds -- signals
    likely non-termination rather than hanging the test suite forever. Mirrors
    [with_cluster_and_storage]'s own [Alcotest.fail "cluster did not quiesce..."], restated as a
    real exception since this is a library, not a test file, and cannot depend on Alcotest. *)

val run :
  seed:int ->
  replica_count:int ->
  ?svc_limit:int ->
  ?net_fault_config:Riptide_sim.Network.fault_config ->
  ?storage_fault_config:Riptide_storage.Fault_injecting_storage.fault_config ->
  (replicas:Riptide_vsr.Replica.t array -> settle:(unit -> unit) -> unit) ->
  unit
(** [run ~seed ~replica_count ?svc_limit ?net_fault_config ?storage_fault_config body] stands up
    [replica_count] real {!Riptide_vsr.Replica.t}s wired over one shared, freshly-created
    {!Riptide_sim.Network.t} (via {!Riptide_sim.Sim_transport}), each with its own fresh
    {!Riptide_storage.Fault_injecting_storage.t} wrapping its own fresh
    {!Riptide_storage.Memory_storage.t} (see {!Riptide_storage.Fault_injecting_storage.create}'s
    [replication_quorum], computed here as VSR's own [f + 1 = ((replica_count - 1) / 2) + 1]), runs
    each replica's dispatch loop ([Sim_transport.receive] -> [Replica.handle_message], forever) as
    its own forked fiber inside one {!Eio_mock.Backend.run}, calls [body ~replicas ~settle] once
    everything is wired, then unwinds the whole switch (stopping every dispatch fiber) once [body]
    returns.

    {b [replicas.(i)] is replica [i + 1]}, matching every existing cluster-test harness in this
    repo ([with_cluster], [with_cluster_and_storage]). {b Every replica's [view_number] is pinned
    to [1] before [body] runs} (via [Replica.for_test_set_view_number], same as
    [with_cluster_and_storage]), so [Primary(1) = 1] and [replicas.(0)] is always the primary a
    caller can [propose] against directly -- without this, [Replica.create]'s own default
    [view_number = 0] would make replica [replica_count] (not replica [1]) the primary (see
    {!Riptide_vsr.Replica.primary}'s own doc comment on view [0]'s degenerate case), silently
    turning any [propose] against [replicas.(0)] into the documented no-op and making every trace
    this harness produces vacuously trivial. This is one of the two places this implementation had
    to diverge from a literal reading of this task's own brief, whose illustrative sketch calls
    [propose] on [replicas.(0)] without ever pinning the view -- see [cluster.ml]'s own comment at
    the pin site for the other.

    {b Seed splitting}: [seed] is never used directly. One root {!Riptide_sim.Prng.t} is created
    from it, then drawn from exactly [1 + replica_count] times, in a fixed order -- once for the
    network's own sub-seed, then once per replica (index order [0, 1, ..., replica_count - 1]) for
    that replica's storage sub-seed -- and each drawn integer reseeds an independent, freshly
    created {!Riptide_sim.Prng.t} for its own component. Because {!Riptide_sim.Prng.create} is a
    pure function of its seed and the root draws always happen in this same fixed order, the whole
    split -- and therefore the whole cluster's behavior -- is 100% reproducible from [seed] alone.
    The network's sub-seed and every replica's storage sub-seed are drawn from the root but never
    from each other, and the network and each replica's storage each get their OWN independent
    {!Riptide_sim.Prng.t} instance (not a shared one) -- so, deliberately, adding/changing a storage
    fault never shifts the network's own delivery/fault schedule, and vice versa, matching
    [with_cluster_and_storage]'s own documented reasoning for keeping those two streams
    unentangled.

    [svc_limit] defaults to [3] (an arbitrary but valid choice -- see
    {!Riptide_vsr.Replica.create}'s own [Invalid_argument] cases for what makes a value valid);
    override it if a caller's scenario needs {!Riptide_vsr.Replica.check_timeout}'s
    [TimerSendSVC]/[ForfeitViewChange] guard to fire at a specific count. [net_fault_config]
    defaults to {!Riptide_sim.Network.default_fault_config} (reliable, immediate, single delivery);
    [storage_fault_config] defaults to
    {!Riptide_storage.Fault_injecting_storage.default_fault_config} (every operation passes
    through unchanged).

    {b [settle] is exposed to [body], deliberately NOT part of the brief's own illustrative
    signature} (which took only [replicas:Replica.t array -> unit]): [Replica.propose] appends to
    the proposer's own log synchronously, before anything is sent (see
    {!Riptide_vsr.Replica.propose}'s own doc comment), so nothing about a proposer's own raw log
    length ever depends on message delivery -- a body with no way to drive delivery can only ever
    observe that one, delivery-independent fact, never anything about replication, commitment, or
    a fault's actual effect. [settle] (the same bounded pump-then-yield-twice loop
    [with_cluster_and_storage] already uses, raising {!Did_not_settle} rather than
    [Alcotest.fail] past 20 rounds of a round producing no delivery) is the second, and only other,
    divergence from the brief's literal sketch, needed for exactly this reason -- both are called
    out in this task's own report as deliberate, justified deviations from a stale illustrative
    sketch, not scope creep: no [stop]/[isolate]/[reconnect] (Task 8's own crash/partition
    simulation) is exposed, since neither of this task's two required tests needs it and Tasks
    10/11 are explicitly out of this task's scope.

    {b Task 10: rejects an unsafe [storage_fault_config] before standing up any replica or storage
    at all}: {!Riptide_storage.Fault_injecting_storage}'s own [faults_max = replication_quorum - 1]
    enforcement (Tasks 6/8) is per-instance -- it only ever bounds how many op_numbers one replica's
    own storage may have simultaneously corrupted, in isolation, and only at the moment a corrupting
    write is attempted. It does nothing to stop every replica from independently corrupting its own
    copy of the SAME slot (each replica's corruption decisions are drawn from its own independently
    seeded {!Riptide_sim.Prng.t}), which is the actual cluster-wide danger: if
    [replication_quorum] or more replicas simultaneously hold a corrupted copy of one slot, no
    quorum read can recover it. [run] estimates this risk the only way available at
    cluster-creation time (no op_number or run length is known yet): for one slot every replica
    eventually writes (VSR's own happy-path replication), the number of replicas whose copy gets
    corrupted is Binomial(replica_count, corrupt_probability), whose expectation is [replica_count
    * corrupt_probability]. [run] raises [Invalid_argument
    "storage fault config could corrupt more than faults_max = replication_quorum - 1 replicas'
    copies of the same slot"] whenever that expectation alone already reaches or exceeds
    [faults_max] (and [corrupt_probability > 0.], so the safe, zero-risk
    {!Riptide_storage.Fault_injecting_storage.default_fault_config} is never rejected regardless of
    [replica_count], including the degenerate [faults_max = 0] single-replica case) -- i.e. whenever
    a single slot going unrecoverable is already the EXPECTED outcome under that config, not merely
    a tail probability worth quantifying with an otherwise-arbitrary confidence threshold. This is a
    static, conservative, cluster-level check only; {!Riptide_storage.Fault_injecting_storage}'s own
    per-instance runtime enforcement remains the actual last line of defense during a run, catching
    whatever this preflight check cannot rule out in advance (e.g. a config that passes this check
    but still happens to corrupt a bad run of consecutive slots on one replica).

    {b Why {!Riptide_storage.Memory_storage} under the wrapper, not
    {!Riptide_storage.File_storage}} (the brief's own "Interfaces" line lists [File_storage] as
    consumed, but its illustrative code never actually constructs one): {!Eio_mock.Backend.run} is
    a scheduler with no filesystem capability at all, and {!Riptide_storage.File_storage.create}
    needs a real [~fs] (and an [Eio_main.run]/io_uring scope) to open real files -- exactly the
    same conflict [with_cluster_and_storage]'s own top comment already worked through and resolved
    the same way, for the same reason (this harness asserts PROTOCOL behavior under a storage
    fault, not File_storage's own on-disk behavior, which is covered separately by
    [test/test_file_storage.ml] and [test/test_fault_injecting_storage.ml]). *)
