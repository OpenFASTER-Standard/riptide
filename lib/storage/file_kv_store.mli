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

val max_value_size : int
(** The hard upper bound, in bytes, on a single value this backend can store: one aligned data
    slot. {!Kv_store_intf.S.put} raises [Invalid_argument] naming this limit for anything larger,
    and nothing is written.

    {b Exposed because a caller genuinely cannot infer it and one was already hurt by that} (Task
    9's end-to-end proof, 2026-09-23). {!Kv_store_intf.S.put}'s own contract states no bound at all
    -- it cannot, since it covers every backend -- so a consumer whose values grow over time has no
    way to ask how much room it has. {!Riptide_materialize.Materializer}'s accumulator is exactly
    such a consumer: it is the join of every value ever written to a [merge_key], which for a
    grow-only lattice grows without bound, and it reaches this limit in the ordinary course of
    working rather than through any misuse. See that module's own [write] doc comment for what
    happens when it does, and test_lattice_materialize_crypto_scenarios.ml for the running
    reproduction. *)

val create : sw:Eio.Switch.t -> fs:Eio.Fs.dir_ty Eio.Path.t -> ?owner:string -> string -> t
(** [create ~sw ~fs ?owner dir_path] opens (creating if necessary) a key-value store directory at
    [dir_path]. Every key already durably [put] on a previous [create] of the same [dir_path]
    is visible again immediately -- there is no separate recovery scan needed (unlike
    {!Riptide_storage.File_storage.create}'s ring-highest-op-number reconstruction): each
    key's own file either exists with a valid record or doesn't, and {!get} re-derives that
    per call directly from disk rather than from any in-memory state built at [create] time.

    {b [?owner], subtask 4.6's construction-time fix for a confirmed, real data-destruction bug}:
    this store's key space is flat and untyped (one file per key, named by the key's own content
    hash), so nothing stops two unrelated consumers from independently pointing [create] at the
    same [dir_path] -- and when that happens, they silently corrupt each other's data (see
    {!Riptide_crypto.Redaction_store}'s own [.mli] for the exact, previously-pinned three-way
    reproduction: a keystore and a {!Riptide_materialize.Materializer} sharing one directory).

    When [owner] is [Some tag], [create] writes a small marker file recording [tag] the first
    time any caller claims [dir_path], and on every later [create] of the same [dir_path] with a
    [Some] owner, compares the new [tag] against the marker: a mismatch raises [Invalid_argument]
    immediately, before this call returns a usable [t] and before either consumer can touch the
    shared directory's data at all. A matching [tag] (e.g. the same subsystem reopening its own
    store) succeeds exactly as it always did.

    [owner] is optional, and omitting it is a pure no-op with respect to this check -- for
    backward compatibility, and because it cannot be otherwise: a directory with no marker at all
    (every [dir_path] that predates this task, or whose callers simply never opt in) has nothing
    to compare a later [Some tag] against, so the first [Some]-owner [create] of such a directory
    always succeeds and starts the marker fresh from that point on. Concretely: if EITHER side of
    a real collision omits [owner] -- not just both -- the pair is exactly as unprotected as
    before this task existed. Opting a directory in requires every consumer of it to pass
    [~owner], consistently, from that directory's very first [create] onward; this function has
    no way to retroactively protect a caller who chooses not to. *)
