(* See this file's own [.mli] for the module-level contract. This [.ml]'s comments cover only the
   mechanism itself; see {!Riptide_storage.File_storage}'s top comment for the full bug history
   ("Task 10") and {!Riptide_storage.File_storage}/{!Riptide_storage.File_kv_store}'s own
   [create]/pool-construction call sites for why each picks the [~buffer_count] it does. *)

type t = { pool : Cstruct.t Eio.Stream.t; slot_size : int }

(* [Unix.map_file] is required (POSIX [mmap(2)]) to return a page-aligned address when mapping
   starts at file offset 0, unlike a plain [Bigarray.Array1.create]'s [malloc] -- see
   [file_storage.ml]'s own top comment for the full story of why this, and not the shared
   [eio_linux] buffer pool, is what makes [O_DIRECT] actually work for either of this module's two
   callers. The backing file is purely a vehicle for getting a real [mmap(2)] call; it is created,
   sized, mapped [~shared:false] (so nothing written into the returned buffer ever touches disk
   through it), and then closed + unlinked immediately -- the mapping itself stays valid (a
   standard, portable POSIX property) for as long as the returned [Cstruct.t] is reachable.

   Called exactly [buffer_count] times total, by [create] below, at pool-construction time --
   never again for the rest of that pool's lifetime. That call-frequency change (once per buffer
   instead of once per I/O) is the entire fix Task 10 made; this function's own body is otherwise
   unchanged from the original per-I/O version. *)
let alloc_one_aligned_buffer n =
  let path = Filename.temp_file "riptide_aligned_buffer" "" in
  let fd = Unix.openfile path [ Unix.O_RDWR ] 0o600 in
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
let create ~buffer_count ~slot_size () =
  if buffer_count <= 0 then
    invalid_arg
      (Printf.sprintf "Aligned_buffer_pool.create: ~buffer_count must be positive, got %d"
         buffer_count);
  if slot_size <= 0 then
    invalid_arg
      (Printf.sprintf "Aligned_buffer_pool.create: ~slot_size must be positive, got %d" slot_size);
  let pool = Eio.Stream.create buffer_count in
  for _ = 1 to buffer_count do
    Eio.Stream.add pool (alloc_one_aligned_buffer slot_size)
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
