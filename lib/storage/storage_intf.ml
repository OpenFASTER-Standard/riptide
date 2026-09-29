(** Signature every conforming storage backend implements — mirrors
    [Riptide_transport.Transport_intf.S]'s minimalism: an abstract [t] plus
    the operations callers need, nothing about how a backend is opened or
    closed (each implementation has its own concrete [create]). *)
module type S = sig
  type t

  (** [wal_append t ~op_number bytes] durably appends one WAL entry.
      [op_number] must be exactly one greater than [wal_highest_op_number t]
      (matching {!Riptide_vsr.Replica_log.append}'s own out-of-order guard) —
      implementations raise [Invalid_argument] otherwise. Returns only after
      the write is durable (survives a process crash immediately after).

      {b Which exceptions may legitimately escape, and what each means to a
      caller} (Task 12, audit-remediation Decision 3.3 — this clause is new;
      before it, this contract said nothing about non-[Invalid_argument]
      failures at all, and one going uncaught up through
      {!Riptide_vsr.Replica.durable_append} could kill the whole replica
      process): a conforming implementation may also raise
      - [Eio.Io] wrapping a {!Unix.Unix_error}, or a bare {!Unix.Unix_error}
        directly (a backend not built on Eio), for a REAL, transient
        resource condition — [ENOSPC], [EDQUOT], [EIO], or [ENOMEM] — or
      - [Out_of_memory] itself,

      and {!Riptide_vsr.Replica.durable_append} classifies exactly those
      shapes as its own [storage_fault] refusal (declines to acknowledge,
      counts it, does not crash) rather than an unrecognized exception. Any
      OTHER exception shape — a bare [Sys_error], an [Eio.Io]/[Unix.Unix_error]
      with a different errno, or an [Invalid_argument] not matching one of
      the four documented guard-failure messages this interface's other
      implementations use — is NOT part of this contract and propagates as a
      backend contract violation. A future implementation must not raise
      anything outside this list to signal a refusal it wants a caller to be
      able to retry; there is currently no mechanism for widening the
      recognized set other than updating {!Riptide_vsr.Replica} itself. *)
  val wal_append : t -> op_number:int -> string -> unit

  (** [wal_read t ~op_number] is [None] if no entry was ever written at
      [op_number], or if the entry stored there is corrupt (checksum
      mismatch) — a reader cannot tell those two cases apart from this
      signature alone, by design: telling them apart is exactly what the
      recovery protocol in Task 7 exists to do, using cross-replica
      evidence this single-node signature has no access to. *)
  val wal_read : t -> op_number:int -> string option

  (** [wal_truncate_after t ~op_number] discards every WAL entry with a
      higher op-number. No-op if [op_number >= wal_highest_op_number t].

      {b The discard is DURABLE}, in exactly the sense [wal_append] is:
      reopening the same backend afterwards must not resurrect a discarded
      entry, and must not report a [wal_highest_op_number] above
      [op_number]. Stated here as a contract clause because it was a real
      divergence between two conforming implementations (final-review
      finding I3): [Memory_storage] physically deleted while [File_storage]
      only lowered an in-memory counter, leaving the discarded entries'
      headers and data on disk for its own recovery scan to find again.
      [test/test_storage_shared.ml]'s conformance suite structurally cannot
      check this — it has no reopen case, because [Memory_storage] has no
      restart semantics to have one against — so the clause is pinned by
      [test/test_file_storage.ml]'s own reopen-after-truncate tests instead.
      A backend that cannot honour it must say so at its own [create], not
      leave callers to discover it after a crash. *)
  val wal_truncate_after : t -> op_number:int -> unit

  (** 0 if the WAL is empty. *)
  val wal_highest_op_number : t -> int

  (** Durably overwrites the single superblock record. *)
  val superblock_write : t -> string -> unit

  (** [None] if no superblock was ever written, or if fewer than a majority
      of copies agree (see Task 3). *)
  val superblock_read : t -> string option

  (** [superblock_rebuild_from_wal t] reconstructs a fresh, usable superblock purely from
      whatever this backend can still determine about its own WAL, and durably writes it via
      {!superblock_write} -- the repair action for the state
      {!Riptide_vsr.Replica.restart}'s own fail-stop guard exists to catch (audit-remediation
      Task 13): a superblock unreadable (fewer than a majority of copies verify and agree, or the
      record does not decode) over a WAL that is otherwise completely intact. A torn superblock
      write never touches the WAL itself, so nothing durable is actually lost in that state --
      only the small, separately-stored record a restart needs before it can trust the rest.

      {b Precondition: only callable when [superblock_read t = None].}
      @raise Invalid_argument if [superblock_read t] already returns [Some] -- this function
        exists to REPAIR a lost superblock, never to silently overwrite one that is still
        perfectly good.

      {b Postcondition: [superblock_read t] returns [Some] afterward}, of a record
      {!Riptide_vsr.Replica.restart} can actually decode and use -- not merely "some bytes".

      {b What gets reconstructed, and why each field is what it is} (this is the one place this
      contract has to say something about {!Riptide_vsr.Replica}'s own superblock schema, even
      though this library has no code dependency on [riptide_vsr] -- see
      {!Riptide_storage.File_storage}'s own [.ml], "Task 13", for the full reasoning and why the
      encoding is necessarily duplicated rather than shared). The durable WAL is the only source
      of truth a rebuild has, and it can only speak to [op_number] -- the highest op-number whose
      header and data both still verify, exactly what a fresh {!Riptide_storage.File_storage.create}
      already recovers by scanning the same WAL. Every OTHER field a real VSR superblock carries
      ([view_number], [last_normal_view], [commit_number]) is NOT recoverable from the WAL at all,
      and guessing wrong at any of them is worse than an honest admission of ignorance -- so each
      is set to the same conservative value {!Riptide_vsr.Replica.create}'s own [Init] uses, [0],
      never invented. [commit_number = 0 <= op_number] always holds, so the reconstructed record
      is unconditionally well-formed; [view_number = last_normal_view = 0] reconstructs as
      {!Riptide_vsr.Replica.Normal} status, same as first boot. A replica recovered this way is
      behind on view/commit bookkeeping exactly the way a freshly-caught-up backup is -- it
      relearns both from the ordinary protocol (a later, higher-view [Start_view], and the normal
      commit path) -- but it is never WRONG in a direction that could cost safety: it never claims
      to know a view or a commit it cannot independently prove, and it never discards an
      op-number it can still verify. *)
  val superblock_rebuild_from_wal : t -> unit
end
