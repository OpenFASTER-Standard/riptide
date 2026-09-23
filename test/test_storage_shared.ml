(* test/test_storage_shared.ml

   The [Storage.S] analogue of [test_transport_shared.ml]'s own precedent: a shared, functor-
   parameterized test body ([Make_storage_tests]) that never references [File_storage] or
   [Fault_injecting_storage] by name -- it only ever sees an abstract [S.t] plus [S.wal_append] /
   [S.wal_read] / [S.wal_truncate_after] / [S.wal_highest_op_number] / [S.superblock_write] /
   [S.superblock_read] -- run against two real instantiations below it. That's the actual
   conformance proof this task exists to produce: at zero fault probability,
   [Fault_injecting_storage] must behave identically to [File_storage], because both satisfy the
   exact same [Storage_intf.S] signature and the shared body exercises only that signature.

   [File_storage.t] holds live Eio resources (an open fd) tied to the [~sw:Eio.Switch.t] it was
   created with, and eio_linux closes those fds automatically once that switch finishes -- so,
   unlike [test_transport_shared.ml]'s [make : unit -> T.t] (which needs no ambient resource
   scope), a bare [unit -> S.t] here would hand back a value whose fd is already closed the
   instant [Eio.Switch.run] returns. Each shared test body is therefore parameterized on
   [with_storage : (S.t -> unit) -> unit] instead: a combinator that opens a fresh Eio_main.run +
   temp dir + Eio.Switch.run scope, builds one fresh [S.t] inside it, and keeps that scope open
   for exactly as long as the test body's callback runs -- the glue below (one [with_storage] per
   implementation) is the only implementation-specific code in this file. *)

open Riptide_storage

let with_tmp_dir f =
  let dir = Filename.temp_file "riptide_storage_shared_test" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o700;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () -> f dir)

module Make_storage_tests (S : Storage_intf.S) = struct
  let test_append_and_read (with_storage : (S.t -> unit) -> unit) () =
    with_storage (fun t ->
        S.wal_append t ~op_number:1 "hello";
        Alcotest.(check (option string)) "read back" (Some "hello") (S.wal_read t ~op_number:1))

  let test_read_never_written_is_none (with_storage : (S.t -> unit) -> unit) () =
    with_storage (fun t ->
        Alcotest.(check (option string)) "nothing written yet" None (S.wal_read t ~op_number:1))

  let test_highest_op_number_tracks_appends (with_storage : (S.t -> unit) -> unit) () =
    with_storage (fun t ->
        Alcotest.(check int) "empty WAL" 0 (S.wal_highest_op_number t);
        S.wal_append t ~op_number:1 "a";
        S.wal_append t ~op_number:2 "b";
        Alcotest.(check int) "after two appends" 2 (S.wal_highest_op_number t))

  (* Doesn't assert on the exact exception message -- that text is implementation-specific
     (e.g. [File_storage]'s own wording); the shared, implementation-agnostic part of the
     contract ([Storage_intf.S]'s doc comment on [wal_append]) is only that some
     [Invalid_argument] is raised. *)
  let test_out_of_order_append_rejected (with_storage : (S.t -> unit) -> unit) () =
    with_storage (fun t ->
        S.wal_append t ~op_number:1 "one";
        let raised =
          try
            S.wal_append t ~op_number:3 "skips two";
            false
          with Invalid_argument _ -> true
        in
        Alcotest.(check bool) "out-of-order append raises Invalid_argument" true raised)

  let test_truncate_after (with_storage : (S.t -> unit) -> unit) () =
    with_storage (fun t ->
        S.wal_append t ~op_number:1 "one";
        S.wal_append t ~op_number:2 "two";
        S.wal_append t ~op_number:3 "three";
        S.wal_truncate_after t ~op_number:1;
        Alcotest.(check int) "highest op number after truncate" 1 (S.wal_highest_op_number t);
        Alcotest.(check (option string)) "entry 2 gone" None (S.wal_read t ~op_number:2);
        S.wal_append t ~op_number:2 "replaces old entry 2";
        Alcotest.(check (option string))
          "new entry 2 present" (Some "replaces old entry 2") (S.wal_read t ~op_number:2))

  let test_superblock_round_trip (with_storage : (S.t -> unit) -> unit) () =
    with_storage (fun t ->
        Alcotest.(check (option string)) "nothing written yet" None (S.superblock_read t);
        S.superblock_write t "view=3,commit=7";
        Alcotest.(check (option string))
          "superblock read back" (Some "view=3,commit=7") (S.superblock_read t))

  let shared_tests (with_storage : (S.t -> unit) -> unit) =
    [ ("append and read", `Quick, test_append_and_read with_storage);
      ("read of never-written op_number is None", `Quick, test_read_never_written_is_none with_storage);
      ( "wal_highest_op_number tracks appends", `Quick,
        test_highest_op_number_tracks_appends with_storage );
      ("out-of-order append rejected", `Quick, test_out_of_order_append_rejected with_storage);
      ( "wal_truncate_after discards later entries, then allows re-append", `Quick,
        test_truncate_after with_storage );
      ("superblock write then read (round trip)", `Quick, test_superblock_round_trip with_storage)
    ]
end

(* -- File_storage glue: the ONLY implementation-specific code for this instantiation -- *)

module File_storage_tests = Make_storage_tests (File_storage)

let with_file_storage f =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      f (File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) dir))

let file_storage_tests = File_storage_tests.shared_tests with_file_storage

(* -- Fault_injecting_storage glue: the ONLY implementation-specific code for this instantiation --

   [replication_quorum:3] (=> [faults_max = 2]) and [default_fault_config] (all probabilities
   0.0) throughout -- this conformance run's entire point is proving zero-fault behavior is
   identical to [File_storage]'s, not exercising the fault path (that's
   [test_fault_injecting_storage.ml]'s job, Step 6 of the task brief). *)

module Fault_injecting_storage_tests = Make_storage_tests (Fault_injecting_storage)

let with_fault_injecting_storage f =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let underlying = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) dir in
      let prng = Riptide_sim.Prng.create 1 in
      let t =
        Fault_injecting_storage.create ~prng ~replication_quorum:3
          ~underlying:(module File_storage) underlying
      in
      f t)

let fault_injecting_storage_tests =
  Fault_injecting_storage_tests.shared_tests with_fault_injecting_storage
