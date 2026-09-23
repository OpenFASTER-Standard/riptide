(** A durable, keyed store with real per-key deletion — distinct from
    {!Storage_intf.S}'s bounded-ring-WAL-plus-superblock shape, which has
    no notion of an arbitrary number of independently-deletable keys. *)
module type S = sig
  type t

  val get : t -> key:string -> string option
  (** [None] if the key was never put, was deleted, or its stored value is
      corrupt (checksum mismatch) — the same "cannot distinguish never-written
      from corrupted" ambiguity {!Storage_intf.S.wal_read} already documents. *)

  val put : t -> key:string -> string -> unit
  (** Durably writes [key]'s value, overwriting any previous value. *)

  val delete : t -> key:string -> unit
  (** Durably removes [key]. Durable across a reopen — a deleted key must
      never be resurrected, the same class of bug this project already
      found and fixed once in [File_storage.wal_truncate_after]. No-op if
      the key was never put. *)
end
