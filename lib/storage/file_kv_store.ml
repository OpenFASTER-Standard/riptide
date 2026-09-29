(* A [Kv_store_intf.S] backend: one file per key, in a flat directory, named by the
   hex-encoded SHA-256 content-hash of the key -- distinct from [File_storage]'s bounded-ring
   WAL, which has no notion of an arbitrary number of independently-deletable keys. Reuses
   [File_storage]'s own already-proven [O_DIRECT]+[O_DSYNC] durable I/O technique verbatim
   (transcribed, not imported -- [File_storage]'s [.mli] deliberately exposes only
   [Storage_intf.S] plus its own [create], so [perform_write]/[perform_read]/the
   header-then-data record shape are re-derived here rather than reused as library code). See
   [file_storage.ml] for the original this is transcribed from ([open_file_handle],
   [downgrade_to_dsync_only], [perform_write], [perform_read] -- line numbers deliberately not
   pinned here any more, having gone stale once already across Task 10's refactor).

   {b The buffer pool itself is NOT transcribed} -- unlike the rest of this list, it now lives in
   one place, {!Riptide_storage.Aligned_buffer_pool}, shared by this module and [File_storage]
   both (Task 10 review, Finding 2: the two copies had already cosmetically diverged, which is
   exactly the drift risk that motivated extracting a shared module rather than leaving two
   near-identical copies to keep in sync by hand). See that module's own [.mli] for the pool
   mechanism; this file's own [pool_size]/[create]/[with_buffer] call sites below cover only this
   store's own sizing/concurrency rationale.

   {b Departure from the brief's own code sketch, deliberately, per the task's own instruction
   to prefer [file_storage.ml]'s real technique over the sketch where they conflict}: the
   sketch's [create]/[durable_read] used [Eio.Path.kind] as an existence check. The installed
   Eio 0.12 has no such function -- confirmed directly against
   [/work/toolchain/opam-root/5.0.0/lib/eio/path.mli], which exposes no [kind] at all, and
   [file_storage.ml]'s own top comment ("The installed Eio 0.12's [Eio.Path] has no
   [kind]/[stat]-on-a-path existence check...") already documents exactly this and its fix:
   attempt the operation and catch the resulting [Eio.Io] instead of checking first. [create]
   below follows [file_storage.ml:277] exactly (try [mkdir], ignore [Eio.Io]); [durable_read]
   below applies the same "try, don't check" discipline to a per-key file that may not exist
   (never put, or deleted) by opening it and treating [Eio.Io] (ENOENT) as [None].

   {b On-disk layout, per key.} The file holds exactly one record: a [header_slot_size]-byte
   header ([length] (int64 big-endian, 8B) + [checksum] (32 raw bytes of
   [Riptide.Value.content_hash] over the value's bytes), zero-padded), followed immediately by
   the value's own bytes padded out to [data_slot_size] -- the same "header written first, then
   data" two-region shape [File_storage] uses for its ring slots and superblock records,
   transcribed here for a single record per file instead of many records sharing one file.

   {b Read vs. write opens deliberately use different flags}, matching the brief's own
   [open_flags_write]/[open_flags_read] split: [put] opens with [O_DIRECT+O_DSYNC+O_CREAT]
   (falling back to [O_DSYNC+O_CREAT] alone on [EINVAL], exactly [file_storage.ml]'s dance) --
   durability matters for writes. [get] opens with no flags at all, deliberately without
   [O_CREAT]: unlike the ring/superblock files (always pre-created by [File_storage.create]),
   a per-key file may never have existed, and a plain, non-[O_DIRECT] open both (a) raises a
   real [Eio.Io] (ENOENT) for [durable_read] to treat as "no such key" instead of fabricating
   an empty file as a side effect of reading it, and (b) sidesteps [O_DIRECT] alignment
   concerns entirely for reads, which have no durability requirement of their own to justify
   the complexity -- only the checksum already carried in the header matters for correctness.

   {b Deletion is a real [unlink], not a header zero-out.} Unlike
   [File_storage.wal_truncate_after] (which zeroes a shared ring file's header in place
   because the ring file itself must persist across truncations), each key here owns its own
   file, so [delete] removes the directory entry outright via [Eio.Path.unlink] -- confirmed
   present in the installed Eio 0.12 ([path.mli:133]). A deleted key's [get] afterwards hits a
   real [Eio.Io] (ENOENT) on open, which [durable_read] treats identically to "never put" --
   there is no on-disk trace left for a reopen to resurrect. [delete]'s own catch is narrowed to
   specifically [Eio.Fs.E (Eio.Fs.Not_found _)] (confirmed the real shape [eio_linux]'s
   [wrap_fs] wraps [ENOENT] as, in [lib_eio_linux/err.ml]) -- not a blanket [Eio.Io _] -- so a
   genuine failure (permission denied, I/O error) propagates instead of being silently treated
   as "already deleted"; a caller must be able to trust that [delete] returning means the key is
   actually gone.

   {b [put]'s overwrite is crash-atomic via write-temp-then-rename.} A prior version of
   [durable_write] wrote the new header at offset 0 and the new data after it directly in
   place over the target file -- safe for [File_storage]'s own ring/superblock slots (protected
   there by a separate 3-copy quorum anyway) but not for this module's [put], whose documented
   contract is "durably overwrite any previous value", for a value that must stay readable
   indefinitely. A crash between the header and data writes of a second [put] to an
   already-committed key would leave a header with the new checksum pointing at old data --
   failing the checksum check on read and losing a value an earlier, successful [put] had
   already durably confirmed. Fixed the same way [File_storage]'s own superblock protects a
   similarly-shaped hazard, but with the simpler primitive available here since each key has
   its own file (no need for a multi-copy quorum): [durable_write] stages the full new record
   (header then data, same ordering as before) into a per-key temporary file
   ([path ^ tmp_suffix]), then publishes it with a single [Eio.Path.rename] onto the real key
   path -- confirmed real in the installed Eio 0.12 ([path.mli:145], "atomically unlinks old_t
   and links it as new_t"). POSIX [rename(2)] within one directory is atomic, so [get] (which
   only ever opens the real key path, never the temp one) can only ever observe the fully-old
   record or the fully-new one, never a torn mix -- a crash at any point before the [rename]
   leaves the real path, and therefore the previous value, completely untouched. Publishing is
   only finished once that new directory ENTRY is itself durable, which a [rename] alone does not
   make it, so [durable_write] fsyncs the containing directory afterwards exactly as [delete]
   does -- see [fsync_dir]'s own comment for the full hazard this closes on [put]'s path
   (final-review finding, 2026-09-23). *)

type file_handle = { path : string; mutable fd : Eio_unix.Fd.t; mutable direct_capable : bool }

type t = {
  sw : Eio.Switch.t;
  lock : Eio_unix.Fd.t;
      (* Task 11: a real, OS-level [flock(2)] on [dir_path], held for [t]'s entire lifetime via
         [sw] and released automatically when [sw] finishes -- see
         {!Riptide_storage.Dir_lock}'s own [.mli] for the full rationale, in particular why this
         is a PHYSICAL guard that exists ALONGSIDE, not instead of, [owner]/[check_or_write_owner_marker]
         below (a purely LOGICAL guard). Never read again after [create] stores it here. *)
  fs : Eio.Fs.dir_ty Eio.Path.t;
  dir_path : string;
  owner : string;
  pool : Aligned_buffer_pool.t;
      (* Task 10's buffer pool, built through the same shared
         {!Riptide_storage.Aligned_buffer_pool} module [file_storage.ml] uses (see that file's
         top comment, "Task 10: the [mmap] call above now happens once per pool buffer, not once
         per I/O", and this file's own [pool_size] below for the sizing/concurrency rationale).
         Every buffer in it is exactly [slot_alignment] bytes, [mmap]-backed, allocated once at
         [create] time. *)
}

(* Same single alignment used uniformly for both header and data regions as [File_storage]
   (see that file's own top comment) -- this box's confirmed [O_DIRECT] alignment requirement
   on both its ext4 and overlayfs mounts. *)
let slot_alignment = 4096
let header_record_size = 8 (* length *) + 32 (* checksum *)
let () = assert (header_record_size <= slot_alignment)
let header_slot_size = slot_alignment
let data_slot_size = slot_alignment
let max_value_size = data_slot_size

let open_flags_write = Uring.Open_flags.(dsync + creat + direct)
let open_flags_write_fallback = Uring.Open_flags.(dsync + creat)
let open_flags_read = Uring.Open_flags.empty

(* [pool_size] buffers of exactly [slot_alignment] bytes each, built through the shared
   {!Riptide_storage.Aligned_buffer_pool} module (see that module's own [.mli] for the pool
   mechanism itself, and [file_storage.ml]'s top comment, "Task 10", for the VMA-leak bug both
   this file and that one used to have independently before sharing that module).

   {b Sizing/concurrency rationale, this store's own} (corrected -- Task 10 review round 2,
   Finding 1: the previous version of this comment (itself a correction of an earlier, differently
   wrong version -- Finding M3) claimed a single, exclusive test-only consumer,
   [test/test_dst_scenarios.ml]'s [Lww_materializer], "confirmed by grepping every real
   (non-[.mli]) call to [File_kv_store.create]" -- that grep was never actually run broadly enough
   to support the word "the" it used. Re-grepped for this correction: real (non-[.mli]) calls to
   [File_kv_store.create] appear in seven test files, not one --
   [test/test_file_kv_store.ml], [test/test_lattice_materialize_crypto_scenarios.ml],
   [test/test_redaction.ml], [test/test_materializer.ml],
   [test/test_batch_commit_materialize.ml], [test/test_batch_commit.ml], and
   [test/test_dst_scenarios.ml] itself -- roughly 50 call sites total, dominated by the first two
   (~19 each). Several of these ([test_redaction.ml], [test_batch_commit.ml],
   [test_lattice_materialize_crypto_scenarios.ml]) construct a [File_kv_store.t] that then feeds
   {!Riptide_crypto.Redaction_store} via [~owner:Redaction_store.owner_tag] -- [Redaction_store]
   itself still never calls [File_kv_store.create] (it takes an already-built [kv] on faith, per
   its own [.mli]), it is just one of several real downstream shapes a caller-built [t] takes.

   The conclusion is unchanged despite the narrower-than-claimed reasoning both previous versions
   of this comment gave: access into this store is still strictly sequential in practice, for the
   same reason across all of these -- every one of these call sites is a single-fiber test driver
   (confirmed: none of these seven files forks a fiber that touches a [File_kv_store.t] concurrently
   with another), each running one test step (one [get]/[put]/[delete], or one
   [materialize_up_to]/[propose]/[settle]/[restart] call in the DST driver's case) to completion
   before starting the next. There is no single "the" consumer of this store -- there are many,
   spread across many test files -- but none of them is concurrent, which is the only property this
   sizing rationale actually depends on. [pool_size = 4] gives the same headroom [file_storage.ml]
   gives itself for anything this module's signature doesn't itself forbid from being concurrent (a
   future stress test, a future non-test consumer), without needing a bigger pool for real usage as
   it exists today.) *)
let pool_size = 4

let encode_header ~length ~checksum =
  let buf = Bytes.make header_slot_size '\000' in
  Bytes.set_int64_be buf 0 (Int64.of_int length);
  Bytes.blit_string checksum 0 buf 8 32;
  Bytes.unsafe_to_string buf

let decode_header s =
  let b = Bytes.unsafe_of_string s in
  (Int64.to_int (Bytes.get_int64_be b 0), String.sub s 8 32)

let checksum_of data = Riptide.Value.content_hash (Riptide.Value.Scalar (Riptide.Value.String data))

(* Open-with-O_DIRECT-fallback for writes, transcribed from [file_storage.ml]'s
   [open_file_handle]. [~perm:0o600] since [creat] is always set here. *)
let open_file_handle_write ~sw path =
  try
    let fd =
      Eio_linux.Low_level.openat2 ~sw ~seekable:true ~access:`RW ~flags:open_flags_write
        ~perm:0o600 ~resolve:Uring.Resolve.empty path
    in
    { path; fd; direct_capable = true }
  with Eio.Io _ ->
    let fd =
      Eio_linux.Low_level.openat2 ~sw ~seekable:true ~access:`RW ~flags:open_flags_write_fallback
        ~perm:0o600 ~resolve:Uring.Resolve.empty path
    in
    { path; fd; direct_capable = false }

(* Plain (non-[O_DIRECT], non-creating) open for reads -- see this file's top comment for why
   reads deliberately diverge from [file_storage.ml]'s uniform-flags approach. [~perm:0] per
   [file_storage.ml]'s own documented [openat2] gotcha: a nonzero [~perm] with neither
   [O_CREAT] nor [O_TMPFILE] set raises [EINVAL]. Raises [Eio.Io] (ENOENT) if [path] doesn't
   exist -- deliberately not caught here; [durable_read] below catches it. *)
let open_file_handle_read ~sw path =
  let fd =
    Eio_linux.Low_level.openat2 ~sw ~seekable:true ~access:`RW ~flags:open_flags_read ~perm:0
      ~resolve:Uring.Resolve.empty path
  in
  { path; fd; direct_capable = false }

(* Transcribed from [file_storage.ml]'s [downgrade_to_dsync_only]: permanent for the
   rest of this handle's lifetime once a real [O_DIRECT] failure is hit. Never triggered for a
   read handle ([direct_capable] is always [false] there), so it's only ever reached from a
   write handle's [perform_write]/[perform_read] retry. *)
let downgrade_to_dsync_only ~sw (h : file_handle) =
  if h.direct_capable then begin
    ignore (Eio_unix.Fd.close h.fd);
    h.fd <-
      Eio_linux.Low_level.openat2 ~sw ~seekable:true ~access:`RW ~flags:open_flags_write_fallback
        ~perm:0o600 ~resolve:Uring.Resolve.empty h.path;
    h.direct_capable <- false
  end

(* Transcribed from [file_storage.ml] ([perform_write]). *)
let perform_write ~sw (h : file_handle) ~offset (buf : Cstruct.t) =
  let rec go () =
    try Eio_linux.Low_level.writev ~file_offset:(Optint.Int63.of_int offset) h.fd [ buf ]
    with Eio.Io _ when h.direct_capable ->
      downgrade_to_dsync_only ~sw h;
      go ()
  in
  go ()

(* Transcribed from [file_storage.ml] ([perform_write_from_string]): acquires a pooled buffer,
   blits [data] into it (zero-padded out to [n] by
   {!Riptide_storage.Aligned_buffer_pool.with_buffer}'s own fresh-zero-on-acquire), writes it, and
   releases the buffer -- all before returning. *)
let perform_write_from_string ~pool ~sw (h : file_handle) ~offset ~n data =
  Aligned_buffer_pool.with_buffer pool n (fun buf ->
      Cstruct.blit_from_string data 0 buf 0 (String.length data);
      perform_write ~sw h ~offset buf)

(* Transcribed from [file_storage.ml] ([perform_read]), including that file's own M8 fix
   (Task 10 review): [len] is the full [slot_alignment]-sized amount actually issued to [readv]
   ([O_DIRECT]'s length-alignment requirement leaves no choice there), while [want] is however
   many of those bytes the caller actually needs back -- narrowing via [Cstruct.to_string]'s own
   [~len] here means only one right-sized string is ever allocated, instead of a full
   [slot_alignment]-byte string that every caller below then [String.sub]s down again. [None]
   means "nothing durable at this offset" -- a short/empty read (e.g. a torn write). Returns a
   [string], not a [Cstruct.t] (Task 10): the pooled buffer must be released back to
   {!Riptide_storage.Aligned_buffer_pool.with_buffer}'s pool before this function returns, so
   nothing that outlives the call may still reference it.

   [~zero:false]: both call sites below only ever read INTO [buf] and return [None] (without ever
   converting [buf] to output) on anything short of a full [len]-byte read, so there is no way to
   observe a stale tail left by a prior use of this pooled buffer -- see
   {!Riptide_storage.Aligned_buffer_pool}'s own [.mli] for the general rule this follows. *)
let perform_read ~pool ~sw (h : file_handle) ~offset ~len ~want =
  Aligned_buffer_pool.with_buffer ~zero:false pool len (fun buf ->
      let rec go () =
        match Eio_linux.Low_level.readv ~file_offset:(Optint.Int63.of_int offset) h.fd [ buf ] with
        | exception End_of_file -> None
        | exception Eio.Io _ when h.direct_capable ->
          downgrade_to_dsync_only ~sw h;
          go ()
        | n -> if n = len then Some (Cstruct.to_string ~len:want buf) else None
      in
      go ())

let path_for t ~key =
  Filename.concat t.dir_path
    (Riptide.Value.hash_to_hex
       (Riptide.Value.content_hash (Riptide.Value.Scalar (Riptide.Value.String key))))

(* Suffix for the per-key temporary file [durable_write] stages a new record into before
   atomically publishing it via [Eio.Path.rename] -- see this file's top comment ("[put]'s
   overwrite is crash-atomic...") for the full rationale. Fixed, not randomized: two callers
   concurrently [put]ting the *same* key is not a case [Kv_store_intf.S] promises to handle
   (nothing in its contract mentions concurrent writers) -- this only needs to survive a crash
   during a single writer's own interrupted write, not race a second writer for the name. *)
let tmp_suffix = ".put.tmp"

(* The durability step BOTH [durable_write] and [delete] need, and the reason neither is finished
   once its own file operation returns: POSIX leaves a directory's own metadata -- the list of
   names it contains -- unsynced after a [rename] or an [unlink], even when the file data those
   names point at is itself durable. The entry change can sit in the page cache, or in the
   filesystem's journal ahead of the commit that makes it visible again after a power loss, for an
   unbounded time. Making a change to a DIRECTORY durable requires fsyncing the directory (fsyncing
   a file would say nothing about its name existing, or being gone), which is why this opens
   [dir_path] rather than any key's own path.

   For [delete] this closes the "deleted key must never be resurrected" bug
   [Kv_store_intf.S.delete]'s own contract forbids: a crash right after [delete] returned could
   otherwise bring the file back on the next open, which for this store's first real consumer
   ([Riptide_crypto.Redaction_store.redact]) would mean a redacted record's wrapped DEK returning
   from the dead.

   For [put] it closes the mirror-image hazard, found by the final whole-branch review (2026-09-23)
   after having been missed when [durable_write] was converted to write-temp-then-rename: the temp
   file's own CONTENT is durable ([O_DIRECT]+[O_DSYNC] on every [perform_write]), and [rename] is
   atomic, but the rename's own directory-entry update was never synced, so a power loss inside the
   filesystem's journal-commit window could leave the new name unpersisted. That is not a
   symmetrical "lose the last write" outcome, because callers above this layer commit on the
   strength of [put] having returned: [Riptide_crypto.Redaction_store.encrypt_for_storage] stores a
   record's wrapped DEK through [put] and documents in its own [.mli] that the wrapped DEK is
   durably stored before it returns, then the ciphertext gets committed to a real WAL that IS
   durable. Losing only the keystore entry therefore yields a committed ciphertext whose DEK is
   gone: permanently unopenable, with the hash chain still verifying and nothing surfacing the
   loss. Syncing the directory on [put]'s path is what makes that [.mli]'s guarantee true.

   Plain blocking [Unix] calls rather than [Eio_linux.Low_level]: [openat2] is a file-oriented
   helper here (this module's own [open_file_handle_read]/[open_file_handle_write] both set
   [~seekable:true] and read/write records) and the installed Eio 0.12 exposes no fsync at all, on
   a path or an fd. Blocking briefly in a fiber is already an established practice this module
   shares with {!Riptide_storage.Aligned_buffer_pool}'s own [alloc_one_aligned_buffer] (not this
   module's own code since the Task 10 extraction moved it there; not exposed by that module's
   [.mli] either -- see its [.ml] instead), which does [Unix.openfile]/[ftruncate]/[map_file]
   synchronously, same as this. (Before Task 10, that call
   happened synchronously on every single read and write; now it happens only [pool_size] times,
   once each, at [create] -- the blocking-in-a-fiber precedent this sentence leans on still holds
   either way.) Errors deliberately propagate rather than being swallowed, matching
   [delete]'s narrow catch: a caller must be able to trust that a returning [put] or [delete] means
   the key really, durably is (or is not) there. *)
let fsync_dir t =
  let fd = Unix.openfile t.dir_path [ Unix.O_RDONLY ] 0 in
  Fun.protect ~finally:(fun () -> try Unix.close fd with Unix.Unix_error _ -> ()) (fun () -> Unix.fsync fd)

(* Durably writes [data] to [path] via write-temp-then-rename: header (length + checksum)
   first, then data, into [path ^ tmp_suffix] -- the same "header always written first"
   ordering [File_storage.wal_append] uses, so a crash between the two *temp*-file writes
   leaves (at worst) a garbage temp file that the real [path] never points at -- then a single
   [Eio.Path.rename] of the temp file onto [path] publishes the whole record atomically. Opens
   the temp file with [creat] so a first [put] for a key with no file yet succeeds.

   The [fsync_dir] after the rename is not optional bookkeeping -- see [fsync_dir]'s own comment
   above for why a durable-content, atomically-renamed file is still not a durable KEY without it,
   and what [Riptide_crypto.Redaction_store] loses if it is missing. *)
let durable_write t path data =
  if String.length data > max_value_size then
    invalid_arg
      (Printf.sprintf "put: value of %d bytes exceeds this store's max value size of %d bytes"
         (String.length data) max_value_size);
  let tmp_path = path ^ tmp_suffix in
  let h = open_file_handle_write ~sw:t.sw tmp_path in
  Fun.protect
    ~finally:(fun () -> ignore (Eio_unix.Fd.close h.fd))
    (fun () ->
      let checksum = checksum_of data in
      perform_write_from_string ~pool:t.pool ~sw:t.sw h ~offset:0 ~n:header_slot_size
        (encode_header ~length:(String.length data) ~checksum);
      perform_write_from_string ~pool:t.pool ~sw:t.sw h ~offset:header_slot_size
        ~n:data_slot_size data);
  Eio.Path.rename Eio.Path.(t.fs / tmp_path) Eio.Path.(t.fs / path);
  fsync_dir t

(* [None] for every way this can fail to verify: the file doesn't exist (never put, or
   deleted -- caught as [Eio.Io] from the open itself), a short/missing header or data read, a
   decoded length outside one aligned data slot, or (the main case) a checksum mismatch --
   matching [File_storage.wal_read]'s own "cannot distinguish never-written from corrupted"
   contract, now also covering "deleted". *)
let durable_read t path =
  match open_file_handle_read ~sw:t.sw path with
  | exception Eio.Io _ -> None
  | h ->
    Fun.protect
      ~finally:(fun () -> ignore (Eio_unix.Fd.close h.fd))
      (fun () ->
        match
          perform_read ~pool:t.pool ~sw:t.sw h ~offset:0 ~len:header_slot_size
            ~want:header_record_size
        with
        | None -> None
        | Some header_s -> (
          let length, checksum = decode_header header_s in
          if length < 0 || length > data_slot_size then None
          else
            match
              perform_read ~pool:t.pool ~sw:t.sw h ~offset:header_slot_size ~len:data_slot_size
                ~want:length
            with
            | None -> None
            | Some data -> if checksum_of data = checksum then Some data else None))

(* The marker file [check_or_write_owner_marker] reads/writes to enforce exclusive directory
   ownership -- subtask 4.6's construction-time fix for a confirmed, real data-destruction bug:
   sharing one [dir_path] between a [Redaction_store] keystore and a [Materializer] accumulator
   silently destroys data in three distinct ways. It catches a MISMATCHED tag only: a shared
   directory claimed twice under the SAME tag still destroys data, exactly as before, {b for two
   handles that never overlap in time} -- Task 11's {!Riptide_storage.Dir_lock} guard (run strictly
   before this function, see [create] above) now catches the same-tag case too whenever a second
   [create] is attempted while an earlier handle over [dir_path] is still live, which is what
   [test_lattice_materialize_crypto_scenarios.ml]'s own negative control
   ([test_using_the_same_owner_tag_on_both_sides_still_destroys_a_wrapped_dek]) demonstrates by
   fully releasing each handle before the next one opens -- the only shape of same-tag collision
   left standing. See [redaction_store.mli]'s own [create] doc comment for the full account of
   both guards and the boundary between them. Named
   with a leading dot so [Eio.Path.read_dir] callers (none exist on this store today, but the
   convention is cheap) don't confuse it for a real key file -- real key files are always exactly
   64 lowercase hex characters ([path_for]'s [hash_to_hex] output), which this name can never
   collide with. *)
let owner_marker_name = ".riptide-kv-owner"

(* Enforces that at most one distinct [owner] tag ever claims [dir_path], across every [create] of
   it for the lifetime of the directory. [owner] is mandatory (see this file's [.mli] on
   [create]'s [~owner]), so every call here has a real tag to check or write.

   Same "try the operation, catch [Eio.Io]" discipline this file's own top comment already
   documents for every other existence check, since the installed Eio 0.12's [Path] has no
   [kind]/[stat] check to test first instead: [Eio.Path.load] on a marker that was never written
   raises [Eio.Io] (confirmed against [path.ml]'s own [load], which opens via [open_in] --
   the same backend open every other existence check in this file already relies on raising
   [Eio.Io] for ENOENT), read here as "no owner has claimed this directory yet, this call is the
   first". [Eio.Path.load]/[Eio.Path.save] themselves are both confirmed real, current functions
   in the installed Eio 0.12 ([path.mli]) -- [save ~create:(`Exclusive perm)] confirmed via
   [fs.ml]'s own [type create] variant. *)
let check_or_write_owner_marker ~fs ~dir_path tag =
  let marker_path = Eio.Path.(fs / dir_path / owner_marker_name) in
  match Eio.Path.load marker_path with
  | existing ->
    if not (String.equal existing tag) then
      invalid_arg
        (Printf.sprintf "File_kv_store.create: %s is owned by %S, not %S" dir_path existing tag)
  | exception Eio.Io _ -> Eio.Path.save ~create:(`Exclusive 0o600) marker_path tag

(* Same try-[mkdir]-then-ignore-[Eio.Io] pattern as [file_storage.ml:277] -- see this file's
   top comment for why (no [Eio.Path.kind] existence check exists in the installed Eio 0.12). The
   owner-marker check runs strictly after this, since it needs [dir_path] to already exist (an
   [Eio.Path.save] into a nonexistent directory would itself raise [Eio.Io], indistinguishable
   from this module's own "no marker yet" case, if the two were reordered). *)
(* [~owner] being mandatory (subtask 4.8) makes "no owner" syntactically inexpressible, but
   [~owner:""] would be the same escape hatch spelled differently: an empty marker file that any
   other empty-tagged consumer matches, i.e. a tag that declares nothing while passing every check.
   Rejected at construction, in the same style as this module's owner-mismatch rejection and
   [Redaction_store.create]'s own. *)
let create ~sw ~fs ~owner dir_path =
  if String.length owner = 0 then
    invalid_arg "File_kv_store.create: ~owner must be a non-empty tag";
  (try Eio.Path.mkdir ~perm:0o700 Eio.Path.(fs / dir_path) with Eio.Io _ -> ());
  (* Task 11: the PHYSICAL guard, taken as early as possible -- strictly before the LOGICAL
     owner-marker check below, and before anything else this module manages. A directory already
     locked by a live handle is refused immediately regardless of what tag the new caller passes,
     the same "reject before doing anything else" precedence [~owner:""] already gets above. See
     {!Riptide_storage.Dir_lock}'s own [.mli] for why this closes the concurrent-handle instance
     of the "same tag, still destroys data" residual gap [check_or_write_owner_marker] alone
     leaves open (still real for two handles that never overlap in time -- see that function's own
     doc comment). *)
  let lock = Dir_lock.acquire ~sw ~caller:"File_kv_store.create" dir_path in
  check_or_write_owner_marker ~fs ~dir_path owner;
  {
    sw;
    lock;
    fs;
    dir_path;
    owner;
    pool = Aligned_buffer_pool.create ~buffer_count:pool_size ~slot_size:slot_alignment ();
  }

(* [check_or_write_owner_marker] above either confirms [owner] against the existing on-disk marker
   or writes a fresh one holding exactly [owner] -- it never resolves or hands back a tag of its
   own. So by the time [create] returns without raising, [owner] (the caller-supplied argument
   itself) IS what the marker file now holds: [t.owner] below is that same argument, not a re-read
   of the marker, but the two are guaranteed to agree. *)
let owner t = t.owner

let get t ~key = durable_read t (path_for t ~key)
let put t ~key data = durable_write t (path_for t ~key) data

let delete t ~key =
  (try Eio.Path.unlink Eio.Path.(t.fs / path_for t ~key) with
  | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) ->
    () (* ENOENT: already absent, matching put's own idempotent-overwrite spirit *));
  fsync_dir t
