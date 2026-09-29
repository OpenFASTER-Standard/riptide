(** A durable, keyed store with real per-key deletion — distinct from
    {!Storage_intf.S}'s bounded-ring-WAL-plus-superblock shape, which has
    no notion of an arbitrary number of independently-deletable keys. *)
module type S = sig
  type t

  val owner : t -> string
  (** The tag this store was constructed with. Every implementer must have one; a backend with no
      real ownership/collision-risk concept can return a fixed placeholder.

      {b That placeholder allowance couples this module type to its consumers, so it is worth
      stating here rather than leaving it to be discovered by reading two interfaces together:} a
      consumer whose own constructor checks [owner] against a caller-supplied tag -- as
      {!Riptide_materialize.Materializer.Make.create} does -- forces every caller building such a
      consumer over a placeholder-returning backend to pass that exact placeholder string as its
      [~owner], or the check spuriously rejects an entirely legitimate construction. A backend
      choosing a placeholder is therefore choosing a string its consumers' callers must know and
      repeat, not an inert stub. *)

  val get : t -> key:string -> string option
  (** [None] if the key was never put, was deleted, or its stored value is
      corrupt (checksum mismatch) — the same "cannot distinguish never-written
      from corrupted" ambiguity {!Storage_intf.S.wal_read} already documents. *)

  val put : t -> key:string -> string -> unit
  (** Durably writes [key]'s value, overwriting any previous value. The overwrite itself is
      atomic against crashes: a crash during a [put] can never leave [key] readable as a torn
      mix of the old and new values -- a subsequent [get] sees either the value from the last
      successful [put], in full, or (if this [put] itself completed) the new one, in full.

      {b Task 16: concurrent writers to the same key are handled per-backend.} For backends that
      support concurrent same-key writes (e.g., {!Riptide_storage.File_kv_store}, which uses
      unique-per-call temp files under {!Riptide_storage.Dir_lock}'s protection), concurrent
      [put] calls to the same key produce an undefined winner (whichever writer finishes last is
      observed), but never a torn mix or phantom [None]. For backends that do not support
      concurrent same-key writes, concurrent [put]s to the same key are undefined (reading the
      backend's own [.mli] or code comments is required to determine which backends make
      concurrency guarantees). *)

  val delete : t -> key:string -> unit
  (** Durably removes [key]. Durable across a reopen — a deleted key must
      never be resurrected, the same class of bug this project already
      found and fixed once in [File_storage.wal_truncate_after]. No-op if
      the key was never put. *)
end
