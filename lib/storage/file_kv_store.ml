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

   {b Sharded by hash prefix (Task 18), not flat.} [path_for] no longer places every key's file
   directly in [dir_path]: each lives at [dir_path/xx/yy/<hash>], where [xx]/[yy] are the first 4
   hex characters of the key's own [hash_to_hex (content_hash key)] (2 characters each) -- the
   same [<hash>] that used to be the flat filename, now also the two directory levels above it.
   This matches the convention content-addressed stores commonly use for exactly this reason (e.g.
   Git's own [.git/objects/xx/yyyy...]): audit finding Storage-Important-5 found that a single
   flat directory's own lookup cost degrades once its entry count climbs past the tens of
   thousands on some filesystems, even though POSIX directory semantics don't require that.
   Splitting into up to 65536 (256 x 256) second-level shard directories bounds any ONE
   directory's entry count to roughly 1/65536th of the total key count, independent of how large
   this store ever grows. {b This does not fix the other two costs Storage-Important-5 also
   found} -- the fixed [header_slot_size + data_slot_size] = 8192-byte file per key (a real ~123x
   space amplification for a small value) and one filesystem inode consumed per key with no
   reclamation short of [delete] -- both inherent to this module's fixed-size-slot-per-file
   layout, not the flat-vs-sharded directory structure sharding changes; see [file_kv_store.mli]'s
   own note for the disclosed cost this leaves on the table by design (a materially larger,
   variable-size-value-format change, out of proportion to this task's scope).

   {b Ruling B (audit-remediation controller, pre-flight, binding on Task 18):} a key's own
   temporary file (staged by [durable_write] before its atomic [rename] -- see "[put]'s overwrite
   is crash-atomic" below) must live in that SAME sharded subdirectory as the key's own final
   path, not at a stale flat-directory location -- it always has, structurally, since the temp
   path is built as [path_for t ~key ^ tmp_suffix_for_call ()], i.e. [path_for]'s own sharded
   result plus a suffix, never a separately-computed flat path. The consequence Ruling B calls out
   is [sweep_stale_temp_files] (Task 16): it used to scan only [dir_path]'s own top level for
   crash-debris temp files, which would now silently stop finding any of them once every per-key
   temp file moves two levels deeper -- see that function's own comment below for the fix.

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
   write handle's [perform_write]/[perform_read] retry.

   {b Task 19, Bug 2 (audit-remediation, use-after-close on a failed reopen) -- transcribed from
   [file_storage.ml]'s own fix.} [h.direct_capable] is set to [false] BEFORE attempting the reopen,
   not after it succeeds: a failed reopen (e.g. [EMFILE]) otherwise leaves [h.fd] closed while
   [h.direct_capable] still reads [true], so a later caller would retry against the already-closed
   fd instead of seeing the handle is broken. See [file_storage.ml]'s own comment on its copy of
   this function for the full reasoning. *)
let downgrade_to_dsync_only ~sw (h : file_handle) =
  if h.direct_capable then begin
    ignore (Eio_unix.Fd.close h.fd);
    h.direct_capable <- false;
    h.fd <-
      Eio_linux.Low_level.openat2 ~sw ~seekable:true ~access:`RW ~flags:open_flags_write_fallback
        ~perm:0o600 ~resolve:Uring.Resolve.empty h.path
  end

(* Transcribed from [file_storage.ml] ([perform_write]), including that file's own Task 19 Bug 1
   fix: narrowed from a blanket [Eio.Io _ when h.direct_capable] to specifically [EINVAL] -- the
   real O_DIRECT-unsupported errno shape -- so an unrelated real storage fault (ENOSPC/EIO/ENOMEM)
   propagates instead of permanently downgrading this handle. See [file_storage.ml]'s own comment
   on its copy of this function for the full reasoning. *)
let perform_write ~sw (h : file_handle) ~offset (buf : Cstruct.t) =
  let rec go () =
    try Eio_linux.Low_level.writev ~file_offset:(Optint.Int63.of_int offset) h.fd [ buf ]
    with Eio.Io (Eio.Exn.X (Eio_unix.Unix_error (Unix.EINVAL, _, _)), _) when h.direct_capable ->
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
        | exception
            Eio.Io (Eio.Exn.X (Eio_unix.Unix_error (Unix.EINVAL, _, _)), _) when h.direct_capable ->
          downgrade_to_dsync_only ~sw h;
          go ()
        | n -> if n = len then Some (Cstruct.to_string ~len:want buf) else None
      in
      go ())

(* Task 18: [dir_path/xx/yy/<hash>] -- see this file's top comment ("Sharded by hash prefix") for
   the full rationale. [xx] is [hash]'s first 2 hex characters, [yy] its next 2 (characters 2-3);
   both are always present since [hash_to_hex] always produces a fixed-length (64-character)
   lowercase hex string, never anything shorter.

   Split out of [path_for] below (Task 24) so [get_by_hash] can build the same sharded location
   directly from an already-computed hash, without hashing it a second time the way [path_for]
   itself does for an arbitrary caller key. *)
let path_from_hash t hash =
  Filename.concat t.dir_path
    (Filename.concat (String.sub hash 0 2) (Filename.concat (String.sub hash 2 2) hash))

let path_for t ~key =
  let hash =
    Riptide.Value.hash_to_hex
      (Riptide.Value.content_hash (Riptide.Value.Scalar (Riptide.Value.String key)))
  in
  path_from_hash t hash

(* Atomic counter to make each [durable_write] call's temp-file suffix unique. Closed audit
   finding (Task 16): concurrent fibers [put]ting the *same* key with a fixed temp-file suffix
   (the old [".put.tmp"] constant) can race to write the same temp path, resulting in one
   writer's partial write landing in the file the other writer then renames into place -- a
   torn mix, never readable, or permanently lost. Making the suffix unique per call
   (pid + atomic counter) ensures each concurrent writer uses its own temp file; POSIX
   [rename]'s atomicity then guarantees a reader always sees one complete writer's record.

   {b Why a module-level atomic counter, not a Thread-local or fiber-local counter:} Eio
   fibers are lightweight OS-thread-less tasks that share one real OS process, so they all
   share the same [Unix.getpid ()] value. Fiber-local storage alone (if Eio exposed it) would
   be wrong: two fibers on the same OS thread would still generate colliding names. The atomic
   counter makes collisions impossible across all fibers in one process. Cross-process
   collisions are already ruled out by the [Unix.getpid ()] part: two separate processes get
   different PIDs. *)
let call_counter = Atomic.make 0

(* Suffix for the per-key temporary file [durable_write] stages a new record into before
   atomically publishing it via [Eio.Path.rename] -- see this file's top comment ("[put]'s
   overwrite is crash-atomic...") for the full rationale. Made unique per call to close the
   audit finding above: concurrent writers to the same key no longer collide on the temp path. *)
let tmp_suffix_for_call () =
  Printf.sprintf ".put.%d.%d.tmp" (Unix.getpid ()) (Atomic.fetch_and_add call_counter 1)

(* The durability step BOTH [durable_write] and [delete] need, and the reason neither is finished
   once its own file operation returns: POSIX leaves a directory's own metadata -- the list of
   names it contains -- unsynced after a [rename] or an [unlink], even when the file data those
   names point at is itself durable. The entry change can sit in the page cache, or in the
   filesystem's journal ahead of the commit that makes it visible again after a power loss, for an
   unbounded time. Making a change to a DIRECTORY durable requires fsyncing the directory (fsyncing
   a file would say nothing about its name existing, or being gone), which is why this opens a
   directory path rather than any key's own file path.

   {b Critical fix (review finding, post-Task-18): fsync the directory the [rename]/[unlink]
   ACTUALLY changed, not [t.dir_path].} [fsync(fd)] on a directory only forces durability of THAT
   directory's own entry list -- never anything below it -- exactly the same principle
   [fsync_file]'s own comment below invokes to explain why [check_or_write_owner_marker] needs a
   separate content fsync in addition to this directory one. Before Task 18's sharding, a key's
   own [path] lived directly in [dir_path], so fsyncing [dir_path] WAS fsyncing the directory that
   held the changed entry -- they were the same directory. After sharding, [path] is
   [dir_path/xx/yy/<hash>]: the [rename]/[unlink] only ever mutates the SHARD2 directory's entries
   ([Filename.dirname path]), two levels below [dir_path]. Fsyncing [dir_path] after that closes
   nothing -- it durabilizes a directory whose entry list never changed, while the actual changed
   entry (in the shard2 directory) stays exactly as unsynced as if this call were never made. Both
   [durable_write] and [delete] below therefore fsync [Filename.dirname path] (the shard2
   directory), not [t.dir_path] -- see each call site's own comment.

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
let fsync_dir ~dir_path =
  let fd = Unix.openfile dir_path [ Unix.O_RDONLY ] 0 in
  Fun.protect ~finally:(fun () -> try Unix.close fd with Unix.Unix_error _ -> ()) (fun () -> Unix.fsync fd)

(* [fsync_dir] above makes a directory ENTRY durable; this makes a FILE's own CONTENT durable --
   needed specifically for [check_or_write_owner_marker]'s marker write (Task 15 review, Finding
   1), because that write goes through plain [Eio.Path.save] rather than this module's own
   [O_DIRECT]+[O_DSYNC] write path ([open_file_handle_write]/[perform_write]). Confirmed against
   the installed Eio 0.12's [path.ml]: [save] is a plain buffered write (opens via
   [with_open_out] and writes via [Flow.copy_string]), with no [O_SYNC]/[O_DSYNC] flag and no
   fsync call anywhere in it --
   unlike [durable_write] above, whose temp file's content is already durable by construction
   before its own [Eio.Path.rename] (every [perform_write] onto that temp file goes through
   [O_DIRECT]+[O_DSYNC], falling back to [O_DSYNC] alone -- see [open_flags_write] above).

   Without this, a crash after [check_or_write_owner_marker]'s [rename] and [fsync_dir] have both
   completed (directory entry durable) but before the temp file's own data blocks reached disk
   could leave the marker holding stale or truncated bytes on recovery, on a filesystem that does
   not order data before metadata (e.g. [data=writeback] mode, or certain overlayfs
   configurations -- see this file's own top comment). Unlike a 0-byte marker, a non-empty-but-
   wrong marker does NOT self-heal (Task 15's own fix only treats an exactly-0-byte marker as
   unclaimed), so a missing fsync here would reintroduce the exact bug class Task 15 exists to
   close, through a narrower window. Same plain-blocking-[Unix] rationale as [fsync_dir] itself: no
   fsync exists on [Eio.Path]/[Eio_linux.Low_level] in the installed Eio 0.12. *)
let fsync_file ~path =
  let fd = Unix.openfile path [ Unix.O_WRONLY ] 0 in
  Fun.protect ~finally:(fun () -> try Unix.close fd with Unix.Unix_error _ -> ()) (fun () -> Unix.fsync fd)

(* [path_for]'s own two shard-directory levels for [path] (i.e. [dir_path/xx] and [dir_path/xx/yy])
   may not exist yet the first time a key under that shard is ever [put] -- this must run before
   [durable_write] below tries to create [path]'s own temp file inside them (Ruling B: the temp
   file lives in the same sharded subdirectory as the final path, so both need these directories to
   already exist). Same try-[mkdir]-then-catch-[Eio.Io] pattern [create]'s own [mkdir] uses (this
   file's top comment explains why: no [mkdir -p] primitive exists in the installed Eio 0.12),
   applied twice, once per level -- outermost first, since the inner [mkdir] would itself fail with
   ENOENT if attempted before the directory it lives in exists.

   {b Critical fix (review finding, post-Task-18): a freshly-created shard directory is itself a
   directory-entry change in its OWN PARENT, and needs the exact same [fsync_dir] treatment
   [durable_write]/[delete] already give their own entry changes -- a crash right after this
   function creates, say, [dir_path/3f] for the very first time, before [dir_path] itself is
   fsynced, can leave that shard directory's own existence unpersisted even though every [put]
   into it afterwards individually fsyncs correctly one level further down.} [Eio.Path.mkdir]
   returning normally (as opposed to raising [Eio.Io] because the directory was already there) is
   exactly the signal that this call changed that parent's entries and therefore needs fsyncing;
   an already-existing shard directory changed nothing, so no extra fsync is needed on the common
   warm-shard path -- fsyncing [dir_path] (or [shard1_dir]) unconditionally on every single [put]
   regardless of whether anything changed there would be real, avoidable I/O cost. This is why the
   two [mkdir] attempts below capture a success/failure boolean via pattern-matching on the call
   itself, rather than being swallowed by a bare [try ... with Eio.Io _ -> ()] the way [create]'s
   own top-level [mkdir] can afford to (nothing downstream of THAT call needs to know whether it
   created [dir_path] or found it already there, since [create] never fsyncs [dir_path]'s own
   parent -- [dir_path]'s parent isn't this module's to manage). *)
let ensure_shard_dirs_exist ~fs path =
  let shard2_dir = Filename.dirname path in
  let shard1_dir = Filename.dirname shard2_dir in
  let dir_path = Filename.dirname shard1_dir in
  let shard1_created =
    match Eio.Path.mkdir ~perm:0o700 Eio.Path.(fs / shard1_dir) with
    | () -> true
    | exception Eio.Io _ -> false
  in
  if shard1_created then fsync_dir ~dir_path;
  let shard2_created =
    match Eio.Path.mkdir ~perm:0o700 Eio.Path.(fs / shard2_dir) with
    | () -> true
    | exception Eio.Io _ -> false
  in
  if shard2_created then fsync_dir ~dir_path:shard1_dir

(* Durably writes [data] to [path] via write-temp-then-rename: header (length + checksum)
   first, then data, into a per-call unique temp file (generated via [tmp_suffix_for_call])
   -- the same "header always written first" ordering [File_storage.wal_append] uses, so a
   crash between the two *temp*-file writes leaves (at worst) a garbage temp file that the
   real [path] never points at -- then a single [Eio.Path.rename] of the temp file onto
   [path] publishes the whole record atomically. Opens the temp file with [creat] so a first
   [put] for a key with no file yet succeeds. Per-call uniqueness ensures concurrent writers
   to the same key never share a temp path (closes audit finding, Task 16).

   The [fsync_dir] after the rename is not optional bookkeeping -- see [fsync_dir]'s own comment
   above for why a durable-content, atomically-renamed file is still not a durable KEY without it,
   and what [Riptide_crypto.Redaction_store] loses if it is missing. {b Fsyncs [Filename.dirname
   path] (the shard2 directory the [rename] actually changed), not [t.dir_path]} -- see
   [fsync_dir]'s own comment for why fsyncing [t.dir_path] itself would durabilize nothing the
   rename actually touched, post-Task-18 sharding. *)
let durable_write t path data =
  if String.length data > max_value_size then
    invalid_arg
      (Printf.sprintf "put: value of %d bytes exceeds this store's max value size of %d bytes"
         (String.length data) max_value_size);
  (* Task 18: [path]'s own two shard-directory levels (see [path_for]) may not exist yet -- ensure
     both before staging the temp file below, since (Ruling B) that temp file lives inside the
     same sharded subdirectory as [path] itself, not at some separately-computed flat location. *)
  ensure_shard_dirs_exist ~fs:t.fs path;
  let tmp_path = path ^ tmp_suffix_for_call () in
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
  fsync_dir ~dir_path:(Filename.dirname path)

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

(* Suffix for the owner marker's own temp file, written by [check_or_write_owner_marker] before
   it atomically [rename]s onto [owner_marker_name] -- the same write-temp-then-rename shape
   [durable_write] above uses for per-key records, applied here to the marker instead. Fixed, not
   randomized, for the following reason: [Dir_lock] (Task 11) already serializes every [create]
   over one [dir_path] by holding an exclusive OS-level [flock(2)] -- see [create]'s own Task 11
   comment. Any second [create] call attempting to acquire [Dir_lock] must wait until the first
   [create]'s own switch closes and [Dir_lock] is released, so there is no actual race for this
   name -- this suffix only needs to survive a crash mid-write, not race a second concurrent
   writer (unlike per-key temp files, which are now randomized per-call via [tmp_suffix_for_call]
   to handle concurrent writers to the SAME key, an internal race that Task 11's [Dir_lock]
   doesn't protect against).

   Just [".tmp"] -- an earlier version of this suffix was [".owner.tmp"], which produced
   [".riptide-kv-owner.owner.tmp"] once appended to [owner_marker_name]: "owner" twice,
   redundantly (Task 15 review, Minor finding M7). *)
let owner_marker_tmp_suffix = ".tmp"

(* Enforces that at most one distinct [owner] tag ever claims [dir_path], across every [create] of
   it for the lifetime of the directory. [owner] is mandatory (see this file's [.mli] on
   [create]'s [~owner]), so every call here has a real tag to check or write.

   Same "try the operation, catch [Eio.Io]" discipline this file's own top comment already
   documents for every other existence check, since the installed Eio 0.12's [Path] has no
   [kind]/[stat] check to test first instead: [Eio.Path.load] on a marker that was never written
   raises [Eio.Io] (confirmed against [path.ml]'s own [load], which opens via [open_in] --
   the same backend open every other existence check in this file already relies on raising
   [Eio.Io] for ENOENT), read here as "no owner has claimed this directory yet, this call is the
   first". [Eio.Path.load]/[Eio.Path.save]/[Eio.Path.rename] are all confirmed real, current
   functions in the installed Eio 0.12 ([path.mli]) -- [save ~create:(`Or_truncate perm)]
   confirmed via [fs.ml]'s own [type create] variant.

   {b Task 15: a 0-byte marker reads back identically to a missing one}, not as a claimed
   [~owner:""]. The OLD scheme wrote the marker via [Eio.Path.save ~create:(`Exclusive 0o600)]
   directly onto [owner_marker_name] -- a create-then-write pair that is not atomic: a crash (or
   kill) between the file's creation and its write completing leaves a real, 0-byte file on disk.
   [Eio.Path.load] on that file succeeds (it exists) and returns [""], which the old code
   compared against [tag] like any other existing marker -- and [""] never equals any real,
   non-empty [tag] (empty tags are themselves rejected at construction, see [create] below), so
   every later [create] of that directory, by anyone, permanently raised the owner-mismatch
   error. There was no code path back out of that state short of manually deleting the marker
   file outside this module entirely.

   The fix: treat "marker exists but its content has zero length" the same as "marker does not
   exist" -- both mean no real claim has actually landed yet, so (re)write [tag] now, exactly as
   the first-ever [create] of a fresh directory would. And write it durably this time: stage
   [tag] in a private temp file first ([owner_marker_tmp_suffix]), [fsync_file] that temp file's
   own content (Task 15 review, Finding 1 -- [Eio.Path.save] alone does no fsync at all, so
   without this the temp file's bytes are not actually durable before the rename that publishes
   them), then [Eio.Path.rename] the temp file onto [owner_marker_name] in one atomic step, then
   fsync the directory (matching [durable_write]'s own reasoning above for why the rename's
   directory-entry update needs its own fsync, not just the file's data) -- so a crash during THIS
   write can, at worst, leave behind an ignorable stray temp file or reproduce the same
   self-healing 0-byte-or-missing state again, never a half-written marker holding a truncated,
   wrong tag. *)
let check_or_write_owner_marker ~fs ~dir_path tag =
  let marker_path = Eio.Path.(fs / dir_path / owner_marker_name) in
  let existing =
    match Eio.Path.load marker_path with existing -> Some existing | exception Eio.Io _ -> None
  in
  match existing with
  | Some existing when String.length existing > 0 ->
    if not (String.equal existing tag) then
      invalid_arg
        (Printf.sprintf "File_kv_store.create: %s is owned by %S, not %S" dir_path existing tag)
  | Some _ (* a 0-byte marker: a crash left this behind, treat it like [None] below *) | None ->
    let tmp_path_str = Filename.concat dir_path (owner_marker_name ^ owner_marker_tmp_suffix) in
    let tmp_path = Eio.Path.(fs / tmp_path_str) in
    Eio.Path.save ~create:(`Or_truncate 0o600) tmp_path tag;
    fsync_file ~path:tmp_path_str;
    Eio.Path.rename tmp_path marker_path;
    fsync_dir ~dir_path

(* Task 16: sweep stale temporary files from a crashed/interrupted [put] that leave behind
   files named [.put.<pid>.<counter>.tmp] (from [tmp_suffix_for_call]). This cleanup runs at
   [create] time, AFTER [Dir_lock.acquire] succeeds, so any temp file sitting in [dir_path]
   at that point cannot belong to any still-live writer -- a live writer's own [create] call
   would already be holding the lock. This is why we can unlink unconditionally: we have
   exclusive access and no other writer can be using this directory.

   This solves the unbounded crash-debris accumulation that the per-call unique suffix
   introduced (Task 16 Important 2): before the fix, a crash left at most one [.put.tmp]
   file per key, self-bounded by reuse (same deterministic name on next put). After the
   fix, each crash leaves a file with a name that will never be generated again (pid+counter
   pair is global), so nothing would ever clean it up without an explicit sweep.

   {b Task 18 (Ruling B): walks two levels of shard subdirectories, not just the top level.}
   [path_for]'s sharding moved every per-key file -- and therefore every per-key temp file too,
   since the temp path is [path_for]'s own result plus a suffix (see this file's top comment) --
   from [dir_path] itself into [dir_path/xx/yy]. A sweep that only scanned [dir_path]'s own top
   level would silently stop finding any of them, quietly reopening the exact crash-debris
   accumulation this task exists to prevent. The top level now holds only the owner marker, the
   lock file, and the shard-1 directories themselves (never a per-key file or temp file directly),
   so this still needs to descend two levels down to find real leaves.

   {b Distinguishing a shard directory from a leaf file without [Eio.Path.kind]/[stat]:} the
   installed Eio 0.12 has neither (this file's top comment already documents this gap and its
   general fix, "try the operation, catch [Eio.Io]", for every other existence check in this
   module) -- so here too, rather than trying to recognize shard-directory names as a special
   case, every entry at every level is discriminated by attempting [Eio.Path.read_dir] on it:
   success means it really is a directory (POSIX's own [opendir] on a non-directory reliably
   raises ENOTDIR, so this is a sound discriminator, not a heuristic), in which case it is
   recursed into one more level; [Eio.Io] means it is a leaf, to be checked against
   [is_stale_temp_file] and unlinked if it matches, exactly as the flat top-level scan always did.
   This also means a stray leaf-level temp file directly at the top level (impossible for
   [durable_write] to produce under the current, always-sharded [path_for], but a cheap safety net
   against exactly this file's own kind of change) is still found and swept, not silently
   skipped because it happens to sit above where the walk expects a leaf. *)
let sweep_stale_temp_files ~fs ~dir_path =
  (* Match stale temp files: the pattern used by [durable_write] is [key_path].put.[pid].[counter].tmp.
     Distinguish from real key files (exactly 64 lowercase hex, no ".put."), the owner marker
     (starts with ".riptide-kv-"), the lock file (".riptide-lock"), and shard directories (exactly
     2 lowercase hex characters, no ".put." either). *)
  let contains_substring haystack needle =
    let nl = String.length needle and hl = String.length haystack in
    let rec go i = i + nl <= hl && (String.sub haystack i nl = needle || go (i + 1)) in
    nl = 0 || go 0
  in
  let is_stale_temp_file basename =
    (* Must contain ".put." and end with ".tmp" -- these patterns uniquely identify temp files. *)
    contains_substring basename ".put." &&
    String.length basename > 4 && String.sub basename (String.length basename - 4) 4 = ".tmp"
  in
  let unlink_leaf_if_stale path_str basename =
    if is_stale_temp_file basename then
      try Eio.Path.unlink Eio.Path.(fs / path_str)
      with Eio.Io _ -> () (* Ignore errors: file already gone, or already handled by concurrent create *)
  in
  (* Applies [unlink_leaf_if_stale] to every entry of [dir_str], which the caller has already
     confirmed (by successfully [read_dir]-ing it) really is a directory of leaf files -- used
     both for the deepest (shard-2) level and, defensively, for anything found one level too
     shallow (see the top comment above). *)
  let sweep_leaf_dir dir_str entries =
    List.iter (fun basename -> unlink_leaf_if_stale (Filename.concat dir_str basename) basename) entries
  in
  (* One entry at [dir_path]'s own top level: either a shard-1 directory (descend one more level)
     or a leaf (top-level owner marker/lock file, or -- defensively -- a stray temp file). *)
  let visit_top_level_entry top_basename =
    let top_path_str = Filename.concat dir_path top_basename in
    match Eio.Path.read_dir Eio.Path.(fs / top_path_str) with
    | shard1_entries ->
      List.iter
        (fun shard1_basename ->
          let shard1_path_str = Filename.concat top_path_str shard1_basename in
          match Eio.Path.read_dir Eio.Path.(fs / shard1_path_str) with
          | shard2_entries -> sweep_leaf_dir shard1_path_str shard2_entries
          | exception Eio.Io _ -> unlink_leaf_if_stale shard1_path_str shard1_basename)
        shard1_entries
    | exception Eio.Io _ -> unlink_leaf_if_stale top_path_str top_basename
  in
  try List.iter visit_top_level_entry (Eio.Path.read_dir Eio.Path.(fs / dir_path))
  with Eio.Io _ -> () (* Directory doesn't exist yet or can't be read; that's fine *)

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
  let lock =
    Dir_lock.acquire ~sw ~caller:"File_kv_store.create"
      ~describe_conflict:(fun () ->
        (* Review finding M3: fold the conflicting handle's own owner tag into the lock's error
           message when it's already sitting right there on disk -- this is precisely the most
           likely real misuse (a keystore and a materializer both accidentally pointed at one
           directory), so restoring this diagnosability matters. Reading the marker here, on the
           failure path only, does not weaken "reject before touching anything else this module
           manages": [acquire] is already about to raise, there is nothing left to protect by not
           reading it.

           Task 15 review, Minor finding M4: a 0-byte marker (the same "crash left an empty file
           behind" case [check_or_write_owner_marker] itself now self-heals from) must not be
           reported here as a real claim by the empty-string owner -- map it to [None] ("no owner
           readable yet") too, for consistency with that rule, even though this is purely a
           diagnostic message and does not change the lock decision itself. *)
        match Eio.Path.load Eio.Path.(fs / dir_path / owner_marker_name) with
        | "" -> None
        | existing -> Some existing
        | exception Eio.Io _ -> None)
      dir_path
  in
  (* Task 11 review (finding I1, and re-review finding 1): the lock's lifetime must track the
     SUCCESSFULLY CONSTRUCTED handle's, not the "flock succeeded" attempt's -- and that means
     EVERY step between [Dir_lock.acquire] succeeding and [t] actually being returned has to sit
     inside this same guarded scrutinee, not just [check_or_write_owner_marker]. The I1 fix's
     first cut only wrapped the owner-marker check and left [Aligned_buffer_pool.create] (a real
     mmap-backed allocation that does genuine syscalls per pooled buffer, and can genuinely raise
     under fd/disk/memory pressure) sitting in the success branch's own body, OUTSIDE the
     [exception exn -> ...] handler's reach -- in a [match e with | pat -> body | exception exn ->
     handler] expression, [exception exn] only catches exceptions raised while evaluating [e]
     itself, never ones raised while evaluating [body]. A live-reproduced RED/GREEN check
     confirmed this: injecting a failure at the (then-unwrapped) pool-creation call reproduced the
     EXACT SAME bug I1 was meant to fix -- a subsequent, entirely legitimate [create] over the same
     directory in the same switch got spuriously refused with "already locked by another open
     handle". Folding both [check_or_write_owner_marker] AND the pool allocation AND the final
     record construction into ONE scrutinee (mirroring [file_storage.ml]'s own [create], whose
     analogous fix already covers its entire post-lock body this same way) closes that gap: ANY
     exception anywhere in this block now goes through the same [exception exn -> ...] handler
     below. See [test_a_failed_create_releases_its_lock_before_reraising] below for the
     owner-tag-mismatch-shaped RED/GREEN evidence this fix already had; the pool-creation-shaped
     RED/GREEN check for this specific gap was done manually (temporarily forcing pool creation to
     fail, confirming the leak, restoring) rather than left as a permanent test, since
     [Aligned_buffer_pool.create]'s buffer count/slot size aren't parameters a test can control
     from this module's own public surface -- see this task's own review-round-2 report for the
     exact commands and output. Task 16 re-review (Important finding): [sweep_stale_temp_files]
     moved inside this same scrutinee to inherit the lock-release guarantee structurally. *)
  match
    (* Task 16: sweep any stale temp files left behind by crashed writers, now that we hold the
       exclusive [flock(2)]. This runs as the first statement inside the protected scrutinee,
       before the owner-marker check, to ensure any exception raised by the sweep is caught by
       the [exception exn -> ...] handler below and the lock is properly closed. *)
    sweep_stale_temp_files ~fs ~dir_path;
    check_or_write_owner_marker ~fs ~dir_path owner;
    let pool =
      Aligned_buffer_pool.create ~dir_path ~buffer_count:pool_size ~slot_size:slot_alignment ()
    in
    { sw; lock; fs; dir_path; owner; pool }
  with
  | t -> t
  | exception exn ->
    let bt = Printexc.get_raw_backtrace () in
    Eio_unix.Fd.close lock;
    Printexc.raise_with_backtrace exn bt

(* [check_or_write_owner_marker] above either confirms [owner] against the existing on-disk marker
   or writes a fresh one holding exactly [owner] -- it never resolves or hands back a tag of its
   own. So by the time [create] returns without raising, [owner] (the caller-supplied argument
   itself) IS what the marker file now holds: [t.owner] below is that same argument, not a re-read
   of the marker, but the two are guaranteed to agree. *)
let owner t = t.owner

let get t ~key = durable_read t (path_for t ~key)
let put t ~key data = durable_write t (path_for t ~key) data

let delete t ~key =
  let path = path_for t ~key in
  (try Eio.Path.unlink Eio.Path.(t.fs / path) with
  | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) ->
    () (* ENOENT: already absent, matching put's own idempotent-overwrite spirit *));
  (* Fsyncs [Filename.dirname path] (the shard2 directory the [unlink] actually changed), not
     [t.dir_path] -- see [fsync_dir]'s own comment (Critical fix, post-Task-18 review) for why
     fsyncing [t.dir_path] itself would durabilize nothing this [unlink] actually touched. *)
  fsync_dir ~dir_path:(Filename.dirname path)

(* Task 24: the read counterpart [fold] below's own contract requires. [fold] can only ever hand
   its callback this store's OWN internal identifier (the content-hash filename -- see
   [Kv_store_intf.S.fold]'s doc comment for the full reasoning), never a caller's original [put]
   key, since that original string is never itself persisted. [get] cannot be reused to read such a
   value back: [get t ~key:hash] would hash [hash] a SECOND time via [path_for] and look for a file
   at [path_from_hash t (hash_of hash)] -- an entirely different, essentially never-existing
   location, not [path_from_hash t hash] itself. [get_by_hash] is the direct counterpart: it treats
   its argument as an already-computed internal identifier, builds the record's path straight from
   it via [path_from_hash], and never re-hashes. *)
let get_by_hash t ~hash = durable_read t (path_from_hash t hash)

(* [Kv_store_intf.S.fold]: walks the sharded (Task 18) two-level directory tree, applying [f] to
   every real per-key record file it finds -- see [kv_store_intf.mli]'s own [fold] doc for what
   [key] actually is here (this store's own internal identifier, i.e. exactly the 64-lowercase-hex
   filename [path_for]/[path_from_hash] use, never the original caller-supplied key, which this
   backend never persists in the clear).

   Reuses [sweep_stale_temp_files]'s own directory-vs-leaf discrimination technique verbatim
   (successfully [Eio.Path.read_dir]-ing an entry is a sound directory test, since the installed
   Eio 0.12 exposes no [kind]/[stat] to check first instead -- see this file's top comment) --
   applied here to VISIT every real leaf, rather than to unlink some of them.

   A leaf is only ever passed to [f] if its own basename is exactly the 64-lowercase-hex-character
   shape [path_for]'s [hash_to_hex] output always has ([is_real_key_filename] below) -- this
   excludes the owner marker ([owner_marker_name], which starts with a dot), the lock file
   ([".riptide-lock"]), and any stray [*.put.*.tmp] crash-debris file [is_stale_temp_file] would
   also recognize: none of those names can ever collide with 64 lowercase hex characters. No claim
   about visitation ORDER is made or relied on here, matching [kv_store_intf.mli]'s own [fold] doc
   exactly: [Eio.Path.read_dir]'s own ordering is unspecified. *)
let is_lowercase_hex_char c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')

let is_real_key_filename basename =
  String.length basename = 64
  &&
  let ok = ref true in
  String.iter (fun c -> if not (is_lowercase_hex_char c) then ok := false) basename;
  !ok

let fold t ~init f =
  let visit_leaf_dir entries acc =
    List.fold_left
      (fun acc basename -> if is_real_key_filename basename then f ~key:basename acc else acc)
      acc entries
  in
  let visit_top_level_entry acc top_basename =
    let top_path_str = Filename.concat t.dir_path top_basename in
    match Eio.Path.read_dir Eio.Path.(t.fs / top_path_str) with
    | shard1_entries ->
      List.fold_left
        (fun acc shard1_basename ->
          let shard1_path_str = Filename.concat top_path_str shard1_basename in
          match Eio.Path.read_dir Eio.Path.(t.fs / shard1_path_str) with
          | shard2_entries -> visit_leaf_dir shard2_entries acc
          | exception Eio.Io _ ->
            (* Defensive, mirroring [sweep_stale_temp_files]'s own top comment: a leaf found one
               level too shallow. Can't happen for anything [durable_write] itself produces under
               the current, always-sharded [path_for], but a real key file found here would still
               need visiting rather than being silently skipped just because of where it sits. *)
            if is_real_key_filename shard1_basename then f ~key:shard1_basename acc else acc)
        acc shard1_entries
    | exception Eio.Io _ ->
      (* A top-level leaf: the owner marker, the lock file, or -- defensively -- a stray file.
         Never a real key file: [path_for] always shards two levels deep, so a genuine per-key
         record can never live directly at [t.dir_path]'s own top level. *)
      if is_real_key_filename top_basename then f ~key:top_basename acc else acc
  in
  match Eio.Path.read_dir Eio.Path.(t.fs / t.dir_path) with
  | top_entries -> List.fold_left visit_top_level_entry init top_entries
  | exception Eio.Io _ -> init (* directory doesn't exist yet -- nothing to fold over *)
