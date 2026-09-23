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
      the write is durable (survives a process crash immediately after). *)
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
end
