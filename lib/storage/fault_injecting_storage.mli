(** A [Storage.S] backend that wraps any other conforming backend (in practice
    {!Riptide_storage.File_storage}, but this module is genuinely generic over the wrapped
    module -- a real conformance benefit of {!Storage_intf.S} staying minimal) and injects
    deterministic, seeded faults into it, for driving the VSR recovery protocol's
    storage-fault-handling paths (Task 7) and, eventually, the DST harness (Task 9) through real
    storage corruption/loss without needing a real disk to actually fail.

    At the zero-probability default {!default_fault_config}, every operation passes straight
    through to the wrapped backend unchanged -- {!Riptide_storage.File_storage} and this module
    are required to behave identically under it (see [test/test_storage_shared.ml]'s shared
    conformance suite, run against both).

    Every random decision this module makes is drawn from the single {!Riptide_sim.Prng.t} passed
    to {!create}, explicitly threaded -- never {!Stdlib.Random} or any OS entropy source -- so an
    entire run is reproducible from one seed number, mirroring
    {!Riptide_sim.Network}'s own fault-injection discipline. *)

include Storage_intf.S

type fault_config = {
  drop_probability : float;
      (** Probability a [wal_append]'s data is lost rather than durably persisted. The call still
          returns [unit] (a caller sees no error) -- but unlike an early version of this module,
          the [op_number] itself *is* still delegated to the wrapped backend (as an empty-string
          entry standing in for "nothing useful was actually retained"), so the wrapped backend's
          own [wal_highest_op_number] -- and hence this module's own, a direct passthrough --
          advances exactly as a well-behaved caller expects. [wal_read] of that [op_number] on
          *this* [t] is unconditionally [None] regardless of what the wrapped backend reports
          (tracked in [dropped_slots], the same masking technique [corrupted_slots] below already
          uses for [corrupt_probability], with the same restart-persistence limitation: this
          bookkeeping is this particular [t] value's own in-memory state, so it does not survive a
          fresh {!create} wrapping a reopened backend). This matches
          {!Storage_intf.S.wal_read}'s own documented ambiguity between "never written" and
          "written, then lost" -- a caller cannot and need not tell those apart.

          The earlier version of this module skipped delegation outright on a drop instead, which
          left the wrapped backend's [wal_highest_op_number] one behind whatever the wrapper
          itself considered current. That is a real defect, not a harmless simplification: the
          caller's very next *legitimate*, sequential [wal_append] would fall through to the
          normal passthrough branch, reach the wrapped backend's own out-of-order guard expecting
          [op_number = wal_highest_op_number t + 1], and raise [Invalid_argument] -- an exception
          that looks like a caller bug, not an observable storage fault, defeating this module's
          whole purpose (driving the recovery protocol's fault-handling paths through *observable*
          faults, never crashing the simulated replica). Always delegating instead closes that gap
          structurally: this module's [wal_append] never again disagrees with the wrapped
          backend's own bookkeeping about which op_number comes next, regardless of what fired.

          Models a storage layer that falsely acknowledges a write it never actually persisted.
          Unlike [corrupt_probability] below, dropped slots do not count against [faults_max] --
          deferred; see the design doc's own report for the reasoning (a drop, unlike a
          corruption, produces no persistent on-disk artifact for a differently-implemented
          recovery path to trip over, so the two faults aren't obviously equally dangerous to cap
          the same way, but this hasn't been worked through yet). *)
  corrupt_probability : float;
      (** Probability a [wal_append]'s data is XOR-flipped at one deterministically-chosen byte
          position before being delegated to the wrapped backend's own [wal_append] -- corruption
          happens once, at write time, to the bytes actually handed to the wrapped backend, so it
          is permanent and content-seeded: re-reading the same corrupted entry always returns the
          same (corrupted) result, it never "heals" on a later [wal_read] call. Empty ([""])
          entries are never corrupted (there is no byte to flip).

          A wrapped backend recomputes its own checksum from exactly the (already-flipped) bytes
          it receives, so it cannot itself detect anything wrong -- it durably stores a
          self-consistent, checksum-valid entry, just not the one the caller actually meant to
          write. [wal_read] on *this* [t] returns [None] for such an entry regardless (tracked
          explicitly, not rediscovered via the wrapped backend's own checksum machinery). This
          tracking is this particular [t] value's own in-memory state: it does not survive a
          fresh {!create} wrapping a reopened backend (e.g. simulating a process restart) -- a new
          wrapper has no memory of earlier corruption and will report whatever the freshly-wrapped
          backend itself reports, which, per the above, reads the corrupted bytes back as valid.
          Modeling storage corruption that itself durably survives a restart needs corrupting
          bytes already covered by an already-computed checksum, which requires bypassing
          [Storage_intf.S] to reach the wrapped backend's own on-disk representation directly (see
          [test/test_file_storage.ml]'s own direct-file-corruption tests for that pattern) -- out
          of scope for this generic, implementation-agnostic wrapper; left to whichever later task
          wires restart scenarios together. *)
}

val default_fault_config : fault_config
(** Both probabilities [0.0] -- i.e. every operation passes straight through, unchanged, to the
    wrapped backend. *)

val create :
  prng:Riptide_sim.Prng.t ->
  ?fault_config:fault_config ->
  replication_quorum:int ->
  underlying:(module Storage_intf.S with type t = 'a) ->
  'a ->
  t
(** [create ~prng ?fault_config ~replication_quorum ~underlying:(module U) u] wraps the already-
    constructed backend value [u] (of [U]'s own [t]) with fault injection driven by [prng] and
    [fault_config] (defaults to {!default_fault_config}, i.e. no faults).

    [replication_quorum] is the cluster's replication quorum size; this module enforces
    [faults_max = replication_quorum - 1] simultaneous corrupted WAL slots (Decision 7 of the
    storage-fault-tolerant-recovery design: a cluster with quorum [q] can tolerate at most [q - 1]
    simultaneously faulty replicas and still make safe progress) -- a [wal_append] whose corrupt
    decision would push the count of currently-live corrupted slots to or past [faults_max]
    raises [Invalid_argument "faults_max exceeded"] instead of silently corrupting anyway. A
    corrupted slot stops counting against the cap once it is truncated away via
    [wal_truncate_after]; this module has no visibility into the wrapped backend's own physical
    storage layout (e.g. ring-slot reuse), so a slot evicted only by the wrapped backend's own
    internal eviction (not an explicit [wal_truncate_after] call) may continue to count against
    the cap even after it is no longer really live -- a conservative (never permits more live
    faults than intended), not unsafe, approximation. *)

val for_test_corrupt_entry : t -> op_number:int -> unit
(** [for_test_corrupt_entry t ~op_number] corrupts exactly that one already-written WAL entry,
    deterministically and immediately -- the counterpart of {!fault_config}'s own
    [corrupt_probability] for a caller that needs a SPECIFIC replica's SPECIFIC op-number to fault
    at a SPECIFIC moment (Task 8's cluster recovery tests), which the probabilistic path
    structurally cannot express: that one only ever fires at write time, on whichever appends
    happen to draw it, so a test that has already settled a cluster into a known-good state has no
    write left to attach a fault to. Named [for_test_*] to match the convention
    {!Riptide_vsr.Replica}'s own test-support surface already uses.

    {b The effect is identical to the probabilistic path's}, by construction rather than by
    coincidence: one byte of the entry is XOR-flipped (same [flip_one_byte], same [prng] draw) and
    written back through the wrapped backend's own [wal_append], so the corruption is REAL and
    durable on that backend -- a differently-implemented reader that bypasses this wrapper entirely
    sees the flipped bytes, not the original -- and the [op_number] is recorded in the same
    [corrupted_slots] bookkeeping, so {!wal_read} of it on THIS [t] returns [None]. It is
    consequently subject to the same caveats documented on [corrupt_probability]: the [None]-masking
    is this [t] value's own in-memory state and does not survive a fresh {!create} over the same
    backend, and it is cleared for a slot once that slot is truncated away (which is what lets a
    genuine repair -- truncate to the longest correct prefix, re-append -- become visible again).

    {b Counts against [faults_max] exactly like a probabilistic corruption}, raising
    [Invalid_argument "faults_max exceeded"] rather than corrupting beyond the cap: one invariant,
    one meaning, whichever path reached it.

    {b Raises [Invalid_argument] for an [op_number] with no readable durable entry behind it}
    (below 1, above {!wal_highest_op_number}, or already corrupted/dropped on this [t]) rather than
    being a silent no-op -- deliberately diverging from {!Riptide_storage.Memory_storage.for_test_corrupt},
    which documents out-of-range as a no-op. Every caller of this function is a test whose whole
    premise is that the fault landed; a silent no-op there does not fail, it produces a
    fault-free run wearing a corruption test's name.

    {b [wal_highest_op_number] is deliberately UNCHANGED}: this moves exactly one slot from
    VSR.tla's ["present"] to its ["corrupt"] state, never to ["absent"] -- a slot the replica
    durably wrote must never read back as provably-empty, or two replicas could jointly "prove" a
    committed op was never held. A caller that wants ["absent"] wants {!wal_truncate_after}. Entries
    above [op_number] are preserved byte-for-byte (reaching an already-written slot at all requires
    truncating back to it first, since {!Storage_intf.S} has no random-access write). *)

val set_fault_config : t -> fault_config -> unit
(** Replaces [t]'s fault config for every subsequent [wal_append], without touching any
    already-recorded [corrupted_slots]/[dropped_slots] bookkeeping for op_numbers appended under
    the old config. Useful for a caller (e.g. a DST harness, Task 9) that wants to vary fault
    rates over the course of one simulated run instead of fixing them for the wrapper's whole
    lifetime. *)
