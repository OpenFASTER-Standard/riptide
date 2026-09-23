(* test/test_fault_injecting_storage.ml

   [test_storage_shared.ml] already proves [Fault_injecting_storage] conforms to [Storage_intf.S]
   at zero fault probability. This file is the adversarial half (Step 6 of the task brief): proof
   that the fault path is genuinely exercised, not vacuously present. Mirrors
   [test_sim_faults.ml]'s own precedent for [Network] ("corrupt_probability = 1.0 always applies
   corruption") -- same idea, applied to [Storage.S] instead of [Transport.S]. *)

open Riptide_storage

let with_tmp_dir f =
  let dir = Filename.temp_file "riptide_fault_injecting_storage_test" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o700;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () -> f dir)

let with_wrapped ?fault_config ~replication_quorum ~seed f =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let underlying = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) dir in
      let prng = Riptide_sim.Prng.create seed in
      let t =
        Fault_injecting_storage.create ~prng ?fault_config ~replication_quorum
          ~underlying:(module File_storage) underlying
      in
      f t)

(* The core adversarial claim: with [corrupt_probability = 1.0], a real [wal_append] really does
   flip a byte before delegating to the underlying write, so the subsequent [wal_read] genuinely
   comes back [None] (a checksum mismatch inside [File_storage]) -- not merely "capable of it in
   principle." A deliberately weakened version of [Fault_injecting_storage] (e.g. the corruption
   branch commented out, or the byte-flip turned into a no-op) makes this specific assertion fail:
   confirmed live by temporarily neutering [flip_one_byte] to the identity function and rerunning
   this test, which then failed as expected (see task-6-report.md for the transcript). *)
let test_corrupt_probability_one_makes_read_return_none () =
  with_wrapped
    ~fault_config:{ Fault_injecting_storage.default_fault_config with corrupt_probability = 1.0 }
    ~replication_quorum:4 (* faults_max = 3, plenty of headroom for one corrupted entry *)
    ~seed:1
    (fun t ->
      Fault_injecting_storage.wal_append t ~op_number:1 "will be corrupted before it ever hits disk";
      Alcotest.(check (option string))
        "corrupt_probability = 1.0 really does corrupt the entry, read comes back None" None
        (Fault_injecting_storage.wal_read t ~op_number:1))

(* Same idea, the other direction: [corrupt_probability = 0.0] (the default) must never corrupt --
   proves the fault decision is genuinely probability-driven, not e.g. always-on with the config
   ignored. *)
let test_corrupt_probability_zero_never_corrupts () =
  with_wrapped ~replication_quorum:4 ~seed:2 (fun t ->
      Fault_injecting_storage.wal_append t ~op_number:1 "never touched";
      Alcotest.(check (option string))
        "corrupt_probability = 0.0 (default) never corrupts" (Some "never touched")
        (Fault_injecting_storage.wal_read t ~op_number:1))

(* Decision 7's cap: [faults_max = replication_quorum - 1]. [replication_quorum:2] => [faults_max
   = 1] -- the first corrupted entry is allowed (0 live corrupted slots < 1), the second must be
   refused outright ([Invalid_argument], not silently skipped/downgraded to a clean write), since
   a second simultaneously-corrupted slot would exceed what the replication protocol can tolerate
   with only a 2-replica quorum. *)
let test_faults_max_exceeded_raises () =
  with_wrapped
    ~fault_config:{ Fault_injecting_storage.default_fault_config with corrupt_probability = 1.0 }
    ~replication_quorum:2 ~seed:3
    (fun t ->
      Fault_injecting_storage.wal_append t ~op_number:1 "first corrupted slot, within cap";
      Alcotest.check_raises "a second simultaneous corrupted slot exceeds faults_max = 1"
        (Invalid_argument "faults_max exceeded") (fun () ->
          Fault_injecting_storage.wal_append t ~op_number:2 "second corrupted slot, over cap"))

(* The cap is scoped to *live* corrupted slots, not a lifetime total: truncating away a corrupted
   entry must free its slot back up for a later corruption to reuse. *)
let test_faults_max_cap_frees_up_after_truncate () =
  with_wrapped
    ~fault_config:{ Fault_injecting_storage.default_fault_config with corrupt_probability = 1.0 }
    ~replication_quorum:2 ~seed:4
    (fun t ->
      Fault_injecting_storage.wal_append t ~op_number:1 "corrupted, then truncated away";
      Fault_injecting_storage.wal_truncate_after t ~op_number:0;
      (* op_number 1 no longer exists, so it must count as an out-of-order append re-admitting
         op_number 1 from scratch -- also proving the truncated slot really freed the cap. *)
      Fault_injecting_storage.wal_append t ~op_number:1 "corrupts again, cap should allow it")

let tests =
  [ ( "corrupt_probability = 1.0 really corrupts (wal_read returns None)", `Quick,
      test_corrupt_probability_one_makes_read_return_none );
    ("corrupt_probability = 0.0 never corrupts", `Quick, test_corrupt_probability_zero_never_corrupts);
    ("faults_max = replication_quorum - 1 is enforced, raises when exceeded", `Quick,
      test_faults_max_exceeded_raises);
    ( "faults_max cap frees up once a corrupted slot is truncated away", `Quick,
      test_faults_max_cap_frees_up_after_truncate )
  ]
