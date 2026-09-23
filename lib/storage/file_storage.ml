(* One WAL entry per file, named by op-number -- Task 2 replaces this with the real fixed-size
   ring; this task only needs to prove the durable-write-then-read-after-restart primitive itself
   works against the real installed [eio_linux]. No directory file descriptor is needed:
   [Eio_linux.Low_level.openat2] accepts a full path with [?dir] omitted (an absolute-style path
   resolves on its own, the same as passing no [dirfd] to POSIX [openat]), so directory handling
   stays on the portable [Eio.Path] API and only individual entry files go through the low-level
   [io_uring] path.

   {b Real behaviors confirmed live against this box's actual installed [eio_linux v0.12]/[uring
   v2.7.0], on both ext4 ([/work]) and overlayfs ([/tmp]) -- none obvious from the [.mli]s alone.
   See this plan's Task 1 report for the full experiment trail:}

   - {b [O_DIRECT] dropped; [O_DSYNC] alone is what this module actually opens WAL entry files
     with.} A first version of this module used [O_DIRECT]+[O_DSYNC], per this task's own brief.
     [O_DIRECT] enforces the standard Linux rule that a transfer's length (and offset, and memory
     buffer address) be a multiple of the filesystem's logical block size (512 bytes here) --
     already enough to make the brief's own sketch fail every real test payload (none are
     512-byte multiples) -- but padding around that wasn't the real blocker. The actual blocker:
     writes through [eio_linux]'s shared fixed-buffer pool (the only buffer [Low_level.write]
     accepts) were {e intermittently} rejected with [EINVAL] -- same code, same payload, same
     file, sometimes fails, sometimes doesn't, at roughly a 40-60% failure rate once this test
     suite's full binary (not a small standalone repro) was doing the writing. That pattern
     -- correctness that depends on the surrounding binary/process, not just the code -- matches
     [O_DIRECT]'s memory-buffer alignment requirement (typically page-granularity) landing on a
     Bigarray whose actual base-pointer alignment [eio_linux] does not itself guarantee: whether
     the shared 256KB fixed buffer happens to land at a page-aligned address depends on allocator
     behavior outside this module's control (and, empirically, on what else is linked into and
     has already allocated inside the same process). [O_DIRECT] is a bypass-the-page-cache
     {e performance} optimization, not a requirement for the durability [Storage.S] actually
     promises: [O_DSYNC] alone already guarantees a [write] does not return until the data (and
     any metadata needed to retrieve it) has reached stable storage -- POSIX's definition of
     synchronized I/O data integrity completion -- with no alignment requirement on length,
     offset, or buffer address at all. Dropping [O_DIRECT] and keeping only [O_DSYNC] made the
     flakiness disappear entirely across dozens of repeated full-suite runs (see the report), so
     that is what ships here. A later task revisiting this for performance (bypassing the page
     cache on the hot write path) would need to either pin down why [eio_linux]'s fixed-buffer
     allocation isn't reliably page-aligned on this box, or hand [O_DIRECT] a buffer this code
     allocates and aligns itself instead of relying on the shared pool.
   - [Eio_linux.Low_level.openat2]'s [~perm] argument is passed straight through to the real
     Linux [openat2(2)] syscall, which -- unlike the legacy [open(2)] -- is strict about it:
     [openat2(2)] returns [EINVAL] if [how.mode <> 0] while neither [O_CREAT] nor [O_TMPFILE] is
     set in [how.flags]. Opening an existing entry for reading (no [creat] flag) with a nonzero
     [~perm] therefore fails outright -- which a broad [Eio.Io _ -> None] catch (matching this
     module's documented "no entry / corrupt entry" collapse) would otherwise silently misreport
     as "nothing was ever written here" even for an entry that exists and was written
     successfully. Read opens below always pass [~perm:0] for exactly this reason.
   - The installed Eio 0.12's [Eio.Path] has no [kind]/[stat]-on-a-path existence check (only
     [File.stat] on an already-{e open} file), so {!create} cannot check-then-create a directory
     the way an initial sketch assumed. It instead just attempts [Eio.Path.mkdir] and ignores the
     [Eio.Io] ([EEXIST]) that raises when [dir_path] already exists.
   - A zero-length transfer is mishandled in both directions by this [eio_linux] version:
     [Eio_linux.Low_level.write fd chunk 0] raises [End_of_file] (confirmed deterministic,
     independent of file offset) instead of succeeding as the true no-op a POSIX [write(2)] of
     zero bytes is; symmetrically, [read_upto] on a real, existing, genuinely-empty file also
     raises [End_of_file] instead of returning [0]. {!durable_write} skips the [write] call
     entirely for an empty entry (the preceding [openat2] with [creat] already created the file
     with the right, empty content), and {!durable_read} catches the read side's [End_of_file]
     and treats it as the empty string -- safe to do there specifically because it only runs
     after [openat2] has already confirmed the entry exists, so [End_of_file] at that point can
     only mean "zero bytes", never "missing". *)

type t = {
  sw : Eio.Switch.t;
  dir_path : string;
  mutable highest_op_number : int;
}

let open_flags_write = Uring.Open_flags.(dsync + creat)
let open_flags_read = Uring.Open_flags.empty

(* Every entry file is named [entry_prefix ^ "%010d"] (the op-number, zero-padded) -- used both
   to build a specific entry's path ({!entry_path}) and, in {!create}, to recover
   [highest_op_number] from whatever is already on disk when reopening an existing directory
   after a restart: nothing else records that number durably in this task's minimal per-file
   layout, so it must be re-derived from the directory listing itself every time. *)
let entry_prefix = "wal-"

let op_number_of_entry_name name =
  let prefix_len = String.length entry_prefix in
  if String.length name > prefix_len && String.sub name 0 prefix_len = entry_prefix then
    int_of_string_opt (String.sub name prefix_len (String.length name - prefix_len))
  else None

let create ~sw ~fs dir_path =
  (try Eio.Path.mkdir ~perm:0o700 Eio.Path.(fs / dir_path) with Eio.Io _ -> ());
  let highest_op_number =
    Eio.Path.read_dir Eio.Path.(fs / dir_path)
    |> List.filter_map op_number_of_entry_name
    |> List.fold_left max 0
  in
  { sw; dir_path; highest_op_number }

let entry_path t ~op_number = Printf.sprintf "%s/%s%010d" t.dir_path entry_prefix op_number

let durable_write t path (data : string) =
  let fd =
    Eio_linux.Low_level.openat2 ~sw:t.sw ~seekable:true ~access:`RW ~flags:open_flags_write
      ~perm:0o600 ~resolve:Uring.Resolve.empty path
  in
  Fun.protect
    ~finally:(fun () -> ignore (Eio_unix.Fd.close fd))
    (fun () ->
      let len = String.length data in
      (* [Eio_linux.Low_level.write]'s zero-length case raises [End_of_file] rather than
         succeeding as a no-op (confirmed live, deterministic, independent of file offset -- see
         this file's own top comment). A zero-byte entry needs no write() at all: [openat2] with
         [creat] above already created the file with exactly the right (empty) content by the
         time it returned, so just skip straight to a no-op here instead of calling into the
         buggy zero-length path. *)
      if len = 0 then ()
      else begin
        let chunk = Eio_linux.Low_level.alloc_fixed_or_wait () in
        Fun.protect
          ~finally:(fun () -> Eio_linux.Low_level.free_fixed chunk)
          (fun () ->
            let chunk_len = Uring.Region.length chunk in
            if len > chunk_len then
              invalid_arg
                (Printf.sprintf
                   "wal_append: entry of %d bytes exceeds this primitive's max entry size of %d \
                    bytes (one fixed-buffer chunk)"
                   len chunk_len);
            let cs = Uring.Region.to_cstruct chunk in
            Cstruct.blit_from_string data 0 cs 0 len;
            Eio_linux.Low_level.write fd chunk len)
      end)

let durable_read t path =
  match
    (* [~perm:0]: see this file's own top comment -- a nonzero mode on a non-[creat] open fails
       real [openat2(2)] with [EINVAL], not the [ENOENT] a caller might expect here. *)
    Eio_linux.Low_level.openat2 ~sw:t.sw ~seekable:true ~access:`R ~flags:open_flags_read ~perm:0
      ~resolve:Uring.Resolve.empty path
  with
  | exception Eio.Io _ -> None (* ENOENT: nothing was ever written at this path *)
  | fd ->
    Fun.protect
      ~finally:(fun () -> ignore (Eio_unix.Fd.close fd))
      (fun () ->
        let chunk = Eio_linux.Low_level.alloc_fixed_or_wait () in
        Fun.protect
          ~finally:(fun () -> Eio_linux.Low_level.free_fixed chunk)
          (fun () ->
            (* [read_upto] raises [End_of_file] for a genuinely empty file rather than returning
               [0] (confirmed live -- the mirror image of {!durable_write}'s zero-length [write]
               quirk noted in this file's own top comment). The [openat2] above already succeeded,
               so the entry does exist; [End_of_file] here unambiguously means "zero bytes were
               written", i.e. the empty string, not "missing". *)
            match Eio_linux.Low_level.read_upto fd chunk (Uring.Region.length chunk) with
            | exception End_of_file -> Some ""
            | n -> Some (Uring.Region.to_string ~len:n chunk)))

let wal_append t ~op_number data =
  if op_number <> t.highest_op_number + 1 then
    invalid_arg
      (Printf.sprintf "wal_append: op_number %d is not wal_highest_op_number t + 1" op_number)
  else begin
    durable_write t (entry_path t ~op_number) data;
    t.highest_op_number <- op_number
  end

let wal_read t ~op_number =
  if op_number < 1 || op_number > t.highest_op_number then None
  else durable_read t (entry_path t ~op_number)

let wal_highest_op_number t = t.highest_op_number
let wal_truncate_after (_ : t) ~op_number:(_ : int) = failwith "not implemented until Task 2"
let superblock_write (_ : t) (_ : string) = failwith "not implemented until Task 3"
let superblock_read (_ : t) = failwith "not implemented until Task 3"
