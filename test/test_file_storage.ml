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

let test_append_over_chunk_size_rejected () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) dir in
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

(* --- Task 2: fixed-size ring WAL, redundant headers, checksum verification --- *)

let ring_capacity = 8 (* the default -- small, so a wraparound test is cheap to write *)

let test_ring_wraps_around () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) dir in
      for op = 1 to ring_capacity + 3 do
        File_storage.wal_append t ~op_number:op (Printf.sprintf "entry-%d" op)
      done;
      (* the ring only holds the most recent ring_capacity entries *)
      Alcotest.(check (option string)) "oldest entry evicted by wraparound" None
        (File_storage.wal_read t ~op_number:1);
      Alcotest.(check (option string)) "most recent entry present" (Some "entry-11")
        (File_storage.wal_read t ~op_number:(ring_capacity + 3)))

let test_custom_ring_capacity_is_honored () =
  (* Proves the [?ring_capacity] knob on [create] is real, not just accepted and ignored --
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
      let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) dir in
      List.iter
        (fun op -> File_storage.wal_append t ~op_number:op (Printf.sprintf "e%d" op))
        [ 1; 2; 3 ];
      File_storage.wal_truncate_after t ~op_number:1;
      Alcotest.(check int) "highest op number after truncate" 1 (File_storage.wal_highest_op_number t);
      Alcotest.(check (option string)) "entry 2 gone" None (File_storage.wal_read t ~op_number:2);
      File_storage.wal_append t ~op_number:2 "replaces old entry 2";
      Alcotest.(check (option string)) "new entry 2 present" (Some "replaces old entry 2")
        (File_storage.wal_read t ~op_number:2))

let test_truncate_after_is_noop_above_highest () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      Eio.Switch.run @@ fun sw ->
      let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) dir in
      File_storage.wal_append t ~op_number:1 "one";
      File_storage.wal_truncate_after t ~op_number:5;
      Alcotest.(check int) "highest op number unchanged" 1 (File_storage.wal_highest_op_number t);
      Alcotest.(check (option string)) "entry 1 still present" (Some "one")
        (File_storage.wal_read t ~op_number:1))

let test_corrupted_entry_reads_as_none () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun dir ->
      (Eio.Switch.run @@ fun sw ->
       let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) dir in
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
      let t2 = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) dir in
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
       let t = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) dir in
       for op = 1 to ring_capacity + 2 do
         File_storage.wal_append t ~op_number:op (Printf.sprintf "entry-%d" op)
       done);
      Eio.Switch.run @@ fun sw ->
      let t2 = File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) dir in
      Alcotest.(check int) "highest op number recovered across reopen" (ring_capacity + 2)
        (File_storage.wal_highest_op_number t2);
      Alcotest.(check (option string)) "most recent entry survives reopen"
        (Some (Printf.sprintf "entry-%d" (ring_capacity + 2)))
        (File_storage.wal_read t2 ~op_number:(ring_capacity + 2)))

let tests =
  [
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
    ("custom ?ring_capacity is honored", `Quick, test_custom_ring_capacity_is_honored);
    ("wal_truncate_after discards later entries", `Quick, test_truncate_after);
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
  ]
