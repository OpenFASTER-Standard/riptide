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
   temp-file layout, so it's mirrored here deliberately, purely for these two tests -- if
   [file_kv_store.ml]'s own [path_for]/[tmp_suffix] ever changes, these two tests fail loudly
   (the leftover-tmp / manufactured-crash-debris assertions below) rather than silently. *)
let key_hash_hex key =
  Riptide.Value.hash_to_hex
    (Riptide.Value.content_hash (Riptide.Value.Scalar (Riptide.Value.String key)))

let tmp_suffix = ".put.tmp"
let real_path_for dir key = Filename.concat dir (key_hash_hex key)
let tmp_path_for dir key = real_path_for dir key ^ tmp_suffix

let test_put_overwrite_leaves_no_leftover_tmp_file () =
  (* Review Focus: a successful overwrite's staged temp file must be gone (renamed away, not
     merely written and left behind) once [put] returns, and the real path must hold exactly
     the new value -- the normal-path half of the atomic-overwrite fix. *)
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"test" dir in
      File_kv_store.put t ~key:"k" "v1";
      File_kv_store.put t ~key:"k" "v2";
      Alcotest.(check bool) "no leftover temp file after rename" false
        (Sys.file_exists (tmp_path_for dir "k"));
      Alcotest.(check bool) "real file exists" true (Sys.file_exists (real_path_for dir "k"));
      Alcotest.(check (option string)) "real file holds exactly the new value" (Some "v2")
        (File_kv_store.get t ~key:"k"))

let test_interrupted_overwrite_leaves_old_value_intact () =
  (* Review Focus: this is exactly the crash scenario the reviewer described -- a failure
     partway through a second [put]'s write-to-temp phase must leave the key's already-durable
     value fully intact and readable, never a torn header/data mix. A real [put] always writes
     its full header+data record into [tmp_path_for dir "k"] *before* ever calling [rename]; we
     stand in for "the process died at some point during that write" by dropping clearly-invalid
     bytes at that same temp path directly and never renaming it -- precisely what an
     interrupted writer could never do either, since only [put] itself ever calls [rename]. *)
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"test" dir in
      File_kv_store.put t ~key:"k" "original";
      let oc = open_out_bin (tmp_path_for dir "k") in
      output_string oc "garbage-partial-write-left-by-a-simulated-crash";
      close_out oc;
      Alcotest.(check (option string)) "old value still fully intact and readable" (Some "original")
        (File_kv_store.get t ~key:"k");
      (* A later, successful put must still work correctly despite the stale temp-file debris
         a real crash would also have left behind. *)
      File_kv_store.put t ~key:"k" "new";
      Alcotest.(check (option string)) "subsequent put still succeeds" (Some "new")
        (File_kv_store.get t ~key:"k"))

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
   2. [test_put_and_delete_both_fsync_the_directory] is a source-level guard on the two call sites
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
  let rec find = function
    | [] -> Alcotest.failf "no top-level binding %S found in %s" name file_kv_store_source_path
    | line :: rest ->
      if starts_binding line && String.length line >= 4 + String.length name
         && String.sub line 4 (String.length name) = name then
        let rec take acc = function
          | [] -> List.rev acc
          | l :: tl ->
            if l <> "" && l.[0] <> ' ' && l.[0] <> ')' then List.rev acc else take (l :: acc) tl
        in
        String.concat "\n" (line :: take [] rest)
      else find rest
  in
  find lines

let contains ~needle haystack =
  let nl = String.length needle and hl = String.length haystack in
  let rec go i = i + nl <= hl && (String.sub haystack i nl = needle || go (i + 1)) in
  nl = 0 || go 0

let index_of ~needle haystack =
  let nl = String.length needle and hl = String.length haystack in
  let rec go i =
    if i + nl > hl then None else if String.sub haystack i nl = needle then Some i else go (i + 1)
  in
  go 0

let test_put_and_delete_both_fsync_the_directory () =
  let source = read_file file_kv_store_source_path in
  let durable_write = top_level_binding_body source "durable_write" in
  Alcotest.(check bool)
    "durable_write still publishes via Eio.Path.rename" true
    (contains ~needle:"Eio.Path.rename" durable_write);
  Alcotest.(check bool)
    "durable_write fsyncs the containing directory (Finding 1 regression guard)" true
    (contains ~needle:"fsync_dir t" durable_write);
  (* Ordering matters, not just presence: syncing the directory before the rename would sync a
     state that does not yet contain the new entry, which is no guarantee at all. *)
  (match
     (index_of ~needle:"Eio.Path.rename" durable_write, index_of ~needle:"fsync_dir t" durable_write)
   with
  | Some rename_at, Some fsync_at ->
    Alcotest.(check bool) "the fsync_dir comes AFTER the rename, not before" true (fsync_at > rename_at)
  | _ -> Alcotest.fail "expected both Eio.Path.rename and fsync_dir t in durable_write's body");
  let delete_body = top_level_binding_body source "delete" in
  Alcotest.(check bool)
    "delete still fsyncs the containing directory too" true
    (contains ~needle:"fsync_dir t" delete_body)

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

(* Task 11: the PHYSICAL guard -- see [Test_file_storage]'s own copy of this comment (identical
   rationale, [File_kv_store.create] instead of [File_storage.create]) for the full account of the
   Critical finding this closes and why [flock(2)], not [Unix.lockf], is what makes the
   same-process test below actually observe a conflict. *)
let expected_lock_message ~caller dir =
  Invalid_argument
    (Printf.sprintf
       "%s: %s is already locked by another open handle (a real flock(2), not this codebase's \
        separate logical owner-tag check -- see Riptide_storage.Dir_lock's own .mli)"
       caller dir)

let test_a_second_create_on_a_locked_directory_is_refused () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let (_ : File_kv_store.t) =
        File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"redaction-keystore" dir
      in
      (* Even a DIFFERENT owner tag is refused by the lock, before the marker is ever consulted --
         the physical guard runs first and does not care what either side calls itself. *)
      Alcotest.check_raises
        "a second create on the same directory, while the first handle is still live, is refused \
         immediately regardless of the owner tag it passes"
        (expected_lock_message ~caller:"File_kv_store.create" dir)
        (fun () ->
          ignore (File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"materializer" dir)))

(* Stronger evidence than the same-process double-handle above: a REAL second OS process -- see
   [Test_file_storage.test_a_real_second_os_process_holding_the_lock_is_refused] for the full
   rationale (forked before any Eio event loop exists in this test; the child never touches Eio,
   only plain blocking [Unix]/[flock(2)] calls through the same C symbol [Dir_lock] itself uses). *)
external test_only_flock_exclusive_nonblocking : Unix.file_descr -> bool
  = "riptide_flock_exclusive_nonblocking"

let test_a_real_second_os_process_holding_the_lock_is_refused () =
  with_tmp_dir (fun dir ->
      (try Unix.mkdir dir 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
      let lock_path = Filename.concat dir ".riptide-lock" in
      let ready_r, ready_w = Unix.pipe () in
      let release_r, release_w = Unix.pipe () in
      match Unix.fork () with
      | 0 ->
        Unix.close ready_r;
        Unix.close release_w;
        let fd = Unix.openfile lock_path [ Unix.O_RDWR; Unix.O_CREAT ] 0o600 in
        if not (test_only_flock_exclusive_nonblocking fd) then Unix._exit 1;
        ignore (Unix.write ready_w (Bytes.of_string "1") 0 1);
        ignore (Unix.read release_r (Bytes.create 1) 0 1);
        Unix._exit 0
      | child_pid ->
        Unix.close ready_w;
        Unix.close release_r;
        Fun.protect
          ~finally:(fun () ->
            (try ignore (Unix.write release_w (Bytes.of_string "1") 0 1) with Unix.Unix_error _ -> ());
            ignore (Unix.waitpid [] child_pid))
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
    ("put and delete both fsync the directory", `Quick,
      test_put_and_delete_both_fsync_the_directory);
    ("owner mismatch is rejected at construction", `Quick,
      test_owner_mismatch_is_rejected_at_construction);
    ("matching owner reopens cleanly", `Quick, test_matching_owner_reopens_cleanly);
    ("an empty owner is rejected at construction", `Quick,
      test_an_empty_owner_is_rejected_at_construction);
    ("owner reads back the tag used at construction", `Quick,
      test_owner_reads_back_the_tag_used_at_construction);
    ( "Task 11: a second create on an already-locked directory is refused immediately",
      `Quick,
      test_a_second_create_on_a_locked_directory_is_refused );
    ( "Task 11: a create is refused while a REAL second OS process holds the real flock",
      `Quick,
      test_a_real_second_os_process_holding_the_lock_is_refused );
  ]
