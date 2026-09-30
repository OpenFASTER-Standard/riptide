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
      unique-per-call temp-file naming plus atomic [Eio.Path.rename] to ensure each writer uses
      a distinct temp path), concurrent [put] calls to the same key produce an undefined winner
      (whichever writer finishes last is observed), but never a torn mix or phantom [None]. For
      backends that do not support concurrent same-key writes, concurrent [put]s to the same key
      are undefined (reading the backend's own [.mli] or code comments is required to determine
      which backends make concurrency guarantees). *)

  val delete : t -> key:string -> unit
  (** Durably removes [key]. Durable across a reopen — a deleted key must
      never be resurrected, the same class of bug this project already
      found and fixed once in [File_storage.wal_truncate_after]. No-op if
      the key was never put. *)

  val fold : t -> init:'a -> (key:string -> 'a -> 'a) -> 'a
  (** [fold t ~init f] applies [f] once to each key currently present in [t] (i.e. every key that
      has been [put] and not since [delete]d), threading an accumulator through starting from
      [init]. Added to close audit finding Storage-Important-6 (Task 24): enumerating a store's
      contents used to require an external log of every key ever written, which
      {!Riptide_crypto.Redaction_store} (Task 6/Decision 4's keystore) has no such log for on its
      own.

      {b [key] here is this store's own INTERNAL identifier for the record — NOT necessarily the
      original string a caller passed to [put].} [get]/[put]/[delete] above already make
      [key:string] deliberately opaque: nothing in this module type promises a backend stores that
      string in the clear. {!Riptide_storage.File_kv_store}, the one real implementer as of this
      writing, does not: every key is hashed via SHA-256 before it ever touches disk (see
      [file_kv_store.ml]'s [path_for]), and only that hash — never the original key — is persisted,
      as the record's own filename. So for that backend, the [key] passed to [f] is the
      64-lowercase-hex-character content hash of whatever string was originally [put], and there is
      no way, structurally, to invert a SHA-256 hash back to its pre-image: {b [fold] cannot, and
      does not claim to, recover an original key a backend never stored in the clear.} A different,
      hypothetical backend that genuinely does store keys in the clear could honestly hand back the
      real original string here instead — but that is a fact about that backend, not something this
      module type requires or [fold]'s own contract can promise in general.

      {b No ordering guarantee whatsoever.} The order in which [f] is applied across the keys
      currently present is unspecified: not insertion order, not any order stable across two calls
      against the same unmodified [t], nothing. A caller that needs a stable order must sort the
      result itself. *)
end
