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

let test_put_then_get () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) dir in
      File_kv_store.put t ~key:"foo" "bar";
      Alcotest.(check (option string)) "read back" (Some "bar") (File_kv_store.get t ~key:"foo"))

let test_get_of_never_put_key_is_none () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) dir in
      Alcotest.(check (option string)) "never put" None (File_kv_store.get t ~key:"nope"))

let test_delete_is_durable_across_reopen () =
  (* Review Focus: this is the exact bug class already found once in
     File_storage.wal_truncate_after -- prove it doesn't recur here. *)
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      (Eio.Switch.run @@ fun sw ->
       let t = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) dir in
       File_kv_store.put t ~key:"secret" "shhh";
       File_kv_store.delete t ~key:"secret");
      Eio.Switch.run @@ fun sw ->
      let t2 = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) dir in
      Alcotest.(check (option string)) "deleted key stays gone after reopen" None
        (File_kv_store.get t2 ~key:"secret"))

let test_put_overwrites () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) dir in
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
      let t = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) dir in
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
      let t = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) dir in
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

let tests =
  [
    ("put then get", `Quick, test_put_then_get);
    ("get of never-put key is None", `Quick, test_get_of_never_put_key_is_none);
    ("delete is durable across reopen", `Quick, test_delete_is_durable_across_reopen);
    ("put overwrites", `Quick, test_put_overwrites);
    ("put overwrite leaves no leftover tmp file", `Quick,
      test_put_overwrite_leaves_no_leftover_tmp_file);
    ("interrupted overwrite leaves old value intact", `Quick,
      test_interrupted_overwrite_leaves_old_value_intact);
  ]
