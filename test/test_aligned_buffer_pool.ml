(* Regression coverage for [Riptide_storage.Aligned_buffer_pool.create]'s own input validation
   (Task 10 review round 2, Finding 5). This module was extracted from [File_storage]/
   [File_kv_store] (Task 10 review round 1, Finding 2) and is explicitly documented as "meant to
   be reusable by any future caller" -- but until this fix, [create] validated neither
   [~buffer_count] nor [~slot_size], so a bad value from a future caller would not fail cleanly:

   - [~buffer_count:0] silently built a pool where the very first [with_buffer] call blocks
     FOREVER on [Eio.Stream.take] -- a real, permanent deadlock, not an error, since
     [Eio.Stream.create 0] is itself a valid empty stream and the loop that would normally seed
     it with buffers never runs at count 0.
   - A negative [~buffer_count] raised from deep inside [Eio.Stream.create], with a message
     naming neither this module nor which argument was wrong.
   - [~slot_size:0] (or negative) reached [Unix.map_file] with an invalid dimension and failed
     with an equally unhelpful, deep error.

   These tests confirm the fix: both bad-input shapes now raise a clear [Invalid_argument] naming
   this module and the specific bad argument, immediately from [create] itself -- never by
   reaching [with_buffer] (which would be the deadlock case) or by falling through to
   [Eio.Stream.create]/[Unix.map_file]'s own opaque errors. Deliberately does not wrap these calls
   in [Eio_main.run]: [create] raises before performing any Eio effect at all for every case tested
   here (confirmed by these tests passing under the suite's plain, non-Eio driver), which is itself
   part of what "immediately" means -- a caller doesn't need a running scheduler in place just to
   get told its arguments were bad. *)

open Riptide_storage

(* [~dir_path] is exercised only by [test_valid_arguments_still_build_a_working_pool] below: every
   other test here raises out of [create]'s own [~buffer_count]/[~slot_size] validation before
   [~dir_path] is ever touched (see [create]'s own body -- both checks run before the allocation
   loop), so an intentionally nonexistent path both keeps those tests' intent narrow (only the
   argument named in each test is what's actually being exercised) and would loudly fail (a real
   [Sys_error], not a silently-wrong pass) if a future change ever made [create] read [~dir_path]
   before validating the other two arguments. *)
let unused_dir_path = "/nonexistent-argument-validation-only-dir"

let test_zero_buffer_count_is_rejected_immediately () =
  Alcotest.check_raises "buffer_count = 0 raises immediately instead of building a pool that
                          deadlocks on the first with_buffer call"
    (Invalid_argument "Aligned_buffer_pool.create: ~buffer_count must be positive, got 0")
    (fun () ->
      ignore
        (Aligned_buffer_pool.create ~dir_path:unused_dir_path ~buffer_count:0 ~slot_size:4096 ()))

let test_negative_buffer_count_is_rejected_immediately () =
  Alcotest.check_raises "a negative buffer_count raises a clear, immediate error instead of a deep,
                          unhelpful one from Eio.Stream.create"
    (Invalid_argument "Aligned_buffer_pool.create: ~buffer_count must be positive, got -1")
    (fun () ->
      ignore
        (Aligned_buffer_pool.create ~dir_path:unused_dir_path ~buffer_count:(-1)
           ~slot_size:4096 ()))

let test_zero_slot_size_is_rejected_immediately () =
  Alcotest.check_raises "slot_size = 0 raises a clear, immediate error instead of a deep,
                          unhelpful one from Unix.map_file"
    (Invalid_argument "Aligned_buffer_pool.create: ~slot_size must be positive, got 0")
    (fun () ->
      ignore (Aligned_buffer_pool.create ~dir_path:unused_dir_path ~buffer_count:4 ~slot_size:0 ()))

let test_negative_slot_size_is_rejected_immediately () =
  Alcotest.check_raises "a negative slot_size raises a clear, immediate error instead of a deep,
                          unhelpful one from Unix.map_file"
    (Invalid_argument "Aligned_buffer_pool.create: ~slot_size must be positive, got -4096")
    (fun () ->
      ignore
        (Aligned_buffer_pool.create ~dir_path:unused_dir_path ~buffer_count:4
           ~slot_size:(-4096) ()))

(* Non-vacuity: valid arguments still build a working pool, and a full acquire/use/release cycle
   through it round-trips real data -- proves the validation above rejects only genuinely bad
   values, not a broken [create] that now rejects everything. Needs a REAL directory (unlike the
   validation-only tests above): with valid arguments, [create] actually reaches
   [alloc_one_aligned_buffer], which creates a real throwaway backing file inside [~dir_path]
   (Task 17). *)
let test_valid_arguments_still_build_a_working_pool () =
  let dir = Filename.temp_file "riptide_aligned_buffer_pool_test" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o700;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () ->
      let pool = Aligned_buffer_pool.create ~dir_path:dir ~buffer_count:2 ~slot_size:4096 () in
      let result =
        Aligned_buffer_pool.with_buffer pool 5 (fun buf ->
            Cstruct.blit_from_string "hello" 0 buf 0 5;
            Cstruct.to_string ~len:5 buf)
      in
      Alcotest.(check string) "a buffer acquired from a validly-sized pool round-trips real data"
        "hello" result)

let tests =
  [
    ("buffer_count = 0 is rejected immediately", `Quick, test_zero_buffer_count_is_rejected_immediately);
    ( "negative buffer_count is rejected immediately",
      `Quick,
      test_negative_buffer_count_is_rejected_immediately );
    ("slot_size = 0 is rejected immediately", `Quick, test_zero_slot_size_is_rejected_immediately);
    ( "negative slot_size is rejected immediately",
      `Quick,
      test_negative_slot_size_is_rejected_immediately );
    ("valid arguments still build a working pool", `Quick, test_valid_arguments_still_build_a_working_pool);
  ]
