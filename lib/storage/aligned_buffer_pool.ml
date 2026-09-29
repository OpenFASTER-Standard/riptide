(* See this file's own [.mli] for the module-level contract. This [.ml]'s comments cover only the
   mechanism itself; see {!Riptide_storage.File_storage}'s top comment for the full bug history
   ("Task 10") and {!Riptide_storage.File_storage}/{!Riptide_storage.File_kv_store}'s own
   [create]/pool-construction call sites for why each picks the [~buffer_count] it does. *)

type t = { pool : Cstruct.t Eio.Stream.t; slot_size : int }

(* Atomic counter making each throwaway backing-file name below unique across the [buffer_count]
   calls [create] makes in its allocation loop (and across every other pool this same process ever
   constructs) -- same pid+atomic-counter pattern as {!Riptide_storage.File_kv_store}'s own
   [call_counter]/[tmp_suffix_for_call] (see that module's own comment for why a module-level
   atomic counter, not thread/fiber-local state, is what actually rules out collisions between
   fibers sharing one OS process). Nothing here ever runs concurrently within a single [create]
   call (the allocation loop below is sequential, not forked across fibers), so the counter is
   overkill for that alone -- it earns its keep once a future caller builds more than one pool
   over the same [dir_path], or another pool's [create] call is still in its own allocation loop
   for a *different* pool over the same directory (Task 17 review: {!Riptide_storage.File_storage}
   and {!Riptide_storage.File_kv_store} both call [Aligned_buffer_pool.create] from their own,
   otherwise-unrelated [create] functions, and while {!Riptide_storage.Dir_lock} prevents two LIVE
   handles from ever sharing one [dir_path], it says nothing about two never-concurrent, sequential
   pool-allocation loops both starting their counters back at their own module-load value). *)
let call_counter = Atomic.make 0

(* Task 17: name for the per-buffer, throwaway [mmap]-backing file below, created inside the
   CALLER's own [dir_path] instead of [Filename.temp_file]'s [TMPDIR]-rooted scratch directory --
   closes the audit finding that durable on-disk storage must never depend on an environment
   variable pointing anywhere usable at all (a live reproduction showed [File_storage.create]/
   [wal_append] raising [Sys_error] when [TMPDIR] pointed at a nonexistent directory). See this
   module's own [.mli] [create] doc, and the [~dir_path] call sites in [file_storage.ml]/
   [file_kv_store.ml], for the full rationale.

   Dot-prefixed so it reads as this module's own private file sitting alongside whatever real,
   caller-owned files already live in [dir_path] -- matching this codebase's existing convention
   for such files (e.g. [File_kv_store]'s own [".riptide-lock"] and owner-marker names), and
   deliberately a name no other part of this codebase ever writes, so it can never collide with a
   real file. Pid + the atomic counter above make it unique across every buffer this process ever
   allocates from any pool, the same collision-avoidance argument
   [File_kv_store.tmp_suffix_for_call] makes for per-key temp files. *)
let temp_backing_file_name () =
  Printf.sprintf ".riptide-aligned-buffer-pool.%d.%d.tmp" (Unix.getpid ())
    (Atomic.fetch_and_add call_counter 1)

(* [Unix.map_file] is required (POSIX [mmap(2)]) to return a page-aligned address when mapping
   starts at file offset 0, unlike a plain [Bigarray.Array1.create]'s [malloc] -- see
   [file_storage.ml]'s own top comment for the full story of why this, and not the shared
   [eio_linux] buffer pool, is what makes [O_DIRECT] actually work for either of this module's two
   callers. The backing file is purely a vehicle for getting a real [mmap(2)] call; it is created,
   sized, mapped [~shared:false] (so nothing written into the returned buffer ever touches disk
   through it), and then closed + unlinked immediately -- the mapping itself stays valid (a
   standard, portable POSIX property) for as long as the returned [Cstruct.t] is reachable.

   [~dir_path] (Task 17): the backing file now lives inside the CALLER's own storage directory
   instead of [Filename.temp_file]'s [TMPDIR]-rooted one -- see [temp_backing_file_name] above.

   {b Disclosed residual gap (Task 17 review):} a process killed between [Unix.openfile]/
   [ftruncate]/[map_file] succeeding and the [Fun.protect] finally's [Unix.unlink] running (e.g.
   [SIGKILL], a handful of syscalls wide) leaves this throwaway file behind permanently in
   [dir_path] -- nothing in this codebase sweeps it (it matches neither
   [File_kv_store.sweep_stale_temp_files]'s [".put."]-based pattern nor anything [File_storage]
   scans for). Before this task, the same crash left the same kind of debris in [TMPDIR] instead,
   where it was usually someone else's problem to reap (systemd-tmpfiles, a reboot); now it is
   permanent, un-swept debris inside the real data directory. Judged proportionate to disclose
   rather than build a dedicated sweep for: the window is a handful of non-blocking syscalls (no
   I/O wait, no fsync), several orders of magnitude narrower than the crash windows this plan's
   other tasks (e.g. Task 15/16's own multi-step durable writes) build real sweeps for.

   Called exactly [buffer_count] times total, by [create] below, at pool-construction time --
   never again for the rest of that pool's lifetime. That call-frequency change (once per buffer
   instead of once per I/O) is the entire fix Task 10 made; this function's own body is otherwise
   unchanged from the original per-I/O version. *)
let alloc_one_aligned_buffer ~dir_path n =
  let path = Filename.concat dir_path (temp_backing_file_name ()) in
  let fd = Unix.openfile path [ Unix.O_RDWR; Unix.O_CREAT ] 0o600 in
  Fun.protect
    ~finally:(fun () ->
      Unix.close fd;
      try Unix.unlink path with Unix.Unix_error _ -> ())
    (fun () ->
      Unix.ftruncate fd n;
      let ba = Unix.map_file fd ~pos:0L Bigarray.char Bigarray.c_layout false [| n |] in
      Cstruct.of_bigarray (Bigarray.array1_of_genarray ba))

(* Validate both arguments up front rather than letting a bad value reach [Eio.Stream.create]/
   [alloc_one_aligned_buffer] below. Both current real callers ([File_storage], [File_kv_store])
   pass safe, hardcoded values ([buffer_count = 4], [slot_size = 4096]), so this exists purely for
   whoever the "future caller" this module documents itself as being reusable for turns out to
   be -- three concretely bad failure modes otherwise, none of which name this module or the bad
   argument at the point they surface:
   - [buffer_count = 0]: [Eio.Stream.create 0] is a valid, empty rendezvous stream (no exception),
     but the construction loop below that would normally push initial buffers never runs, so
     every future [with_buffer] call blocks on [Eio.Stream.take] FOREVER -- a silent deadlock, not
     an error, with nothing at the call site to explain why.
   - [buffer_count < 0]: raises from deep inside [Eio.Stream.create] itself, with a message naming
     neither this module nor which argument was wrong.
   - [slot_size <= 0]: reaches [Unix.map_file] with a zero/invalid dimension and fails with an
     equally unhelpful, deep [Unix.Unix_error]/[Invalid_argument] far from this call.

   No additional lower bound (e.g. requiring [slot_size] to be a multiple of the OS page size) is
   imposed here: [Unix.map_file]'s page-ALIGNMENT guarantee (see [alloc_one_aligned_buffer] above)
   is a property of the mapping's starting ADDRESS, not its length, and holds for any positive
   [slot_size] regardless of the page size. A separate constraint -- [O_DIRECT] requiring the
   LENGTH of each individual read/write to be a multiple of the filesystem's logical block size --
   is real, but it's a property of how a caller's own [Eio_linux.Low_level.readv]/[writev] calls
   use the buffer, not of this allocation-only module; both real callers already size their own
   [slot_alignment] (4096) to satisfy it, documented at their own call sites, per this module's own
   [.mli] ("sizing ... is the caller's job, not this module's"). *)
let create ~dir_path ~buffer_count ~slot_size () =
  if buffer_count <= 0 then
    invalid_arg
      (Printf.sprintf "Aligned_buffer_pool.create: ~buffer_count must be positive, got %d"
         buffer_count);
  if slot_size <= 0 then
    invalid_arg
      (Printf.sprintf "Aligned_buffer_pool.create: ~slot_size must be positive, got %d" slot_size);
  let pool = Eio.Stream.create buffer_count in
  for _ = 1 to buffer_count do
    Eio.Stream.add pool (alloc_one_aligned_buffer ~dir_path slot_size)
  done;
  { pool; slot_size }

let with_buffer ?(zero = true) t n f =
  if n < 0 then
    invalid_arg (Printf.sprintf "Aligned_buffer_pool.with_buffer: n (%d) is negative" n)
  else if n > t.slot_size then
    invalid_arg
      (Printf.sprintf "Aligned_buffer_pool.with_buffer: n (%d) exceeds this pool's fixed buffer \
                        size of %d"
         n t.slot_size);
  let buf = Eio.Stream.take t.pool in
  Fun.protect
    ~finally:(fun () -> Eio.Stream.add t.pool buf)
    (fun () ->
      if zero then Cstruct.memset buf 0;
      (* Every real call site in this codebase, as of this writing, always passes exactly
         [t.slot_size] (see [file_storage.ml]/[file_kv_store.ml]: every header/data write and
         read uses a fixed [header_slot_size]/[data_slot_size], both equal to their own
         [slot_alignment]), so the [Cstruct.sub] branch below is currently unreached. Kept anyway,
         deliberately: this module is meant to be reusable by any future caller with a genuinely
         variable-length need, and narrowing to a real sub-view for [n < t.slot_size] is the
         correct general behavior, not defensive dead code to prune. *)
      f (if n = t.slot_size then buf else Cstruct.sub buf 0 n))
