(** A [Kv_store_intf.S] backend: one file per key, in a flat directory, named by the
    hex-encoded SHA-256 content-hash of the key. Reuses {!Riptide_storage.File_storage}'s own
    already-proven [O_DIRECT]+[O_DSYNC] durable I/O technique (transcribed, not imported --
    that module's own [.mli] exposes only [Storage_intf.S] plus its own [create], nothing of
    its low-level helpers). See {!Riptide_storage.File_kv_store}'s [.ml] top comment for: the
    per-key on-disk record layout (header: length + checksum, then data); why reads
    deliberately use different, non-[O_DIRECT], non-creating open flags than writes; and why
    [delete] is a real [Eio.Path.unlink] rather than a header zero-out (unlike
    {!Riptide_storage.File_storage.wal_truncate_after}, which cannot unlink because its ring
    file holds many other still-live entries).

    {b Two properties of [delete] worth stating here, since {!Kv_store_intf.S}'s own contract
    cannot state them for every backend.} First, the removal is durable against a crash, not
    merely against a reopen: the [unlink] is followed by an fsync of the containing {e directory},
    without which POSIX leaves the directory-entry removal unsynced and a crash right after
    [delete] returns could resurrect the key. Second, [delete] does {b not} scrub: the value's
    bytes are not overwritten before the [unlink], so they may remain forensically recoverable
    from unallocated blocks (or a filesystem journal/snapshot/backup) until those blocks are
    reused. That is a deliberate, disclosed limitation rather than an oversight -- see
    {!Riptide_crypto.Redaction_store.redact}, this store's first real consumer, for what it does
    and does not imply for redaction. *)

include Kv_store_intf.S

val create : sw:Eio.Switch.t -> fs:Eio.Fs.dir_ty Eio.Path.t -> string -> t
(** [create ~sw ~fs dir_path] opens (creating if necessary) a key-value store directory at
    [dir_path]. Every key already durably [put] on a previous [create] of the same [dir_path]
    is visible again immediately -- there is no separate recovery scan needed (unlike
    {!Riptide_storage.File_storage.create}'s ring-highest-op-number reconstruction): each
    key's own file either exists with a valid record or doesn't, and {!get} re-derives that
    per call directly from disk rather than from any in-memory state built at [create] time. *)
