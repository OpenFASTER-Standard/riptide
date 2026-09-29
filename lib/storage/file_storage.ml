(* A fixed-size ring WAL with redundant, physically-separate headers, backed by real
   [O_DIRECT]+[O_DSYNC]-durable writes via [eio_linux]'s low-level [io_uring] API where the
   underlying filesystem supports it (falling back to [O_DSYNC] alone, gracefully and
   automatically, where it doesn't -- see "O_DIRECT: second attempt, this time it works" below).

   {b On-disk layout.} One ring file per storage [t], named [ring] inside the storage
   directory. [ring_capacity] fixed-size slots, each with two physically separate regions:

   - {b Header region} (bytes [0 .. ring_capacity * header_slot_size - 1]): slot [i]'s header
     lives at byte offset [i * header_slot_size]. A header's logical content is 48 bytes --
     [op_number] (int64 big-endian, 8B), [length] (int64 big-endian, 8B), [checksum] (32 raw
     bytes of {!Riptide.Value.content_hash} over the entry's data) -- zero-padded out to
     [header_slot_size] on disk.
   - {b Data region} (bytes [ring_capacity * header_slot_size ..]): slot [i]'s data lives at
     byte offset [ring_capacity * header_slot_size + i * data_slot_size], the entry's own bytes
     zero-padded out to [data_slot_size].

   Redundant/separate headers (Decision 6) means exactly this: a slot's header and its data
   are never adjacent or interleaved, so a torn/partial write of one can never be mistaken for
   a torn/partial write of the other -- {!wal_append} always writes the header first, so a
   crash between the two writes leaves a header durably pointing at *stale* data (the previous
   occupant's), which {!wal_read}'s checksum-plus-op_number check on the data catches, rather
   than ever leaving a header pointing at fresh, correct data with no header covering it at all.

   {b [O_DIRECT]: second attempt, this time it works.} Task 1's own version of this module
   (see its report for the full experiment trail) tried [O_DIRECT]+[O_DSYNC] for its one-
   file-per-entry, arbitrary-length design and dropped [O_DIRECT] after finding real,
   {e intermittent} [EINVAL] failures (~40-60% of writes, under the full test-suite binary, not
   a small standalone repro) that traced to [eio_linux]'s shared fixed-buffer pool
   ([Low_level.alloc_fixed_or_wait]/[Uring.Region]) not guaranteeing the page-aligned base
   address [O_DIRECT] requires -- a plain [Bigarray.Array1.create] with no alignment call,
   confirmed against [eio_linux]'s actual source.

   This module's fixed-size ring makes the *length/offset* half of [O_DIRECT]'s alignment
   requirement trivial (every header/data write is exactly [header_slot_size]/[data_slot_size]
   bytes, both multiples of [slot_alignment], at offsets that are themselves always multiples
   of [slot_alignment]). The *buffer-address* half -- the thing that actually broke Task 1 --
   is solved by getting each buffer's page-aligned address from a real [mmap(2)] call (via
   [Unix.map_file] over a throwaway, immediately-unlinked temp file -- POSIX requires this to
   return a page-aligned address, and unlike [Bigarray.Array1.create]'s plain [malloc],
   [Unix.map_file] goes through a real [mmap(2)] for every allocation, confirmed by reading the
   OCaml runtime's own [otherlibs/unix/mmap_unix.c]: [caml_unix_map_file] calls
   [mmap(NULL, ...)] and returns that address, adjusted only by [start_pos mod page_size] --
   zero when mapping from offset 0, as here) -- so alignment holds regardless of what else the
   surrounding binary/process has already allocated, which is exactly the property Task 1's
   shared-pool version lacked. [Eio_linux.Low_level.writev]/[readv] (rather than
   [write]/[read_upto], which only accept the shared pool's [Uring.Region.chunk]) are what let
   this module hand [io_uring] an arbitrary, self-allocated [Cstruct.t] instead.

   {b Task 10: the [mmap] call above now happens once per pool buffer, not once per I/O.} The
   very first version of this technique (Task 2) called [alloc_aligned_buffer] (since renamed to
   {!alloc_one_aligned_buffer} by this very task, see below) -- open a fresh
   temp file, [ftruncate], [mmap], then close+unlink the temp file, keeping only the mapping --
   on EVERY single read and write, relying on the OCaml GC to eventually finalize and [munmap]
   the returned [Bigarray]/[Cstruct.t]. The audit that produced this task's own plan measured
   the real consequence live: ~4 kernel VMA mappings leaked per WAL op (one each for
   [write_header]/[write_data]/[read_header]/[read_data]) with zero reclamation under ordinary
   GC tuning -- nothing about this module's usage pattern ever pressures the GC into a major
   collection often enough to keep up -- hard-crashing the process (past [ENOMEM]/[Out_of_memory])
   at roughly 16,000 WAL ops even on a box with 47GB free RAM, because VMA count, not RSS, is
   what OOMs first. That is a process-wide resource-exhaustion bug, not a leak whose damage stays
   scoped to one [t]: enough WAL ops through any single replica's storage eventually starves
   every other allocation in the same process.

   The fix (the buffer pool below, see [pool_size]/{!create_buffer_pool}/{!with_pooled_buffer})
   keeps the exact same [mmap]-backed technique -- it is still the
   simplest way to get a guaranteed page-aligned address on this runtime, and switching to
   [Bigarray.Array1.create] with manual alignment would trade one proven-safe primitive for an
   unproven one for no real benefit -- but calls it exactly [pool_size] times, once each, when
   [t] is created, and never again for that [t]'s entire lifetime. Every read/write acquires one
   of those pre-allocated buffers from the pool and releases it explicitly ([Fun.protect], not
   GC finalization) the moment it is done with it, whether the I/O succeeded or raised. See
   [pool_size]'s own comment below for sizing and the concurrency model that justifies it.

   {b Real evidence, not a guess:} a standalone probe performing this exact
   allocate-aligned-buffer-then-[O_DIRECT]-write-then-read cycle was run 5 times x 500
   iterations (2500 operations) against a real file on {e both} this box's ext4 mount
   ([/work]) and its overlayfs mount ([/tmp], the temp-dir filesystem this very test suite
   runs against) -- 0 failures across all 5000 operations on either filesystem. See Task 2's
   own report for the probe source and full output. This module still keeps a defensive,
   automatic runtime fallback ({!downgrade_to_dsync_only}) for any [t] that hits a genuine
   [EINVAL] anyway (e.g. a filesystem that rejects [O_DIRECT] outright, such as tmpfs) -- it is
   not required to reproduce the above evidence, but costs nothing to keep as a safety net for
   filesystems this box's own mounts don't happen to cover.

   {b Everything below this point is carried over verbatim from Task 1's own experiment trail
   (still true, unchanged by the ring rewrite):}

   - [Eio_linux.Low_level.openat2]'s [~perm] argument is passed straight through to the real
     Linux [openat2(2)] syscall, which -- unlike the legacy [open(2)] -- is strict about it:
     [openat2(2)] returns [EINVAL] if [how.mode <> 0] while neither [O_CREAT] nor [O_TMPFILE] is
     set in [how.flags]. Read opens below always pass [~perm:0] for exactly this reason
     ([O_CREAT] is only ever combined with a real [~perm] on the ring file's own open, which is
     always [~access:`RW] with [creat] set).
   - The installed Eio 0.12's [Eio.Path] has no [kind]/[stat]-on-a-path existence check (only
     [File.stat] on an already-{e open} file), so {!create} cannot check-then-create a directory
     the way an initial sketch assumed. It instead just attempts [Eio.Path.mkdir] and ignores the
     [Eio.Io] ([EEXIST]) that raises when [dir_path] already exists.

   {b Task 3: the superblock.} 3 independent files, [superblock-0]..[superblock-2] in the same
   storage directory -- physically separate files rather than slots in one shared file, so a
   whole-file corruption of one copy can never take a second copy down with it. Each file holds
   exactly one record, reusing the ring WAL's own header-then-data shape from above ([op_number]
   unused here, always encoded as 0) at fixed offsets 0 / [header_slot_size]. The flexible
   quorum (Decision 6): {!superblock_write} requires all 3 writes to succeed (the strict side);
   {!superblock_read} re-verifies each copy's own checksum independently and returns [Some] only
   if at least 2 of the (up to 3) verified copies agree byte-for-byte, tolerating up to 1
   corrupted or missing copy. *)

type header = { op_number : int; length : int; checksum : string }

(* A single open file plus its current O_DIRECT-capability state -- shared by the ring WAL file
   and each of the superblock's 3 copies (Task 3) so the O_DIRECT-with-automatic-O_DSYNC-
   fallback dance ({!perform_write}/{!perform_read}/{!downgrade_to_dsync_only} below) is written
   once and reused across all of them, rather than duplicated per file. *)
type file_handle = { path : string; mutable fd : Eio_unix.Fd.t; mutable direct_capable : bool }

type t = {
  sw : Eio.Switch.t;
  ring : file_handle;
  ring_capacity : int;
  mutable highest_op_number : int;
  pool : Cstruct.t Eio.Stream.t;
      (* Task 10's buffer pool -- see this file's top comment ("Task 10: the [mmap] call above
         now happens once per pool buffer, not once per I/O") for why this exists, and
         {!with_pooled_buffer} below for how it's used. Every buffer in it is exactly
         [slot_alignment] bytes, [mmap]-backed, allocated once by {!create_buffer_pool} at
         [create] time. *)
  superblocks : file_handle array;
      (* [superblock_copies] (3) independent files -- see this file's own top comment,
         "Task 3: the superblock", for the on-disk layout and quorum this backs. *)
  may_evict : (op_number:int -> bool) option;
      (* Subtask 3.7: the caller's veto over this ring's one destructive moment. Consulted by
         [wal_append] with the op-number ABOUT TO BE EVICTED (never with the one being appended),
         and only when an append genuinely overwrites a live prior entry. [None] -- the default --
         means every eviction proceeds, which is this module's entire pre-3.7 behavior.

         In-memory, per-[t], and deliberately NOT persisted: it is a policy the owner supplies
         afresh on every [create], evaluated against whatever [recover_highest_op_number] found on
         disk. Nothing about a refusal is durable either -- see [wal_append]. *)
}

let ring_file_name = "ring"
let superblock_copies = 3
let superblock_file_name i = Printf.sprintf "superblock-%d" i

(* One page. Also this box's own confirmed [O_DIRECT] memory/offset/length alignment
   requirement on both its ext4 and overlayfs mounts (see this file's top comment) -- used
   uniformly as the slot size for both regions rather than tuning header/data slots
   separately, since simplicity here matters more than the wasted space of a 4096-byte slot
   holding a 48-byte header. *)
let slot_alignment = 4096

let header_record_size = 8 (* op_number *) + 8 (* length *) + 32 (* checksum *)
let () = assert (header_record_size <= slot_alignment)
let header_slot_size = slot_alignment
let data_slot_size = slot_alignment
let max_entry_size = data_slot_size

let open_flags_direct = Uring.Open_flags.(dsync + creat + direct)
let open_flags_dsync_only = Uring.Open_flags.(dsync + creat)

(* {!Unix.map_file} is required (POSIX [mmap(2)]) to return a page-aligned address when
   mapping starts at file offset 0, unlike a plain [Bigarray.Array1.create]'s [malloc] -- see
   this file's own top comment for why that distinction is exactly what makes [O_DIRECT] work
   here where Task 1's shared-pool version couldn't. The backing file is purely a vehicle for
   getting a real [mmap(2)] call; it is created, sized, mapped [~shared:false] (so nothing
   written into the returned buffer ever touches disk through it), and then closed + unlinked
   immediately -- the mapping itself stays valid (a standard, portable POSIX property) for as
   long as the returned [Cstruct.t] is reachable.

   Task 10: this is now called exactly [pool_size] times total, by {!create_buffer_pool} at
   [create] time -- never again per read/write. Kept as its own function (rather than inlined
   into {!create_buffer_pool}) because it is still, on its own, the thing that makes [O_DIRECT]
   work at all; only its CALL FREQUENCY changed, not what it does or why. *)
let alloc_one_aligned_buffer n =
  let path = Filename.temp_file "riptide_storage_aligned" "" in
  let fd = Unix.openfile path [ Unix.O_RDWR ] 0o600 in
  Fun.protect
    ~finally:(fun () ->
      Unix.close fd;
      try Unix.unlink path with Unix.Unix_error _ -> ())
    (fun () ->
      Unix.ftruncate fd n;
      let ba = Unix.map_file fd ~pos:0L Bigarray.char Bigarray.c_layout false [| n |] in
      Cstruct.of_bigarray (Bigarray.array1_of_genarray ba))

(* Small, fixed-size pool of page-aligned buffers, owned by [t] and allocated once at [create]
   time -- see this file's top comment ("Task 10") for the bug this closes.

   {b Sizing.} [pool_size] buffers of exactly [slot_alignment] bytes each. Every call site in
   this file that ever needs an aligned buffer asks for exactly [header_slot_size] or
   [data_slot_size] bytes, both always equal to [slot_alignment] (see their definitions below),
   so one uniform buffer size covers every caller with no waste and no per-request variance to
   plan for.

   [pool_size] itself (4) is sized against this codebase's confirmed concurrency model, not
   guessed: [lib/dst/cluster.ml] forks exactly one Eio fiber per replica
   (`Array.iteri (fun i _ -> Eio.Fiber.fork ~sw (fun () -> ... dispatch_loop ...))`), and that
   fiber's `dispatch_loop` receives and fully handles one message at a time before receiving the
   next -- so a single replica's own calls into its own [File_storage.t] are always strictly
   sequential, never concurrent, and even a pool of 1 would be correct there. 4 gives headroom
   for anything this module's signature doesn't itself forbid from being concurrent (a test
   driving a handle from multiple fibers at once, e.g. a future stress test, or superblock's own
   3 sequential-but-not-required-to-stay-sequential copy writes) without needing a bigger pool
   for real usage.

   {b What happens when more I/Os are genuinely in flight than [pool_size]}: {!with_pooled_buffer}
   BLOCKS the calling fiber (via {!Eio.Stream.take}, a real cooperative suspend, never a busy
   spin) until a buffer is released, rather than growing the pool to match. Deliberate: an
   unbounded pool turns a burst of concurrent I/O into unbounded memory/VMA growth, exactly the
   failure mode this whole task exists to remove, just moved one level up. A bounded pool with
   blocking acquisition instead turns that burst into ordinary backpressure -- indistinguishable,
   from a caller's perspective, from the I/O itself just taking longer, which is what it would do
   anyway on a real disk under contention. *)
let pool_size = 4

let create_buffer_pool () =
  let pool = Eio.Stream.create pool_size in
  for _ = 1 to pool_size do
    Eio.Stream.add pool (alloc_one_aligned_buffer slot_alignment)
  done;
  pool

(* Acquires one buffer from [pool] (blocking if none is free), zeroes it, hands [f] a
   [n]-byte view onto it, and unconditionally returns the (full-size) buffer to the pool
   afterwards -- on success or on an exception raised by [f], via [Fun.protect], so a failed
   I/O can never leak a buffer out of the pool.

   {b Why zero on every acquire, not just once at pool-creation time.} The very first version of
   this technique relied on each buffer's backing temp file having just been freshly
   [ftruncate]d -- which the kernel zero-fills -- so a write of fewer than [slot_alignment]
   bytes (e.g. {!write_data} writing an entry shorter than one data slot) could skip explicitly
   padding the rest and still write a correctly-zero-padded slot. A POOLED buffer is reused
   across many writes, so without a fresh zero on each acquire, a later short write would leave
   whatever a PRIOR write happened to leave behind in the tail of the slot rather than zeros --
   a real correctness regression this refactor must not introduce. The [Cstruct.memset] this
   costs is one page (4096 bytes) per acquire, negligible next to the I/O it accompanies. *)
let with_pooled_buffer pool n f =
  if n < 0 || n > slot_alignment then
    invalid_arg
      (Printf.sprintf "with_pooled_buffer: %d exceeds this pool's fixed buffer size of %d" n
         slot_alignment);
  let buf = Eio.Stream.take pool in
  Fun.protect
    ~finally:(fun () -> Eio.Stream.add pool buf)
    (fun () ->
      Cstruct.memset buf 0;
      f (if n = slot_alignment then buf else Cstruct.sub buf 0 n))

let header_offset ~slot = slot * header_slot_size
let header_region_size t = t.ring_capacity * header_slot_size
let data_offset t ~slot = header_region_size t + (slot * data_slot_size)

let encode_header ~op_number ~length ~checksum =
  let buf = Bytes.make header_slot_size '\000' in
  Bytes.set_int64_be buf 0 (Int64.of_int op_number);
  Bytes.set_int64_be buf 8 (Int64.of_int length);
  Bytes.blit_string checksum 0 buf 16 32;
  Bytes.unsafe_to_string buf

let decode_header s =
  let b = Bytes.unsafe_of_string s in
  {
    op_number = Int64.to_int (Bytes.get_int64_be b 0);
    length = Int64.to_int (Bytes.get_int64_be b 8);
    checksum = String.sub s 16 32;
  }

(* Opens [path] O_DIRECT-capable if the filesystem allows it, falling back to [O_DSYNC] alone
   otherwise -- the same open-with-fallback [create] itself used to do inline for the ring file
   alone; factored out here so it's shared with the superblock's 3 files too (Task 3). *)
let open_file_handle ~sw path =
  try
    let fd =
      Eio_linux.Low_level.openat2 ~sw ~seekable:true ~access:`RW ~flags:open_flags_direct
        ~perm:0o600 ~resolve:Uring.Resolve.empty path
    in
    { path; fd; direct_capable = true }
  with Eio.Io _ ->
    let fd =
      Eio_linux.Low_level.openat2 ~sw ~seekable:true ~access:`RW ~flags:open_flags_dsync_only
        ~perm:0o600 ~resolve:Uring.Resolve.empty path
    in
    { path; fd; direct_capable = false }

(* Closes [h]'s current (O_DIRECT) fd and reopens the same file with [O_DSYNC] alone --
   permanent for the rest of this handle's lifetime, mirroring Task 1's own ruling for the
   filesystems where [O_DIRECT] genuinely doesn't work (e.g. tmpfs rejects it outright). Only
   ever called after a real [Eio.Io] failure while [h.direct_capable] was still [true]; see
   this file's top comment for why this is believed to be a dead path on this box's own
   mounts (ext4, overlayfs) rather than the routine case it was for Task 1. *)
let downgrade_to_dsync_only ~sw (h : file_handle) =
  if h.direct_capable then begin
    ignore (Eio_unix.Fd.close h.fd);
    h.fd <-
      Eio_linux.Low_level.openat2 ~sw ~seekable:true ~access:`RW ~flags:open_flags_dsync_only
        ~perm:0o600 ~resolve:Uring.Resolve.empty h.path;
    h.direct_capable <- false
  end

let perform_write ~sw (h : file_handle) ~offset (buf : Cstruct.t) =
  let rec go () =
    try Eio_linux.Low_level.writev ~file_offset:(Optint.Int63.of_int offset) h.fd [ buf ]
    with Eio.Io _ when h.direct_capable ->
      downgrade_to_dsync_only ~sw h;
      go ()
  in
  go ()

(* Acquires a pooled buffer, blits [data] into it (zero-padded out to [n] by
   {!with_pooled_buffer}'s own fresh-zero-on-acquire), writes it, and releases the buffer --
   all before returning. Factored out because every write call site below (WAL header, WAL
   data, each superblock copy's header and data) does exactly this same
   acquire-blit-write-release sequence, differing only in [data]/[n]/[offset]. *)
let perform_write_from_string ~pool ~sw (h : file_handle) ~offset ~n data =
  with_pooled_buffer pool n (fun buf ->
      Cstruct.blit_from_string data 0 buf 0 (String.length data);
      perform_write ~sw h ~offset buf)

(* [None] means "nothing durable at this offset yet" (a short/empty read -- i.e. this part of
   the file has never been written, whether because it's fresh or because [t]'s [ring_capacity]
   differs from a previous run and this slot is past the old high-water mark). Any other outcome
   either returns exactly the [len] bytes requested or raises.

   Returns a [string], not a [Cstruct.t] (a signature change from the pre-Task-10 version): the
   pooled buffer must be released back to {!with_pooled_buffer}'s pool before this function
   returns, so nothing that outlives the call may still reference it -- converting to an
   owned [string] while still inside the pool's scope is what makes that safe. *)
let perform_read ~pool ~sw (h : file_handle) ~offset ~len =
  with_pooled_buffer pool len (fun buf ->
      let rec go () =
        match Eio_linux.Low_level.readv ~file_offset:(Optint.Int63.of_int offset) h.fd [ buf ] with
        | exception End_of_file -> None
        | exception Eio.Io _ when h.direct_capable ->
          downgrade_to_dsync_only ~sw h;
          go ()
        | n -> if n = len then Some (Cstruct.to_string buf) else None
      in
      go ())

let write_header t ~slot ~op_number ~length ~checksum =
  let encoded = encode_header ~op_number ~length ~checksum in
  perform_write_from_string ~pool:t.pool ~sw:t.sw t.ring ~offset:(header_offset ~slot)
    ~n:header_slot_size encoded

let read_header t ~slot =
  match
    perform_read ~pool:t.pool ~sw:t.sw t.ring ~offset:(header_offset ~slot) ~len:header_slot_size
  with
  | None -> None
  | Some s -> Some (decode_header s)

let write_data t ~slot data =
  perform_write_from_string ~pool:t.pool ~sw:t.sw t.ring ~offset:(data_offset t ~slot)
    ~n:data_slot_size data

let read_data t ~slot ~length =
  if length < 0 || length > data_slot_size then None
  else
    match
      perform_read ~pool:t.pool ~sw:t.sw t.ring ~offset:(data_offset t ~slot) ~len:data_slot_size
    with
    | None -> None
    | Some s -> Some (String.sub s 0 length)

let checksum_of data =
  Riptide.Value.content_hash (Riptide.Value.Scalar (Riptide.Value.String data))

(* Reconstructs [highest_op_number] from whatever is already durable on disk: scans every
   slot's header, and for each one that (a) round-trips a matching checksum against that
   slot's own data and (b) whose own [op_number] actually maps back to this slot (defends
   against a header that coincidentally checksum-matches stale data but was never real --
   astronomically unlikely on its own, but cheap to also check), takes the max [op_number]
   found. Mirrors {!wal_read}'s own two-check (checksum + op_number) validation exactly. *)
let recover_highest_op_number t =
  let best = ref 0 in
  for slot = 0 to t.ring_capacity - 1 do
    match read_header t ~slot with
    | None -> ()
    | Some header ->
      if header.op_number > 0 && (header.op_number - 1) mod t.ring_capacity = slot then
        match read_data t ~slot ~length:header.length with
        | None -> ()
        | Some data -> if checksum_of data = header.checksum then best := max !best header.op_number
  done;
  !best

(* [~ring_capacity] is REQUIRED, deliberately -- it used to default to 8 (final-review finding
   I4). Pairing "silently destroys committed, acknowledged data past this bound" (see
   [test_dst_scenarios.ml]'s own ring-capacity boundary test, which reproduces the total
   protocol-level consequence with zero injected faults) with a small, invisible default is
   backwards: the caller that most needs to think about the bound is exactly the one that would
   never see it. Raising the default instead would have kept the same shape, just with a
   less-likely-to-bite number -- a caller still could not tell from its own call site what bound
   it had accepted. Making it explicit costs every call site one argument and makes the sizing
   decision impossible to inherit by accident. *)
let create ~sw ~fs ~ring_capacity ?may_evict dir_path =
  (try Eio.Path.mkdir ~perm:0o700 Eio.Path.(fs / dir_path) with Eio.Io _ -> ());
  let ring = open_file_handle ~sw (Filename.concat dir_path ring_file_name) in
  let superblocks =
    Array.init superblock_copies (fun i ->
        open_file_handle ~sw (Filename.concat dir_path (superblock_file_name i)))
  in
  let pool = create_buffer_pool () in
  let t = { sw; ring; ring_capacity; highest_op_number = 0; pool; superblocks; may_evict } in
  t.highest_op_number <- recover_highest_op_number t;
  t

(* Subtask 3.7: does appending [op_number] destroy a live prior entry, and if so which one?

   Slot assignment is [(op_number - 1) mod ring_capacity], so op-numbers [1 .. ring_capacity] are
   the only ones that land in a slot no prior op-number has ever occupied. Every op_number above
   that reuses the slot last held by [op_number - ring_capacity] -- and because [wal_append]
   enforces a strictly dense, gapless sequence ([op_number = highest_op_number + 1], the check
   directly above), that earlier op-number was definitely written, so this is a genuine eviction
   rather than a coincidence of arithmetic.

   Deliberately NOT expressed as "is the slot currently occupied?" (a [read_header] probe): a
   truncation zeroes discarded slots' headers, so a probe would call a post-truncation re-append
   "not an eviction" and skip the gate even though the caller's own accounting may still care. The
   arithmetic answers the question the owner is actually asking -- which op-number's data is about
   to stop being readable -- without an I/O round-trip. *)
let evicted_op_number t ~op_number =
  if op_number > t.ring_capacity then Some (op_number - t.ring_capacity) else None

(* The eviction gate sits AFTER both pre-existing argument checks, not before them, which is a
   considered deviation from subtask 3.7's own plan sketch (it put the gate first).

   [Out_of_sequence] and [Entry_rejected] are both statements about the CALL being wrong -- a
   skipped op-number, an entry this ring physically cannot hold. [Eviction_blocked] is the opposite
   kind of statement: the call is perfectly well-formed and would succeed at a later moment, once
   the owner's predicate relents. {!Riptide_vsr.Replica}'s [append_refusals] doc draws exactly this
   line ("this entry can never be durable here" vs. a retryable backpressure signal), and subtask
   3.7's whole purpose is for a caller to trust [eviction_blocked]'s count as a materialization-lag
   signal -- so an oversized entry must not be able to inflate it. Ordering the checks this way
   also means an oversized or out-of-sequence call behaves identically whether or not [?may_evict]
   was supplied.

   A refusal is a clean no-op: nothing is written, [highest_op_number] does not move, and the entry
   that would have been evicted stays readable. That is what makes retrying the SAME op_number
   later sound, which is precisely what [Replica.durable_append]'s callers do with a classified
   refusal (they decline to acknowledge and leave the op to be re-driven). *)
let wal_append t ~op_number data =
  if op_number <> t.highest_op_number + 1 then
    invalid_arg
      (Printf.sprintf "wal_append: op_number %d is not wal_highest_op_number t + 1" op_number)
  else begin
    let len = String.length data in
    if len > max_entry_size then
      invalid_arg
        (Printf.sprintf
           "wal_append: entry of %d bytes exceeds this ring's max entry size of %d bytes (one \
            aligned data slot)"
           len max_entry_size);
    (match (t.may_evict, evicted_op_number t ~op_number) with
    | None, _ | _, None -> ()
    | Some may_evict, Some evicted ->
      if not (may_evict ~op_number:evicted) then
        invalid_arg (Printf.sprintf "wal_append: eviction blocked for op_number %d" evicted));
    let slot = (op_number - 1) mod t.ring_capacity in
    let checksum = checksum_of data in
    write_header t ~slot ~op_number ~length:len ~checksum;
    write_data t ~slot data;
    t.highest_op_number <- op_number
  end

let wal_read t ~op_number =
  if op_number < 1 || op_number > t.highest_op_number then None
  else
    let slot = (op_number - 1) mod t.ring_capacity in
    match read_header t ~slot with
    | None -> None
    | Some header ->
      if header.op_number <> op_number then None
      else begin
        match read_data t ~slot ~length:header.length with
        | None -> None
        | Some data -> if checksum_of data = header.checksum then Some data else None
      end

let wal_highest_op_number t = t.highest_op_number

(* DURABLE, not merely a counter decrement (final-review finding I3).

   This used to lower [highest_op_number] and nothing else. The discarded entries' headers and
   data stayed on disk, so [recover_highest_op_number] found them again on the next {!create} and
   resurrected them -- diverging from {!Riptide_storage.Memory_storage}, which physically deletes,
   on the one operation whose entire purpose is to make entries go away. [test_storage_shared.ml]'s
   conformance suite structurally could not catch that (it has no reopen case, since Memory_storage
   has no restart semantics to have one against), so the divergence lived behind a passing suite.

   WHY IT IS A REAL DEFECT AND NOT COSMETIC. A truncation is how a view change discards an
   uncommitted suffix. With a non-durable truncate, a crash between the truncate and the superblock
   write brings the replica back with the DISCARDED entries readable, and it then presents them as
   live log entries in its next DoViewChange -- stale values a peer can adopt. Made durable, the
   same crash leaves those slots unreadable-but-in-range, i.e. VSR.tla's "corrupt" rather than
   anything a replica would ship or nack, which is the conservative direction this whole storage
   model is built on.

   HOW: overwrite each discarded slot's HEADER with zeros. [recover_highest_op_number] and
   {!wal_read} both require [header.op_number > 0] and a checksum that verifies against the slot's
   own data, so a zeroed header makes the slot unrecoverable by either -- without any new on-disk
   format, using the same header write the ring already performs. The data region is deliberately
   left alone: nothing can reach it without a header, and rewriting it would double the I/O for no
   change in what any reader can observe.

   The loop is clamped to at most [ring_capacity] slots. Op-numbers [op_number + 1 ..
   highest_op_number] can span far more than the ring holds, and the slots repeat modulo capacity,
   so the last [ring_capacity] of them already cover every DISTINCT slot exactly once. Clamping is
   also what keeps a truncation over a long log from costing one write per discarded op-number.
   It cannot zero a slot that is still live: any op at or below [op_number] sharing a slot with a
   discarded one was already physically overwritten by that discarded one when it was appended --
   the ring had destroyed it long before this call. *)
let wal_truncate_after t ~op_number =
  if op_number < t.highest_op_number then begin
    let first = max (op_number + 1) (t.highest_op_number - t.ring_capacity + 1) in
    for o = first to t.highest_op_number do
      write_header t ~slot:((o - 1) mod t.ring_capacity) ~op_number:0 ~length:0
        ~checksum:(String.make 32 '\000')
    done;
    t.highest_op_number <- op_number
  end

(* Each superblock file holds exactly one record (unlike the ring, which packs many slots into
   one shared file) -- so there's only ever one header offset and one data offset, both fixed,
   mirroring a single WAL slot's own header-then-data layout (see this file's own top comment,
   "Task 3: the superblock"). *)
let superblock_header_offset = 0
let superblock_data_offset = header_slot_size

let write_superblock_copy t (h : file_handle) data =
  let len = String.length data in
  if len > max_entry_size then
    invalid_arg
      (Printf.sprintf
         "superblock_write: data of %d bytes exceeds the superblock's max size of %d bytes (one \
          aligned data slot)"
         len max_entry_size);
  let checksum = checksum_of data in
  perform_write_from_string ~pool:t.pool ~sw:t.sw h ~offset:superblock_header_offset
    ~n:header_slot_size
    (encode_header ~op_number:0 ~length:len ~checksum);
  perform_write_from_string ~pool:t.pool ~sw:t.sw h ~offset:superblock_data_offset
    ~n:data_slot_size data

(* [None] covers every way a single copy can fail to verify: missing/short file, a header that
   doesn't even read back as [header_slot_size] bytes, a decoded length outside the one aligned
   data slot this module ever writes, or (the main case) a checksum mismatch against that copy's
   own data. Never raises on a corrupted copy -- corruption here is an expected, tolerated
   condition, not a bug. *)
let read_superblock_copy t (h : file_handle) =
  match
    perform_read ~pool:t.pool ~sw:t.sw h ~offset:superblock_header_offset ~len:header_slot_size
  with
  | None -> None
  | Some header_s -> (
    let header = decode_header header_s in
    if header.length < 0 || header.length > data_slot_size then None
    else
      match
        perform_read ~pool:t.pool ~sw:t.sw h ~offset:superblock_data_offset ~len:data_slot_size
      with
      | None -> None
      | Some data_s ->
        let data = String.sub data_s 0 header.length in
        if checksum_of data = header.checksum then Some data else None)

(* Write is the strict side of the flexible quorum (Decision 6): all 3 copies must durably
   succeed, or this raises (via [perform_write]'s own propagation, same as [wal_append] never
   catching a genuine I/O failure either) rather than silently leaving some copies stale. *)
let superblock_write t data = Array.iter (fun h -> write_superblock_copy t h data) t.superblocks

(* Read is the tolerant side: verify all (up to 3) copies independently, then return [Some]
   only if at least 2 of the verified ones agree byte-for-byte -- up to 1 corrupted or missing
   copy is tolerated, 2 corrupted/missing is an honest [None] rather than trusting a lone
   survivor. Re-reads from disk on every call, no cached field on [t], matching [wal_read]. *)
let superblock_read t =
  let verified = List.filter_map (read_superblock_copy t) (Array.to_list t.superblocks) in
  List.find_opt (fun x -> List.length (List.filter (String.equal x) verified) >= 2) verified
