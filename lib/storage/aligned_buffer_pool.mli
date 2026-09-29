(** A small, fixed-size pool of page-aligned, [mmap]-backed buffers, allocated once up front and
    reused for the rest of the pool's lifetime instead of once per I/O.

    Extracted (Task 10 review, Finding 2) out of {!Riptide_storage.File_storage} and
    {!Riptide_storage.File_kv_store}, which had each grown their own byte-for-byte identical copy
    of this logic while fixing the same VMA-leak bug independently. Both now build their pool
    through this module instead. See {!Riptide_storage.File_storage}'s own [.ml] top comment
    ("Task 10: the [mmap] call above now happens once per pool buffer, not once per I/O") for the
    full story of the bug this closes and why [mmap] (not [Bigarray.Array1.create]) is the
    allocation primitive.

    {b Sizing and concurrency model are the caller's job, not this module's.} How many buffers a
    pool needs, and whether blocking-on-contention is safe for a given caller, both depend on that
    caller's own concurrency model (e.g. {!Riptide_storage.File_storage}'s one-Eio-fiber-per-replica
    argument) -- this module only provides the mechanism, parameterized by [~buffer_count] and
    [~slot_size]; each caller documents its own sizing rationale at its own [create] call site. *)

type t

val create : buffer_count:int -> slot_size:int -> unit -> t
(** [create ~buffer_count ~slot_size ()] allocates [buffer_count] real, page-aligned,
    [mmap]-backed buffers of exactly [slot_size] bytes each, up front, and returns a pool holding
    them. Never allocates again for the rest of [t]'s lifetime -- see {!with_buffer}, the only way
    to get at a buffer afterwards. *)

val with_buffer : ?zero:bool -> t -> int -> (Cstruct.t -> 'a) -> 'a
(** [with_buffer ?zero t n f] acquires one buffer from [t] (blocking the calling fiber via
    [Eio.Stream.take] -- a real cooperative suspend, never a busy spin -- if none is currently
    free), zeroes it (unless [~zero:false]), hands [f] an [n]-byte view onto it, and
    unconditionally returns the (full-size) buffer to the pool afterwards -- on success or on an
    exception raised by [f], via [Fun.protect], so a failed I/O can never leak a buffer out of the
    pool. Raises [Invalid_argument] if [n] is negative or exceeds [t]'s own [slot_size].

    {b Why zero on every acquire, not just once at pool-creation time (the [~zero:true] default).}
    A pooled buffer is reused across many callers, so without a fresh zero on each acquire, a
    caller writing fewer than [slot_size] bytes into it (e.g. a short WAL entry) would leave
    whatever a PRIOR use happened to leave behind in the tail of the buffer rather than zeros -- a
    real correctness hazard for any caller relying on a fully-zero-padded buffer. The
    [Cstruct.memset] this costs is one buffer's worth per acquire, negligible next to the I/O it
    typically accompanies.

    {b [~zero:false] is a deliberate, narrow opt-out for read-only callers.} A caller that only
    ever reads INTO [buf] via [f] (never writes caller-supplied data into a not-fully-overwritten
    tail) has nothing to protect against a stale tail from a prior use: either the read fully
    overwrites every byte [f] later inspects, or [f] itself never surfaces the buffer's contents
    at all (e.g. it returns [None] on a short/failed read without ever converting the buffer to
    output). Passing [~zero:false] in that case skips a memset that would otherwise be pure
    overhead. Getting this wrong (passing [~zero:false] for a caller that DOES rely on a
    zero-filled tail) is a real correctness hazard, not a performance-only mistake -- callers must
    justify it at their own call site, the same way {!Riptide_storage.File_storage}'s own
    [perform_read] does.

    {b Blocking-acquisition, deliberately, instead of growing the pool.} When more callers are
    genuinely in flight than [buffer_count], this function blocks rather than allocating a fresh
    buffer: an unbounded pool just moves the VMA-growth failure mode this module exists to close up
    one level. A bounded pool with blocking acquisition instead turns a burst into ordinary
    backpressure -- indistinguishable, from a caller's perspective, from the I/O itself just taking
    longer.

    {b Not reentrant.} Calling [with_buffer] again, for the SAME [t], from inside an [f] that is
    already running as part of an outer [with_buffer t _ _] call, will deadlock once enough
    concurrently-nested acquisitions exhaust [buffer_count] -- the outer call's buffer is not
    released until its own [f] returns, so a nested acquire is competing for a buffer that will
    never become free until the nested call itself gives up waiting, which it never does. Callers
    must never hold a buffer from [t] while acquiring another from the same [t]. *)
