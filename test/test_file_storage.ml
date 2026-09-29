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
  with_tmp_dir (fun dir ->
      (try Unix.mkdir dir 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
      let lock_path = Filename.concat dir ".riptide-lock" in
      let ready_r, ready_w = Unix.pipe () in
      let release_r, release_w = Unix.pipe () in
      match Unix.fork () with
      | 0 ->
        (* Child: hold a real flock(2) on the exact lock file [File_storage.create] itself would
           open, then wait to be told to let go. Never touches Eio, Alcotest, or anything else
           belonging to the parent's own test bookkeeping -- exits via [Unix._exit], never a plain
           [exit], so no parent-side [at_exit] (including Alcotest's own reporting) runs twice. *)
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
                  (expected_lock_message ~caller:"File_storage.create" dir)
                  (fun () ->
                    ignore (File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity dir)))))

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
  ]
