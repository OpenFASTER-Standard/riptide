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

    {b Task 11: also takes a real, OS-level lock on [dir_path]}, strictly before the [~owner]
    marker check below (via {!Riptide_storage.Dir_lock.acquire}), held for the returned [t]'s
    entire lifetime.

    @raise Invalid_argument immediately, before the [~owner] check and before touching any key
      file, if [dir_path] is already locked by another live handle -- this process's own or a
      genuinely different OS process's. A PHYSICAL guard, independent of and in addition to the
      LOGICAL [~owner] guard described below; see {!Riptide_storage.Dir_lock}'s own [.mli] for the
      full rationale and how the two guards' scopes differ. When the conflicting handle's owner tag
      is already readable on disk (the marker {!Riptide_storage.Dir_lock} itself knows nothing
      about), the message names it (review finding M3) via {!Riptide_storage.Dir_lock.acquire}'s
      [describe_conflict] hook.

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
    two unrelated consumers that both pass the SAME [~owner] for the same [dir_path]
    {b and never hold a live handle at the same instant}. The marker matches, so both [create]
    calls succeed exactly as a legitimate reopen does -- a tag cannot tell "this subsystem
    reopening its own store" apart from "an unrelated consumer using my tag" -- and the two then
    share one flat key space and destroy each other's data with nothing raised anywhere, exactly
    as before this guard existed.

    {b Narrowed by Task 11, not closed:} this used to be open for a SIMULTANEOUSLY-live same-tag
    pair reached through TWO SEPARATE [create] calls too (two independently-opened handles over
    [dir_path] at once) -- that specific shape is now caught by {!Riptide_storage.Dir_lock}'s own
    physical [flock(2)] guard (see [create]'s own doc comment above), regardless of whether the two
    tags match, since the lock is taken before the marker is ever consulted. What Task 11's lock
    actually closes is exactly that: double construction of two separate [t]s over one [dir_path],
    whether from one process or two.

    {b What remains genuinely open, stated precisely rather than narrowed further than the lock
    actually reaches (review finding I2, 2026-09-29 -- an earlier version of this disclosure said
    only "strictly sequential reuse" remained, which overclaimed what the lock reaches; falsified
    live by a test that shares one already-built handle between two consumers and still silently
    destroys data with the lock never once firing):} two different shapes, neither of which a lock
    scoped to one [create] call's own [t] can see, since both involve at most ONE live [t] at the
    lock's own granularity:

    - {b Strictly SEQUENTIAL reuse over time}: one handle fully released (its switch finished, its
      lock dropped) before a second, differently-purposed consumer opens the same directory under a
      copied or inherited tag. The marker cannot tell "my own store reopening" apart from "an
      unrelated consumer that happens to use my tag" once there is no live handle left to conflict
      with.
    - {b SIMULTANEOUS use of a single, ALREADY-CONSTRUCTED handle by two different logical
      consumers at once} -- this module's own [create] above takes [~owner] and checks it against
      the marker, but a caller that constructs exactly ONE [t] (one [create] call, one lock, one
      marker check) and then hands that SAME [t] to two unrelated consumers has given neither guard
      a second call to compare against: the lock is already held, for that one [t]'s whole
      lifetime, by nothing that conflicts with itself, and the marker was only ever consulted once.
      {!Riptide_crypto.Redaction_store.create}'s own [.mli] states the resulting requirement in
      prose ("[kv] must be this keystore's alone"), not as anything construction-time code here can
      enforce.

    Both shapes destroy each other's data over one shared, flat key space exactly as silently and
    exactly as completely as before either guard existed. Both are backed by running code, not just
    this disclosure, in [test/test_lattice_materialize_crypto_scenarios.ml]'s
    [test_using_the_same_owner_tag_on_both_sides_still_destroys_a_wrapped_dek]: its first two
    phases demonstrate the SEQUENTIAL shape (a materializer's write, through its own,
    separately-opened handle, silently destroys a record a now-closed keystore handle wrote
    earlier), and its third phase demonstrates the SHARED-HANDLE shape directly (one [kv], a
    keystore and a materializer both built from it at once, a keystore [put] silently overwriting
    the materializer's own accumulator value at a colliding key -- the lock never once fires,
    because only one [create] call is ever made). See
    {!Riptide_crypto.Redaction_store.create}'s own doc comment for the full account. Fixing the
    sequential gap means changing this marker mechanism itself (e.g. per-consumer key prefixes, or
    a persistent, not merely handle-lifetime-scoped, exclusivity record); fixing the shared-handle
    gap means a guard this module structurally cannot provide at all, since by the time [create]
    receives (or, for {!Riptide_crypto.Redaction_store.create} and
    {!Riptide_materialize.Materializer.Make.create}, is handed) a [kv], there is no way to tell "the
    only consumer of this handle" from "one of several". Both are out of scope here, per subtask
    4.8's design spec Non-Goal ("No change to the marker-file mechanism"). *)

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
