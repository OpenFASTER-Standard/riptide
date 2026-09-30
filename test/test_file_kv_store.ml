(* Regression coverage for [Riptide_storage.File_kv_store] -- a durable, keyed store with real
   per-key deletion (Task 2 of the lattice-materialization-redaction-encryption plan). Distinct
   from [Test_file_storage]'s bounded-ring-WAL conformance suite: this store has no notion of
   op_number/ring capacity at all, just an arbitrary number of independently-deletable keys, one
   file per key. Real file I/O via [Eio_main.run] against a real temp directory -- same rationale
   as [Test_file_storage]: there is no mock filesystem layer to substitute for proving durability
   across a real reopen.

   {b No dedicated test for [delete]'s narrowed [Eio.Fs.Not_found]-only catch}: constructing a
   real, reliable non-ENOENT failure (e.g. permission denied) requires an operation the test
   process's own privileges actually reject, and this suite runs as root in its CI/dev
   environment -- confirmed live that [chmod 000] on a directory does not stop root from
   unlinking inside it (Linux's [CAP_DAC_OVERRIDE]), so no clean seam exists here to simulate
   "delete fails for a real reason other than ENOENT". The fix itself
   ([Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _)] instead of a blanket [Eio.Io _], matching the
   real shape [eio_linux]'s own [wrap_fs] produces for ENOENT, confirmed against
   [lib_eio_linux/err.ml]) is still exercised on every run by
   [test_delete_is_durable_across_reopen] and [test_get_of_never_put_key_is_none] continuing to
   pass -- both depend on the ENOENT case itself still being caught correctly. *)

open Riptide_storage

let with_tmp_dir f =
  let dir = Filename.temp_file "riptide_kv_test" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o700;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () -> f dir)

(* Task 10 regression, transcribed from [test_file_storage.ml]'s own (see that file's comment
   for the full rationale): counts this process's own [/proc/self/maps] lines, matching the
   audit's own measurement method for the [alloc_aligned_buffer]-per-I/O VMA leak. *)
let count_self_maps () =
  let ic = open_in "/proc/self/maps" in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () ->
      let n = ref 0 in
      (try
         while true do
           ignore (input_line ic);
           incr n
         done
       with End_of_file -> ());
      !n)

(* Task 10: the [File_kv_store] half of the same regression -- put+get cycles (against a
   single key, reused every iteration, so this measures the per-call buffer lifecycle rather than
   directory growth) against a real [File_kv_store], asserting the map count stays flat rather
   than growing ~4 VMAs per op the way the per-I/O-[mmap] implementation this task replaces did.

   {b [op_count] is 1,000, smaller than [Test_file_storage]'s own 3,000} (see that file's own
   comment on its [op_count] for the full "why not the audit's 20,000" rationale, which applies
   here too) -- this store's [put] does substantially more per call than a bare WAL append
   (open, write header, write data, [rename], then a real directory [fsync]), measured (a
   standalone probe against this exact fixed implementation) at ~185 cycles/s, roughly a third
   of [File_storage]'s own rate. 1,000 cycles (~5.5s at the measured rate) keeps this well
   inside this suite's 15s per-test watchdog with a wide safety margin, while remaining
   massively larger than the ~25 cycles it would take the pre-fix implementation to blow past
   the [< 100] map-growth threshold below.

   {b RED/GREEN evidence, actually observed against these exact 1,000 ops (Task 10 review,
   Finding 1)} -- same methodology as [Test_file_storage]'s own equivalent comment: temporarily
   reverted [file_kv_store.ml]'s [perform_write_from_string]/[perform_read] to call a fresh
   per-I/O [mmap] directly (bypassing {!Riptide_storage.Aligned_buffer_pool}, mirroring the
   pre-Task-10 implementation), then ran this exact test, unmodified, both ways:
   - {b RED} (reverted to per-I/O [mmap]): FAILED via the assertion itself, in 6.55s (well inside
     the 15s watchdog) -- [before=46 after=2598 delta=2552], nowhere close to the [< 100]
     threshold below.
   - {b GREEN} (the real, committed buffer-pool implementation): [before=46 after=46 delta=0] --
     not merely "under 100", genuinely flat. *)
let op_count = 1_000

let test_repeated_io_does_not_grow_the_process_map_count () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"test" dir in
      let before = count_self_maps () in
      for i = 1 to op_count do
        File_kv_store.put t ~key:"k" (Printf.sprintf "task 10 regression entry %d" i);
        ignore (File_kv_store.get t ~key:"k")
      done;
      let after = count_self_maps () in
      Alcotest.(check bool)
        (Printf.sprintf
           "map count stays flat, not linear in op count (before=%d after=%d delta=%d)" before
           after (after - before))
        true (after - before < 100))

let test_put_then_get () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"test" dir in
      File_kv_store.put t ~key:"foo" "bar";
      Alcotest.(check (option string)) "read back" (Some "bar") (File_kv_store.get t ~key:"foo"))

let test_get_of_never_put_key_is_none () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"test" dir in
      Alcotest.(check (option string)) "never put" None (File_kv_store.get t ~key:"nope"))

let test_delete_is_durable_across_reopen () =
  (* Review Focus: this is the exact bug class already found once in
     File_storage.wal_truncate_after -- prove it doesn't recur here. *)
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      (Eio.Switch.run @@ fun sw ->
       let t = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"test" dir in
       File_kv_store.put t ~key:"secret" "shhh";
       File_kv_store.delete t ~key:"secret");
      Eio.Switch.run @@ fun sw ->
      let t2 = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"test" dir in
      Alcotest.(check (option string)) "deleted key stays gone after reopen" None
        (File_kv_store.get t2 ~key:"secret"))

let test_put_overwrites () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"test" dir in
      File_kv_store.put t ~key:"k" "v1";
      File_kv_store.put t ~key:"k" "v2";
      Alcotest.(check (option string)) "overwritten" (Some "v2") (File_kv_store.get t ~key:"k"))

(* -- Finding 1: [put]'s overwrite must be crash-atomic (write-temp-then-rename), not an
   in-place header-then-data overwrite. [File_kv_store.mli] exposes no way to see the on-disk
   temp-file layout. Task 16 changed [tmp_suffix] from a fixed constant to a per-call dynamic
   value ([pid + atomic counter]), so the temp-file test helpers below are updated to work with
   that pattern: any file matching the pattern [*\.put\.\d+\.\d+\.tmp$] is a temp file. *)
let key_hash_hex key =
  Riptide.Value.hash_to_hex
    (Riptide.Value.content_hash (Riptide.Value.Scalar (Riptide.Value.String key)))

(* Task 18: [path_for] shards every key's file two directory levels deep
   ([dir/xx/yy/<hash>], [xx]/[yy] being [hash]'s first 4 hex characters) instead of placing it
   flat in [dir]. [path_for] itself is private (not exposed by [file_kv_store.mli]), so this
   recomputes the expected location from the same public [Riptide.Value.hash_to_hex
   (Riptide.Value.content_hash ...)] primitive [path_for] itself uses, rather than reaching into
   the module's internals. *)
let real_path_for dir key =
  let hash = key_hash_hex key in
  Filename.concat dir
    (Filename.concat (String.sub hash 0 2) (Filename.concat (String.sub hash 2 2) hash))

let contains ~needle haystack =
  let nl = String.length needle and hl = String.length haystack in
  let rec go i = i + nl <= hl && (String.sub haystack i nl = needle || go (i + 1)) in
  nl = 0 || go 0

(* Match any temp file for a key: the pattern is [keypath].put.[pid].[counter].tmp *)
let is_temp_file_for path =
  let basename = Filename.basename path in
  (* Check if the filename ends with .tmp and contains .put. *)
  String.length basename > 4 && String.sub basename (String.length basename - 4) 4 = ".tmp" &&
  contains ~needle:".put." basename

(* Find any temp files anywhere under [dir], however deeply nested -- Task 18 moved per-key temp
   files two shard levels down, so this walks real subdirectories recursively (using plain
   [Sys.is_directory], not [file_kv_store.ml]'s own Eio-based, kind-less-Eio-0.12 discrimination
   trick, since this is test code operating through the OS directly rather than through Eio) instead
   of assuming a flat top level the way this helper used to. *)
let find_temp_files_in_dir dir =
  let rec walk dir =
    try
      Array.to_list (Sys.readdir dir)
      |> List.concat_map (fun basename ->
             let path = Filename.concat dir basename in
             if Sys.is_directory path then walk path
             else if is_temp_file_for path then [ path ]
             else [])
    with Sys_error _ -> []
  in
  walk dir

let test_put_overwrite_leaves_no_leftover_tmp_file () =
  (* Review Focus: a successful overwrite's staged temp file must be gone (renamed away, not
     merely written and left behind) once [put] returns, and the real path must hold exactly
     the new value -- the normal-path half of the atomic-overwrite fix. Task 16: with dynamic
     per-call suffixes, we verify no .put.*.*.tmp files are left behind, rather than checking
     for a specific fixed filename. *)
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"test" dir in
      File_kv_store.put t ~key:"k" "v1";
      File_kv_store.put t ~key:"k" "v2";
      let temp_files = find_temp_files_in_dir dir in
      Alcotest.(check bool) "no leftover temp files after rename" false
        (List.length temp_files > 0);
      Alcotest.(check bool) "real file exists" true (Sys.file_exists (real_path_for dir "k"));
      Alcotest.(check (option string)) "real file holds exactly the new value" (Some "v2")
        (File_kv_store.get t ~key:"k"))

let test_interrupted_overwrite_leaves_old_value_intact () =
  (* Task 16: stale temp files from crashes are automatically swept at [create] time, so this
     test verifies that behavior: create a stale .put.*.tmp file before opening a handle, then
     confirm the handle's creation sweeps it away (and any real key's data stays intact). *)
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      (Eio.Switch.run @@ fun sw ->
       let t = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"test" dir in
       File_kv_store.put t ~key:"k" "original");
      (* After the first handle closes, create a stale temp file to simulate crash debris. *)
      let stale_tmp_path = Filename.concat dir (key_hash_hex "k" ^ ".put.99999.99999.tmp") in
      let oc = open_out_bin stale_tmp_path in
      output_string oc "garbage-partial-write-left-by-a-simulated-crash";
      close_out oc;
      Alcotest.(check bool) "stale temp file exists before create" true
        (Sys.file_exists stale_tmp_path);
      (Eio.Switch.run @@ fun sw ->
       (* Opening a new handle triggers create-time sweep, which removes the stale file. *)
       let t2 = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"test" dir in
       Alcotest.(check bool) "stale temp file was swept away during create" false
         (Sys.file_exists stale_tmp_path);
       (* Real key's data survives intact. *)
       Alcotest.(check (option string)) "original value still readable after sweep" (Some "original")
         (File_kv_store.get t2 ~key:"k")))

(* -- Final-review Finding 1: [put] must make the renamed directory ENTRY durable, not just the
   temp file's content, by fsyncing the containing directory after the rename -- exactly as
   [delete] already does after its [unlink].

   {b What is and is not observable here, stated plainly, because it determines the shape of these
   two tests.} A directory fsync has no userspace-visible effect on a machine that does not actually
   lose power: the page cache serves the same bytes either way, so no amount of reopening,
   restatting, or re-reading can distinguish "synced" from "not synced". Confirmed on this box that
   none of the usual escape hatches exist either: no [strace]/[ltrace]/[gdb] installed,
   [/proc/sys/kernel/yama/ptrace_scope] is [1] (so a self-attaching tracer is out), and the process
   lacks [CAP_SYS_ADMIN], which [fanotify]'s open-event reporting would need; there is no [inotify]
   binding in this switch, and an [LD_PRELOAD] interposition shim would mean adding C stubs to this
   test suite (a real risk in this environment, where [CC] is globally an [sccache] wrapper that
   breaks naive C compilation -- see the box's own notes). [atime] is no help either: opening a
   directory without reading it does not update it.

   So the coverage is deliberately two-part, and the second part is the one that actually fails if
   the fix is reverted:

   1. [test_put_is_durable_across_reopen] mirrors [test_delete_is_durable_across_reopen] above --
      which is, on inspection, exactly and only how [delete]'s own [fsync_dir] is covered today.
      It proves the value survives a real close-and-reopen; it does NOT prove the sync happened.
   2. [test_durable_write_and_delete_fsync_the_shard_directory_not_dir_path] is a source-level
      guard on the two call sites
      themselves, and is honest about being one. It fails loudly if the [fsync_dir] call after
      [durable_write]'s [Eio.Path.rename] (or [delete]'s, for symmetry) is ever removed or
      reordered -- which is the actual regression to prevent, since the bug being fixed was a
      missing call, not a subtly wrong one. [test_golden.ml] already establishes the
      read-a-source-file-declared-as-a-dune-dep pattern used here. *)
let test_put_is_durable_across_reopen () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      (Eio.Switch.run @@ fun sw ->
       let t = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"test" dir in
       File_kv_store.put t ~key:"wrapped-dek" "ciphertext-key-material");
      Eio.Switch.run @@ fun sw ->
      let t2 = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"test" dir in
      Alcotest.(check (option string))
        "put value is still there after a full close and reopen"
        (Some "ciphertext-key-material")
        (File_kv_store.get t2 ~key:"wrapped-dek"))

(* Relative to this test's own working directory (_build/default/test/), declared in test/dune's
   own [(deps ...)] so dune both copies it into a sandbox and reruns this test when it changes --
   the same arrangement, and the same reasoning, as [test_golden.ml]'s [golden_file_path]. *)
let file_kv_store_source_path = "../lib/storage/file_kv_store.ml"

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () -> really_input_string ic (in_channel_length ic))

(* The body of a top-level [let <name> ...] binding: everything from that binding up to the next
   line starting in column 0, which in this file is always either the next top-level [let] or the
   next top-level comment. *)
let top_level_binding_body source name =
  let lines = String.split_on_char '\n' source in
  let starts_binding line = String.length line > 4 && String.sub line 0 4 = "let " in
  (* Word-boundary check on the character right after [name] -- see [test_file_storage.ml]'s own
     copy of this helper (Task 19 review, Minor finding) for the full rationale: without it,
     looking up a short binding name would also match a longer one sharing its prefix (e.g.
     ["perform_write"] vs. [let perform_write_from_string ...]), silently returning the wrong
     binding's body. *)
  let is_ident_char c =
    (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c = '_' || c = '\''
  in
  let rec find = function
    | [] -> Alcotest.failf "no top-level binding %S found in %s" name file_kv_store_source_path
    | line :: rest ->
      let name_end = 4 + String.length name in
      if starts_binding line && String.length line >= name_end
         && String.sub line 4 (String.length name) = name
         && (String.length line = name_end || not (is_ident_char line.[name_end])) then
        let rec take acc = function
          | [] -> List.rev acc
          | l :: tl ->
            if l <> "" && l.[0] <> ' ' && l.[0] <> ')' then List.rev acc else take (l :: acc) tl
        in
        String.concat "\n" (line :: take [] rest)
      else find rest
  in
  find lines

let index_of ~needle haystack =
  let nl = String.length needle and hl = String.length haystack in
  let rec go i =
    if i + nl > hl then None else if String.sub haystack i nl = needle then Some i else go (i + 1)
  in
  go 0

(* Task 18 post-review Critical fix: before sharding, a key's own [path] lived directly in
   [t.dir_path], so fsyncing [t.dir_path] after [durable_write]'s [rename]/[delete]'s [unlink] WAS
   fsyncing the directory whose entries actually changed -- they were the same directory. After
   sharding, [path] is [t.dir_path/xx/yy/<hash>]; the [rename]/[unlink] only ever changes the
   SHARD2 directory's entries ([Filename.dirname path]), two levels below [t.dir_path]. Fsyncing
   [t.dir_path] itself therefore closes nothing real: [fsync(fd)] on a directory only durabilizes
   THAT directory's own entry list, never a descendant's (the exact principle this file's own
   [fsync_file] comment already invokes for a different call site). This is a real, live regression
   this test file's own logical read-after-write/delete tests above cannot catch: a directory fsync
   has no observable effect short of an actual crash/remount (see [test_put_is_durable_across_reopen]
   and this suite's own top comment for why no such simulation is practical on this box), so this
   is a source-level guard instead, matching this file's own established convention for exactly
   this class of otherwise-unobservable durability property (see
   [test_check_or_write_owner_marker_is_atomic_via_temp_then_rename_then_fsync] below for the
   precedent). It fails loudly if either call site ever regresses back to fsyncing [t.dir_path]
   directly. *)
let test_durable_write_and_delete_fsync_the_shard_directory_not_dir_path () =
  let source = read_file file_kv_store_source_path in
  let durable_write = top_level_binding_body source "durable_write" in
  Alcotest.(check bool)
    "durable_write still publishes via Eio.Path.rename" true
    (contains ~needle:"Eio.Path.rename" durable_write);
  Alcotest.(check bool)
    "durable_write fsyncs the SHARD directory that actually changed (Filename.dirname path), not \
     t.dir_path (Critical fix regression guard)"
    true
    (contains ~needle:"fsync_dir ~dir_path:(Filename.dirname path)" durable_write);
  Alcotest.(check bool)
    "durable_write does NOT fsync t.dir_path directly -- that would durabilize nothing the rename \
     actually touched, post-sharding"
    false
    (contains ~needle:"fsync_dir ~dir_path:t.dir_path" durable_write);
  (* Ordering matters, not just presence: syncing the directory before the rename would sync a
     state that does not yet contain the new entry, which is no guarantee at all. *)
  (match
     (index_of ~needle:"Eio.Path.rename" durable_write,
      index_of ~needle:"fsync_dir ~dir_path:(Filename.dirname path)" durable_write)
   with
  | Some rename_at, Some fsync_at ->
    Alcotest.(check bool) "the fsync_dir comes AFTER the rename, not before" true (fsync_at > rename_at)
  | _ ->
    Alcotest.fail
      "expected both Eio.Path.rename and fsync_dir ~dir_path:(Filename.dirname path) in \
       durable_write's body");
  let delete_body = top_level_binding_body source "delete" in
  Alcotest.(check bool)
    "delete fsyncs the SHARD directory that actually changed (Filename.dirname path), not \
     t.dir_path (Critical fix regression guard)"
    true
    (contains ~needle:"fsync_dir ~dir_path:(Filename.dirname path)" delete_body);
  Alcotest.(check bool)
    "delete does NOT fsync t.dir_path directly -- same reasoning as durable_write above" false
    (contains ~needle:"fsync_dir ~dir_path:t.dir_path" delete_body)

(* Task 18 post-review Critical fix, second layer: a freshly-created shard directory is itself a
   directory-entry change in ITS OWN PARENT, which needs the same [fsync_dir] treatment as any
   other entry change this module makes durable -- otherwise a crash right after the very first
   [put] under a cold two-level prefix could leave that shard directory's own existence unpersisted,
   even though the key file inside it (fsynced by [durable_write] itself) is fine. Equally, this
   must NOT fsync unconditionally on every call once a shard is warm (real, avoidable I/O cost on
   every single [put] for directories that already exist and did not change), so the guard here is
   two-sided: presence of [fsync_dir] calls guarded by an actual mkdir-succeeded check, not just
   presence of [Eio.Path.mkdir] on its own. Same source-level-guard technique and rationale as
   [test_durable_write_and_delete_fsync_the_shard_directory_not_dir_path] above. *)
let test_ensure_shard_dirs_exist_fsyncs_only_newly_created_parent_levels () =
  let source = read_file file_kv_store_source_path in
  let body = top_level_binding_body source "ensure_shard_dirs_exist" in
  Alcotest.(check bool) "still creates both shard levels via Eio.Path.mkdir" true
    (let count =
       let rec go i n = match index_of ~needle:"Eio.Path.mkdir" (String.sub body i (String.length body - i)) with
         | None -> n
         | Some rel -> go (i + rel + 1) (n + 1)
       in
       go 0 0
     in
     count >= 2);
  Alcotest.(check bool)
    "mkdir's own success/failure is captured (not swallowed by a bare try...with, which would lose \
     the created-vs-already-there distinction this fix depends on)"
    true
    (contains ~needle:"exception Eio.Io _ -> false" body);
  Alcotest.(check bool) "fsyncs a parent level when this call actually created it" true
    (contains ~needle:"if shard1_created then fsync_dir" body
    && contains ~needle:"if shard2_created then fsync_dir" body)

(* -- Subtask 4.6: [create]'s [~owner] closes PART of a confirmed, real data-destruction bug --
   sharing one [dir_path] between a [Redaction_store] keystore and a [Materializer] accumulator
   silently corrupts data (three distinct ways). What [~owner] catches, and what it does not, is
   pinned by two tests in [test_lattice_materialize_crypto_scenarios.ml]: a DIFFERENT-tag pair is
   rejected at construction with the keystore's data intact
   ([test_a_shared_kv_directory_is_rejected_at_construction]), while a SAME-tag pair constructs
   cleanly and still destroys a wrapped DEK silently
   ([test_using_the_same_owner_tag_on_both_sides_still_destroys_a_wrapped_dek]) -- a real,
   disclosed, still-open residual gap, not a closed one. The earlier omitted-[~owner] reproduction
   was deleted by subtask 4.8, which made [~owner] mandatory: that state no longer compiles, so
   there is no "omitting [owner] leaves a caller unaffected" case left to cover here. These tests
   cover this module's own side: a real mismatch is rejected loudly at construction, a matching
   owner reopens exactly as before, and an empty tag is refused outright. *)

(* Task 11 restructured both tests below to close the FIRST handle's switch before the second
   [create] attempt: [File_kv_store.create] now also takes a real, OS-level [flock(2)] on
   [dir_path] (strictly before the [~owner] marker check -- see [Riptide_storage.Dir_lock]'s own
   [.mli]), so a second [create] attempted while the first handle is still live would now be
   refused by THAT lock, not by whatever this test is actually trying to exercise (an owner
   mismatch below; a legitimate same-owner reopen in the next test). Closing the first handle
   first is exactly the "release before reopening" pattern this suite's own
   [test_write_then_read_after_reopen]-shaped tests already use elsewhere -- and it is what
   "reopen" means to begin with, so [test_matching_owner_reopens_cleanly] below is, if anything,
   more honest about what it tests now than before. The direct, dedicated coverage for Task 11's
   own lock (two handles genuinely live at once) is
   [test_a_second_create_on_a_locked_directory_is_refused] and
   [test_a_real_second_os_process_holding_the_lock_is_refused], further down this file. *)

let test_owner_mismatch_is_rejected_at_construction () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      (Eio.Switch.run @@ fun sw ->
       let (_ : File_kv_store.t) =
         File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"redaction-keystore" dir
       in
       ());
      Eio.Switch.run @@ fun sw ->
      Alcotest.check_raises "a second, different owner is rejected"
        (Invalid_argument
           (Printf.sprintf "File_kv_store.create: %s is owned by \"redaction-keystore\", not \
                             \"materializer\""
              dir))
        (fun () ->
          ignore (File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"materializer" dir)))

let test_matching_owner_reopens_cleanly () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      (Eio.Switch.run @@ fun sw ->
       let t1 = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"redaction-keystore" dir in
       File_kv_store.put t1 ~key:"k" "v");
      Eio.Switch.run @@ fun sw ->
      let t2 = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"redaction-keystore" dir in
      Alcotest.(check (option string)) "the same-owner reopen sees the same data" (Some "v")
        (File_kv_store.get t2 ~key:"k"))

(* An empty tag is the "no owner" escape hatch spelled differently -- mandatory [~owner] removed
   the syntactic form, and this closes the degenerate one. Rejected before the directory is even
   created, so the check cannot be mistaken for a marker comparison against an existing claim. *)

let test_an_empty_owner_is_rejected_at_construction () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      Alcotest.check_raises "an empty owner tag is refused"
        (Invalid_argument "File_kv_store.create: ~owner must be a non-empty tag")
        (fun () -> ignore (File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"" dir));
      (* Non-vacuity: the rejection is about the tag, not about this directory -- a real tag on the
         very same, still-unclaimed directory succeeds immediately afterwards. *)
      let t = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"a-real-tag" dir in
      Alcotest.(check string) "and a non-empty tag on the same directory still works" "a-real-tag"
        (File_kv_store.owner t))

(* -- Subtask 4.8's [File_kv_store] half: [owner] must read back the exact construction-time tag
   the marker mechanism above resolved -- not merely echo the argument uninspected, though for
   this backend those two happen to coincide (see [check_or_write_owner_marker]: it either matches
   the existing marker or writes a fresh one with exactly [tag], so reaching [create]'s return
   means [tag] IS what's now on disk). This is what [Redaction_store.create] (subtask 4.8's other
   half) verifies against below. *)

let test_owner_reads_back_the_tag_used_at_construction () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"a-real-tag" dir in
      Alcotest.(check string) "owner reads back the construction-time tag" "a-real-tag"
        (File_kv_store.owner t))

(* Task 15: a 0-byte marker is what the OLD create-then-write scheme
   ([Eio.Path.save ~create:(`Exclusive ...)]) leaves behind when a process crashes (or is killed)
   between the file's creation and its write completing -- the create half of that pair is its own
   separate syscall from the write, so a crash between them is a real, reachable window, not a
   theoretical one. [Eio.Path.load] on a 0-byte file succeeds and returns [""], which the old code
   read as "this directory is owned by the empty string" -- a claim NO real tag can ever match
   again (["" <> tag] for every non-empty [tag], and [~owner:""] is itself rejected at
   construction elsewhere in this module), permanently bricking the directory. The fix must treat
   a 0-byte marker exactly like a missing one: "no real claim yet, write [tag] now".

   Writes the 0-byte marker directly via plain [Unix], bypassing [File_kv_store] entirely, to
   simulate exactly the crash window above -- not via any [File_kv_store] call, since no call this
   module exposes can itself leave a 0-byte marker on a still-passing run (that's the whole bug:
   today there is no code path back OUT of "owned by \"\"" once it happens). The marker's own file
   name, [".riptide-kv-owner"], is private to [file_kv_store.ml] (not exposed by its [.mli]) --
   duplicated here as a literal rather than exported solely for this test, matching this suite's
   existing practice of exercising private on-disk layout details by literal path
   ([test_put_overwrite_leaves_no_leftover_tmp_file] does the same for [".put.tmp"]). *)
let owner_marker_name = ".riptide-kv-owner"

(* Review finding M6 (Task 15 review): [O_TRUNC] added -- without it, this only genuinely
   produces a 0-byte file when [owner_marker_name] does not already exist at [dir] (an [O_CREAT]
   with no existing file opens at length 0 either way). Harmless as originally written, since every
   call site uses a fresh [with_tmp_dir] directory with no marker yet, but a latent trap if this
   helper is ever reused after a real marker already exists -- [O_TRUNC] makes it unconditionally
   produce a 0-byte file regardless of what, if anything, was there before. *)
let write_a_zero_byte_marker_directly dir =
  let fd =
    Unix.openfile (Filename.concat dir owner_marker_name)
      [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600
  in
  Unix.close fd

let test_a_zero_byte_marker_is_treated_as_unclaimed_not_as_owner_empty_string () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      write_a_zero_byte_marker_directly dir;
      (Eio.Switch.run @@ fun sw ->
       let t = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"redaction-store" dir in
       Alcotest.(check string) "the directory is now claimed by the real owner" "redaction-store"
         (File_kv_store.owner t));
      (* Review finding 2 (Task 15 review): [owner t] alone only proves the constructor remembered
         the argument it was handed -- it is [t.owner], not anything read back from disk -- so a
         regression that correctly treats a 0-byte marker as unclaimed but silently DROPS the
         actual write (e.g. removing the [save]/[rename] pair while leaving [fsync_dir] in place)
         would still pass that assertion alone, leaving the directory permanently unclaimed with no
         real marker ever written. Reopening under a DIFFERENT tag, after the first handle's switch
         (and therefore its lock) has fully released, is the stronger check: it only raises if a
         genuine, non-empty marker holding "redaction-store" is really sitting on disk for the
         mismatch comparison to find. *)
      Eio.Switch.run @@ fun sw ->
      Alcotest.check_raises
        "a real marker was actually written to disk -- a differently-tagged reopen now conflicts"
        (Invalid_argument
           (Printf.sprintf
              "File_kv_store.create: %s is owned by \"redaction-store\", not \"different-owner\""
              dir))
        (fun () ->
          ignore (File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"different-owner" dir)))

(* Review finding 3 (Task 15 review): the atomic-write property itself
   (temp-then-rename-then-fsync) for the owner marker had zero test coverage -- unlike
   [durable_write]'s equivalent, which
   [test_durable_write_and_delete_fsync_the_shard_directory_not_dir_path] above already guards at
   the source level. Right now, replacing the whole Task 15 fix with a single non-atomic
   [Eio.Path.save ~create:(`Or_truncate 0o600) marker_path tag] (no temp file, no rename, no fsync)
   would leave every other test in this file green -- silently reverting the fix. Same
   source-level-guard technique as
   [test_durable_write_and_delete_fsync_the_shard_directory_not_dir_path] (see that test's own
   comment for why this is deliberately not trying to observe the fsync's effect, only its
   presence and ordering in the source). *)
let owner_marker_tmp_suffix = ".tmp"
let owner_tmp_path_for dir = Filename.concat dir (owner_marker_name ^ owner_marker_tmp_suffix)

let test_check_or_write_owner_marker_is_atomic_via_temp_then_rename_then_fsync () =
  let source = read_file file_kv_store_source_path in
  let body = top_level_binding_body source "check_or_write_owner_marker" in
  Alcotest.(check bool)
    "check_or_write_owner_marker still publishes via Eio.Path.rename" true
    (contains ~needle:"Eio.Path.rename" body);
  Alcotest.(check bool)
    "check_or_write_owner_marker fsyncs the containing directory (Finding 3 regression guard)" true
    (contains ~needle:"fsync_dir ~dir_path" body);
  Alcotest.(check bool)
    "check_or_write_owner_marker fsyncs the temp file's own content before publishing it (Finding \
     1 regression guard -- deleting just this call must fail this test, not only Finding 1's own \
     since-retired RED/GREEN trace)"
    true
    (contains ~needle:"fsync_file" body);
  (match
     (index_of ~needle:"Eio.Path.save" body, index_of ~needle:"Eio.Path.rename" body)
   with
  | Some save_at, Some rename_at ->
    Alcotest.(check bool) "the temp file is staged (Eio.Path.save) before the rename, not after"
      true (rename_at > save_at)
  | _ ->
    Alcotest.fail
      "expected both Eio.Path.save and Eio.Path.rename in check_or_write_owner_marker's body");
  (match (index_of ~needle:"Eio.Path.save" body, index_of ~needle:"fsync_file" body) with
  | Some save_at, Some fsync_file_at ->
    Alcotest.(check bool) "fsync_file runs AFTER the temp file is staged, not before" true
      (fsync_file_at > save_at)
  | _ -> Alcotest.fail "expected both Eio.Path.save and fsync_file in check_or_write_owner_marker's body");
  (match (index_of ~needle:"fsync_file" body, index_of ~needle:"Eio.Path.rename" body) with
  | Some fsync_file_at, Some rename_at ->
    Alcotest.(check bool) "fsync_file runs BEFORE the rename that publishes the temp file, not after"
      true (rename_at > fsync_file_at)
  | _ ->
    Alcotest.fail "expected both fsync_file and Eio.Path.rename in check_or_write_owner_marker's body");
  (match
     (index_of ~needle:"Eio.Path.rename" body, index_of ~needle:"fsync_dir ~dir_path" body)
   with
  | Some rename_at, Some fsync_at ->
    Alcotest.(check bool) "the fsync_dir comes AFTER the rename, not before" true
      (fsync_at > rename_at)
  | _ ->
    Alcotest.fail
      "expected both Eio.Path.rename and fsync_dir ~dir_path in check_or_write_owner_marker's body")

let test_owner_marker_write_leaves_no_leftover_tmp_file () =
  (* Mirrors [test_put_overwrite_leaves_no_leftover_tmp_file] above, for the owner marker's own
     temp file instead of a per-key one: a successful self-heal's staged temp file must be gone
     (renamed away, not merely written and left behind) once [create] returns. *)
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      write_a_zero_byte_marker_directly dir;
      Eio.Switch.run @@ fun sw ->
      let (_ : File_kv_store.t) =
        File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"redaction-store" dir
      in
      Alcotest.(check bool) "no leftover owner-marker temp file after rename" false
        (Sys.file_exists (owner_tmp_path_for dir)))

(* Task 11: the PHYSICAL guard -- see [Test_file_storage]'s own copy of this comment (identical
   rationale, [File_kv_store.create] instead of [File_storage.create]) for the full account of the
   Critical finding this closes and why [flock(2)], not [Unix.lockf], is what makes the
   same-process test below actually observe a conflict. *)
(* Review finding M4: delegates to {!Dir_lock.conflict_message}, the single source of truth for
   this exact wording, rather than duplicating the literal string here (this file used to be one
   of four independent copies -- see that function's own [.mli] doc for the full account). [?owner]
   forwards straight through to {!Dir_lock.conflict_message}'s own [?owner] -- see review finding
   M3: the lock's message names the conflicting handle's owner tag when it's readable on disk. *)
let expected_lock_message ~caller ?owner dir =
  Invalid_argument (Dir_lock.conflict_message ~caller ?owner dir)

let test_a_second_create_on_a_locked_directory_is_refused () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let (_ : File_kv_store.t) =
        File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"redaction-keystore" dir
      in
      (* Even a DIFFERENT owner tag is refused by the lock, before the marker is ever consulted --
         the physical guard runs first and does not care what either side calls itself. The first
         handle's own tag ("redaction-keystore") is already durably on disk in the owner marker by
         this point (written inside its own successful [create]), so the lock's failure message
         names it (M3), regardless of what tag THIS second, refused attempt passes. *)
      Alcotest.check_raises
        "a second create on the same directory, while the first handle is still live, is refused \
         immediately regardless of the owner tag it passes"
        (expected_lock_message ~caller:"File_kv_store.create" ~owner:"redaction-keystore" dir)
        (fun () ->
          ignore (File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"materializer" dir)))

(* Task 15 review, Minor finding M4, dedicated regression test (out-of-scope observation raised
   by that same review's own re-review, closed here): a 0-byte owner marker must be reported as
   "no owner readable yet" ([None], i.e. omitted from the message) in the LOCK's conflict
   diagnostic, not as a real claim by the empty-string owner ([Some ""]) -- consistent with
   [check_or_write_owner_marker]'s own self-healing treatment of a 0-byte marker as unclaimed
   (see [test_a_zero_byte_marker_is_treated_as_unclaimed_not_as_owner_empty_string] above). Held
   the lock directly via [Dir_lock.acquire] (bypassing [File_kv_store.create] entirely) so the
   marker on disk can be pinned at exactly 0 bytes for the whole window the second [create]
   attempt observes it -- going through a real first [File_kv_store.create] would always leave a
   real, non-empty tag written by the time any second attempt could run. *)
let test_a_locked_directory_with_a_zero_byte_marker_omits_the_owner_hint () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      write_a_zero_byte_marker_directly dir;
      Eio.Switch.run @@ fun sw ->
      let (_ : Eio_unix.Fd.t) = Dir_lock.acquire ~sw ~caller:"probe" dir in
      Alcotest.check_raises
        "a 0-byte marker is reported as no owner readable yet, not as owner \"\""
        (expected_lock_message ~caller:"File_kv_store.create" dir)
        (fun () ->
          ignore (File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"materializer" dir)))

(* Review finding I1, live-reproduced: [Dir_lock.acquire] registers the lock fd with [sw] the
   instant [flock(2)] succeeds -- but nothing released it if the REST of [create] then raised for
   some other reason. The reviewer reproduced this live: switch 1 creates+closes under
   [owner-a]; switch 2 attempts [owner-b] (correctly rejected by the owner-tag check) and THEN, in
   the SAME switch, attempts [owner-a] -- the rightful owner, with no live handle anywhere -- and
   got spuriously refused with "already locked by another open handle". This falsified this test
   file's own [test_an_empty_owner_is_rejected_at_construction] assertion ("a real tag on the very
   same directory succeeds immediately afterwards"), which only happened to still hold there
   because the EMPTY-tag check runs and raises {e before} [Dir_lock.acquire] is ever reached in
   that specific case -- it would not have held for a check that runs after the lock, exactly the
   owner-tag-mismatch shape this test reproduces directly. *)
let test_a_failed_create_releases_its_lock_before_reraising () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      let fs = Eio.Stdenv.fs env in
      (* Construct a first legitimate handle so the marker holds a real tag, then close it: the
         failure below must come from the SECOND create's own OWNER-TAG mismatch, not from the
         lock -- a live handle from THIS switch would make the lock fire first (as in
         [test_a_second_create_on_a_locked_directory_is_refused] above), which would not exercise
         finding I1's actual scenario at all. Two SEQUENTIAL (not nested) [Eio.Switch.run] calls,
         matching the "release before reopening" pattern [test_owner_mismatch_is_rejected_at_construction]
         above already uses -- not one switch nested inside the other, which does not reliably tear
         the inner one down before the surrounding code continues. *)
      (Eio.Switch.run @@ fun sw0 ->
       let (_ : File_kv_store.t) = File_kv_store.create ~sw:sw0 ~fs ~owner:"redaction-keystore" dir in
       ());
      Eio.Switch.run @@ fun sw ->
      (* This SUCCEEDS at the lock (no live handle holds it, [sw0] above is already closed), then
         fails at the owner-tag check -- AFTER [Dir_lock.acquire] has already registered the lock
         fd with [sw]. Before the I1 fix, that lock fd stayed registered with [sw] for [sw]'s
         entire remaining lifetime even though this [create] raised and returned no [t]. *)
      Alcotest.check_raises "the owner-tag mismatch fails construction, exactly as before"
        (Invalid_argument
           (Printf.sprintf
              "File_kv_store.create: %s is owned by \"redaction-keystore\", not \"wrong-tag\"" dir))
        (fun () -> ignore (File_kv_store.create ~sw ~fs ~owner:"wrong-tag" dir));
      (* THE regression this test exists to catch: the rightful owner, in the SAME switch, with no
         live handle anywhere, must succeed immediately -- not be refused by a lock the failed
         attempt above should have released. *)
      let t = File_kv_store.create ~sw ~fs ~owner:"redaction-keystore" dir in
      Alcotest.(check string)
        "and a legitimate create right afterwards, in the same switch, succeeds because the \
         failed attempt's lock was released"
        "redaction-keystore" (File_kv_store.owner t))

(* Stronger evidence than the same-process double-handle above: a REAL second OS process -- see
   [Test_file_storage.test_a_real_second_os_process_holding_the_lock_is_refused] for the full
   rationale (forked before any Eio event loop exists in this test; the child never touches Eio,
   only plain blocking [Unix]/[flock(2)] calls through the same C symbol [Dir_lock] itself uses). *)
external test_only_flock_exclusive_nonblocking : Unix.file_descr -> bool
  = "riptide_flock_exclusive_nonblocking"

let test_a_real_second_os_process_holding_the_lock_is_refused () =
  (* Review finding 3 (re-review, round 2) -- see
     [Test_file_storage.test_a_real_second_os_process_holding_the_lock_is_refused]'s own,
     identical fix and comment for the full rationale and the live standalone-run RED/GREEN
     evidence (exit 141 == SIGPIPE without this, a clean reported failure with it): if the forked
     child below exits early, its end of [release_r] closes with it, and the parent's own
     unconditional write to [release_w] inside [Fun.protect]'s [~finally] then has no reader left
     at all -- fatal SIGPIPE by default disposition, invisible to any [Unix.Unix_error] guard
     around that write, only masked in a full suite run by some earlier test's own [Eio_main.run]
     already having set this process-wide as a side effect. *)
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  with_tmp_dir (fun dir ->
      (* [with_tmp_dir] already [Unix.mkdir]s [dir] itself (see this file's own definition above)
         -- no need to redo it here (review finding M6: this used to re-[mkdir] redundantly, which
         reads as if the directory's existence were in doubt at this point, when it never is). *)
      let lock_path = Filename.concat dir ".riptide-lock" in
      let ready_r, ready_w = Unix.pipe () in
      let release_r, release_w = Unix.pipe () in
      match Unix.fork () with
      | 0 ->
        (* Review finding I4: the whole branch is now wrapped in a [try ... with _ -> Unix._exit 2]
           guard -- see [Test_file_storage]'s own identical fix for the full rationale (an
           unguarded exception here escapes into the parent's [with_tmp_dir] cleanup and then into
           Alcotest itself, re-running the entire rest of the suite a second time; reproduced live
           by deliberately breaking this exact [openfile] call). *)
        (try
           Unix.close ready_r;
           Unix.close release_w;
           let fd = Unix.openfile lock_path [ Unix.O_RDWR; Unix.O_CREAT ] 0o600 in
           if not (test_only_flock_exclusive_nonblocking fd) then Unix._exit 1;
           ignore (Unix.write ready_w (Bytes.of_string "1") 0 1);
           ignore (Unix.read release_r (Bytes.create 1) 0 1);
           Unix._exit 0
         with _ -> Unix._exit 2)
      | child_pid ->
        Unix.close ready_w;
        Unix.close release_r;
        Fun.protect
          ~finally:(fun () ->
            (try ignore (Unix.write release_w (Bytes.of_string "1") 0 1) with Unix.Unix_error _ -> ());
            ignore (Unix.waitpid [] child_pid);
            (* Review finding M5: [ready_r]/[release_w] (this parent's own ends of both pipes)
               were never closed after this point -- a real fd leak, one pair per test run. *)
            (try Unix.close ready_r with Unix.Unix_error _ -> ());
            (try Unix.close release_w with Unix.Unix_error _ -> ()))
          (fun () ->
            let n = Unix.read ready_r (Bytes.create 1) 0 1 in
            Alcotest.(check int) "the child process actually acquired the real lock first" 1 n;
            Eio_main.run (fun env ->
                Eio.Switch.run @@ fun sw ->
                Alcotest.check_raises
                  "a create from THIS process is refused immediately while a genuinely different \
                   OS process holds the real flock"
                  (expected_lock_message ~caller:"File_kv_store.create" dir)
                  (fun () ->
                    ignore
                      (File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"redaction-keystore"
                         dir)))))

(* Task 16: concurrent same-key writes must not produce torn/phantom values.
   Two concurrent fibers writing different-length values to the same key can race to use the
   same temp-file path (with the fixed [".put.tmp"] suffix), resulting in one writer's partial
   write landing in the file the other writer then renames into place -- a mix of both writers'
   bytes, neither readable, or neither recoverable. This test reproduces that bug by spawning
   [n] concurrent fibers, each writing a distinct, identifiable value to the same key, and
   verifies the result is exactly one complete, unscrambled value. *)

let is_one_of_the_written_values ~candidates result =
  match result with
  | None -> false
  | Some v -> Array.exists (String.equal v) candidates

let test_concurrent_same_key_puts_never_produce_a_torn_unreadable_record () =
  (* Real concurrent Eio fibers, same key, distinguishable different-length values,
     driven the same way the audit's own reproduction did. *)
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"test" dir in
      (* Spawn n concurrent fibers, each writing a distinct value to the same key.
         Values differ in length (value_i is repeated i+1 times) so a torn write is easily
         distinguishable from a complete one -- "ab" can never be produced by writing any
         individual value (each is one of ["a", "aa", "aaa", ... "aaa...a"]).

         Use a counter to track completion: each fiber increments it when done, and we
         wait until all fibers have signaled completion before proceeding to [get]. *)
      let n = 16 in
      let written_values = Array.init n (fun i -> String.make (i + 1) 'a') in
      let completed = Atomic.make 0 in
      for i = 0 to n - 1 do
        Eio.Fiber.fork ~sw (fun () ->
            File_kv_store.put t ~key:"shared" written_values.(i);
            ignore (Atomic.fetch_and_add completed 1))
      done;
      (* Wait for all fibers to complete. Use a simple spin-yield loop (deliberate choice
         for test clarity: polling the atomic counter is more transparent than setting up
         channels or condition variables for this bounded test scenario). *)
      let rec wait_for_completion () =
        if Atomic.get completed < n then begin
          Eio.Fiber.yield ();
          wait_for_completion ()
        end
      in
      wait_for_completion ();
      (* Now all puts have completed. Verify the result is one of the complete values. *)
      let result = File_kv_store.get t ~key:"shared" in
      Alcotest.(check bool)
        "the surviving value is one writer's complete value, never a torn mix or None"
        true (is_one_of_the_written_values ~candidates:written_values result))

(* Task 17: the [File_kv_store] half of the same closed audit finding -- see
   [test_file_storage.ml]'s own [test_storage_operations_do_not_depend_on_tmpdir] for the full
   rationale, including why [Filename.set_temp_dir_name] (not [Unix.putenv "TMPDIR"], as the
   plan's own sketch suggested) is the mechanism that actually reproduces this against this
   installed OCaml 5.0.0 stdlib's [Filename.temp_file]. This module's own [durable_write]/
   [check_or_write_owner_marker] temp files are already built via [path ^ tmp_suffix_for_call ()]/
   [Filename.concat dir_path ...] (Task 16/Task 15, both already landed -- confirmed by reading
   both functions directly), so the only [TMPDIR] dependency reachable from [File_kv_store.create]
   is the same {!Riptide_storage.Aligned_buffer_pool.alloc_one_aligned_buffer} this test's
   [File_storage] counterpart exercises, called from [File_kv_store.create]'s own
   [Aligned_buffer_pool.create] call site. *)
let test_storage_operations_do_not_depend_on_tmpdir () =
  with_tmp_dir (fun dir ->
      let original_temp_dir = Filename.get_temp_dir_name () in
      Fun.protect
        ~finally:(fun () -> Filename.set_temp_dir_name original_temp_dir)
        (fun () ->
          Filename.set_temp_dir_name "/nonexistent-audit-check-dir";
          Eio_main.run @@ fun env ->
          Eio.Switch.run @@ fun sw ->
          let t = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"test" dir in
          File_kv_store.put t ~key:"k" "v";
          Alcotest.(check (option string))
            "put/get (and the pool allocation create performs to make it possible) succeeded \
             without a usable TMPDIR"
            (Some "v") (File_kv_store.get t ~key:"k")))

(* -- Task 18: shard the flat one-file-per-key directory by hash prefix. [path_for] is private
   (not exposed by [file_kv_store.mli]), so these tests -- like [real_path_for]/[key_hash_hex]
   above, which already compute this same sharded location -- check real files on disk through
   [put]/[get]/[delete], never a private hook into the module. *)
let test_path_for_shards_across_subdirectories () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"test" dir in
      File_kv_store.put t ~key:"a" "va";
      File_kv_store.put t ~key:"totally-different-key" "vb";
      let p1 = real_path_for dir "a" and p2 = real_path_for dir "totally-different-key" in
      (* Sanity, not a coincidence of these two literal keys: confirm their hashes actually land
         in different shard subdirectories before treating that as evidence of anything. *)
      Alcotest.(check bool) "the two test keys' hash prefixes actually differ" true
        (Filename.dirname p1 <> Filename.dirname p2);
      Alcotest.(check bool)
        "key \"a\"'s file lives inside its own two-level hash-prefix shard subdirectory, not \
         flat in dir_path"
        true (Sys.file_exists p1);
      Alcotest.(check bool)
        "key \"totally-different-key\"'s file lives inside its own (different) two-level shard \
         subdirectory"
        true (Sys.file_exists p2);
      Alcotest.(check bool) "the old flat top-level path is NOT where the file lives anymore"
        false (Sys.file_exists (Filename.concat dir (key_hash_hex "a"))))

let test_put_get_delete_round_trip_through_sharded_path () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"test" dir in
      let sharded_path = real_path_for dir "round-trip-key" in
      File_kv_store.put t ~key:"round-trip-key" "round-trip-value";
      Alcotest.(check bool)
        "put actually wrote the key's file into its two-level shard subdirectory" true
        (Sys.file_exists sharded_path);
      Alcotest.(check (option string)) "get returns what was put, through the sharded path"
        (Some "round-trip-value") (File_kv_store.get t ~key:"round-trip-key");
      File_kv_store.delete t ~key:"round-trip-key";
      Alcotest.(check (option string)) "get after delete is None, through the sharded path" None
        (File_kv_store.get t ~key:"round-trip-key");
      Alcotest.(check bool) "delete actually removed the sharded file from disk, not just a copy"
        false (Sys.file_exists sharded_path))

(* Ruling B (audit-remediation controller, pre-flight): sharding [path_for] must move the per-key
   TEMP file into the same sharded subdirectory as the final key path, and [sweep_stale_temp_files]
   (Task 16) must be fixed to still find stale [.put.<pid>.<counter>.tmp] debris once it can no
   longer sit flat at the top level. This is the regression test for that consequence: it plants
   stale debris directly inside a real two-level shard subdirectory (independent of [path_for]'s
   own current behavior -- built by hand via plain [Unix], the same way
   [test_interrupted_overwrite_leaves_old_value_intact] above plants its own flat stale temp file)
   and confirms a fresh [create]'s sweep still finds and removes it, and that an unrelated real key
   elsewhere in the store survives the sweep untouched. *)
let test_sweep_still_finds_stale_temp_files_inside_shard_subdirectories () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      let hash = key_hash_hex "shard-swept-key" in
      let shard1_dir = Filename.concat dir (String.sub hash 0 2) in
      let shard2_dir = Filename.concat shard1_dir (String.sub hash 2 2) in
      Unix.mkdir shard1_dir 0o700;
      Unix.mkdir shard2_dir 0o700;
      let stale_tmp_path = Filename.concat shard2_dir (hash ^ ".put.99999.99999.tmp") in
      let oc = open_out_bin stale_tmp_path in
      output_string oc "garbage-partial-write-left-by-a-simulated-crash-inside-a-shard-dir";
      close_out oc;
      Alcotest.(check bool) "stale temp file exists, inside its shard subdirectory, before create"
        true (Sys.file_exists stale_tmp_path);
      Eio.Switch.run @@ fun sw ->
      let t = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"test" dir in
      Alcotest.(check bool)
        "the sweep still finds and removes stale temp files nested inside a shard subdirectory \
         (Ruling B regression: sharding must not silently reopen the crash-debris-accumulation \
         bug Task 16 closed)"
        false (Sys.file_exists stale_tmp_path);
      (* The shard directories themselves, and real data elsewhere in the store, must survive the
         deeper walk untouched -- the walk must distinguish a stale-temp-file leaf from a shard
         directory entry, not unlink everything it finds two levels down. *)
      Alcotest.(check bool) "the shard subdirectories themselves are not deleted by the sweep" true
        (Sys.file_exists shard2_dir);
      File_kv_store.put t ~key:"unrelated-key" "still-here";
      Alcotest.(check (option string)) "an unrelated real key put after the sweep still works"
        (Some "still-here") (File_kv_store.get t ~key:"unrelated-key"))

(* -- Task 19: audit-remediation "minor bundle" -- O_DIRECT misdetection and use-after-close on a
   failed reopen (Bug 3, the [ring_capacity] startup-cost doc note, is [file_storage.mli]-only).
   This module's [perform_write]/[perform_read]/[downgrade_to_dsync_only] were transcribed from
   [file_storage.ml]'s originals (see this file's own top comment), so both bugs need their own,
   separate fix and their own, separate regression coverage here -- fixing one file's copy does not
   fix the other's.

   {b Both tests below are source-level guards, not dynamic reproductions}, for a reason specific
   to THIS module (unlike [file_storage.ml]'s own Bug 1 test, which IS a real dynamic
   reproduction -- see that file's [test_an_unrelated_write_error_does_not_permanently_strip_o_direct]
   for the full technique). [File_storage]'s ring handle is one [file_handle] held open and reused
   for [t]'s entire lifetime, so a wrong downgrade has a lasting, externally observable effect.
   [File_kv_store.put]/[get] instead open a BRAND NEW [file_handle] for every single call (see
   [durable_write]'s [open_file_handle_write] and [durable_read]'s [open_file_handle_read]) and
   always close it again before returning, success or exception (via [Fun.protect]) -- so there is
   no [t]-scoped state for a wrong downgrade to corrupt across calls, and by the time any caller
   (including a test) regains control, the handle whose [direct_capable] flag is in question is
   already gone. Reaching [downgrade_to_dsync_only] at all would in any case require a genuine
   [EINVAL] on write/read, which [file_storage.ml]'s own top comment already documents as
   unreproducible on this box's own mounts -- see that file's Bug-1/Bug-2 section comment for the
   full investigation (RLIMIT_FSIZE via a real [ulimit -f] gives a real, non-EINVAL EFBIG, which is
   exactly why THAT test can be dynamic while genuinely triggering [EINVAL] itself cannot). *)

let test_o_direct_downgrade_guard_matches_only_einval () =
  let source = read_file file_kv_store_source_path in
  List.iter
    (fun name ->
      let body = top_level_binding_body source name in
      Alcotest.(check bool)
        (Printf.sprintf
           "%s's downgrade guard narrows to EINVAL specifically -- a different errno (ENOSPC/EIO/\
            ENOMEM/etc) is a real storage fault, not \"O_DIRECT unsupported\", and must propagate \
            rather than trigger a permanent downgrade"
           name)
        true
        (contains ~needle:"Unix.EINVAL" body);
      Alcotest.(check bool)
        (Printf.sprintf
           "%s no longer has the old, unconditional \"Eio.Io _ when h.direct_capable\" \
            catch-anything guard"
           name)
        false
        (contains ~needle:"Eio.Io _ when h.direct_capable" body))
    [ "perform_write"; "perform_read" ]

(* -- Task 24: Kv_store_intf.S.fold. The plan's own sketch test asserted [fold] visits the ORIGINAL
   keys ["a"; "b"; "c"] -- that is false for this backend and would only pass by coincidence (it
   never would, since [path_for] hashes every key before it ever touches disk; see this file's top
   comment and [kv_store_intf.ml]'s own [fold] doc). The real, honest assertion this test makes
   instead: [fold] visits exactly the SET of each put key's own content hash -- computed here via
   the same public [key_hash_hex] helper this file already uses for [real_path_for] above, not via
   any private hook into [path_for] itself -- once each, no more, no fewer, and no visit of the
   owner marker or lock file's own names either. *)
let test_fold_visits_every_key_currently_present () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"test" dir in
      let original_keys = [ "a"; "b"; "c" ] in
      List.iter (fun k -> File_kv_store.put t ~key:k "v") original_keys;
      let expected_hashes = List.sort compare (List.map key_hash_hex original_keys) in
      let seen = File_kv_store.fold t ~init:[] (fun ~key acc -> key :: acc) in
      Alcotest.(check (list string))
        "fold visits exactly each put key's own content hash, once each -- never the original key \
         strings themselves, which this backend never persists in the clear"
        expected_hashes (List.sort compare seen))

(* A store with nothing put yet still has an owner marker and a lock file sitting in its top-level
   directory once [create] has run -- [fold] must not mistake either for a real key. *)
let test_fold_over_an_empty_store_visits_nothing () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"test" dir in
      Alcotest.(check int) "an empty store folds to nothing -- the owner marker and lock file are \
                            not mistaken for real keys"
        0
        (File_kv_store.fold t ~init:0 (fun ~key:_ acc -> acc + 1)))

(* [fold] must reflect [delete] -- a key removed before the fold must not still be visited. *)
let test_fold_does_not_visit_a_deleted_key () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"test" dir in
      File_kv_store.put t ~key:"stays" "v1";
      File_kv_store.put t ~key:"goes" "v2";
      File_kv_store.delete t ~key:"goes";
      let seen = File_kv_store.fold t ~init:[] (fun ~key acc -> key :: acc) in
      Alcotest.(check (list string)) "only the surviving key's hash is visited"
        [ key_hash_hex "stays" ] seen)

(* Task 24: [get_by_hash] is the read counterpart [fold]'s own contract makes necessary -- [get]
   cannot be reused with a hash [fold] hands back (it would hash that hash a second time). This
   pins the actual, real-world composition [Redaction_store.enumerate_event_ids] depends on: fold
   for hashes, then [get_by_hash] each one back to its stored value. *)
let test_get_by_hash_reads_back_what_fold_finds () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"test" dir in
      File_kv_store.put t ~key:"k" "the-value";
      let hash =
        match File_kv_store.fold t ~init:[] (fun ~key acc -> key :: acc) with
        | [ h ] -> h
        | _ -> Alcotest.fail "expected fold to find exactly one key"
      in
      Alcotest.(check string) "fold's own key is exactly this key's content hash" (key_hash_hex "k")
        hash;
      Alcotest.(check (option string)) "get_by_hash reads back the value fold's hash points at"
        (Some "the-value") (File_kv_store.get_by_hash t ~hash);
      Alcotest.(check (option string))
        "get, by contrast, does NOT find the same record when handed that same hash as an opaque \
         key -- it would hash the hash a second time and land somewhere else entirely"
        None (File_kv_store.get t ~key:hash))

let test_downgrade_marks_direct_incapable_before_attempting_the_reopen () =
  let source = read_file file_kv_store_source_path in
  let body = top_level_binding_body source "downgrade_to_dsync_only" in
  match (index_of ~needle:"h.direct_capable <- false" body, index_of ~needle:"openat2" body) with
  | Some assign_at, Some open_at ->
    Alcotest.(check bool)
      "h.direct_capable is set to false BEFORE attempting the reopen, not after it succeeds" true
      (assign_at < open_at)
  | _ ->
    Alcotest.fail
      "expected both \"h.direct_capable <- false\" and an openat2 call in \
       downgrade_to_dsync_only's body"

let tests =
  [
    ( "Task 10: repeated I/O does not grow the process's kernel map count",
      (* `Slow`, not `Quick` (M10, Task 10 review) -- see this test's own comment above and
         [Test_file_storage]'s equivalent for the full rationale. *)
      `Slow,
      test_repeated_io_does_not_grow_the_process_map_count );
    ("put then get", `Quick, test_put_then_get);
    ("get of never-put key is None", `Quick, test_get_of_never_put_key_is_none);
    ("delete is durable across reopen", `Quick, test_delete_is_durable_across_reopen);
    ("put overwrites", `Quick, test_put_overwrites);
    ("put overwrite leaves no leftover tmp file", `Quick,
      test_put_overwrite_leaves_no_leftover_tmp_file);
    ("interrupted overwrite leaves old value intact", `Quick,
      test_interrupted_overwrite_leaves_old_value_intact);
    ("put is durable across reopen", `Quick, test_put_is_durable_across_reopen);
    ( "Task 18 review (Critical fix): durable_write/delete fsync the shard directory, not \
       t.dir_path",
      `Quick,
      test_durable_write_and_delete_fsync_the_shard_directory_not_dir_path );
    ( "Task 18 review (Critical fix): ensure_shard_dirs_exist fsyncs only newly-created parent \
       levels",
      `Quick,
      test_ensure_shard_dirs_exist_fsyncs_only_newly_created_parent_levels );
    ("owner mismatch is rejected at construction", `Quick,
      test_owner_mismatch_is_rejected_at_construction);
    ("matching owner reopens cleanly", `Quick, test_matching_owner_reopens_cleanly);
    ("an empty owner is rejected at construction", `Quick,
      test_an_empty_owner_is_rejected_at_construction);
    ("owner reads back the tag used at construction", `Quick,
      test_owner_reads_back_the_tag_used_at_construction);
    ( "Task 15: a 0-byte marker (crash between create and write) self-heals instead of \
       permanently bricking the directory",
      `Quick,
      test_a_zero_byte_marker_is_treated_as_unclaimed_not_as_owner_empty_string );
    ( "Task 15 review (Finding 3): check_or_write_owner_marker is atomic via \
       temp-then-rename-then-fsync",
      `Quick,
      test_check_or_write_owner_marker_is_atomic_via_temp_then_rename_then_fsync );
    ( "Task 15 review (Finding 3): the owner-marker write leaves no leftover temp file",
      `Quick,
      test_owner_marker_write_leaves_no_leftover_tmp_file );
    ( "Task 11: a second create on an already-locked directory is refused immediately",
      `Quick,
      test_a_second_create_on_a_locked_directory_is_refused );
    ( "Task 15 review (M4): a locked directory with a 0-byte marker omits the owner hint",
      `Quick,
      test_a_locked_directory_with_a_zero_byte_marker_omits_the_owner_hint );
    ( "Task 11: a create is refused while a REAL second OS process holds the real flock",
      `Quick,
      test_a_real_second_os_process_holding_the_lock_is_refused );
    ( "Task 11 review (I1): a failed create releases its lock before re-raising",
      `Quick,
      test_a_failed_create_releases_its_lock_before_reraising );
    ( "Task 16: concurrent same-key puts never produce torn/phantom values",
      `Quick,
      test_concurrent_same_key_puts_never_produce_a_torn_unreadable_record );
    ( "Task 17: File_kv_store.create/put/get do not depend on TMPDIR",
      `Quick,
      test_storage_operations_do_not_depend_on_tmpdir );
    ( "Task 18: path_for shards keys across two-level hash-prefix subdirectories",
      `Quick,
      test_path_for_shards_across_subdirectories );
    ( "Task 18: put/get/delete round-trip correctly through the sharded path",
      `Quick,
      test_put_get_delete_round_trip_through_sharded_path );
    ( "Task 18 (Ruling B): sweep_stale_temp_files still finds debris inside shard subdirectories",
      `Quick,
      test_sweep_still_finds_stale_temp_files_inside_shard_subdirectories );
    ( "Task 19 Bug 1: the downgrade guard matches only EINVAL, not any Eio.Io",
      `Quick,
      test_o_direct_downgrade_guard_matches_only_einval );
    ( "Task 19 Bug 2: downgrade marks direct_capable false before attempting the reopen",
      `Quick,
      test_downgrade_marks_direct_incapable_before_attempting_the_reopen );
    ( "Task 24: fold visits exactly each put key's own content hash, once each",
      `Quick,
      test_fold_visits_every_key_currently_present );
    ("Task 24: fold over an empty store visits nothing", `Quick, test_fold_over_an_empty_store_visits_nothing);
    ("Task 24: fold does not visit a deleted key", `Quick, test_fold_does_not_visit_a_deleted_key);
    ( "Task 24: get_by_hash reads back what fold finds, unlike get on the same hash",
      `Quick,
      test_get_by_hash_reads_back_what_fold_finds );
  ]
