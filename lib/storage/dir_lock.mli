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
    data (see [file_kv_store.mli]'s own "residual gap" section, updated to reflect this). What
    remains genuinely open is strictly SEQUENTIAL reuse -- one handle fully closed (its lock
    released) before a second, differently-purposed consumer opens the same directory under a tag
    it copied or was handed -- which no lock scoped to a handle's own lifetime can see.

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

val acquire : sw:Eio.Switch.t -> caller:string -> string -> Eio_unix.Fd.t
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

    @raise Invalid_argument immediately -- before touching anything else in [dir_path] -- if
      another live open file description already holds this lock (an already-running handle from
      this process or a different one). [caller] is folded into the message (e.g.
      ["File_storage.create"]) to say which module's [create] refused. *)
