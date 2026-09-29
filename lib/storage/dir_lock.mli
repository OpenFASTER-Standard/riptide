(** A real, OS-level, exclusive filesystem lock on a directory -- the PHYSICAL guard closing the
    live-reproduced Critical finding that neither {!Riptide_storage.File_storage.create} nor
    {!Riptide_storage.File_kv_store.create} used to take any process-level lock on their target
    directory at all: two genuinely separate OS processes both legitimately constructing a store
    over the SAME [dir_path] at the same moment (an accidental double-start from a supervisor, a
    botched deployment briefly running old+new versions) could silently interleave writes and
    corrupt data at the filesystem level. The audit that produced this task reproduced it live --
    two real concurrent processes writing to the same [File_storage] directory left 26-31% of WAL
    entries permanently unreadable, and in one run left the superblock with no 2 of its 3 copies
    agreeing (unrecoverable).

    {b This is a physical guard, not a replacement for either module's own existing LOGICAL
    owner-tag mechanism} ({!Riptide_storage.File_kv_store.create}'s [~owner] marker). The two catch
    different failure modes and neither subsumes the other in general: this lock stops concurrent
    PROCESSES (or, within one process, concurrent independently-opened handles) from touching the
    same directory at once, regardless of what either side believes it owns; the owner tag stops a
    caller-declared logical mismatch (e.g. a keystore vs. a materializer accidentally pointed at
    the same directory) even when the two never overlap in time, which this lock's guarantee is
    scoped to a live handle's lifetime and says nothing about. In the one case where their scopes
    DO overlap -- two handles alive at the same instant, whether same-tag or different-tag -- this
    lock now also closes what {!Riptide_storage.File_kv_store.create}'s [~owner] check alone could
    not: a same-tag pair used to construct cleanly on both sides and then silently destroy shared
    data (see [file_kv_store.mli]'s own "residual gap" section, updated to reflect this).

    {b What remains genuinely open (review finding I2, 2026-09-29 -- an earlier version of this
    disclosure narrowed it to "strictly sequential reuse" alone, which overclaims what a lock
    scoped to one [acquire] call's own [t] can possibly reach):} two different shapes.

    - {b Strictly SEQUENTIAL reuse}: one handle fully closed (its lock released) before a second,
      differently-purposed consumer opens the same directory under a tag it copied or was handed.
      This lock's scope is a live handle's own lifetime, so two handles that never overlap in time
      are invisible to it by construction.
    - {b SIMULTANEOUS use of a single, ALREADY-CONSTRUCTED handle by two different logical
      consumers at once} -- e.g. one {!Riptide_storage.File_kv_store.t}, built via exactly one
      [create] call (hence exactly one [acquire] call, one lock, held for that one [t]'s whole
      lifetime), handed by its caller to both a {!Riptide_crypto.Redaction_store.t} and a
      {!Riptide_materialize.Materializer.t}. This lock cannot see it because there is only ever one
      [acquire] call in that shape -- nothing else ever contends for the same lock file, so nothing
      ever gets refused. See [file_kv_store.mli]'s own "residual gap" section for the full account,
      including the running test that demonstrates this shape specifically (not merely the
      sequential one).

    {b Why flock(2), not [Unix.lockf] (POSIX/[fcntl] locks).} [fcntl] locks are associated with a
    (process, inode) pair, not an open file description: a SECOND [Unix.openfile] of the same path
    from the SAME process does not conflict with a lock the first descriptor already holds (the
    kernel treats it as the same process re-asserting its own lock) -- confirmed live against this
    exact primitive before choosing [flock(2)] instead. That would make the real, in-process
    double-[create] hazard this module exists to catch invisible to a single-process test, and
    would fail to catch a real same-process double-construction bug (e.g. two independent
    subsystems in one long-lived server process each opening their own handle) at all. [flock(2)]'s
    lock is tied to the open file description [open(2)] itself creates, so two independent opens --
    same process or not -- always conflict. Neither the OCaml stdlib [Unix] module nor any already-
    installed opam package in this switch exposes [flock(2)], so [riptide_flock_stubs.c] is a
    small, direct binding rather than a new dependency. *)

val conflict_message : caller:string -> ?owner:string -> string -> string
(** [conflict_message ~caller ?owner dir_path] builds the exact string {!acquire} raises (wrapped
    in [Invalid_argument]) when [dir_path] is already locked -- exported as the single source of
    truth for this wording (review finding M4: this string used to be independently duplicated in
    four places -- this module plus three test files -- with nothing keeping them in sync; callers
    asserting against {!acquire}'s failure now build the expected string through this function
    instead of copying the literal). [owner], when supplied, folds in a human-readable hint about
    who currently holds the lock (see {!acquire}'s own [describe_conflict] parameter, review
    finding M3, for how a caller supplies one). *)

val acquire :
  sw:Eio.Switch.t -> caller:string -> ?describe_conflict:(unit -> string option) -> string ->
  Eio_unix.Fd.t
(** [acquire ~sw ~caller dir_path] takes a real, exclusive, non-blocking [flock(2)] lock on a
    dedicated [.riptide-lock] file inside [dir_path] (created if it does not already exist; the
    directory itself must already exist -- see each caller's own [create], which always [mkdir]s
    first). The lock is registered with [sw]: it is held for as long as [sw] remains open and is
    released automatically -- the kernel drops a [flock(2)] lock the instant its last referencing
    open file description is closed -- when [sw] finishes, mirroring exactly the switch-scoped
    lifetime {!Riptide_storage.File_storage}'s and {!Riptide_storage.File_kv_store}'s own [ring]/
    superblock/per-key fds already have. There is no separate explicit "release"/"unlock" entry
    point for the same reason those files expose none of their own: every real caller here relies
    on this same switch-scoped-fd pattern, not on an explicit close call.

    {b Caller responsibility (review finding I1):} this function has no way to know whether the
    [t] its caller's own [create] eventually returns will actually be constructed successfully --
    it only knows the lock itself was acquired. If anything in the rest of that [create] raises
    after a successful {!acquire}, before [create] returns a usable [t], the CALLER must release
    this lock explicitly (e.g. via [Eio_unix.Fd.close]) on that exception path before re-raising --
    otherwise the lock fd stays registered with [sw] for [sw]'s entire remaining lifetime even
    though no live [t] is using it, spuriously refusing a later, legitimate [acquire] over the same
    directory in the same switch. Both {!Riptide_storage.File_storage.create} and
    {!Riptide_storage.File_kv_store.create} do this; see either one's own [create] for the pattern,
    and [test_a_failed_create_releases_its_lock_before_reraising] in
    [test/test_file_kv_store.ml] for the live regression test this closes.

    @param describe_conflict called only if the lock is already held, to build a human-readable
      hint about who holds it -- e.g. {!Riptide_storage.File_kv_store.create} passes a thunk that
      reads its own owner-marker file (review finding M3: the conflicting handle's owner tag is
      sitting right there on disk, and folding it into the message restores the diagnosability the
      old owner-tag-first message used to have, for precisely the most likely real misuse -- two
      subsystems accidentally pointed at the same directory). [Dir_lock] itself has and needs no
      notion of "owner tags" or marker files; this keeps that convention entirely on the caller's
      side. [describe_conflict] returning [None] (or being omitted, as
      {!Riptide_storage.File_storage}, which has no owner concept of its own, always does) omits
      the hint from the message.

    @raise Invalid_argument immediately -- before touching anything else in [dir_path] -- if
      another live open file description already holds this lock (an already-running handle from
      this process or a different one). Built via {!conflict_message}; [caller] is folded into the
      message (e.g. ["File_storage.create"]) to say which module's [create] refused. *)
