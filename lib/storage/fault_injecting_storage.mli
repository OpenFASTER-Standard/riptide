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
      (** Probability a [wal_append] is silently never delegated to the wrapped backend -- the
          call still returns [unit] (a caller sees no error), but nothing durable happens, so a
          later [wal_read] of that [op_number] is [None] and the wrapped backend's own
          [wal_highest_op_number] does not advance past it. Models a storage layer that falsely
          acknowledges a write it never actually persisted. *)
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
