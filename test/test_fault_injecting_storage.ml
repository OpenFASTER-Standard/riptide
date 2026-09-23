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
      let underlying = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity:8 dir in
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
      let underlying = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity:8 dir in
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

(* ============================================================================================
   Task 8's own addition: [for_test_corrupt_entry], the DETERMINISTIC counterpart of the
   probabilistic [corrupt_probability] path above. A cluster test that wants to prove recovery
   from a specific replica's specific corrupted op-number cannot use the probabilistic path at
   all: that one only ever fires at *write* time, on whichever appends happen to draw it, and a
   test that has already settled a cluster into a known-good state has no write left to attach it
   to. Everything below runs against a real [File_storage] (not [Memory_storage]) on purpose --
   these are the tests that have to prove the bytes on the actual disk changed. *)

let with_wrapped_and_underlying ?fault_config ~replication_quorum ~seed f =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let underlying = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity:8 dir in
      let prng = Riptide_sim.Prng.create seed in
      let t =
        Fault_injecting_storage.create ~prng ?fault_config ~replication_quorum
          ~underlying:(module File_storage) underlying
      in
      f t underlying)

(* The core claim, and the reason this function exists rather than the test poking [wal_read]'s
   result: the corruption is REAL and ON DISK. Proven three independent ways in one test --
   (a) through this wrapper, the slot reads [None]; (b) through the underlying [File_storage]
   directly, bypassing this wrapper's own [corrupted_slots] mask entirely, the bytes that come
   back are NOT the ones that were written (the flip really reached the durable representation,
   which is exactly what a later reader that does not share this wrapper's in-memory bookkeeping
   would see); (c) [wal_highest_op_number] is UNCHANGED, which is what makes this VSR.tla's
   "corrupt" state rather than its "absent" state -- the distinction the whole nack-soundness
   argument rests on (see [Memory_storage.for_test_corrupt]'s own doc comment). *)
let test_for_test_corrupt_entry_really_corrupts_the_durable_entry () =
  with_wrapped_and_underlying ~replication_quorum:3 ~seed:7 (fun t underlying ->
      Fault_injecting_storage.wal_append t ~op_number:1 "entry one";
      Fault_injecting_storage.wal_append t ~op_number:2 "entry two, the victim";
      Fault_injecting_storage.wal_append t ~op_number:3 "entry three";
      Fault_injecting_storage.for_test_corrupt_entry t ~op_number:2;
      Alcotest.(check (option string)) "(a) the corrupted slot reads back None through the wrapper" None
        (Fault_injecting_storage.wal_read t ~op_number:2);
      Alcotest.(check bool)
        "(b) and the bytes on the real File_storage underneath are genuinely no longer the original"
        true
        (File_storage.wal_read underlying ~op_number:2 <> Some "entry two, the victim");
      Alcotest.(check int) "(c) wal_highest_op_number is untouched: this is CORRUPT, never ABSENT" 3
        (Fault_injecting_storage.wal_highest_op_number t);
      (* The neighbours are collateral this must not damage: corrupting a MIDDLE entry goes through
         a truncate-and-rewrite (Storage_intf.S has no random-access write), so the suffix above it
         has to be restored byte-for-byte. *)
      Alcotest.(check (option string)) "the entry below the victim is untouched" (Some "entry one")
        (Fault_injecting_storage.wal_read t ~op_number:1);
      Alcotest.(check (option string)) "the entry ABOVE the victim survived the rewrite verbatim"
        (Some "entry three")
        (Fault_injecting_storage.wal_read t ~op_number:3))

(* The cap is the same one the probabilistic path enforces (Decision 7) -- deliberately NOT
   bypassed just because this entry point is explicit and test-only. One invariant, one meaning,
   whichever path got there: this wrapper never holds more than [faults_max] live corrupted slots. *)
let test_for_test_corrupt_entry_respects_faults_max () =
  with_wrapped_and_underlying ~replication_quorum:2 (* faults_max = 1 *) ~seed:8 (fun t _underlying ->
      Fault_injecting_storage.wal_append t ~op_number:1 "a";
      Fault_injecting_storage.wal_append t ~op_number:2 "b";
      Fault_injecting_storage.for_test_corrupt_entry t ~op_number:1;
      Alcotest.check_raises "a second live corrupted slot exceeds faults_max = 1"
        (Invalid_argument "faults_max exceeded") (fun () ->
          Fault_injecting_storage.for_test_corrupt_entry t ~op_number:2))

(* An op-number with nothing durable behind it must RAISE, never be a silent no-op. A silent no-op
   is the specific failure mode that makes a corruption-recovery test pass vacuously: the test
   believes it injected a fault, nothing was injected, and the "recovery" it then asserts is just
   an ordinary fault-free run. ([Memory_storage.for_test_corrupt] is documented as a no-op out of
   range; this one deliberately diverges, because its only callers are tests whose whole premise is
   that the fault landed.) *)
let test_for_test_corrupt_entry_raises_out_of_range_rather_than_silently_doing_nothing () =
  with_wrapped_and_underlying ~replication_quorum:3 ~seed:9 (fun t _underlying ->
      Fault_injecting_storage.wal_append t ~op_number:1 "only entry";
      Alcotest.check_raises "above the durable range"
        (Invalid_argument "for_test_corrupt_entry: no readable durable entry at that op_number")
        (fun () -> Fault_injecting_storage.for_test_corrupt_entry t ~op_number:2);
      Alcotest.check_raises "below the durable range (op-numbers are 1-indexed)"
        (Invalid_argument "for_test_corrupt_entry: no readable durable entry at that op_number")
        (fun () -> Fault_injecting_storage.for_test_corrupt_entry t ~op_number:0);
      Alcotest.(check (option string)) "and the real entry was left completely alone"
        (Some "only entry")
        (Fault_injecting_storage.wal_read t ~op_number:1);
      (* The same rule applied to an ALREADY-corrupted slot, which is the non-obvious case: the
         wrapped backend still hands those bytes back happily (they are self-consistent down
         there -- only this wrapper's own bookkeeping makes them [None]), so judging readability
         by the wrapped backend alone would silently "corrupt" a slot with no intact entry left to
         destroy -- and, at replication_quorum 3, would do so without even tripping faults_max. *)
      Fault_injecting_storage.for_test_corrupt_entry t ~op_number:1;
      Alcotest.check_raises "a slot this wrapper has already corrupted"
        (Invalid_argument "for_test_corrupt_entry: no readable durable entry at that op_number")
        (fun () -> Fault_injecting_storage.for_test_corrupt_entry t ~op_number:1))

(* [wal_truncate_after] must free a [for_test_corrupt_entry]-corrupted slot's bookkeeping exactly
   the way it frees a probabilistically-corrupted one -- the property the cluster tests' durable
   REPAIR assertions rest on: [Replica]'s own log adoption truncates to the longest correct prefix
   and re-appends, so a slot that stayed masked forever would make a genuinely repaired entry still
   read back as [None]. *)
let test_for_test_corrupt_entry_bookkeeping_is_cleared_by_truncate () =
  with_wrapped_and_underlying ~replication_quorum:3 ~seed:10 (fun t _underlying ->
      Fault_injecting_storage.wal_append t ~op_number:1 "a";
      Fault_injecting_storage.wal_append t ~op_number:2 "b";
      Fault_injecting_storage.for_test_corrupt_entry t ~op_number:2;
      Alcotest.(check (option string)) "corrupted" None (Fault_injecting_storage.wal_read t ~op_number:2);
      Fault_injecting_storage.wal_truncate_after t ~op_number:1;
      Fault_injecting_storage.wal_append t ~op_number:2 "b, rewritten by a repair";
      Alcotest.(check (option string)) "the repaired entry is readable again, not masked by stale bookkeeping"
        (Some "b, rewritten by a repair")
        (Fault_injecting_storage.wal_read t ~op_number:2))

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
      `Quick, test_wal_truncate_after_clears_dropped_slots );
    ( "for_test_corrupt_entry really corrupts the durable entry, leaving its neighbours intact",
      `Quick, test_for_test_corrupt_entry_really_corrupts_the_durable_entry );
    ("for_test_corrupt_entry respects faults_max too", `Quick, test_for_test_corrupt_entry_respects_faults_max);
    ( "for_test_corrupt_entry raises out of range rather than silently doing nothing", `Quick,
      test_for_test_corrupt_entry_raises_out_of_range_rather_than_silently_doing_nothing );
    ( "a for_test_corrupt_entry slot's bookkeeping is cleared by a truncate, so a repair is visible",
      `Quick, test_for_test_corrupt_entry_bookkeeping_is_cleared_by_truncate )
  ]
