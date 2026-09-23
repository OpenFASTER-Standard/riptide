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
(** Raised by the [settle] function passed to a [run]/{!run_on_file_storage} body if the cluster
    has not quiesced within a generous, bounded number of rounds -- signals likely non-termination
    rather than hanging the test suite forever. Mirrors [with_cluster_and_storage]'s own
    [Alcotest.fail "cluster did not quiesce..."], restated as a real exception since this is a
    library, not a test file, and cannot depend on Alcotest.

    {b Quiesced means two things, not one} (the second added by Task 11): nothing further was
    delivered, AND no already-delivered message is still being handled. [settle] bounds those two
    with separate budgets -- 20 rounds that each actually delivered something (the original bound,
    unchanged: a cluster generating messages forever is the real livelock signal) and 5000 waits
    for an in-flight handler (which by definition deliver nothing, so they could never consume the
    first budget). Either budget running out raises this. *)

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
    a fault's actual effect. [settle] (originally the same bounded pump-then-yield-twice loop
    [with_cluster_and_storage] already uses, raising {!Did_not_settle} rather than [Alcotest.fail];
    corrected in Task 11 to also wait out messages whose handler has started but not returned --
    see {!Did_not_settle} and [cluster.ml]'s own comment at the [inflight] counter for what that
    loop silently got wrong and the measured before/after) is the second, and only other,
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
    a tail probability worth quantifying with an otherwise-arbitrary confidence threshold.

    {b This is a static, expectation-based estimate, not a hard guarantee, and it has no runtime
    backstop for the specific danger it targets.} It only models one arbitrary slot in isolation,
    using nothing but [replica_count] and [corrupt_probability] (the only inputs available at
    cluster-creation time, before any op_number or run length is known) -- a config whose
    expectation sits just under the threshold can still, on an unlucky seed, produce
    [faults_max] or more corrupted copies of some slot at runtime, and nothing anywhere in this
    codebase will detect that when it happens. It also does not account for how many op_numbers a
    real run actually touches: every additional write is another independent trial of the same
    per-slot risk, so the true probability that *some* slot in a run crosses the threshold is
    higher than this single-slot expectation suggests -- structurally unavoidable at
    cluster-creation time, before run length is known, but worth naming as a real scope boundary.
    {!Riptide_storage.Fault_injecting_storage}'s own per-instance runtime enforcement is NOT a
    backstop for this risk, despite guarding a superficially similar-sounding thing: it bounds how
    many distinct op_numbers *one* replica's own storage has itself corrupted, checked only against
    that one replica's own corruption history, with zero visibility into any other replica's state
    (each replica draws from its own independently-seeded {!Riptide_sim.Prng.t}). It cannot detect,
    let alone prevent, multiple replicas each independently corrupting their own copy of the *same*
    slot -- the exact cross-replica failure mode this preflight check exists to reduce. There is
    currently no runtime detection anywhere in this codebase for that failure mode; this check
    lowers its likelihood at config-selection time, it does not bound it.

    {b Why {!Riptide_storage.Memory_storage} under the wrapper, not
    {!Riptide_storage.File_storage}} (the brief's own "Interfaces" line lists [File_storage] as
    consumed, but its illustrative code never actually constructs one): {!Eio_mock.Backend.run} is
    a scheduler with no filesystem capability at all, and {!Riptide_storage.File_storage.create}
    needs a real [~fs] (and an [Eio_main.run]/io_uring scope) to open real files -- exactly the
    same conflict [with_cluster_and_storage]'s own top comment already worked through and resolved
    the same way, for the same reason (this harness asserts PROTOCOL behavior under a storage
    fault, not File_storage's own on-disk behavior, which is covered separately by
    [test/test_file_storage.ml] and [test/test_fault_injecting_storage.ml]). *)

val run_on_file_storage :
  env:Eio_unix.Stdenv.base ->
  dir:string ->
  seed:int ->
  replica_count:int ->
  ?svc_limit:int ->
  ?ring_capacity:int ->
  ?net_fault_config:Riptide_sim.Network.fault_config ->
  ?storage_fault_config:Riptide_storage.Fault_injecting_storage.fault_config ->
  (replicas:Riptide_vsr.Replica.t array -> settle:(unit -> unit) -> unit) ->
  unit
(** Task 11. Exactly {!run}, with exactly the same seed splitting, view pin, [settle], Task 10
    pre-flight check and teardown -- except that each replica's
    {!Riptide_storage.Fault_injecting_storage} wraps a real {!Riptide_storage.File_storage} (its
    own subdirectory [dir/1], [dir/2], ... of the caller-supplied, caller-owned [dir], which must
    already exist) instead of a {!Riptide_storage.Memory_storage}.

    {b Call it from inside the caller's own [Eio_main.run], never from inside
    [Eio_mock.Backend.run]}: it takes [env] rather than establishing a backend itself, because
    {!Riptide_storage.File_storage.create} needs a real [~fs] and a real io_uring scope, which is
    precisely what {!run}'s own [Eio_mock.Backend.run] cannot provide (see {!run}'s own closing
    paragraph). The trade is real wall-clock time for real durability: every DECISION in the run is
    still drawn from [seed] through the same {!Riptide_sim.Prng.t} split, so the run stays
    reproducible, but real I/O timing is not virtual and a run is orders of magnitude slower than
    the mock-clock one. Prefer {!run} for seed sweeps; use this when the property under test is
    about the real persistence layer.

    [ring_capacity] defaults to [4096] here, NOT to {!Riptide_storage.File_storage.create}'s own
    default of [8]. This is not a cosmetic choice and it is worth understanding before lowering it:
    {!Riptide_storage.File_storage}'s WAL is a fixed-size ring that silently EVICTS the entry at
    [op_number - ring_capacity] on every append, and nothing in this system ever truncates a
    committed prefix away (there is no checkpointing -- explicitly out of scope for this plan), so
    every entry stays live forever and a log longer than the ring means committed entries are
    destroyed on disk with no signal to anyone. The protocol-level consequence is total, and was
    reproduced deterministically with ZERO injected faults (see [test/test_dst_scenarios.ml]'s own
    ring-boundary test): once the log passes [ring_capacity], every replica's [Do_view_change]
    permanently omits the evicted ops, no replica can either supply them or prove them absent, so
    the first view change after that point never completes -- the cluster forfeits, bumps its view,
    and repeats forever, never returning to [Normal]. A ring big enough to hold the whole run's log
    is the only configuration in which this harness tests the protocol rather than that limit. *)
