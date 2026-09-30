(* Standalone helper process for [test_file_storage.ml]'s
   [test_an_unrelated_write_error_does_not_permanently_strip_o_direct] (Task 19, Bug 1). Never run
   directly by a human -- always spawned as a forked+exec'd child, under a shell that first lowers
   its own [RLIMIT_FSIZE] via [ulimit -f] (see that test's own comment for why this has to be a
   real subprocess rather than something done in-process: [Unix] has no [setrlimit] binding at all
   in this OCaml/opam installation, and even if it did, lowering the WHOLE alcotest binary's
   [RLIMIT_FSIZE] would risk breaking every other test in the same process that legitimately writes
   files larger than this probe's own deliberately tiny limit).

   Genuinely reproduces a REAL, non-EINVAL [Eio.Io] failure ([EFBIG], "File too large") on a real
   [O_DIRECT]-capable file, by writing a [File_storage] ring's WAL header (small, at offset 0) then
   its DATA (at offset [ring_capacity * header_slot_size], always far larger) under a [RLIMIT_FSIZE]
   set between the two -- the header write fits, the data write cannot. This is real OS-level
   resource-limit enforcement, not a simulated exception: confirmed live (a standalone probe outside
   this suite) that Linux's [io_uring]-based [writev] surfaces this failure identically to a
   synchronous [write(2)], as
   [Eio.Io (Eio.Exn.X (Eio_unix.Unix_error (Unix.EFBIG, "writev", "")), _)].

   Prints one line per step to stdout, which the parent test parses: [BEFORE_DIRECT=<bool>] (is the
   ring fd still O_DIRECT-flagged right after [create]?), [APPEND_RAISED=<exn>] or [APPEND_OK], then
   [AFTER_DIRECT=<bool>] (is it STILL O_DIRECT-flagged after the EFBIG failure?) -- the bug this
   closes made this flip to [false] on ANY [Eio.Io], including this unrelated one; the fix requires
   it to stay [true] since [EFBIG] is not the O_DIRECT-unsupported shape ([EINVAL]) the fallback
   exists for. *)

open Riptide_storage

(* The ONLY way to observe [file_handle.direct_capable] from outside this module (it is not exposed
   by [file_storage.mli], nor should it be just for a test): find the real OS fd number backing the
   ring file via [/proc/self/fd] (matching each entry's [readlink] target against the ring path's own
   [realpath]), then read that fd's actual [O_DIRECT] status straight from the kernel via
   [/proc/self/fdinfo/<fd>]'s [flags:] field (octal-encoded [open(2)] flags; [O_DIRECT] is [0o40000]
   on Linux). This is real, dynamic, OS-level evidence, not a guess about what the code must be
   doing internally. *)
let find_fd_for_path target_realpath =
  let dir = "/proc/self/fd" in
  Array.to_list (Sys.readdir dir)
  |> List.filter_map (fun name ->
         match Unix.readlink (Filename.concat dir name) with
         | p when p = target_realpath -> Some (int_of_string name)
         | _ -> None
         | exception _ -> None)

let o_direct_flag_set fd =
  let ic = open_in (Printf.sprintf "/proc/self/fdinfo/%d" fd) in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () ->
      let rec loop () =
        match input_line ic with
        | line when String.length line > 6 && String.sub line 0 6 = "flags:" ->
          let octal = String.trim (String.sub line 6 (String.length line - 6)) in
          int_of_string ("0o" ^ octal) land 0o40000 <> 0
        | _ -> loop ()
        | exception End_of_file -> false
      in
      loop ())

let ring_capacity = 8

let () =
  let dir = Sys.argv.(1) in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let fs = Eio.Stdenv.fs env in
  let t = File_storage.create ~sw ~fs ~ring_capacity dir in
  let ring_target = Unix.realpath (Filename.concat dir "ring") in
  (match find_fd_for_path ring_target with
  | [ fd ] -> Printf.printf "BEFORE_DIRECT=%b\n%!" (o_direct_flag_set fd)
  | others -> Printf.printf "BEFORE_ERROR=found %d fds\n%!" (List.length others));
  (try
     File_storage.wal_append t ~op_number:1 "task-19-bug-1-probe";
     Printf.printf "APPEND_OK\n%!"
   with e -> Printf.printf "APPEND_RAISED=%s\n%!" (Printexc.to_string e));
  (match find_fd_for_path ring_target with
  | [ fd ] -> Printf.printf "AFTER_DIRECT=%b\n%!" (o_direct_flag_set fd)
  | others -> Printf.printf "AFTER_ERROR=found %d fds\n%!" (List.length others))
