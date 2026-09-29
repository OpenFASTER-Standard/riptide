(* Permanent regression coverage for [Riptide_storage.File_storage]'s durable single-entry
   primitive (Task 1 of the storage-fault-tolerant-recovery plan). These tests exercise real
   file I/O via [Eio_main.run] against a real temp directory on disk -- there is no mock
   filesystem layer to substitute here; the whole point is to prove the durable-write-then-
   read-after-restart primitive works for real, against this box's actual [eio_linux]/[Uring]
   [O_DIRECT]+[O_DSYNC] low-level path (Eio's portable API has no [fsync] on the installed
   Eio 0.12/OCaml 5.0.0). *)

open Riptide_storage

(* Small, so a wraparound test is cheap to write. Passed explicitly at every [create] below:
   [~ring_capacity] is a required argument (final-review finding I4), so there is no longer any
   such thing as "the default ring capacity" for a test to silently inherit. *)
let ring_capacity = 8

let with_tmp_dir f =
  let dir = Filename.temp_file "riptide_storage_test" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o700;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () -> f dir)

(* Task 10 regression: counts this process's own [/proc/self/maps] lines, matching the audit's
   own measurement method for the [alloc_aligned_buffer]-per-I/O VMA leak (one line per distinct
   kernel mapping, so an unreleased [mmap] shows up here permanently until the process exits,
   regardless of what the OCaml GC later decides about the [Cstruct.t]/[Bigarray.t] wrapping it). *)
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

(* Task 10: reproduces the audit's own live measurement -- ~4 leaked VMAs per WAL op (one
   [alloc_aligned_buffer] mmap each for [write_header]/[write_data]/[read_header]/[read_data])
   under the PER-I/O-[mmap] implementation this task replaces. Against the buffer-pool
   implementation, the only real [mmap] calls happen once, when the pool's own fixed
   [pool_size] buffers are allocated inside [File_storage.create] -- before [before] is even
   sampled below -- so the map count should stay flat across the whole loop, not grow linearly
   with op count.

   {b [op_count] is 3,000, not the audit's own 20,000}, deliberately: this suite's own
   per-test wall-clock watchdog ([test_riptide.ml]'s [timeout_seconds], 15s, re-armed per test
   -- see its own "TASK 11 CORRECTION" comment for why it is per-test and how high it is
   calibrated) is a real budget this test must fit inside, not a number to work around. A real
   [O_DIRECT]+[O_DSYNC] append+read cycle against this box's actual disk is measured (a
   standalone probe against this exact fixed implementation, 2,000-5,000 cycle runs) at
   ~500-570 cycles/s -- i.e. dominated by genuine disk-durability latency, not by anything this
   task's fix touches -- so 20,000 cycles would take ~35-40s and blow the watchdog on its own,
   independent of whether the leak itself is fixed. 3,000 cycles (~6s at the measured rate,
   comfortable margin under 15s even on a slower/loaded machine) is still overwhelmingly enough
   to distinguish "flat" from "linear in op count": the pre-fix implementation leaks ~4 VMAs
   per op, so even a few hundred cycles would already blow past the [< 100] threshold below;
   3,000 gives a wide safety margin on the detection side while leaving a wide safety margin on
   the timing side too.

   {b RED/GREEN evidence, actually observed against these exact 3,000 ops (Task 10 review,
   Finding 1)} -- the original TDD evidence for this test was for a discarded 20,000-op version,
   and even that failed only via the suite's watchdog timeout, never via this assertion, so this
   exact test had never actually been run against unfixed code before. Confirmed properly by
   temporarily reverting [file_storage.ml]'s [perform_write_from_string]/[perform_read] to call a
   fresh per-I/O [mmap] directly (bypassing {!Riptide_storage.Aligned_buffer_pool} entirely,
   mirroring the pre-Task-10 implementation this task replaced) and running this exact test,
   unmodified, both ways:
   - {b RED} (reverted to per-I/O [mmap]): FAILED via the assertion itself, in 6.78s (well inside
     the 15s watchdog) -- [before=54 after=5802 delta=5748], nowhere close to the [< 100]
     threshold below.
   - {b GREEN} (the real, committed buffer-pool implementation): [before=46 after=46 delta=0] --
     not merely "under 100", genuinely flat. *)
let op_count = 3_000

let test_repeated_io_does_not_grow_the_process_map_count () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity dir in
      let before = count_self_maps () in
      for i = 1 to op_count do
        File_storage.wal_append t ~op_number:i "task 10: repeated I/O leak regression entry";
        ignore (File_storage.wal_read t ~op_number:i)
      done;
      let after = count_self_maps () in
      Alcotest.(check bool)
        (Printf.sprintf
           "map count stays flat, not linear in op count (before=%d after=%d delta=%d)" before
           after (after - before))
        true (after - before < 100))

let test_write_then_read_same_handle () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity dir in
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
       let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity dir in
       File_storage.wal_append t ~op_number:1 "survives a restart");
      Eio.Switch.run @@ fun sw ->
      let t2 = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity dir in
      Alcotest.(check (option string))
        "still there after reopen" (Some "survives a restart")
        (File_storage.wal_read t2 ~op_number:1))

let test_out_of_order_append_rejected () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity dir in
      File_storage.wal_append t ~op_number:1 "one";
      Alcotest.check_raises "op_number 3 after 1 is out of order"
        (Invalid_argument "wal_append: op_number 3 is not wal_highest_op_number t + 1")
        (fun () -> File_storage.wal_append t ~op_number:3 "skips two"))

let test_append_over_chunk_size_rejected () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity dir in
      let oversized = String.make 4097 'x' in
      Alcotest.check_raises "entry larger than one aligned data slot is rejected"
        (Invalid_argument
           "wal_append: entry of 4097 bytes exceeds this ring's max entry size of 4096 bytes \
            (one aligned data slot)")
        (fun () -> File_storage.wal_append t ~op_number:1 oversized))

let test_read_never_written_is_none () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity dir in
      Alcotest.(check (option string))
        "nothing written yet" None
        (File_storage.wal_read t ~op_number:1))

let test_highest_op_number_tracks_appends () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity dir in
      Alcotest.(check int) "empty WAL" 0 (File_storage.wal_highest_op_number t);
      File_storage.wal_append t ~op_number:1 "a";
      File_storage.wal_append t ~op_number:2 "b";
      Alcotest.(check int) "after two appends" 2 (File_storage.wal_highest_op_number t))

let test_empty_entry_round_trips () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity dir in
      File_storage.wal_append t ~op_number:1 "";
      Alcotest.(check (option string))
        "an appended empty string reads back as Some \"\", not None" (Some "")
        (File_storage.wal_read t ~op_number:1))

(* --- Task 2: fixed-size ring WAL, redundant headers, checksum verification --- *)

let test_ring_wraps_around () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity dir in
      for op = 1 to ring_capacity + 3 do
        File_storage.wal_append t ~op_number:op (Printf.sprintf "entry-%d" op)
      done;
      (* the ring only holds the most recent ring_capacity entries *)
      Alcotest.(check (option string)) "oldest entry evicted by wraparound" None
        (File_storage.wal_read t ~op_number:1);
      Alcotest.(check (option string)) "most recent entry present" (Some "entry-11")
        (File_storage.wal_read t ~op_number:(ring_capacity + 3)))

let test_custom_ring_capacity_is_honored () =
  (* Proves the [~ring_capacity] argument to [create] is real, not just accepted and ignored --
     with a ring of 3, the 4th append must evict op 1. *)
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity:3 dir in
      for op = 1 to 4 do
        File_storage.wal_append t ~op_number:op (Printf.sprintf "entry-%d" op)
      done;
      Alcotest.(check (option string)) "op 1 evicted by a ring of capacity 3" None
        (File_storage.wal_read t ~op_number:1);
      Alcotest.(check (option string)) "op 2 still present" (Some "entry-2")
        (File_storage.wal_read t ~op_number:2))

let test_truncate_after () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity dir in
      List.iter
        (fun op -> File_storage.wal_append t ~op_number:op (Printf.sprintf "e%d" op))
        [ 1; 2; 3 ];
      File_storage.wal_truncate_after t ~op_number:1;
      Alcotest.(check int) "highest op number after truncate" 1 (File_storage.wal_highest_op_number t);
      Alcotest.(check (option string)) "entry 2 gone" None (File_storage.wal_read t ~op_number:2);
      File_storage.wal_append t ~op_number:2 "replaces old entry 2";
      Alcotest.(check (option string)) "new entry 2 present" (Some "replaces old entry 2")
        (File_storage.wal_read t ~op_number:2))

(* FINAL-REVIEW FINDING I3: [wal_truncate_after] must be DURABLE, like every other write in this
   module, not merely an in-memory counter decrement.

   It used to lower [highest_op_number] and nothing else. The truncated entries' headers and data
   stayed on disk, so [recover_highest_op_number] found them again on the next [create] and
   RESURRECTED them -- [Memory_storage], which physically deletes, diverged from this module on the
   one operation whose whole purpose is to make entries go away. That divergence was structurally
   invisible to [test_storage_shared.ml]'s conformance suite, which has no reopen case at all
   (Memory_storage has no restart semantics to have one against), so it needs a test here.

   Why it matters rather than being cosmetic: a truncation is how a view change discards an
   uncommitted suffix. With a non-durable truncate, a crash between the truncate and the superblock
   write brings the replica back with the DISCARDED entries readable and presented as real, live
   log entries in its next DoViewChange -- stale values a peer can then adopt. With a durable one
   the same crash leaves those slots unreadable-in-range, i.e. VSR.tla's "corrupt", which is the
   conservative direction the whole storage model is built on. *)
let test_truncate_after_survives_reopen () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      (Eio.Switch.run @@ fun sw ->
       let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity dir in
       for op = 1 to 5 do
         File_storage.wal_append t ~op_number:op (Printf.sprintf "e%d" op)
       done;
       File_storage.wal_truncate_after t ~op_number:2;
       Alcotest.(check int) "truncated in memory" 2 (File_storage.wal_highest_op_number t));
      Eio.Switch.run @@ fun sw ->
      let t2 = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity dir in
      Alcotest.(check int) "the truncation survived the reopen -- entries 3..5 are NOT resurrected"
        2 (File_storage.wal_highest_op_number t2);
      List.iter
        (fun op ->
          Alcotest.(check (option string))
            (Printf.sprintf "op %d stays gone after reopen" op)
            None
            (File_storage.wal_read t2 ~op_number:op))
        [ 3; 4; 5 ];
      (* The surviving prefix is untouched, which is the other half of "durable": a truncate must
         not take anything below its own boundary with it. *)
      Alcotest.(check (option string)) "op 2 survived" (Some "e2") (File_storage.wal_read t2 ~op_number:2);
      Alcotest.(check (option string)) "op 1 survived" (Some "e1") (File_storage.wal_read t2 ~op_number:1);
      (* And the reopened backend is usable: the next append continues from the truncated point. *)
      File_storage.wal_append t2 ~op_number:3 "written after the reopen";
      Alcotest.(check (option string)) "op 3 is the newly written entry, not the resurrected one"
        (Some "written after the reopen")
        (File_storage.wal_read t2 ~op_number:3))

(* The same property where the ring makes it least obvious: a truncation spanning MORE op-numbers
   than the ring has slots. Every distinct slot must be invalidated exactly once, and nothing that
   is still live may be taken down with it. *)
let test_truncate_after_survives_reopen_past_a_full_ring () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      (Eio.Switch.run @@ fun sw ->
       let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity:3 dir in
       for op = 1 to 10 do
         File_storage.wal_append t ~op_number:op (Printf.sprintf "e%d" op)
       done;
       (* 10 -> 8 discards two ops across a ring of 3; ops 1..7 are already physically evicted. *)
       File_storage.wal_truncate_after t ~op_number:8);
      Eio.Switch.run @@ fun sw ->
      let t2 = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity:3 dir in
      Alcotest.(check int) "highest is the truncated value, not the resurrected 10" 8
        (File_storage.wal_highest_op_number t2);
      Alcotest.(check (option string)) "op 8 (still live) survived" (Some "e8")
        (File_storage.wal_read t2 ~op_number:8);
      List.iter
        (fun op ->
          Alcotest.(check (option string))
            (Printf.sprintf "op %d stays gone after reopen" op)
            None
            (File_storage.wal_read t2 ~op_number:op))
        [ 9; 10 ])

let test_truncate_after_is_noop_above_highest () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity dir in
      File_storage.wal_append t ~op_number:1 "one";
      File_storage.wal_truncate_after t ~op_number:5;
      Alcotest.(check int) "highest op number unchanged" 1 (File_storage.wal_highest_op_number t);
      Alcotest.(check (option string)) "entry 1 still present" (Some "one")
        (File_storage.wal_read t ~op_number:1))

let test_corrupted_entry_reads_as_none () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      (Eio.Switch.run @@ fun sw ->
       let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity dir in
       File_storage.wal_append t ~op_number:1 "will be corrupted on disk");
      (* Simulate corruption directly on disk, outside the Storage.S API -- this test is what
         proves the checksum path is real, not a no-op. The whole ring lives in one file named
         "ring" inside [dir] (see [Riptide_storage.File_storage]'s own top comment for the exact
         on-disk layout); slot 0's header -- op_number:int64 (8B) / length:int64 (8B) /
         checksum:32B raw bytes -- starts at byte 0 of that file, so flipping a bit inside the
         checksum field (bytes 16..47) corrupts the checksum without touching the op_number
         field, which is what forces this to go through the checksum check specifically rather
         than the (also-checked) op_number-mismatch path. *)
      let raw_path = Filename.concat dir "ring" in
      let ic = open_in_bin raw_path in
      let contents = really_input_string ic (in_channel_length ic) in
      close_in ic;
      let corrupted = Bytes.of_string contents in
      let checksum_byte_offset = 20 in
      Bytes.set corrupted checksum_byte_offset
        (Char.chr (Char.code (Bytes.get corrupted checksum_byte_offset) lxor 0xFF));
      let oc = open_out_bin raw_path in
      output_bytes oc corrupted;
      close_out oc;
      Eio.Switch.run @@ fun sw ->
      let t2 = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity dir in
      Alcotest.(check (option string)) "corrupted entry reads as None, not garbage" None
        (File_storage.wal_read t2 ~op_number:1))

let test_torn_write_header_updated_data_stale_reads_as_none () =
  (* Exercises the specific safety argument this module's own top comment makes: [wal_append]
     writes the header before the data precisely so that a crash between the two writes leaves
     a header durably pointing at the *previous occupant's* stale data, which [wal_read]'s
     combined checksum + op_number check must catch. [test_corrupted_entry_reads_as_none]
     above only flips a checksum bit inside an entry whose header was never touched/reused --
     it never exercises a header that was legitimately overwritten by a *later* real write (the
     actual torn-write shape). This test constructs that shape directly:

     - ring_capacity:2, so op_number 3 legitimately reuses op_number 1's slot (slot 0),
       overwriting op 1's real data with op 3's real data -- both fully, correctly written.
     - Then, past the [Storage.S] API, patch *only* slot 0's on-disk header bytes (not the data
       region, which keeps op 3's real payload) to revert its op_number field to claim [1]
       again and to corrupt its checksum -- i.e. a header whose op_number field matches a query
       for op 1, but whose checksum does not match what is actually sitting in that slot's data
       region (op 3's payload). This is exactly the header/data relationship a real torn write
       leaves behind (header updated, data stale relative to the header), just reached by
       reverting rather than advancing, since advancing is unreachable through the public API:
       [wal_read]'s bounds check only ever admits an op_number that some real, fully-completed
       [wal_append] (or a recovery scan that itself requires a matching checksum) already
       advanced [wal_highest_op_number] past -- so a header patched to claim an op_number that
       was *never* really, fully written is always rejected by the bounds check first, never
       reaching the checksum comparison at all. Reopening (rather than reusing the live [t])
       both proves the corruption is genuinely durable on disk and gives slot 1's still-valid,
       untouched op 2 header enough headroom for [wal_highest_op_number] to admit a query for
       op 1 past the bounds check, so the assertion below is actually exercising the checksum
       comparison, not merely being rejected earlier for an unrelated reason. *)
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      (Eio.Switch.run @@ fun sw ->
       let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity:2 dir in
       File_storage.wal_append t ~op_number:1 "first payload, slot 0";
       File_storage.wal_append t ~op_number:2 "second payload, slot 1";
       File_storage.wal_append t ~op_number:3 "third payload, legitimately overwrote slot 0");
      let raw_path = Filename.concat dir "ring" in
      let ic = open_in_bin raw_path in
      let contents = really_input_string ic (in_channel_length ic) in
      close_in ic;
      let corrupted = Bytes.of_string contents in
      (* Slot 0's header lives at file offset 0 (see this module's own top comment for the
         layout): op_number is the first 8 bytes, big-endian, mirroring
         [File_storage.encode_header]. Revert it from 3 (the real, current occupant) to 1. *)
      Bytes.set_int64_be corrupted 0 1L;
      (* Checksum field is bytes 16..47; flip one bit inside it, same byte offset and technique
         as [test_corrupted_entry_reads_as_none] above. *)
      let checksum_byte_offset = 20 in
      Bytes.set corrupted checksum_byte_offset
        (Char.chr (Char.code (Bytes.get corrupted checksum_byte_offset) lxor 0xFF));
      let oc = open_out_bin raw_path in
      output_bytes oc corrupted;
      close_out oc;
      Eio.Switch.run @@ fun sw ->
      let t2 = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity:2 dir in
      Alcotest.(check (option string))
        "header claims op 1 but slot 0's real data is op 3's -- checksum mismatch against \
         stale-relative-to-the-header data is caught, not returned as fresh-looking-but-wrong"
        None
        (File_storage.wal_read t2 ~op_number:1))

let test_highest_op_number_recovered_across_reopen_with_ring_layout () =
  (* Task 1's own [test_write_then_read_after_reopen] already covers the single-entry case;
     this covers the ring-specific part of recovery: scanning every slot's header (not just
     "does anything exist"), including after wraparound has made op_number 1's slot get
     overwritten by a later op. *)
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      (Eio.Switch.run @@ fun sw ->
       let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity dir in
       for op = 1 to ring_capacity + 2 do
         File_storage.wal_append t ~op_number:op (Printf.sprintf "entry-%d" op)
       done);
      Eio.Switch.run @@ fun sw ->
      let t2 = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity dir in
      Alcotest.(check int) "highest op number recovered across reopen" (ring_capacity + 2)
        (File_storage.wal_highest_op_number t2);
      Alcotest.(check (option string)) "most recent entry survives reopen"
        (Some (Printf.sprintf "entry-%d" (ring_capacity + 2)))
        (File_storage.wal_read t2 ~op_number:(ring_capacity + 2)))

(* --- Task 3: 3-copy superblock with flexible read/write quorum --- *)

let test_superblock_write_then_read () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity dir in
      File_storage.superblock_write t "view=3,commit=7";
      Alcotest.(check (option string)) "superblock read back" (Some "view=3,commit=7")
        (File_storage.superblock_read t))

let test_superblock_survives_one_corrupted_copy () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      (Eio.Switch.run @@ fun sw ->
       let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity dir in
       File_storage.superblock_write t "view=5,commit=10");
      let copy0 = Filename.concat dir "superblock-0" in
      let oc = open_out_bin copy0 in
      output_string oc "garbage, wrong length and checksum";
      close_out oc;
      Eio.Switch.run @@ fun sw ->
      let t2 = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity dir in
      Alcotest.(check (option string)) "majority (2 of 3) still readable" (Some "view=5,commit=10")
        (File_storage.superblock_read t2))

let test_superblock_none_without_majority () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      (Eio.Switch.run @@ fun sw ->
       let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity dir in
       File_storage.superblock_write t "view=1,commit=0");
      List.iter
        (fun i ->
          let oc = open_out_bin (Filename.concat dir (Printf.sprintf "superblock-%d" i)) in
          output_string oc "garbage"; close_out oc)
        [ 0; 1 ];
      Eio.Switch.run @@ fun sw ->
      let t2 = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity dir in
      Alcotest.(check (option string)) "2 of 3 corrupted -- no majority, honest None" None
        (File_storage.superblock_read t2))

(* Task 13: the repair action for the exact state [Riptide_vsr.Replica.restart]'s own fail-stop
   guard exists to catch -- a superblock unreadable over an otherwise fully intact WAL (final-
   review finding C1). Matches [test_superblock_none_without_majority]'s own direct-file-
   corruption pattern above, but tears all 3 copies (not just 2) to put beyond doubt that
   [superblock_read] genuinely returns [None] before the rebuild is attempted, not merely "no
   majority from a lucky surviving pair".

   TASK 13 FIX ROUND. Two changes here, both real:
   - The three non-WAL-derivable fields are now SUPPLIED (review finding 1), and this test supplies
     plausible real ones -- what an operator would have read off a surviving peer of a cluster that
     had committed 4 of its 5 durable ops in view 3 -- not the zeros the first cut invented.
   - The assertion DECODES the rebuilt record and checks every field (review finding M11). Asserting
     only [Option.is_some] would pass for any bytes at all, including bytes no
     [Riptide_vsr.Replica.restart] could ever use, which is precisely what this repair has to
     produce. Decoded through {!Riptide_storage.Superblock_record}, which since finding 5 is the SAME
     definition [Riptide_vsr.Replica]'s own [superblock_decode] delegates to -- so this really is
     "the replica could use this", not a lookalike decoder written for the test. *)
let test_superblock_rebuild_recovers_from_an_unreadable_superblock_over_an_intact_wal () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      (Eio.Switch.run @@ fun sw ->
       let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity dir in
       for op = 1 to 5 do
         File_storage.wal_append t ~op_number:op (Printf.sprintf "entry-%d" op)
       done;
       File_storage.superblock_write t "some prior superblock content");
      (* The crash: all 3 superblock copies are torn/destroyed out from under the WAL, which is
         left completely untouched -- exactly what an ordinary crash partway through
         [superblock_write]'s 3 sequential, non-atomic copy writes produces on its own. *)
      List.iter
        (fun i ->
          let oc = open_out_bin (Filename.concat dir (Printf.sprintf "superblock-%d" i)) in
          output_string oc "garbage, wrong length and checksum"; close_out oc)
        [ 0; 1; 2 ];
      Eio.Switch.run @@ fun sw ->
      let t2 = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity dir in
      Alcotest.(check int) "the WAL survived the torn superblock untouched" 5
        (File_storage.wal_highest_op_number t2);
      Alcotest.(check (option string)) "precondition: the superblock really is gone" None
        (File_storage.superblock_read t2);
      File_storage.superblock_rebuild_from_wal t2 ~view_number:3 ~last_normal_view:3
        ~commit_number:4;
      Alcotest.(check bool) "superblock_read now returns Some" true
        (Option.is_some (File_storage.superblock_read t2));
      let decoded =
        Option.bind (File_storage.superblock_read t2) Riptide_storage.Superblock_record.decode
      in
      Alcotest.(check bool) "and the bytes really decode as a usable superblock record" true
        (decoded <> None);
      match decoded with
      | None -> ()
      | Some r ->
        Alcotest.(check int) "op_number reconstructed from the WAL, in full" 5
          r.Riptide_storage.Superblock_record.op_number;
        Alcotest.(check int) "commit_number is exactly what the operator supplied" 4
          r.Riptide_storage.Superblock_record.commit_number;
        Alcotest.(check int) "view_number is exactly what the operator supplied" 3
          r.Riptide_storage.Superblock_record.view_number;
        Alcotest.(check int) "last_normal_view is exactly what the operator supplied" 3
          r.Riptide_storage.Superblock_record.last_normal_view)

(* TASK 13 FIX ROUND (review finding 2): the op-number derivation must OVER-report, never under-.
   A crash between a slot's header write and its data write -- two separate, non-atomic 4096-byte
   writes inside one [wal_append] -- leaves the topmost slot durable-but-corrupt: its header
   verifies and maps back to its own slot, its data does not checksum. Simulated here by zeroing
   the top entry's DATA region directly on disk, leaving its header intact.

   The rebuilt superblock must still claim that op-number. Under-reporting it (which is what
   [recover_highest_op_number], the scan [create] uses for the stricter "fully readable" meaning,
   would have given) turns a slot the replica really did durably hold into one it PROVES absent via
   [sender_proves_absent]'s [o > n] disjunct -- the one-word "corrupt -> absent" mutation
   spec/tla/VSR.tla:111-150 records TLC refuting, reintroduced through the repair tool. *)
let test_superblock_rebuild_over_reports_an_op_whose_data_no_longer_verifies () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      (Eio.Switch.run @@ fun sw ->
       let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity dir in
       for op = 1 to 3 do
         File_storage.wal_append t ~op_number:op (Printf.sprintf "entry-%d" op)
       done);
      (* Slot layout (see file_storage.ml's own top comment): [ring_capacity] header slots of 4096
         bytes each, then [ring_capacity] data slots of 4096 bytes each. Op 3 lives in slot 2, so
         its data slot starts at [(ring_capacity + 2) * 4096]. Zeroing it leaves the header (which
         carries op_number/length/checksum) completely untouched. *)
      let ring = Filename.concat dir "ring" in
      let fd = Unix.openfile ring [ Unix.O_RDWR ] 0o600 in
      ignore (Unix.lseek fd ((ring_capacity + 2) * 4096) Unix.SEEK_SET);
      ignore (Unix.write fd (Bytes.make 4096 '\000') 0 4096);
      Unix.close fd;
      (* And the superblock goes too, the ordinary way. *)
      List.iter
        (fun i ->
          let oc = open_out_bin (Filename.concat dir (Printf.sprintf "superblock-%d" i)) in
          output_string oc "garbage, wrong length and checksum"; close_out oc)
        [ 0; 1; 2 ];
      Eio.Switch.run @@ fun sw ->
      let t2 = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity dir in
      (* [create]'s own scan DOES require the data to verify, so it honestly reports 2 -- that is
         the value whose meaning is "fully readable", and it is unchanged by this fix. *)
      Alcotest.(check int) "precondition: op 3's data no longer verifies, so wal_read cannot see it"
        2 (File_storage.wal_highest_op_number t2);
      Alcotest.(check (option string)) "precondition: and op 3 really is unreadable" None
        (File_storage.wal_read t2 ~op_number:3);
      Alcotest.(check bool) "precondition: op 2 next to it is fine" true
        (File_storage.wal_read t2 ~op_number:2 = Some "entry-2");
      File_storage.superblock_rebuild_from_wal t2 ~view_number:1 ~last_normal_view:1
        ~commit_number:2;
      let decoded =
        Option.bind (File_storage.superblock_read t2) Riptide_storage.Superblock_record.decode
      in
      match decoded with
      | None -> Alcotest.fail "the rebuilt superblock must decode"
      | Some r ->
        Alcotest.(check int)
          "THE POINT: the rebuild claims op 3 -- header-verified, data-corrupt is CORRUPT, never \
           ABSENT"
          3 r.Riptide_storage.Superblock_record.op_number)

(* The precondition guard: rebuilding must never be allowed to clobber a superblock that is
   already perfectly readable -- this function exists to REPAIR a lost superblock, never to
   silently overwrite a good one. *)
let test_superblock_rebuild_refuses_when_superblock_is_already_readable () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity dir in
      File_storage.superblock_write t "a perfectly good superblock";
      (* The expected message is the SHARED constant, not a hand-typed copy of it (review finding
         M10): the implementation and this assertion can no longer drift apart. *)
      Alcotest.check_raises "refuses to rebuild over an already-usable superblock"
        (Invalid_argument Riptide_storage.Superblock_record.refusal_superblock_already_readable)
        (fun () ->
          File_storage.superblock_rebuild_from_wal t ~view_number:1 ~last_normal_view:1
            ~commit_number:0))

(* TASK 13 FIX ROUND (review finding M8): the OTHER half of the precondition. A backend with no
   superblock AND no WAL is FIRST BOOT, not a lost superblock -- and
   [Riptide_vsr.Replica.restart]'s own guard says so, by being conditioned on
   [wal_highest_op_number > 0] and not on the superblock alone. Rebuilding here repairs nothing and
   does real harm: [Riptide_vsr.Replica.create] refuses if ANY superblock exists, so a degenerate
   one written over a virgin backend permanently forecloses the only constructor that was still
   legitimate for it. *)
let test_superblock_rebuild_refuses_on_a_genuinely_empty_backend () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity dir in
      Alcotest.(check (option string)) "precondition: no superblock" None
        (File_storage.superblock_read t);
      Alcotest.(check int) "precondition: and an empty WAL" 0 (File_storage.wal_highest_op_number t);
      Alcotest.check_raises "refuses: there is nothing to repair on a virgin backend"
        (Invalid_argument Riptide_storage.Superblock_record.refusal_empty_wal) (fun () ->
          File_storage.superblock_rebuild_from_wal t ~view_number:0 ~last_normal_view:0
            ~commit_number:0);
      Alcotest.(check (option string)) "and nothing was written -- the refusal is a total no-op" None
        (File_storage.superblock_read t))

(* TASK 13 FIX ROUND (review finding 1, the validation half): the supplied values are checked for
   well-formedness on their face. These checks catch a transposed argument or a typo and nothing
   more -- they cannot check that the values are TRUE, which is the hazard the doc comment on
   [superblock_rebuild_from_wal] is actually about, and which the three-replica trace test in
   test_vsr_replica_recovery.ml is what pins. Both directions of the [commit_number <= op_number]
   and [last_normal_view <= view_number] rules are exercised. *)
let test_superblock_rebuild_rejects_ill_formed_supplied_values () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      (Eio.Switch.run @@ fun sw ->
       let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity dir in
       File_storage.wal_append t ~op_number:1 "one";
       File_storage.wal_append t ~op_number:2 "two");
      Eio.Switch.run @@ fun sw ->
      let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity dir in
      (* [~naming] is the distinctive part of the expected message, so each case is pinned to its OWN
         rejection rather than to "some Invalid_argument" -- three guards that all raise the same
         exception type are exactly where a copy-paste mistake hides. *)
      let raises what ~naming f =
        let msg = try (f (); "no exception was raised at all") with Invalid_argument m -> m in
        let contains needle =
          let n = String.length needle and h = String.length msg in
          let rec loop i = i + n <= h && (String.sub msg i n = needle || loop (i + 1)) in
          loop 0
        in
        Alcotest.(check bool) what true
          (String.starts_with ~prefix:"superblock_rebuild_from_wal: " msg && contains naming)
      in
      raises "a negative commit_number is rejected" ~naming:"must all be >= 0" (fun () ->
          File_storage.superblock_rebuild_from_wal t ~view_number:1 ~last_normal_view:1
            ~commit_number:(-1));
      raises "a commit_number above the WAL's own op_number is rejected"
        ~naming:"commit_number 3 exceeds the op_number 2" (fun () ->
          File_storage.superblock_rebuild_from_wal t ~view_number:1 ~last_normal_view:1
            ~commit_number:3);
      raises "a last_normal_view ahead of view_number is rejected"
        ~naming:"last_normal_view 2 exceeds view_number 1" (fun () ->
          File_storage.superblock_rebuild_from_wal t ~view_number:1 ~last_normal_view:2
            ~commit_number:1);
      Alcotest.(check (option string))
        "every rejection is a total no-op -- no half-written superblock" None
        (File_storage.superblock_read t);
      (* And the well-formed boundary case really is accepted: commit_number exactly equal to the
         WAL's own op_number, last_normal_view exactly equal to view_number. *)
      File_storage.superblock_rebuild_from_wal t ~view_number:7 ~last_normal_view:7 ~commit_number:2;
      Alcotest.(check bool) "the boundary-legal values are accepted" true
        (Option.bind (File_storage.superblock_read t) Riptide_storage.Superblock_record.decode
        = Some
            { Riptide_storage.Superblock_record.view_number = 7;
              last_normal_view = 7;
              op_number = 2;
              commit_number = 2
            }))

(* ============================================================================================
   SUBTASK 3.7: the [?may_evict] eviction gate.

   A ring of [ring_capacity] slots silently destroys op_number [n - ring_capacity] when op_number
   [n] is appended, and nothing in this system ever truncates a committed prefix away -- which is
   exactly the unsignalled data loss [~ring_capacity]'s own required-argument comment describes.
   [?may_evict] is the caller's veto over that one moment: it is consulted with the op-number ABOUT
   TO BE EVICTED, and a [false] turns the silent overwrite into a classifiable [Invalid_argument]
   refusal that {!Riptide_vsr.Replica}'s existing [classify_append_refusal] buckets as
   [eviction_blocked].

   Three properties are pinned here, deliberately as three separate tests rather than one: that a
   refused eviction raises with the exact message the classifier matches, that a permitted one is
   completely unaffected (the predicate is a gate, not a hard stop), and that omitting the argument
   preserves this module's pre-existing behavior byte for byte -- the last of these is what every
   existing call site in the repo relies on and is the one that would silently regress. *)

(* Only a GENUINE eviction consults the predicate. With [ring_capacity = 2], op-numbers 1 and 2
   land in fresh, never-written slots (no eviction, no consultation at all); op_number 3 is the
   first append that overwrites a live prior entry, and the entry it overwrites is op_number
   [3 - 2 = 1]. The predicate below refuses exactly that one op-number, so the message's "for
   op_number 1" proves the ARGUMENT is the evicted op-number and not the appending one. *)
let test_may_evict_blocks_a_genuine_eviction () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t =
        File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity:2
          ~may_evict:(fun ~op_number -> op_number > 1)
          dir
      in
      File_storage.wal_append t ~op_number:1 "a";
      File_storage.wal_append t ~op_number:2 "b";
      Alcotest.check_raises "eviction of a blocked op-number raises, classifiably"
        (Invalid_argument "wal_append: eviction blocked for op_number 1")
        (fun () -> File_storage.wal_append t ~op_number:3 "c");
      (* The refusal is a clean no-op, not a partial write: nothing about the ring moved. This is
         load-bearing for the protocol above -- [Replica.durable_append] treats a classified
         refusal as "not durable, declined" and expects to be able to retry the SAME op_number
         later once the predicate relents, which is only sound if the failed attempt left no
         trace. *)
      Alcotest.(check int) "highest_op_number did not advance" 2
        (File_storage.wal_highest_op_number t);
      Alcotest.(check (option string)) "the entry that would have been evicted is still there"
        (Some "a") (File_storage.wal_read t ~op_number:1);
      Alcotest.(check (option string)) "and op 3 was not written" None
        (File_storage.wal_read t ~op_number:3))

let test_may_evict_allows_a_permitted_eviction () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t =
        File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity:2
          ~may_evict:(fun ~op_number:_ -> true)
          dir
      in
      File_storage.wal_append t ~op_number:1 "a";
      File_storage.wal_append t ~op_number:2 "b";
      File_storage.wal_append t ~op_number:3 "c";
      Alcotest.(check (option string)) "op 3 landed, op 1's slot was reused" (Some "c")
        (File_storage.wal_read t ~op_number:3);
      Alcotest.(check (option string)) "op 1 is gone, exactly as an ungated ring would leave it"
        None (File_storage.wal_read t ~op_number:1))

let test_no_may_evict_supplied_is_unaffected () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity:2 dir in
      File_storage.wal_append t ~op_number:1 "a";
      File_storage.wal_append t ~op_number:2 "b";
      File_storage.wal_append t ~op_number:3 "c";
      Alcotest.(check (option string)) "eviction proceeds as before with no predicate" (Some "c")
        (File_storage.wal_read t ~op_number:3))

(* The predicate is consulted ONLY for a genuine eviction, never for a first-time write into a
   fresh slot. A predicate that refuses everything must therefore still let the first
   [ring_capacity] op-numbers through untouched -- if the gate were keyed on the APPENDING
   op-number, or fired for every append, this would raise on op_number 1 and a caller using
   [?may_evict] could never write anything at all. *)
let test_may_evict_is_not_consulted_before_the_ring_is_full () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let consulted = ref [] in
      let t =
        File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity:3
          ~may_evict:(fun ~op_number ->
            consulted := op_number :: !consulted;
            false)
          dir
      in
      for op = 1 to 3 do
        File_storage.wal_append t ~op_number:op (Printf.sprintf "entry-%d" op)
      done;
      Alcotest.(check (list int)) "a ring-filling prefix consults the predicate zero times" []
        !consulted;
      Alcotest.(check int) "and all three appends landed" 3 (File_storage.wal_highest_op_number t);
      Alcotest.check_raises "the first append that would evict is the first one refused"
        (Invalid_argument "wal_append: eviction blocked for op_number 1")
        (fun () -> File_storage.wal_append t ~op_number:4 "entry-4");
      Alcotest.(check (list int)) "consulted exactly once, with the evicted op-number" [ 1 ]
        !consulted)

(* Precedence between two refusals that can both apply to one call: an oversized entry that would
   ALSO evict is reported as the oversize (=> [entry_rejected]), not as the blocked eviction.

   This is deliberate and is a considered deviation from the plan's own sketch, which put the
   eviction gate ahead of the length check. The two refusals mean opposite things to a caller:
   [eviction_blocked] means "not yet, retry this exact op_number once the predicate relents", while
   [entry_rejected] means "this entry can never be durable here" (see [replica.mli]'s own
   [append_refusals] doc). Reporting a permanently-impossible entry as a retryable backpressure
   signal would both lie to the retrier and inflate the very counter subtask 3.7 exists to make
   trustworthy as a materialization-lag signal. Checking the entry's own validity first also keeps
   this module's behavior for an oversized entry identical whether or not [?may_evict] was
   supplied. *)
let test_oversized_entry_beats_a_blocked_eviction () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t =
        File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity:2
          ~may_evict:(fun ~op_number:_ -> false)
          dir
      in
      File_storage.wal_append t ~op_number:1 "a";
      File_storage.wal_append t ~op_number:2 "b";
      Alcotest.check_raises "the entry's own un-storability is reported, not the blocked eviction"
        (Invalid_argument
           "wal_append: entry of 4097 bytes exceeds this ring's max entry size of 4096 bytes \
            (one aligned data slot)")
        (fun () -> File_storage.wal_append t ~op_number:3 (String.make 4097 'x')))

(* An out-of-sequence op_number is also reported as itself, not as a blocked eviction -- the
   sequence check already ran first before this change and still does. Pins that adding the gate
   did not reorder the two. *)
let test_out_of_sequence_beats_a_blocked_eviction () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t =
        File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity:2
          ~may_evict:(fun ~op_number:_ -> false)
          dir
      in
      File_storage.wal_append t ~op_number:1 "a";
      File_storage.wal_append t ~op_number:2 "b";
      Alcotest.check_raises "out-of-sequence is reported as out-of-sequence"
        (Invalid_argument "wal_append: op_number 5 is not wal_highest_op_number t + 1")
        (fun () -> File_storage.wal_append t ~op_number:5 "e"))

(* The gate is in-memory state on [t], not on disk, and it governs FUTURE appends only -- a reopen
   of the same directory with no predicate must not inherit a refusal, and one WITH a predicate
   must apply it against the recovered [highest_op_number] rather than restarting the count. *)
let test_may_evict_applies_after_a_reopen_against_the_recovered_op_number () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      (Eio.Switch.run @@ fun sw ->
       let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity:2 dir in
       File_storage.wal_append t ~op_number:1 "a";
       File_storage.wal_append t ~op_number:2 "b");
      Eio.Switch.run @@ fun sw ->
      let t2 =
        File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity:2
          ~may_evict:(fun ~op_number -> op_number > 1)
          dir
      in
      Alcotest.(check int) "reopen recovered the pre-existing log" 2
        (File_storage.wal_highest_op_number t2);
      Alcotest.check_raises "the predicate gates the next eviction, not a restarted count"
        (Invalid_argument "wal_append: eviction blocked for op_number 1")
        (fun () -> File_storage.wal_append t2 ~op_number:3 "c"))

(* Task 11: the PHYSICAL guard -- a real [flock(2)] on the target directory, held for the whole
   lifetime of the handle [create] returns, closing a real, live-reproduced Critical finding (two
   genuinely separate OS processes both constructing a store over the same directory at once could
   silently interleave writes and corrupt data at the filesystem level; the audit measured 26-31%
   of WAL entries left permanently unreadable). See [Riptide_storage.Dir_lock]'s own [.mli] for the
   full rationale, including why this is a real [flock(2)] rather than [Unix.lockf] (POSIX [fcntl]
   locks, which would NOT conflict against a second [Unix.openfile] from the SAME process -- the
   exact shape the test right below needs to observe a conflict for). *)
(* Review finding M4: delegates to {!Dir_lock.conflict_message}, the single source of truth for
   this exact wording, rather than duplicating the literal string here (this file used to be one
   of four independent copies -- see that function's own [.mli] doc for the full account). *)
let expected_lock_message ~caller dir = Invalid_argument (Dir_lock.conflict_message ~caller dir)

let test_a_second_create_on_a_locked_directory_is_refused () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let (_ : File_storage.t) = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity dir in
      Alcotest.check_raises
        "a second create on the same directory, while the first handle is still live, is refused \
         immediately"
        (expected_lock_message ~caller:"File_storage.create" dir)
        (fun () -> ignore (File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity dir)))

(* Stronger evidence than the same-process double-handle above: a REAL second OS process, forked
   BEFORE this test's [Eio_main.run] even starts (so there is no live io_uring/epoll state for the
   child to inherit into an unsafe mid-flight condition -- the child never touches Eio at all, only
   plain blocking [Unix] calls), mirroring exactly the shape the audit itself used to reproduce the
   underlying corruption: two genuinely separate OS processes against the same directory. The child
   takes the real lock via the SAME C symbol [Dir_lock] itself calls (declared locally here, not
   exposed by [Dir_lock]'s own [.mli] -- an [external] only needs the C symbol name to match, not
   the declaring module, so this does not require weakening that module's public interface for a
   test). *)
external test_only_flock_exclusive_nonblocking : Unix.file_descr -> bool
  = "riptide_flock_exclusive_nonblocking"

let test_a_real_second_os_process_holding_the_lock_is_refused () =
  (* Review finding 3 (re-review, round 2), live-reproduced: if the forked child below exits
     EARLY (e.g. the I4 exception guard's own [Unix._exit 2], triggered by some real failure in
     the child before it ever writes to [ready_w]), the child's own end of [release_r] is closed
     the instant the child process exits -- the kernel closes every fd a process still held on
     exit. If that was the ONLY open read end of that pipe (it always is here: the parent already
     closed its own [release_r] just below), the parent's later, unconditional write to
     [release_w] inside [Fun.protect]'s [~finally] then has no reader left at all, which raises
     SIGPIPE -- fatal by DEFAULT disposition, not something any [Unix.Unix_error] guard around
     that write can catch, because the process is killed before the write syscall ever returns an
     error to the OCaml runtime for an exception to be raised from. Reproduced live: with the
     child's own [openfile] call broken (see the historical I4 comment below for exactly how) and
     this SIGPIPE fix removed, running this one test STANDALONE (not as part of the full suite)
     exits with code 141 (128 + [SIGPIPE]'s signal number 13 -- the classic shell signature of a
     process killed by an uncaught signal) and zero further output after the "actually acquired
     the real lock first" assertion fails -- a real crash, not a reported test failure. It does
     NOT reproduce inside a full [dune test --force] run, because some earlier test's own
     [Eio_main.run] has, by then, already set [SIGPIPE]'s disposition to ignored process-wide as a
     side effect (Eio's own io_uring/epoll setup does this) -- an ACCIDENTAL mask that happens to
     cover this bug in the full suite, not a real fix, which is exactly why this needs its own
     explicit, local disposition rather than relying on suite ordering. Setting this BEFORE
     [Unix.fork] below means the child inherits the same ignored disposition too (harmless, and
     protects the child's own write to [ready_w] from the same class of failure if the parent
     ever gives up early). With [Sys.Signal_ignore] in place, the write instead fails with a
     real, catchable [Unix.Unix_error (Unix.EPIPE, ...)] -- already handled by the existing
     [with Unix.Unix_error _ -> ()] guard around that write, below -- so the test now fails
     cleanly (reporting the real underlying problem) instead of taking the whole process down. *)
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
        (* Child: hold a real flock(2) on the exact lock file [File_storage.create] itself would
           open, then wait to be told to let go. Never touches Eio, Alcotest, or anything else
           belonging to the parent's own test bookkeeping -- exits via [Unix._exit], never a plain
           [exit], so no parent-side [at_exit] (including Alcotest's own reporting) runs twice.

           Review finding I4: the whole branch is now wrapped in a [try ... with _ -> Unix._exit 2]
           guard. Without it, any exception here (e.g. [openfile] under fd exhaustion, a failed
           pipe write) would escape uncaught, unwind through the PARENT's own [with_tmp_dir]
           cleanup (rm -rf'ing [dir] out from under this still-running child), and fall through
           into Alcotest itself -- which then re-runs the ENTIRE REST OF THE TEST SUITE a second
           time, as an independent process sharing this one's stdout. Reproduced live (Task 11
           review): deliberately breaking this child's [openfile] call produced one
           [dune test --force] invocation that printed 729 [\[OK\]] lines and TWO complete "470
           tests run" summaries. *)
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
                  (expected_lock_message ~caller:"File_storage.create" dir)
                  (fun () ->
                    ignore (File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity dir)))))

(* Review finding I1, live-reproduced: [Dir_lock.acquire] registers the lock fd with [sw] the
   instant [flock(2)] succeeds -- but nothing released it if the REST of [create] then raised for
   some other reason. [File_storage.create] itself has no post-lock construction-time check that
   can fail on ordinary input the way [File_kv_store.create]'s owner-tag mismatch can (see
   [test_file_kv_store.ml]'s own copy of this test for the live before/after RED/GREEN evidence
   against that natural failure mode) -- so this test forces the same shape by hand: pre-creating a
   DIRECTORY at the exact path [create] itself tries to [open_file_handle] the ring file at, so
   [Eio_linux.Low_level.openat2] fails (EISDIR) whichever open-flags variant it retries with, and
   the exception propagates out of [create] strictly AFTER [Dir_lock.acquire] has already
   succeeded. Confirmed this reproduces the same bug shape by temporarily reverting
   [file_storage.ml]'s [create] to the pre-fix version (lock acquired, then the rest of [create]
   run unguarded) and observing the second, legitimate [create] below fail with
   [expected_lock_message] even though the first attempt never returned a live [t] -- then
   restoring the fix and confirming it passes. *)
let test_a_failed_create_releases_its_lock_before_reraising () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      let fs = Eio.Stdenv.fs env in
      Eio.Switch.run @@ fun sw ->
      Unix.mkdir (Filename.concat dir "ring") 0o700;
      (* Review finding 4 (re-review, round 2): the original version of this assertion used
         [try ... with _ -> true] to catch the expected failure, which passes for literally ANY
         exception -- including, e.g., a future regression that made this [create] fail via THE
         LOCK ITSELF ([Dir_lock]'s own [Invalid_argument] conflict message, the exact wording
         [expected_lock_message] above builds) instead of the intended, unrelated EISDIR failure
         this test is actually meant to exercise. That is the same weakness class Task 11's own I3
         finding was filed against a different test for: a test that cannot actually distinguish
         the regression it claims to guard against. Fixed by positively asserting the SPECIFIC
         shape this failure has -- a real [Eio.Io] exception (confirmed live: printing the raised
         exception here showed [Eio.Io Unix_error (Is a directory, "openat2", "")], from
         [open_file_handle]'s second, unguarded [openat2] retry once the pre-created "ring"
         directory makes both open-flag variants fail with EISDIR) -- which structurally can never
         be [Dir_lock]'s own [Invalid_argument], so a future change that accidentally routed this
         failure through the lock instead of EISDIR would now show up here as a genuine, specific
         mismatch rather than silently passing. *)
      (match File_storage.create ~sw ~fs ~ring_capacity dir with
      | (_ : File_storage.t) ->
        Alcotest.fail "expected create to fail on the pre-created ring directory, but it succeeded"
      | exception Eio.Io _ -> ()
      | exception e ->
        Alcotest.failf
          "create failed, but not with the expected Eio.Io (EISDIR) shape -- got %s instead (this \
           must not be Dir_lock's own Invalid_argument conflict message)"
          (Printexc.to_string e));
      (* THE regression this test exists to catch: a legitimate create, in the SAME switch, with
         no live handle anywhere, must succeed immediately afterwards -- not be refused by a lock
         the failed attempt above should have released. *)
      Unix.rmdir (Filename.concat dir "ring");
      let (_ : File_storage.t) = File_storage.create ~sw ~fs ~ring_capacity dir in
      ())

let tests =
  [
    ( "Task 10: repeated I/O does not grow the process's kernel map count",
      (* `Slow`, not `Quick` (M10, Task 10 review): this and its `File_kv_store` counterpart
         roughly doubled this suite's runtime (~17s -> ~29s) driving thousands of real
         [O_DIRECT]+[O_DSYNC] I/O cycles against actual disk. `Slow` lets a fast inner loop
         (`--quick-tests`/`ALCOTEST_QUICK_TESTS=true`) skip them while a full/CI `dune test`
         still exercises them. *)
      `Slow,
      test_repeated_io_does_not_grow_the_process_map_count );
    ("write then read, same handle", `Quick, test_write_then_read_same_handle);
    ("write then read, after reopen (real durability)", `Quick, test_write_then_read_after_reopen);
    ("out-of-order append rejected", `Quick, test_out_of_order_append_rejected);
    ( "append of an entry over the chunk-size limit is rejected",
      `Quick,
      test_append_over_chunk_size_rejected );
    ("read of never-written op_number is None", `Quick, test_read_never_written_is_none);
    ("wal_highest_op_number tracks appends", `Quick, test_highest_op_number_tracks_appends);
    ("empty entry round-trips as Some \"\"", `Quick, test_empty_entry_round_trips);
    ("ring wraps around, evicting the oldest entry", `Quick, test_ring_wraps_around);
    ("custom ~ring_capacity is honored", `Quick, test_custom_ring_capacity_is_honored);
    ("wal_truncate_after discards later entries", `Quick, test_truncate_after);
    ( "I3: wal_truncate_after is DURABLE -- truncated entries are not resurrected by a reopen",
      `Quick,
      test_truncate_after_survives_reopen );
    ( "I3: the same, for a truncation spanning more op-numbers than the ring has slots",
      `Quick,
      test_truncate_after_survives_reopen_past_a_full_ring );
    ( "wal_truncate_after is a no-op above the current highest",
      `Quick,
      test_truncate_after_is_noop_above_highest );
    ("corrupted entry reads as None, not garbage", `Quick, test_corrupted_entry_reads_as_none);
    ( "torn write: header updated to a reused slot's op_number/checksum, data stale relative to \
       it, reads as None",
      `Quick,
      test_torn_write_header_updated_data_stale_reads_as_none );
    ( "highest op number recovered across reopen, with ring layout",
      `Quick,
      test_highest_op_number_recovered_across_reopen_with_ring_layout );
    ("superblock write then read", `Quick, test_superblock_write_then_read);
    ( "superblock read survives one corrupted copy (majority)",
      `Quick,
      test_superblock_survives_one_corrupted_copy );
    ( "superblock read returns None without a majority (2 of 3 corrupted)",
      `Quick,
      test_superblock_none_without_majority );
    ( "Task 13: superblock_rebuild_from_wal recovers an unreadable superblock over an intact WAL",
      `Quick,
      test_superblock_rebuild_recovers_from_an_unreadable_superblock_over_an_intact_wal );
    ( "Task 13: superblock_rebuild_from_wal refuses when the superblock is already readable",
      `Quick,
      test_superblock_rebuild_refuses_when_superblock_is_already_readable );
    ( "Task 13 fix (finding 2): superblock_rebuild_from_wal over-reports an op whose data no longer \
       verifies",
      `Quick,
      test_superblock_rebuild_over_reports_an_op_whose_data_no_longer_verifies );
    ( "Task 13 fix (finding M8): superblock_rebuild_from_wal refuses on a genuinely empty backend",
      `Quick,
      test_superblock_rebuild_refuses_on_a_genuinely_empty_backend );
    ( "Task 13 fix (finding 1): superblock_rebuild_from_wal rejects ill-formed supplied values",
      `Quick,
      test_superblock_rebuild_rejects_ill_formed_supplied_values );
    ( "3.7: ?may_evict refuses a genuine eviction, raising the classifiable message",
      `Quick,
      test_may_evict_blocks_a_genuine_eviction );
    ( "3.7: ?may_evict permitting an eviction leaves the ring's behavior unchanged",
      `Quick,
      test_may_evict_allows_a_permitted_eviction );
    ( "3.7: omitting ?may_evict preserves this module's pre-existing eviction behavior",
      `Quick,
      test_no_may_evict_supplied_is_unaffected );
    ( "3.7: ?may_evict is not consulted for first-time writes into fresh slots",
      `Quick,
      test_may_evict_is_not_consulted_before_the_ring_is_full );
    ( "3.7: an oversized entry is reported as oversized, not as a blocked eviction",
      `Quick,
      test_oversized_entry_beats_a_blocked_eviction );
    ( "3.7: an out-of-sequence op_number is reported as itself, not as a blocked eviction",
      `Quick,
      test_out_of_sequence_beats_a_blocked_eviction );
    ( "3.7: ?may_evict after a reopen gates against the recovered highest_op_number",
      `Quick,
      test_may_evict_applies_after_a_reopen_against_the_recovered_op_number );
    ( "Task 11: a second create on an already-locked directory is refused immediately",
      `Quick,
      test_a_second_create_on_a_locked_directory_is_refused );
    ( "Task 11: a create is refused while a REAL second OS process holds the real flock",
      `Quick,
      test_a_real_second_os_process_holding_the_lock_is_refused );
    ( "Task 11 review (I1): a failed create releases its lock before re-raising",
      `Quick,
      test_a_failed_create_releases_its_lock_before_reraising );
  ]
