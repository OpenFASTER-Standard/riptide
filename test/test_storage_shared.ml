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

  (* TASK 13 FIX ROUND (review finding 6): the CONTRACT of
     [Storage_intf.S.superblock_rebuild_from_wal], exercised uniformly against every conforming
     backend. Its absence is exactly what let the [Fault_injecting_storage] bug (finding 3 -- a
     rebuild that raised [Invalid_argument] unconditionally, in the one state it exists to repair)
     ship behind a fully green suite: that backend had no rebuild test of its own, and the two
     backend-specific ones that did exist could not have caught it.

     Four clauses, all of them implementation-independent -- exactly what a shared body can assert:
     (1) the precondition refuses on a virgin backend (finding M8); (2) over a populated WAL with no
     superblock, the rebuild succeeds; (3) what it writes DECODES, as a record carrying the
     operator-supplied values verbatim and an [op_number] matching the durable WAL -- decoded through
     [Superblock_record], the single shared schema definition [Riptide_vsr.Replica]'s own
     [superblock_decode] now delegates to (finding 5), so this really does assert "a replica could
     restart on this"; (4) the precondition then refuses a SECOND rebuild, since there is now a
     perfectly good superblock to protect.

     Deliberately NON-ZERO, mutually distinct values for the three supplied fields -- [(view_number,
     last_normal_view, commit_number) = (4, 3, 1)], with [last_normal_view < view_number] so the
     record also describes a genuine mid-view-change state rather than the easy [Normal] case. Zeros
     would pass clause (3) against an implementation that ignored its arguments entirely and
     hardcoded them, which is precisely the defect finding 1 is about; distinct values also catch a
     transposed pair, which equal ones cannot. *)
  let test_superblock_rebuild_from_wal_contract (with_storage : (S.t -> unit) -> unit) () =
    with_storage (fun t ->
        let refused f =
          try
            f ();
            false
          with Invalid_argument _ -> true
        in
        Alcotest.(check bool)
          "an empty backend is FIRST BOOT, not a lost superblock: the rebuild refuses" true
          (refused (fun () ->
               S.superblock_rebuild_from_wal t ~view_number:0 ~last_normal_view:0 ~commit_number:0));
        S.wal_append t ~op_number:1 "one";
        S.wal_append t ~op_number:2 "two";
        S.wal_append t ~op_number:3 "three";
        Alcotest.(check (option string)) "precondition: no superblock over a populated WAL" None
          (S.superblock_read t);
        S.superblock_rebuild_from_wal t ~view_number:4 ~last_normal_view:3 ~commit_number:1;
        Alcotest.(check bool) "the rebuild wrote something" true
          (S.superblock_read t <> None);
        Alcotest.(check bool)
          "and it decodes as the exact record a Replica.restart would recover: op_number from the \
           WAL, the other three supplied verbatim"
          true
          (Option.bind (S.superblock_read t) Superblock_record.decode
          = Some
              { Superblock_record.view_number = 4;
                last_normal_view = 3;
                op_number = 3;
                commit_number = 1
              });
        Alcotest.(check bool)
          "a second rebuild now refuses -- there is a perfectly good superblock to protect" true
          (refused (fun () ->
               S.superblock_rebuild_from_wal t ~view_number:4 ~last_normal_view:3 ~commit_number:1)))

  let shared_tests (with_storage : (S.t -> unit) -> unit) =
    [ ("append and read", `Quick, test_append_and_read with_storage);
      ("read of never-written op_number is None", `Quick, test_read_never_written_is_none with_storage);
      ( "wal_highest_op_number tracks appends", `Quick,
        test_highest_op_number_tracks_appends with_storage );
      ("out-of-order append rejected", `Quick, test_out_of_order_append_rejected with_storage);
      ( "wal_truncate_after discards later entries, then allows re-append", `Quick,
        test_truncate_after with_storage );
      ("superblock write then read (round trip)", `Quick, test_superblock_round_trip with_storage);
      ( "Task 13 fix (finding 6): superblock_rebuild_from_wal's contract", `Quick,
        test_superblock_rebuild_from_wal_contract with_storage )
    ]
end

(* -- File_storage glue: the ONLY implementation-specific code for this instantiation -- *)

module File_storage_tests = Make_storage_tests (File_storage)

let with_file_storage f =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      f (File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity:8 dir))

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
      let underlying = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity:8 dir in
      let prng = Riptide_sim.Prng.create 1 in
      let t =
        Fault_injecting_storage.create ~prng ~replication_quorum:3
          ~underlying:(module File_storage) underlying
      in
      f t)

let fault_injecting_storage_tests =
  Fault_injecting_storage_tests.shared_tests with_fault_injecting_storage

(* -- Memory_storage glue: the ONLY implementation-specific code for this instantiation --

   The shortest [with_storage] of the three, and that is the point: [Memory_storage.t] holds no
   Eio resource, so there is no [Eio_main.run]/[Eio.Switch.run]/temp-dir scope to keep open around
   the callback. It is run through the same shared body as the other two precisely so "the backend
   the VSR replica unit tests construct" is a conformance-checked [Storage_intf.S], not a stub
   that only happens to satisfy the calls those tests make. *)

module Memory_storage_tests = Make_storage_tests (Memory_storage)

let with_memory_storage f = f (Memory_storage.create ())
let memory_storage_tests = Memory_storage_tests.shared_tests with_memory_storage
