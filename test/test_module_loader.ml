open Riptide_module

let read_file path =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

(* Shared by every test below that doesn't itself care about protocol enforcement (Task 3's own
   instantiation/invocation/containment/rejection tests, none of which are testing the protocol
   machinery added in Task 4) -- a minimal, permissive one-state self-loop that allows exactly
   the one call every one of those tests' own guests is actually invoked with ("handle"), so
   Loader.instantiate's now-mandatory ~protocol argument never gets in their way. Tests that
   specifically exercise protocol enforcement (below) build their own, deliberately narrower
   protocol instead. *)
(* Substring test, for asserting on a real error message's content rather than merely its
   non-emptiness -- [Str] is already a dependency of this test executable (test/dune), and
   test_module_reactor.ml uses this exact helper for the same purpose. *)
let string_contains ~needle haystack =
  try
    ignore (Str.search_forward (Str.regexp_string needle) haystack 0);
    true
  with Not_found -> false

let permissive_protocol () =
  Protocol.create ~states:[ "init" ] ~initial:"init"
    ~transitions:[ { Protocol.from_state = "init"; on_call = "handle"; to_state = "init" } ]

let test_invoke_calls_the_guests_handle_and_observes_its_log_call () =
  let logged = ref [] in
  let host =
    {
      Loader.read_materialized = (fun ~merge_key:_ -> None);
      propose_write = (fun _ -> Ok ());
      log = (fun s -> logged := s :: !logged);
    }
  in
  let m =
    Loader.instantiate ~tier:Loader.Sfi ~module_bytes:(read_file "fixtures/echo.wat") ~host
      ~protocol:(permissive_protocol ())
  in
  (match Loader.invoke m ~entrypoint:"handle" ~arg:Bytes.empty with
  | Ok _ -> ()
  | Error e -> Alcotest.fail e);
  Alcotest.(check (list string)) "guest logged once" [ "hello" ] !logged

let test_a_runaway_module_is_contained_not_crashing_the_host () =
  let host =
    {
      Loader.read_materialized = (fun ~merge_key:_ -> None);
      propose_write = (fun _ -> Ok ());
      log = (fun _ -> ());
    }
  in
  let m =
    Loader.instantiate ~tier:Loader.Sfi ~module_bytes:(read_file "fixtures/runaway.wat") ~host
      ~protocol:(permissive_protocol ())
  in
  match Loader.invoke m ~entrypoint:"handle" ~arg:Bytes.empty with
  | Ok _ -> Alcotest.fail "expected containment, not success"
  | Error e -> Alcotest.(check bool) "fuel exhaustion is reported, not a host crash" true (String.length e > 0)

(* Final-fix-wave finding I2: the containment deadline must charge GUEST execution time only, never
   time the PARENT spends servicing a host call the guest is BLOCKED on. [read_materialized] and
   [propose_write] both have that shape -- the guest issues its call and cannot continue until the
   parent writes a response frame back -- and both are entirely caller-supplied code: Task 6's
   reactor wires a real [Batch_commit.propose] into [propose_write], which cascades through the
   authorization checkpoint, a VSR commit, materialization and every further nested module dispatch
   before returning. Charging all of that to the guest made a perfectly well-behaved guest get
   SIGKILLed and reported "fuel exhausted" AFTER its own write had already been proposed and
   committed by the very closure whose duration caused the report.

   [propose_write.wat] is the right guest for this, and specifically a better one than the [echo.wat]
   /[host.log] version this test used in fix-wave round 1: [log] is fire-and-forget (no response
   frame, guest never blocks), so it must NOT be credited at all -- see
   [test_a_spinning_guest_that_calls_a_slow_log_closure_is_still_contained_on_schedule] below for the
   containment escape that mis-credit caused, found by re-review. This test therefore exercises the
   arm the credit is genuinely correct for, and the one I2's real motivating scenario (the reactor's
   propose_write cascade) actually travels through. The guest does essentially no work of its own, so
   it either completes ([Ok], correct) or is reported as a runaway ([Error], the bug) purely as a
   function of how blocked-on-host time is accounted. *)
let test_time_spent_in_a_host_closure_is_not_charged_against_the_guests_fuel_budget () =
  let host =
    {
      Loader.read_materialized = (fun ~merge_key:_ -> None);
      (* Deliberately longer than the ENTIRE budget, so pre-fix there is no remaining time left at
         all the moment this returns -- not a marginal, timing-sensitive overrun. *)
      propose_write =
        (fun _ ->
          Unix.sleepf (Loader.fuel_budget_seconds +. 0.3);
          Ok ());
      log = (fun _ -> ());
    }
  in
  let m =
    Loader.instantiate ~tier:Loader.Sfi ~module_bytes:(read_file "fixtures/propose_write.wat") ~host
      ~protocol:(permissive_protocol ())
  in
  match Loader.invoke m ~entrypoint:"handle" ~arg:(Bytes.of_string "allow-me") with
  | Ok result ->
    (* Not just "Ok": the guest's own post-call work (storing the status byte it got back, then
       returning it) genuinely ran to completion after the slow closure returned, which is what
       proves the call was serviced rather than the guest merely being reported as successful. *)
    Alcotest.(check string)
      "the guest resumed after the slow host call and returned the success status byte it was handed"
      "\000" (Bytes.to_string result)
  | Error e ->
    Alcotest.failf
      "a guest that did nothing but make one (slow) blocking host call was reported as a \
       containment failure -- time it spent BLOCKED on the host is being charged against its own \
       fuel budget: %s"
      e

(* Re-review of fix-wave round 1 (Important): the mirror property, and the reason the credit above
   must be narrow. [host.log] is fire-and-forget -- [make_host_extern]'s "log" case writes the frame
   and returns, with no response frame for the guest to wait on -- so a guest keeps executing at full
   speed while the parent is still inside the log closure. Round 1 credited that parent-side time
   back to the deadline for all three arms alike, which handed a guest free execution time it was
   actually using: one slow log call bought this fixture's infinite loop an extra whole fuel budget,
   and a guest interleaving log calls with compute could extend its own deadline without limit. That
   is a containment escape in the one mechanism whose entire job is bounding untrusted guest
   execution -- strictly worse than the (real) bug I2 fixed.

   The oracle here has to be elapsed wall-clock time, not the result value: both the correct and the
   broken behavior end in [Error] (the guest never terminates either way), and only WHEN differs.
   With the log closure sleeping [fuel_budget_seconds +. 0.2], correct containment kills the guest as
   soon as that closure returns (~budget + 0.2s, since by then the deadline has already passed),
   while the broken credit pushes the deadline a full budget further out (~2 * budget + 0.2s). The
   threshold below sits between those with ~1s of slack on each side, sized off the budget rather
   than hardcoded. *)
let test_a_spinning_guest_that_calls_a_slow_log_closure_is_still_contained_on_schedule () =
  let host =
    {
      Loader.read_materialized = (fun ~merge_key:_ -> None);
      propose_write = (fun _ -> Ok ());
      log = (fun _ -> Unix.sleepf (Loader.fuel_budget_seconds +. 0.2));
    }
  in
  let m =
    Loader.instantiate ~tier:Loader.Sfi ~module_bytes:(read_file "fixtures/log_then_spin.wat") ~host
      ~protocol:(permissive_protocol ())
  in
  let started = Unix.gettimeofday () in
  let result = Loader.invoke m ~entrypoint:"handle" ~arg:Bytes.empty in
  let elapsed = Unix.gettimeofday () -. started in
  (match result with
  | Ok _ -> Alcotest.fail "a guest spinning forever returned Ok -- it was not contained at all"
  | Error e ->
    Alcotest.(check bool) "the spinning guest was contained via the wall-clock budget" true
      (string_contains ~needle:"fuel exhausted" e));
  let ceiling = Loader.fuel_budget_seconds *. 1.6 in
  Alcotest.(check bool)
    (Printf.sprintf
       "containment happened on schedule (%.2fs elapsed, ceiling %.2fs): a fire-and-forget log call \
        must not buy a spinning guest extra deadline"
       elapsed ceiling)
    true (elapsed < ceiling)

let test_read_materialized_relays_a_known_value_back_to_the_guest () =
  let seen_keys = ref [] in
  let host =
    {
      Loader.read_materialized =
        (fun ~merge_key ->
          seen_keys := merge_key :: !seen_keys;
          if merge_key = "known" then Some (Bytes.of_string "VALUE123") else None);
      propose_write = (fun _ -> Ok ());
      log = (fun _ -> ());
    }
  in
  let m =
    Loader.instantiate ~tier:Loader.Sfi ~module_bytes:(read_file "fixtures/read_materialized.wat")
      ~host ~protocol:(permissive_protocol ())
  in
  (* arg byte 0 = '\000' selects the "known" key in this fixture's own convention. *)
  match Loader.invoke m ~entrypoint:"handle" ~arg:(Bytes.make 1 '\000') with
  | Error e -> Alcotest.fail e
  | Ok result ->
    Alcotest.(check string) "the host's value round-tripped through the guest and back out"
      "VALUE123" (Bytes.to_string result);
    Alcotest.(check (list string)) "the host observed the real key the guest asked for" [ "known" ]
      !seen_keys

let test_read_materialized_relays_none_for_a_missing_key () =
  let seen_keys = ref [] in
  let host =
    {
      Loader.read_materialized =
        (fun ~merge_key ->
          seen_keys := merge_key :: !seen_keys;
          if merge_key = "known" then Some (Bytes.of_string "VALUE123") else None);
      propose_write = (fun _ -> Ok ());
      log = (fun _ -> ());
    }
  in
  let m =
    Loader.instantiate ~tier:Loader.Sfi ~module_bytes:(read_file "fixtures/read_materialized.wat")
      ~host ~protocol:(permissive_protocol ())
  in
  (* any nonzero arg byte 0 selects the "missing" key in this fixture's own convention. *)
  match Loader.invoke m ~entrypoint:"handle" ~arg:(Bytes.make 1 '\001') with
  | Error e -> Alcotest.fail e
  | Ok result ->
    Alcotest.(check string) "None comes back out as zero bytes, not a stale/garbage value" ""
      (Bytes.to_string result);
    Alcotest.(check (list string)) "the host observed the real key the guest asked for"
      [ "missing" ] !seen_keys

let test_propose_write_relays_the_guests_bytes_to_the_host_and_returns_success () =
  let seen_payloads = ref [] in
  let host =
    {
      Loader.read_materialized = (fun ~merge_key:_ -> None);
      propose_write =
        (fun payload ->
          seen_payloads := Bytes.to_string payload :: !seen_payloads;
          if Bytes.to_string payload = "reject-me" then Error "nope" else Ok ());
      log = (fun _ -> ());
    }
  in
  let m =
    Loader.instantiate ~tier:Loader.Sfi ~module_bytes:(read_file "fixtures/propose_write.wat")
      ~host ~protocol:(permissive_protocol ())
  in
  match Loader.invoke m ~entrypoint:"handle" ~arg:(Bytes.of_string "allow-me") with
  | Error e -> Alcotest.fail e
  | Ok result ->
    Alcotest.(check string) "the guest observed a success status byte (0) back from the host"
      "\000" (Bytes.to_string result);
    Alcotest.(check (list string))
      "the host received the guest's own exact payload bytes, unmodified" [ "allow-me" ]
      !seen_payloads

let test_propose_write_relays_the_hosts_denial_back_to_the_guest () =
  let seen_payloads = ref [] in
  let host =
    {
      Loader.read_materialized = (fun ~merge_key:_ -> None);
      propose_write =
        (fun payload ->
          seen_payloads := Bytes.to_string payload :: !seen_payloads;
          if Bytes.to_string payload = "reject-me" then Error "nope" else Ok ());
      log = (fun _ -> ());
    }
  in
  let m =
    Loader.instantiate ~tier:Loader.Sfi ~module_bytes:(read_file "fixtures/propose_write.wat")
      ~host ~protocol:(permissive_protocol ())
  in
  match Loader.invoke m ~entrypoint:"handle" ~arg:(Bytes.of_string "reject-me") with
  | Error e -> Alcotest.fail e
  | Ok result ->
    Alcotest.(check string) "the guest observed a denial status byte (1) back from the host"
      "\001" (Bytes.to_string result);
    Alcotest.(check (list string)) "the host still received the exact rejected payload"
      [ "reject-me" ] !seen_payloads

let no_op_host () =
  {
    Loader.read_materialized = (fun ~merge_key:_ -> None);
    propose_write = (fun _ -> Ok ());
    log = (fun _ -> ());
  }

(* ── Final fix wave, finding I7: Decision 5's own two named isolation properties, neither of which
   had a real test ───────────────────────────────────────────────────────────────────────────────
   The spec's Testing-strategy section names, for Decision 5: "a module that deliberately loops
   forever or overruns its own memory is contained -- doesn't crash the host, doesn't touch another
   module's or the core's memory, triggers fuel exhaustion or a trap as designed." Only the
   loop-forever half was actually covered (by [test_a_runaway_module_is_contained_...]); the
   memory-overrun half was covered only by three INSTANTIATE-time rejection tests (an over-large or
   unbounded DECLARED maximum, an imported memory), all of which abort before any guest code runs,
   and the cross-module claim was asserted nowhere at all. *)

let test_a_guest_that_accesses_memory_out_of_bounds_traps_and_is_reported_as_an_error () =
  let m =
    Loader.instantiate ~tier:Loader.Sfi ~module_bytes:(read_file "fixtures/out_of_bounds.wat")
      ~host:(no_op_host ()) ~protocol:(permissive_protocol ())
  in
  match Loader.invoke m ~entrypoint:"handle" ~arg:Bytes.empty with
  | Ok _ ->
    Alcotest.fail
      "a genuine out-of-bounds linear-memory access returned Ok -- the trap was not surfaced at all"
  | Error e ->
    (* Two separate things worth asserting, because "Error" alone would also be produced by the
       wall-clock containment path, which is a DIFFERENT mechanism (this guest terminates
       immediately -- it never runs long enough to time out) and would mean the trap itself went
       unobserved. *)
    (* The real message wasmtime v49 produces for this fixture, confirmed live:
         error while executing at wasm backtrace: 0: 0x3c - <unknown>!<wasm function 0>
         Caused by:
           0: memory fault at wasm address 0x7ffffffc in linear memory of size 0x10000
           1: wasm trap: out of bounds memory access
       Both needles below come from that real text -- checked rather than pattern-guessed, and
       checked as two separate assertions so a future runtime-version change that renames one of
       them still says precisely which half stopped matching. *)
    Alcotest.(check bool)
      "the guest's own real WASM trap is what is reported (message names the out-of-bounds memory \
       access)"
      true
      (let lower = String.lowercase_ascii e in
       string_contains ~needle:"out of bounds" lower);
    Alcotest.(check bool) "...reported as a WASM-level trap, not some other failure shape" true
      (string_contains ~needle:"wasm trap" (String.lowercase_ascii e));
    Alcotest.(check bool) "...and not the unrelated wall-clock containment path" false
      (string_contains ~needle:"fuel exhausted" e)

let test_two_separately_instantiated_modules_do_not_share_linear_memory () =
  let module_bytes = read_file "fixtures/memory_sentinel.wat" in
  let instantiate () =
    Loader.instantiate ~tier:Loader.Sfi ~module_bytes ~host:(no_op_host ())
      ~protocol:(permissive_protocol ())
  in
  let writer = instantiate () in
  let reader = instantiate () in
  (* The sentinel this fixture stores, little-endian, as the writer itself reads it back out --
     asserted rather than assumed, so the reader's four zero bytes below are known to be real
     isolation and not a fixture that silently wrote nothing at all. *)
  let sentinel = "\x34\x12\xed\x5e" in
  (match Loader.invoke writer ~entrypoint:"handle" ~arg:(Bytes.make 1 '\000') with
  | Error e -> Alcotest.failf "the writer guest itself failed: %s" e
  | Ok result ->
    Alcotest.(check string) "the writer really did write its sentinel into its own linear memory"
      sentinel (Bytes.to_string result));
  (match Loader.invoke reader ~entrypoint:"handle" ~arg:(Bytes.make 1 '\001') with
  | Error e -> Alcotest.failf "the reader guest itself failed: %s" e
  | Ok result ->
    Alcotest.(check string)
      "a separately-instantiated module reading the SAME offset observes zero-initialized memory, \
       not the other module's sentinel"
      "\000\000\000\000" (Bytes.to_string result));
  (* Same property one step further in, and free to check here: even the SAME [t], invoked again,
     observes nothing its own previous invocation wrote. That is Decision 5's "one fresh instance
     per invocation, no stale state between invocations" made observable -- here it holds for a
     second, independent reason too, since every invocation's guest code runs in a forked child
     whose writes land only in that child's own copy-on-write view of the memory. *)
  match Loader.invoke writer ~entrypoint:"handle" ~arg:(Bytes.make 1 '\001') with
  | Error e -> Alcotest.failf "the writer's second invocation itself failed: %s" e
  | Ok result ->
    Alcotest.(check string)
      "even the same t's next invocation does not observe what its own previous invocation wrote"
      "\000\000\000\000" (Bytes.to_string result)


let test_instantiate_rejects_a_module_declaring_a_memory_maximum_over_the_cap () =
  Alcotest.check_raises
    "an over-large self-declared memory maximum is rejected at load time, not silently honored"
    (Failure
       "Loader.instantiate: guest module's own declared memory maximum (65536 pages / 4294967296 \
        bytes) exceeds this loader's cap (1024 pages / 67108864 bytes)") (fun () ->
      ignore
        (Loader.instantiate ~tier:Loader.Sfi
           ~module_bytes:(read_file "fixtures/oversized_memory.wat") ~host:(no_op_host ())
           ~protocol:(permissive_protocol ())))

let test_instantiate_rejects_a_module_declaring_no_memory_maximum_at_all () =
  Alcotest.check_raises
    "an unbounded (no declared maximum) memory is rejected too, not just an over-large bounded one"
    (Failure
       "Loader.instantiate: guest module declares its memory with no maximum at all (unbounded \
        growth) -- a declared maximum of at most 1024 pages (67108864 bytes) is required") (fun () ->
      ignore
        (Loader.instantiate ~tier:Loader.Sfi
           ~module_bytes:(read_file "fixtures/unbounded_memory.wat") ~host:(no_op_host ())
           ~protocol:(permissive_protocol ())))

let test_instantiate_rejects_a_module_that_imports_memory_instead_of_declaring_it_locally () =
  Alcotest.check_raises
    "a memory import (not caught by the local-declaration-only memory-limit check above) is \
     still rejected at load time, with a clear Failure -- not wasmtime's own opaque \
     arity-mismatch Trap"
    (Failure
       "Loader.instantiate: guest module imports a memory (\"host\".\"memory\") -- only function \
        imports from \"host\" are supported") (fun () ->
      ignore
        (Loader.instantiate ~tier:Loader.Sfi ~module_bytes:(read_file "fixtures/memory_import.wat")
           ~host:(no_op_host ()) ~protocol:(permissive_protocol ())))

(* Shared by both "no zombie/fd leak" regression tests below: asserts the containment call
   returned a real [Error] (never raised), that the forked child was genuinely reaped (not left
   as a zombie -- [Unix.kill pid 0] must fail with [ESRCH]; it would still SUCCEED on an unreaped
   zombie, which is still visible to the process table), and that both parent-side pipe fds were
   genuinely closed (a redundant [Unix.close] must fail with [EBADF], not silently succeed on a
   still-open descriptor). *)
let assert_contained_failure_with_no_leaks ~scenario (result, child_pid, req_r, resp_w) =
  (match result with
  | Ok _ ->
    Alcotest.fail
      (Printf.sprintf
         "expected a containment-failure Error (invoke's own contract: never raises), not Ok, \
          for %s"
         scenario)
  | Error e ->
    Alcotest.(check bool) "a real, non-empty error is returned instead of an uncaught exception"
      true
      (String.length e > 0));
  (match Unix.kill child_pid 0 with
  | () -> Alcotest.fail "the forked child was left as a zombie -- not reaped"
  | exception Unix.Unix_error (Unix.ESRCH, _, _) -> ()
  | exception exn -> raise exn);
  let confirm_closed name fd =
    match Unix.close fd with
    | () -> Alcotest.fail (Printf.sprintf "%s was leaked open, not closed" name)
    | exception Unix.Unix_error (Unix.EBADF, _, _) -> ()
    | exception exn -> raise exn
  in
  confirm_closed "req_r" req_r;
  confirm_closed "resp_w" resp_w

let test_run_contained_reaps_and_closes_fds_even_when_the_child_dies_mid_message () =
  Loader.For_testing.simulate_child_death_mid_message ()
  |> assert_contained_failure_with_no_leaks ~scenario:"a child that never completed its message"

let test_run_contained_reaps_and_closes_fds_even_when_a_host_callback_raises_mid_step () =
  Loader.For_testing.simulate_an_exception_mid_step ()
  |> assert_contained_failure_with_no_leaks
       ~scenario:
         "a host callback (or the surrounding Unix.select call, per the code review's own live \
          SIGALRM-watchdog reproduction) raising mid-step"

let test_cleanup_reaps_and_closes_fds_even_under_repeated_signals_mid_cleanup () =
  Loader.For_testing.simulate_repeated_signals_during_cleanup ()
  |> assert_contained_failure_with_no_leaks
       ~scenario:
         "a real, rapidly repeated SIGALRM firing throughout an entire contained call, including \
          during cleanup's own kill/waitpid/close/close sequence"

let test_cleanup_reaps_and_closes_fds_even_when_a_signal_lands_in_its_pre_mask_window () =
  (* [SIG_BLOCK] with an empty set is a pure query of the mask currently in effect. Sampling it
     either side of the call guards the second, quieter half of this same window: cleanup blocks
     every asynchronous signal for the duration of its own sequence, and an interruption between
     "blocked" and "the restore is armed" would leave them blocked in this process permanently --
     which no later test would attribute to this one. This is a guard, not a live reproduction:
     that specific window is a single instruction wide by construction now (the block happens
     inside the [Fun.protect] that restores it), so it cannot be widened the way the pre-mask
     window below can. *)
  let mask_before_the_call = List.sort compare (Unix.sigprocmask Unix.SIG_BLOCK []) in
  let outcome = Loader.For_testing.simulate_signal_in_cleanups_pre_mask_window () in
  let mask_after_the_call = List.sort compare (Unix.sigprocmask Unix.SIG_BLOCK []) in
  Alcotest.(check (list int))
    "cleanup restored the caller's own signal mask exactly, despite being interrupted mid-attempt"
    mask_before_the_call mask_after_the_call;
  outcome
  |> assert_contained_failure_with_no_leaks
       ~scenario:
         "a real SIGALRM landing in the one instant cleanup's own signal masking cannot cover -- \
          after cleanup has entered its guard, before its sigprocmask has taken hold -- which \
          without the retry loop leaves the whole kill/waitpid/close/close sequence un-run \
          behind a normal-looking result, with no exception raised anywhere to notice it by"

(* Fix-wave round 2, re-review finding on M1: [invoke] has to create two pipes and fork before the
   guest can run, and nothing guarded that window -- a real fd exhaustion made
   [Unix.Unix_error(EMFILE, "pipe", "")] escape uncaught (falsifying the raise contract the same doc
   comment states) and, when it was the SECOND pipe that failed, leaked the first pipe's two
   descriptors permanently (falsifying "no exit path leaks a file descriptor", on exactly the path
   where descriptors are already scarce).

   Driven through [module_loader_emfile_probe.exe] under a real, shell-level [ulimit -n], for the same
   reason [test_transport_tcp.ml] and [test_file_storage.ml] already drive their own EMFILE/EFBIG
   reproductions that way: the property only exists with a genuinely FULL descriptor table, and
   lowering this suite's own budget would break every other test sharing the process. The probe's own
   top comment documents how it arranges exactly two free descriptors so that the first pipe succeeds
   and the second fails -- the leak-prone case specifically, not merely "some pipe failed". *)
let emfile_probe_path = "./module_loader_emfile_probe.exe"

let run_emfile_probe ~ulimit_n =
  let output_path = Filename.temp_file "module_loader_emfile_probe" ".log" in
  let out_fd = Unix.openfile output_path [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
  let pid =
    match Unix.fork () with
    | 0 ->
      (try
         Unix.dup2 out_fd Unix.stdout;
         Unix.dup2 out_fd Unix.stderr;
         Unix.close out_fd;
         Unix.execv "/bin/sh"
           [|
             "/bin/sh";
             "-c";
             Printf.sprintf "ulimit -n %d && exec %s fixtures/echo.wat" ulimit_n
               (Filename.quote emfile_probe_path);
           |]
       with _ -> Unix._exit 127)
    | child -> child
  in
  Unix.close out_fd;
  let status = snd (Unix.waitpid [] pid) in
  let output = read_file output_path in
  Sys.remove output_path;
  (status, output)

let test_invoke_reports_an_error_and_leaks_no_fd_when_the_containment_pipes_cannot_be_created () =
  (* 64 is comfortable enough for the probe's own startup (dynamic linker, the fixture read, whatever
     wasmtime's own compilation touches) while leaving a table small enough to fill with a handful of
     [Unix.dup] calls. *)
  let status, output = run_emfile_probe ~ulimit_n:64 in
  (* Reported first, so a setup failure inside the probe is legible rather than showing up only as an
     exit code. *)
  Alcotest.(check bool)
    (Printf.sprintf "the probe got past its own setup (output: %s)" (String.trim output))
    false
    (string_contains ~needle:"PROBE-SETUP-FAILED" output);
  Alcotest.(check bool)
    "invoke returned an Error naming the pipe-creation failure, rather than raising Unix_error"
    true
    (string_contains ~needle:"could not create the containment pipes" output);
  Alcotest.(check bool) "invoke did not raise" false (string_contains ~needle:"PROBE-RESULT raised" output);
  (* The probe compares its own [/proc/self/fd] count either side of the failed [invoke] and reports
     the two numbers plus its verdict; both appear in [output] above, which every label here
     includes, so a failure shows the real before/after counts without this test re-parsing them. *)
  Alcotest.(check bool)
    (Printf.sprintf "no descriptor was leaked by the failed setup; probe output: %s"
       (String.trim output))
    true
    (string_contains ~needle:"no_leak=true" output);
  Alcotest.(check bool)
    (Printf.sprintf "the probe exited 0 (all its own checks passed); full output: %s"
       (String.trim output))
    true
    (status = Unix.WEXITED 0)

let test_microvm_tier_raises_a_clear_not_implemented_error () =
  Alcotest.check_raises "microvm tier is designed, not built"
    (Failure "Loader.instantiate: Microvm tier is not yet implemented (Task 8's own job)") (fun () ->
      ignore
        (Loader.instantiate ~tier:Loader.Microvm ~module_bytes:(read_file "fixtures/echo.wat")
           ~host:
             {
               Loader.read_materialized = (fun ~merge_key:_ -> None);
               propose_write = (fun _ -> Ok ());
               log = ignore;
             }
           ~protocol:(permissive_protocol ())))

let test_a_call_violating_the_declared_protocol_is_rejected_not_forwarded_to_the_guest () =
  let called = ref false in
  let host =
    {
      Loader.read_materialized = (fun ~merge_key:_ -> None);
      propose_write = (fun _ -> called := true; Ok ());
      log = (fun _ -> ());
    }
  in
  let protocol =
    Protocol.create ~states:[ "init"; "ready" ] ~initial:"init"
      ~transitions:[ { from_state = "init"; on_call = "init"; to_state = "ready" } ]
  in
  let m =
    Loader.instantiate ~tier:Loader.Sfi ~module_bytes:(read_file "fixtures/protocol_violator.wat")
      ~host ~protocol
  in
  match Loader.invoke m ~entrypoint:"handle" ~arg:Bytes.empty with
  | Ok _ -> Alcotest.fail "expected rejection"
  | Error _ ->
    Alcotest.(check bool) "the guest's own propose_write was never reached" false !called

let test_two_concurrent_invocations_of_the_same_module_do_not_share_protocol_state () =
  let host =
    {
      Loader.read_materialized = (fun ~merge_key:_ -> None);
      propose_write = (fun _ -> Ok ());
      log = (fun _ -> ());
    }
  in
  (* Two transitions, not one: "ready" additionally permits "handle" (looping back to "ready"),
     so this test is actually discriminating -- not just a protocol that unconditionally rejects
     "handle" from any state regardless of isolation. If m1's own "init" call wrongly advanced a
     checker SHARED with m2 to "ready", m2's own "handle" call would then be wrongly PERMITTED
     (a real regression this exact shape caught live in code review, by temporarily memoizing/
     sharing the checker ref across same-protocol-value instantiate calls and confirming the
     single-transition version of this test still reported [OK] despite the sharing). With a
     correctly-isolated m2 (still at its own fresh "init"), "handle" has no transition from
     "init" and is still correctly rejected. *)
  let protocol =
    Protocol.create ~states:[ "init"; "ready" ] ~initial:"init"
      ~transitions:
        [
          { from_state = "init"; on_call = "init"; to_state = "ready" };
          { from_state = "ready"; on_call = "handle"; to_state = "ready" };
        ]
  in
  let module_bytes = read_file "fixtures/echo.wat" in
  let m1 = Loader.instantiate ~tier:Loader.Sfi ~module_bytes ~host ~protocol in
  let m2 = Loader.instantiate ~tier:Loader.Sfi ~module_bytes ~host ~protocol in
  (* m1 progresses its own protocol; m2, freshly instantiated, must still start at "init" *)
  ignore (Loader.invoke m1 ~entrypoint:"init" ~arg:Bytes.empty);
  match Loader.invoke m2 ~entrypoint:"handle" ~arg:Bytes.empty with
  | Ok _ -> Alcotest.fail "m2 should still be at its own fresh initial state"
  | Error _ -> ()

let tests =
  [
    ( "Loader.invoke calls the guest's handle and observes its log call",
      `Quick,
      test_invoke_calls_the_guests_handle_and_observes_its_log_call );
    ( "Loader.invoke contains a runaway module instead of crashing the host",
      `Quick,
      test_a_runaway_module_is_contained_not_crashing_the_host );
    ( "Loader.invoke does not charge blocked-on-host time against the guest's own fuel budget",
      `Quick,
      test_time_spent_in_a_host_closure_is_not_charged_against_the_guests_fuel_budget );
    ( "Loader.invoke still contains a spinning guest on schedule despite a slow fire-and-forget log \
       closure",
      `Quick,
      test_a_spinning_guest_that_calls_a_slow_log_closure_is_still_contained_on_schedule );
    ( "Loader.invoke relays a known read_materialized value back to the guest",
      `Quick,
      test_read_materialized_relays_a_known_value_back_to_the_guest );
    ( "Loader.invoke relays None for a missing read_materialized key",
      `Quick,
      test_read_materialized_relays_none_for_a_missing_key );
    ( "Loader.invoke relays the guest's propose_write bytes to the host and returns success",
      `Quick,
      test_propose_write_relays_the_guests_bytes_to_the_host_and_returns_success );
    ( "Loader.invoke relays the host's propose_write denial back to the guest",
      `Quick,
      test_propose_write_relays_the_hosts_denial_back_to_the_guest );
    ( "Loader.instantiate rejects a module declaring a memory maximum over the cap",
      `Quick,
      test_instantiate_rejects_a_module_declaring_a_memory_maximum_over_the_cap );
    ( "Loader.instantiate rejects a module declaring no memory maximum at all",
      `Quick,
      test_instantiate_rejects_a_module_declaring_no_memory_maximum_at_all );
    ( "Loader.invoke reports a guest's genuine out-of-bounds memory access as a trap, not a host \
       crash",
      `Quick,
      test_a_guest_that_accesses_memory_out_of_bounds_traps_and_is_reported_as_an_error );
    ( "two separately-instantiated modules do not share linear memory",
      `Quick,
      test_two_separately_instantiated_modules_do_not_share_linear_memory );
    ( "Loader.instantiate rejects a module that imports memory instead of declaring it locally",
      `Quick,
      test_instantiate_rejects_a_module_that_imports_memory_instead_of_declaring_it_locally );
    ( "run_contained reaps the child and closes both pipe fds even when it dies mid-message",
      `Quick,
      test_run_contained_reaps_and_closes_fds_even_when_the_child_dies_mid_message );
    ( "run_contained reaps the child and closes both pipe fds even when a host callback raises \
       mid-step",
      `Quick,
      test_run_contained_reaps_and_closes_fds_even_when_a_host_callback_raises_mid_step );
    ( "cleanup reaps the child and closes both pipe fds even under repeated signals mid-cleanup",
      `Quick,
      test_cleanup_reaps_and_closes_fds_even_under_repeated_signals_mid_cleanup );
    ( "cleanup reaps the child and closes both pipe fds even when a signal lands in its pre-mask \
       window",
      `Quick,
      test_cleanup_reaps_and_closes_fds_even_when_a_signal_lands_in_its_pre_mask_window );
    ( "Loader.invoke returns an Error and leaks no fd when the containment pipes cannot be created",
      `Quick,
      test_invoke_reports_an_error_and_leaks_no_fd_when_the_containment_pipes_cannot_be_created );
    ( "Loader.instantiate raises a clear not-implemented error for the Microvm tier",
      `Quick,
      test_microvm_tier_raises_a_clear_not_implemented_error );
    ( "Loader.invoke rejects a call violating the declared protocol, never forwarding it to the \
       guest",
      `Quick,
      test_a_call_violating_the_declared_protocol_is_rejected_not_forwarded_to_the_guest );
    ( "two concurrent invocations of the same module do not share protocol state",
      `Quick,
      test_two_concurrent_invocations_of_the_same_module_do_not_share_protocol_state );
  ]
