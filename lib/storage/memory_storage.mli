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

val for_test_lose_superblock : t -> unit
(** [for_test_lose_superblock t] makes {!superblock_read} return [None] again, as if this backend
    had never had a superblock written to it — {b without touching the WAL}, which keeps every
    entry it already held.

    {b That combination is a real, frequently-reachable crash state, not a contrived one}, which
    is why it gets a test hook of its own. {!File_storage}'s superblock is 3 independent copies
    written by 3 sequential, non-atomic header-then-data write pairs, and its [superblock_read]
    returns [None] (honestly, by design) whenever fewer than 2 of them verify and agree — so an
    ordinary crash partway through {!superblock_write}, with no storage fault injected anywhere,
    lands exactly here: superblock unreadable, WAL fully intact.

    Deliberately NOT symmetric with {!for_test_corrupt}'s own careful refusal to make a written
    WAL slot read back absent. That rule (VSR.tla:111-150) is about WAL slots, whose absence is
    protocol EVIDENCE other replicas act on; the superblock is this replica's own private durable
    state and its loss is simply a fact a restart has to cope with. What a restart must not do is
    cope with it by inventing [op_number = 0] — see {!Riptide_vsr.Replica.restart}'s own doc
    comment for the fail-stop guard this hook is the regression test for. *)
