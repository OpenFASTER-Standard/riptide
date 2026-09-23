(** A [Storage.S] backend that keeps everything in process memory: no files, no [Eio] switch, no
    ambient resource scope of any kind.

    {2 What it is for}

    Two things, both real:

    - {b Unit tests and any caller that needs a conforming backend without an [Eio_main.run]
      scope.} {!Riptide_vsr.Replica} now takes a [~storage] backend at construction
      ({!Riptide_vsr.Replica.create}), so every replica -- including the several dozen built by
      this repo's existing single-replica and cluster tests -- needs one. {!File_storage.create}
      needs [~sw]/[~fs], so using it there would mean wrapping every one of those tests in an
      [Eio_main.run] + temp-directory scope purely to construct a value whose durability those
      tests never exercise. This module is that scope-free alternative, and it is a real
      [Storage_intf.S] implementation, not a stub: it is run against
      [test/test_storage_shared.ml]'s shared conformance suite alongside {!File_storage} and
      {!Fault_injecting_storage}.
    - {b Simulating a process restart inside one test process.} A [t] outlives any
      {!Riptide_vsr.Replica.t} built over it, so handing the SAME [t] to
      {!Riptide_vsr.Replica.restart} is exactly VSR.tla's [CrashRestart] (VSR.tla:671-690): the
      durable state (WAL + superblock) survives, every volatile in-memory field of the replica
      does not.

    {2 What it deliberately is NOT}

    Durable. Nothing here survives the process exiting, so this is never the right backend for a
    real deployment -- that is {!File_storage}'s job ([O_DIRECT]+[O_DSYNC], real [io_uring]
    writes). "Durable" in this module means only "survives a simulated replica restart within one
    process", which is precisely the property the recovery protocol's tests need and nothing
    more. *)

include Storage_intf.S

val create : unit -> t
(** A fresh, empty backend: [wal_highest_op_number = 0], [superblock_read = None]. *)

val for_test_corrupt : t -> op_number:int -> unit
(** [for_test_corrupt t ~op_number] makes that WAL entry unreadable ([wal_read] returns [None])
    while leaving {!wal_highest_op_number} untouched — i.e. it moves exactly one slot from
    VSR.tla's ["present"] to its ["corrupt"] state (VSR.tla:100-150), never to ["absent"].

    That distinction is the whole reason this function exists rather than tests simply truncating
    or deleting an entry: a slot the replica durably wrote must never read back as provably-empty,
    because two replicas could then jointly "prove" a committed op was never held (VSR.tla:118-147
    records the TLC run that watches [NoCommittedOpProvablyAbsent] fall at depth 6 when exactly
    that one word is mutated). A test that wants ["absent"] instead should use
    {!wal_truncate_after}, which lowers {!wal_highest_op_number} and therefore really does make
    the slot provably never-written.

    Out-of-range [op_number] (below 1, or above {!wal_highest_op_number}) is a no-op. A later
    {!wal_append} at the same op-number (only reachable after a {!wal_truncate_after}) clears the
    corruption, since it writes genuinely new, verifiable bytes. *)
