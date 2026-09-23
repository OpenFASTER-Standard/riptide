(* Regression coverage for [Riptide_storage.File_kv_store] -- a durable, keyed store with real
   per-key deletion (Task 2 of the lattice-materialization-redaction-encryption plan). Distinct
   from [Test_file_storage]'s bounded-ring-WAL conformance suite: this store has no notion of
   op_number/ring capacity at all, just an arbitrary number of independently-deletable keys, one
   file per key. Real file I/O via [Eio_main.run] against a real temp directory -- same rationale
   as [Test_file_storage]: there is no mock filesystem layer to substitute for proving durability
   across a real reopen. *)

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

let tests =
  [
    ("put then get", `Quick, test_put_then_get);
    ("get of never-put key is None", `Quick, test_get_of_never_put_key_is_none);
    ("delete is durable across reopen", `Quick, test_delete_is_durable_across_reopen);
    ("put overwrites", `Quick, test_put_overwrites);
  ]
