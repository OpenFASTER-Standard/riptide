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

(* Reviewer-traced regression (Important finding on the core deliverable): a dropped write used to
   skip delegating to the underlying entirely, so the underlying's own [wal_highest_op_number]
   never advanced past the dropped entry. The *caller's* very next legitimate sequential append
   then fell through to the passthrough branch, reached the underlying's out-of-order guard
   expecting [op_number = wal_highest_op_number + 1], and raised [Invalid_argument] -- a crash that
   looks like a caller bug, not an observable storage fault. This uses two [t] values wrapping the
   *same* underlying [File_storage.t] (rather than one [t] throughout) specifically so the second
   append is genuinely non-dropped regardless of [drop_probability] -- [fault_config] is fixed for
   a [t]'s whole lifetime, so varying it call-to-call needs either [set_fault_config] (used in the
   truncate test below) or, as here, a second wrapper. This is also exactly the shape of the
   restart-like scenario the [corrupt_probability] doc comment already flags: a fresh wrapper has
   no memory of the first wrapper's fault bookkeeping. *)
let test_drop_then_legitimate_append_does_not_raise () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let underlying = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) dir in
      let prng = Riptide_sim.Prng.create 5 in
      let dropping =
        Fault_injecting_storage.create ~prng
          ~fault_config:{ Fault_injecting_storage.default_fault_config with drop_probability = 1.0 }
          ~replication_quorum:4 ~underlying:(module File_storage) underlying
      in
      Fault_injecting_storage.wal_append dropping ~op_number:1 "dropped, never really persisted";
      (* The core claim: this must NOT raise. Before the fix, it raised
         [Invalid_argument "wal_append: op_number 2 is not wal_highest_op_number t + 1"] because
         the underlying's own highest op_number was still 0. *)
      let clean =
        Fault_injecting_storage.create ~prng ~replication_quorum:4
          ~underlying:(module File_storage) underlying
      in
      Fault_injecting_storage.wal_append clean ~op_number:2 "legitimate, sequential";
      Alcotest.(check (option string))
        "dropped op_number 1 reads back None on the wrapper that actually dropped it" None
        (Fault_injecting_storage.wal_read dropping ~op_number:1);
      Alcotest.(check (option string))
        "the legitimate op_number 2 that followed the drop reads back correctly"
        (Some "legitimate, sequential")
        (Fault_injecting_storage.wal_read clean ~op_number:2))

(* Same design decision (dropped-write bookkeeping should behave like [corrupted_slots]), applied
   to [wal_truncate_after]: a dropped op_number that gets truncated away and later legitimately
   re-written at the same op_number must read back the real data, not stay masked forever by stale
   [dropped_slots] bookkeeping. [set_fault_config] toggles the fault regime mid-lifetime on the
   *same* [t] specifically so this test can isolate "did the truncate actually clear the
   bookkeeping" from "a fresh wrapper never had it in the first place" (the confound the previous
   test's two-wrapper pattern can't rule out). *)
let test_wal_truncate_after_clears_dropped_slots () =
  with_wrapped
    ~fault_config:{ Fault_injecting_storage.default_fault_config with drop_probability = 1.0 }
    ~replication_quorum:4 ~seed:6
    (fun t ->
      Fault_injecting_storage.wal_append t ~op_number:1 "dropped, then truncated away";
      Fault_injecting_storage.wal_truncate_after t ~op_number:0;
      Fault_injecting_storage.set_fault_config t Fault_injecting_storage.default_fault_config;
      Fault_injecting_storage.wal_append t ~op_number:1 "real data written after the truncate";
      Alcotest.(check (option string))
        "re-written op_number 1 is not left masked by stale dropped_slots bookkeeping"
        (Some "real data written after the truncate")
        (Fault_injecting_storage.wal_read t ~op_number:1))

let tests =
  [ ( "corrupt_probability = 1.0 really corrupts (wal_read returns None)", `Quick,
      test_corrupt_probability_one_makes_read_return_none );
    ("corrupt_probability = 0.0 never corrupts", `Quick, test_corrupt_probability_zero_never_corrupts);
    ("faults_max = replication_quorum - 1 is enforced, raises when exceeded", `Quick,
      test_faults_max_exceeded_raises);
    ( "faults_max cap frees up once a corrupted slot is truncated away", `Quick,
      test_faults_max_cap_frees_up_after_truncate );
    ( "a drop followed by a legitimate sequential append does not raise", `Quick,
      test_drop_then_legitimate_append_does_not_raise );
    ( "wal_truncate_after clears dropped_slots bookkeeping the same way it clears corrupted_slots",
      `Quick, test_wal_truncate_after_clears_dropped_slots )
  ]
