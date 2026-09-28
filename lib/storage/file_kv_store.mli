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

val create : sw:Eio.Switch.t -> fs:Eio.Fs.dir_ty Eio.Path.t -> owner:string -> string -> t
(** [create ~sw ~fs ~owner dir_path] opens (creating if necessary) a key-value store directory at
    [dir_path]. Every key already durably [put] on a previous [create] of the same [dir_path]
    is visible again immediately -- there is no separate recovery scan needed (unlike
    {!Riptide_storage.File_storage.create}'s ring-highest-op-number reconstruction): each
    key's own file either exists with a valid record or doesn't, and {!get} re-derives that
    per call directly from disk rather than from any in-memory state built at [create] time.

    {b [~owner], subtask 4.6's construction-time fix for a confirmed, real data-destruction bug,
    made mandatory by subtask 4.8 to close the gap an optional [?owner] left open}: this store's
    key space is flat and untyped (one file per key, named by the key's own content hash), so
    nothing stops two unrelated consumers from independently pointing [create] at the same
    [dir_path] -- and when that happens, they silently corrupt each other's data (see
    {!Riptide_crypto.Redaction_store}'s own [.mli] for the exact three-way reproduction: a keystore
    and a {!Riptide_materialize.Materializer} sharing one directory).

    [owner] must be a non-empty string: [~owner:""] raises [Invalid_argument] before anything is
    created or read. Making [~owner] mandatory removed the syntactic way to express "no owner", and
    an empty tag is that same escape hatch spelled differently -- a marker declaring nothing, which
    any other empty-tagged consumer then matches -- so it is rejected at construction rather than
    accepted as a degenerate tag.

    [create] writes a small marker file recording [owner] the first time any caller claims
    [dir_path], and on every later [create] of the same [dir_path], compares the new [owner]
    against the marker: a mismatch raises [Invalid_argument] immediately, before this call
    returns a usable [t] and before either consumer can touch the shared directory's data at all.
    A matching tag (e.g. the same subsystem reopening its own store) succeeds exactly as it
    always did.

    There is no opt-out: every [File_kv_store.t], from every consumer, now has a declared owner
    (subtask 4.8 made [~owner] mandatory), so a directory can no longer be pointed at without one.
    A directory shared by two consumers that each pass a distinct, real [~owner] is therefore
    always caught at construction time -- the "neither side supplies a tag" and "one side omits its
    tag" gaps a previous, optional [?owner] left open are both closed.

    {b What this does NOT close, and it is a real, still-open gap rather than a hypothetical one:}
    two unrelated consumers that both pass the SAME [~owner] for the same [dir_path]. The marker
    matches, so both [create] calls succeed exactly as a legitimate reopen does -- a tag cannot
    tell "this subsystem reopening its own store" apart from "an unrelated consumer using my tag"
    -- and the two then share one flat key space and destroy each other's data with nothing raised
    anywhere, exactly as before this guard existed. See
    {!Riptide_crypto.Redaction_store.create}'s own doc comment for the full account and for the
    running test that demonstrates the destruction
    ([test_using_the_same_owner_tag_on_both_sides_still_destroys_a_wrapped_dek] in
    [test/test_lattice_materialize_crypto_scenarios.ml]). Fixing it means changing this marker
    mechanism itself, which subtask 4.8's design spec lists as an explicit Non-Goal. *)

val owner : t -> string
(** Restates {!Kv_store_intf.S.owner}'s own spec with this backend's more specific detail below;
    the [include Kv_store_intf.S] above already brings in a [val owner : t -> string] of its own,
    and this local declaration shadows it (silently -- OCaml gives no error or warning for a
    local [val] overriding a same-named included one), so it is this doc comment, not the
    [include], that actually constrains [owner]'s contract here. Keep the two in agreement by
    hand; a divergence would only surface indirectly, e.g. at a
    [Materializer.Make(...)(File_kv_store)] application site.

    [owner t] is the tag [t] was constructed with, i.e. [t]'s own [create] call's [~owner]
    argument -- what the marker file actually holds on disk, whether that [create] confirmed an
    existing marker or wrote a fresh one.

    Exposed for callers that themselves construct a [t] on another module's behalf and need to
    verify, after the fact, that it was tagged the way that module requires --
    {!Riptide_crypto.Redaction_store.create} (subtask 4.8) is the first such caller: it receives an
    already-built [t] rather than constructing one itself, so [create] above's own owner-marker
    guard cannot protect it unless it checks this function's result against its own expected
    tag. {!Riptide_materialize.Materializer.Make.create}, via the generic [KV.owner] any
    {!Kv_store_intf.S} implementer provides, is a second such caller when applied to this module --
    so "first" names an example, not an exhaustive list. *)
