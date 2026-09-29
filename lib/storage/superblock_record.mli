(** The single definition of the VSR superblock record's on-disk schema, plus the two precondition
    checks {!Storage_intf.S.superblock_rebuild_from_wal} enforces — shared by every producer and
    consumer of that record rather than hand-duplicated per call site.

    {b Why this lives in [riptide_storage] and not in [riptide_vsr], where the record's MEANING
    lives.} The dependency runs one way only: [riptide_vsr]'s own [dune] lists [riptide_storage]
    among its libraries, and nothing in [riptide_storage]'s [dune] mentions [riptide_vsr]. Both
    layers need the schema — [riptide_vsr] because
    {!Riptide_vsr.Replica}'s every durable-state write goes through it, [riptide_storage] because
    {!Storage_intf.S.superblock_rebuild_from_wal} has to produce a record a real
    {!Riptide_vsr.Replica.restart} can decode — so the only place it can live ONCE is the lower
    layer, with the upper layer delegating to it.

    {b The hazard this closes, concretely} (Task 13 fix round, review finding 5). Before this
    module existed the four field names/shapes below were typed out independently in THREE places:
    [Riptide_vsr.Replica]'s own [superblock_encode]/[superblock_decode], {!File_storage}'s rebuild,
    and {!Memory_storage}'s rebuild. Nothing mechanically tied them together — a field rename in
    one would have left the other two silently producing records the renamed decoder rejects, i.e.
    a rebuild that "succeeds" and then makes [Replica.restart] refuse for a completely different
    reason than the one the operator was repairing. There is now exactly one place to change.

    This module deliberately knows nothing about what the fields MEAN to the protocol (which
    combinations are reachable, what [status] they reconstruct to, what a view change does with
    them). That is {!Riptide_vsr.Replica}'s own business, and stays documented there. What this
    module owns is the schema and the small set of well-formedness rules that hold for EVERY
    conceivable VSR execution, so no caller can write a record that is nonsense on its face. *)

type t = {
  view_number : int;
  last_normal_view : int;
  op_number : int;
  commit_number : int;
}
(** VSR.tla's own [CrashRestart] durable-state list (VSR.tla:592-596) minus the log itself (which
    lives in the WAL, not here). [rep_status] is deliberately absent: it is RECONSTRUCTED from
    [view_number > last_normal_view] at restart (VSR.tla:680-682), never stored. *)

val encode : t -> string
(** Canonically encodes the record, via {!Riptide.Value.canonical_encode} over a
    [Value.Record] of four [Value.Int] fields named exactly [commit_number], [last_normal_view],
    [op_number], [view_number]. Total: encodes whatever it is given, including combinations
    {!decode} will then refuse (see below) — validation is {!check_rebuild_values}' job, so that
    {!Riptide_vsr.Replica}'s own hot-path superblock write stays a pure encode with no guard in it.
*)

val decode : string -> t option
(** [None] — never an exception — for anything that is not exactly the record {!encode} produces,
    including a record whose [commit_number] exceeds its [op_number]
    ([CommitNumberNeverHigherThanOpNumber], VSR.tla:721-722, applied to durable state as it is read
    back rather than only as it is written: such a record describes a state no reachable execution
    can produce, so it is discarded whole) or any negative field. A partially-decodable superblock
    is no more trustworthy than a missing one. *)

(** The two exact messages {!check_rebuild_precondition} raises with are exported below, purely so a
    test asserting on one references the same string the implementation raises rather than a
    hand-typed copy of it — which is the third and last place review finding M10's drift hazard lived
    (the two backends' copies of the check itself are gone; {!check_rebuild_precondition} is now the
    only copy). Not intended for any other use: a caller reacting to a refusal should match
    [Invalid_argument], not compare message text. *)

val refusal_superblock_already_readable : string
(** [superblock_read <> None]: refusing to rebuild over an already-usable superblock. *)

val refusal_empty_wal : string
(** [durable_op_number = 0]: this is first boot, there is no lost superblock to repair. *)

val check_rebuild_precondition : superblock_read:string option -> durable_op_number:int -> unit
(** The shared precondition of every {!Storage_intf.S.superblock_rebuild_from_wal} implementation,
    stated once here so the three backends (and the tests asserting on the message) cannot drift
    apart — they used to carry three independently typed-out copies of both the check and its
    message (Task 13 fix round, review finding M10).

    [~durable_op_number] is the op-number the caller is about to write into the rebuilt record, i.e.
    the backend's own answer to "what does my WAL still attest to" — i.e.
    {!Storage_intf.S.wal_highest_durable_op_number}, NOT
    {!Storage_intf.S.wal_highest_op_number}, which for {!File_storage} carries the stricter
    "this entry is fully readable" meaning. See
    {!Storage_intf.S.superblock_rebuild_from_wal} on why the rebuild deliberately uses the
    over-reporting derivation.

    @raise Invalid_argument if [superblock_read <> None]: the repair exists to rebuild a LOST
      superblock, never to overwrite one that is still perfectly good.
    @raise Invalid_argument if [durable_op_number = 0]: with no superblock AND nothing durable in the
      WAL there is nothing to repair — that is FIRST BOOT, which {!Riptide_vsr.Replica.restart}
      already handles correctly on its own. Rebuilding there would write a degenerate superblock over
      a virgin backend and thereby permanently foreclose {!Riptide_vsr.Replica.create}, which refuses
      if ANY superblock already exists (review finding M8). The two conditions together are
      {!Riptide_vsr.Replica.restart}'s own fail-stop guard, which is the state this repair exists to
      get a replica out of. *)

val check_rebuild_values :
  view_number:int -> last_normal_view:int -> op_number:int -> commit_number:int -> unit
(** The well-formedness rules the OPERATOR-SUPPLIED values of a rebuild must satisfy. These are
    cheap, local sanity checks — they catch a transposed argument or a typo, and nothing more. {b
    They cannot and do not check that the values are TRUE}, which is the actual hazard
    {!Storage_intf.S.superblock_rebuild_from_wal}'s own doc comment is about: every rule below is
    satisfied by, for example, all-zeros, which is precisely the silent-committed-data-loss input
    that fix round exists to stop being the default.

    @raise Invalid_argument if any of the three supplied values is negative (VSR.tla types every
      one of them [Nat]).
    @raise Invalid_argument if [commit_number > op_number]
      ([CommitNumberNeverHigherThanOpNumber], VSR.tla:721-722). A cluster whose real commit-number
      is above what this replica's own WAL can account for cannot be described by this replica's
      superblock at all: the operator must supply this replica's own commit-number, which is
      necessarily [<= op_number]. Refused rather than silently clamped, because clamping would
      hide exactly the mistake worth seeing.
    @raise Invalid_argument if [last_normal_view > view_number]. [last_normal_view] is the last
      view in which this replica was [Normal], so it can never exceed the current view; the pair is
      also what [restart] reconstructs [status] from, and this ordering is what makes that
      reconstruction meaningful. *)
