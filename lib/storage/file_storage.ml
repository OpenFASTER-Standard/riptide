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
   is solved by {!alloc_aligned_buffer} below: instead of the shared pool, every read/write
   allocates its own buffer via [Unix.map_file] over a throwaway, immediately-unlinked temp
   file. [mmap(2)] is required by POSIX to return page-aligned addresses, and (unlike
   [Bigarray.Array1.create]'s plain [malloc]) [Unix.map_file] goes through a real [mmap(2)]
   call for every allocation (confirmed by reading the OCaml runtime's own
   [otherlibs/unix/mmap_unix.c]: [caml_unix_map_file] calls [mmap(NULL, ...)] and returns that
   address, adjusted only by [start_pos mod page_size] -- zero when mapping from offset 0, as
   here) -- so alignment holds regardless of what else the surrounding binary/process has
   already allocated, which is exactly the property Task 1's shared-pool version lacked.
   [Eio_linux.Low_level.writev]/[readv] (rather than [write]/[read_upto], which only accept the
   shared pool's [Uring.Region.chunk]) are what let this module hand [io_uring] an arbitrary,
   self-allocated [Cstruct.t] instead.

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
  superblocks : file_handle array;
      (* [superblock_copies] (3) independent files -- see this file's own top comment,
         "Task 3: the superblock", for the on-disk layout and quorum this backs. *)
}

let ring_file_name = "ring"
let default_ring_capacity = 8
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
   long as the returned [Cstruct.t] is reachable. *)
let alloc_aligned_buffer n =
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

(* [None] means "nothing durable at this offset yet" (a short/empty read -- i.e. this part of
   the file has never been written, whether because it's fresh or because [t]'s [ring_capacity]
   differs from a previous run and this slot is past the old high-water mark). Any other outcome
   either returns exactly the [len] bytes requested or raises. *)
let perform_read ~sw (h : file_handle) ~offset ~len =
  let buf = alloc_aligned_buffer len in
  let rec go () =
    match Eio_linux.Low_level.readv ~file_offset:(Optint.Int63.of_int offset) h.fd [ buf ] with
    | exception End_of_file -> None
    | exception Eio.Io _ when h.direct_capable ->
      downgrade_to_dsync_only ~sw h;
      go ()
    | n -> if n = len then Some buf else None
  in
  go ()

let write_header t ~slot ~op_number ~length ~checksum =
  let encoded = encode_header ~op_number ~length ~checksum in
  let buf = alloc_aligned_buffer header_slot_size in
  Cstruct.blit_from_string encoded 0 buf 0 header_slot_size;
  perform_write ~sw:t.sw t.ring ~offset:(header_offset ~slot) buf

let read_header t ~slot =
  match perform_read ~sw:t.sw t.ring ~offset:(header_offset ~slot) ~len:header_slot_size with
  | None -> None
  | Some buf -> Some (decode_header (Cstruct.to_string buf))

let write_data t ~slot data =
  let buf = alloc_aligned_buffer data_slot_size in
  (* [buf] is already zero-filled (freshly [ftruncate]d backing file) beyond [data]'s own
     length, so no separate zero-padding step is needed before writing the full slot. *)
  Cstruct.blit_from_string data 0 buf 0 (String.length data);
  perform_write ~sw:t.sw t.ring ~offset:(data_offset t ~slot) buf

let read_data t ~slot ~length =
  if length < 0 || length > data_slot_size then None
  else
    match perform_read ~sw:t.sw t.ring ~offset:(data_offset t ~slot) ~len:data_slot_size with
    | None -> None
    | Some buf -> Some (Cstruct.to_string ~len:length buf)

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

let create ~sw ~fs ?(ring_capacity = default_ring_capacity) dir_path =
  (try Eio.Path.mkdir ~perm:0o700 Eio.Path.(fs / dir_path) with Eio.Io _ -> ());
  let ring = open_file_handle ~sw (Filename.concat dir_path ring_file_name) in
  let superblocks =
    Array.init superblock_copies (fun i ->
        open_file_handle ~sw (Filename.concat dir_path (superblock_file_name i)))
  in
  let t = { sw; ring; ring_capacity; highest_op_number = 0; superblocks } in
  t.highest_op_number <- recover_highest_op_number t;
  t

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

let wal_truncate_after t ~op_number =
  if op_number < t.highest_op_number then t.highest_op_number <- op_number

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
  let header_buf = alloc_aligned_buffer header_slot_size in
  Cstruct.blit_from_string
    (encode_header ~op_number:0 ~length:len ~checksum)
    0 header_buf 0 header_slot_size;
  perform_write ~sw:t.sw h ~offset:superblock_header_offset header_buf;
  let data_buf = alloc_aligned_buffer data_slot_size in
  Cstruct.blit_from_string data 0 data_buf 0 len;
  perform_write ~sw:t.sw h ~offset:superblock_data_offset data_buf

(* [None] covers every way a single copy can fail to verify: missing/short file, a header that
   doesn't even read back as [header_slot_size] bytes, a decoded length outside the one aligned
   data slot this module ever writes, or (the main case) a checksum mismatch against that copy's
   own data. Never raises on a corrupted copy -- corruption here is an expected, tolerated
   condition, not a bug. *)
let read_superblock_copy t (h : file_handle) =
  match perform_read ~sw:t.sw h ~offset:superblock_header_offset ~len:header_slot_size with
  | None -> None
  | Some header_buf -> (
    let header = decode_header (Cstruct.to_string header_buf) in
    if header.length < 0 || header.length > data_slot_size then None
    else
      match perform_read ~sw:t.sw h ~offset:superblock_data_offset ~len:data_slot_size with
      | None -> None
      | Some data_buf ->
        let data = Cstruct.to_string ~len:header.length data_buf in
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
