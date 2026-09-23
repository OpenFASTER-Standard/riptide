(* Permanent regression coverage for [Riptide_storage.File_storage]'s durable single-entry
   primitive (Task 1 of the storage-fault-tolerant-recovery plan). These tests exercise real
   file I/O via [Eio_main.run] against a real temp directory on disk -- there is no mock
   filesystem layer to substitute here; the whole point is to prove the durable-write-then-
   read-after-restart primitive works for real, against this box's actual [eio_linux]/[Uring]
   [O_DIRECT]+[O_DSYNC] low-level path (Eio's portable API has no [fsync] on the installed
   Eio 0.12/OCaml 5.0.0). *)

open Riptide_storage

let with_tmp_dir f =
  let dir = Filename.temp_file "riptide_storage_test" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o700;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () -> f dir)

let test_write_then_read_same_handle () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) dir in
      File_storage.wal_append t ~op_number:1 "first entry";
      Alcotest.(check (option string))
        "read back what was written" (Some "first entry")
        (File_storage.wal_read t ~op_number:1))

let test_write_then_read_after_reopen () =
  (* Proves real durability, not just an in-process cache: close and reopen the same on-disk
     directory as a fresh [t], as a real restart would. *)
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      (Eio.Switch.run @@ fun sw ->
       let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) dir in
       File_storage.wal_append t ~op_number:1 "survives a restart");
      Eio.Switch.run @@ fun sw ->
      let t2 = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) dir in
      Alcotest.(check (option string))
        "still there after reopen" (Some "survives a restart")
        (File_storage.wal_read t2 ~op_number:1))

let test_out_of_order_append_rejected () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) dir in
      File_storage.wal_append t ~op_number:1 "one";
      Alcotest.check_raises "op_number 3 after 1 is out of order"
        (Invalid_argument "wal_append: op_number 3 is not wal_highest_op_number t + 1")
        (fun () -> File_storage.wal_append t ~op_number:3 "skips two"))

let test_read_never_written_is_none () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) dir in
      Alcotest.(check (option string))
        "nothing written yet" None
        (File_storage.wal_read t ~op_number:1))

let test_highest_op_number_tracks_appends () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) dir in
      Alcotest.(check int) "empty WAL" 0 (File_storage.wal_highest_op_number t);
      File_storage.wal_append t ~op_number:1 "a";
      File_storage.wal_append t ~op_number:2 "b";
      Alcotest.(check int) "after two appends" 2 (File_storage.wal_highest_op_number t))

let test_empty_entry_round_trips () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) dir in
      File_storage.wal_append t ~op_number:1 "";
      Alcotest.(check (option string))
        "an appended empty string reads back as Some \"\", not None" (Some "")
        (File_storage.wal_read t ~op_number:1))

let tests =
  [
    ("write then read, same handle", `Quick, test_write_then_read_same_handle);
    ("write then read, after reopen (real durability)", `Quick, test_write_then_read_after_reopen);
    ("out-of-order append rejected", `Quick, test_out_of_order_append_rejected);
    ("read of never-written op_number is None", `Quick, test_read_never_written_is_none);
    ("wal_highest_op_number tracks appends", `Quick, test_highest_op_number_tracks_appends);
    ("empty entry round-trips as Some \"\"", `Quick, test_empty_entry_round_trips);
  ]
