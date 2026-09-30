(* test/module_loader_emfile_probe.ml

   Standalone helper process for [test_module_loader.ml]'s
   [test_invoke_reports_an_error_and_leaks_no_fd_when_the_containment_pipes_cannot_be_created]. Same
   reasoning, and the same fork+exec-under-a-lowering-[ulimit] technique, as
   [tcp_emfile_probe.ml] (RLIMIT_NOFILE/EMFILE, Task 29) and [file_storage_o_direct_probe.ml]
   (RLIMIT_FSIZE/EFBIG, Task 19): the property under test only exists when the process's file-
   descriptor table is genuinely full, and lowering THIS suite's own budget would break every other
   test sharing the process. A disposable child pays that cost, and only it.

   What it proves (fix-wave round 2, re-review finding on M1): {!Loader.invoke} has to create two
   pipes and fork before the guest can run, and nothing guarded that window. Under a real fd
   exhaustion this had two distinct, simultaneous consequences: [Unix.Unix_error(EMFILE, "pipe", "")]
   escaped [invoke] uncaught (falsifying its documented "returns Error, raises only [Out_of_memory]/
   [Stack_overflow]" contract), and -- when it was the SECOND pipe that failed -- the first pipe's
   two descriptors leaked permanently (falsifying the "no exit path leaks a zombie process or a file
   descriptor" claim in the same doc comment), on exactly the path where descriptors are already
   scarce.

   How it arranges that precisely, rather than approximately:
     1. Instantiate the guest FIRST, while descriptors are still plentiful (instantiation reads the
        fixture and compiles it; that is not what is under test).
     2. Record the process's own open-fd count from [/proc/self/fd].
     3. Burn descriptors with [Unix.dup] until EMFILE -- the table is now completely full.
     4. Release EXACTLY TWO of them. This is the interesting case, not a detail: [invoke]'s first
        pipe now succeeds (consuming both), and its second pipe fails. Pre-fix, those two are
        leaked; post-fix, they are closed again before the failure is reported.
     5. Call [invoke]. It must return [Error] (never raise), naming the pipe-creation failure.
     6. Release every remaining burned descriptor and re-count [/proc/self/fd]: equal to step 2's
        count means nothing leaked; two higher means the first pipe was leaked.

   Output: one line per check to stderr (the parent test reads and asserts on them -- no new
   descriptor needed to write there, which matters while the table is full). Exit 0 if every check
   passed, 1 otherwise, 2 for a setup problem. *)

let read_file path =
  let ic = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in ic) (fun () -> really_input_string ic (in_channel_length ic))

(* Counting entries in [/proc/self/fd] itself needs one descriptor, which the caller is responsible
   for having available; every call here is made while at least a few are free. The directory handle
   is always closed, and [Sys.readdir]'s own result includes the handle's own entry, so what matters
   is that the two calls are made the same way -- the comparison is between two like measurements,
   not against an absolute expected value. *)
let open_fd_count () = Array.length (Sys.readdir "/proc/self/fd")

let () =
  let fixture = if Array.length Sys.argv > 1 then Sys.argv.(1) else "fixtures/echo.wat" in
  let protocol =
    Riptide_module.Protocol.create ~states:[ "init" ] ~initial:"init"
      ~transitions:[ { Riptide_module.Protocol.from_state = "init"; on_call = "handle"; to_state = "init" } ]
  in
  let host =
    {
      Riptide_module.Loader.read_materialized = (fun ~merge_key:_ -> None);
      propose_write = (fun _ -> Ok ());
      log = (fun _ -> ());
    }
  in
  let m =
    match
      Riptide_module.Loader.instantiate ~tier:Riptide_module.Loader.Sfi
        ~module_bytes:(read_file fixture) ~host ~protocol
    with
    | m -> m
    | exception exn ->
      Printf.eprintf "PROBE-SETUP-FAILED instantiate raised: %s\n%!" (Printexc.to_string exn);
      exit 2
  in
  let fds_before = open_fd_count () in
  (* Burn the whole table. [Unix.dup] of stderr is the cheapest descriptor to obtain and needs no
     filesystem access at all -- important, since the point is to reach a state where nothing else
     can be opened. *)
  let burned = ref [] in
  let rec burn () =
    match Unix.dup Unix.stderr with
    | fd ->
      burned := fd :: !burned;
      burn ()
    | exception Unix.Unix_error ((Unix.EMFILE | Unix.ENFILE), _, _) -> ()
  in
  burn ();
  if List.length !burned < 2 then (
    Printf.eprintf "PROBE-SETUP-FAILED could not burn at least 2 descriptors (ulimit too low?)\n%!";
    exit 2);
  (* Exactly two free: the first pipe succeeds, the second fails -- the leak-prone case. *)
  (match !burned with
  | a :: b :: rest ->
    (try Unix.close a with Unix.Unix_error _ -> ());
    (try Unix.close b with Unix.Unix_error _ -> ());
    burned := rest
  | _ -> ());
  let result =
    match Riptide_module.Loader.invoke m ~entrypoint:"handle" ~arg:Bytes.empty with
    | Ok _ -> `Ok_unexpectedly
    | Error e -> `Error e
    | exception exn -> `Raised (Printexc.to_string exn)
  in
  List.iter (fun fd -> try Unix.close fd with Unix.Unix_error _ -> ()) !burned;
  burned := [];
  let fds_after = open_fd_count () in
  let ok_contract =
    match result with
    | `Error e ->
      Printf.eprintf "PROBE-RESULT error: %s\n%!" e;
      true
    | `Ok_unexpectedly ->
      Printf.eprintf "PROBE-RESULT unexpected Ok -- the guest cannot have run with a full fd table\n%!";
      false
    | `Raised exn ->
      Printf.eprintf "PROBE-RESULT raised: %s\n%!" exn;
      false
  in
  let ok_no_leak = fds_after = fds_before in
  Printf.eprintf "PROBE-FDS before=%d after=%d\n%!" fds_before fds_after;
  Printf.eprintf "PROBE-VERDICT contract=%b no_leak=%b\n%!" ok_contract ok_no_leak;
  exit (if ok_contract && ok_no_leak then 0 else 1)
