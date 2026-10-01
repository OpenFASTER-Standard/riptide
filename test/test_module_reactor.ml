(* Task 6 (task-master subtasks 6.1 + 6.5): the reactor dispatch loop. This is the pressure test
   this repo's own CLAUDE.md calls for -- every module consumed here (Admission from Task 5,
   Loader/Protocol from Tasks 3-4, Batch_commit's own materialize_sink) is wired together for
   real, not stubbed. See ../.superpowers/sdd/2026-09-30-layer0-layer2-boundary/task-6-report.md
   for the full "Boundary friction found" writeup this task's own dispatch below surfaced. *)
open Riptide
open Riptide_module
open Riptide_batch_commit
open Riptide_vsr

let () = Mirage_crypto_rng_unix.use_default ()

(* ── Shared setup, mirrored from test_module_admission.ml's own pattern (kept self-contained here
   rather than reaching into that other test file's internals) ────────────────────────────────── *)

let cosign_path =
  if Sys.file_exists "/work/toolchain/bin/cosign" then "/work/toolchain/bin/cosign" else "cosign"

let make_temp_dir prefix =
  let path = Filename.temp_file prefix "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  path

let write_file path contents =
  let oc = open_out_bin path in
  output_string oc contents;
  close_out oc

let read_file path =
  let ic = open_in_bin path in
  let s = really_input_string ic (in_channel_length ic) in
  close_in ic;
  s

let sha256_hex path =
  let ic = open_in_bin path in
  let contents = really_input_string ic (in_channel_length ic) in
  close_in ic;
  Digestif.SHA256.(to_hex (digest_string contents))

let () = Unix.putenv "COSIGN_PASSWORD" ""

let run_cosign_setup args ~cwd =
  let cmd =
    Printf.sprintf "cd %s && %s" (Filename.quote cwd) (Filename.quote_command cosign_path args)
  in
  let exit_code = Sys.command cmd in
  if exit_code <> 0 then
    Alcotest.failf "test setup: `cosign %s` (cwd %s) failed with exit %d" (String.concat " " args)
      cwd exit_code

let sign_with_fresh_keypair ~dir artifact =
  run_cosign_setup [ "generate-key-pair" ] ~cwd:dir;
  run_cosign_setup
    [ "sign-blob"; "--key"; Filename.concat dir "cosign.key"; "--bundle";
      Filename.concat dir (Filename.basename artifact) ^ ".bundle"; "--tlog-upload=false";
      "--use-signing-config=false"; "--yes"; artifact ]
    ~cwd:dir;
  Filename.concat dir "cosign.pub"

(* Real end-to-end Admission.verify against a real, freshly cosign-signed copy of a fixture --
   never a bare, unverified path, matching this whole task's own "the reactor only ever loads a
   verified_artifact" framing (admission.mli's own doc comment). *)
let verified_module fixture_relpath tier =
  let dir = make_temp_dir "reactor_test" in
  let artifact = Filename.concat dir (Filename.basename fixture_relpath) in
  write_file artifact (read_file fixture_relpath);
  let key = sign_with_fresh_keypair ~dir artifact in
  match
    Admission.verify ~cosign_path ~key ~digest:(sha256_hex artifact) ~tier ~artifact_path:artifact
  with
  | Ok verified -> verified
  | Error e -> Alcotest.failf "test setup: Admission.verify failed: %s" e

let verified_echo () = verified_module "fixtures/echo.wat" Loader.Sfi
let verified_propose_write () = verified_module "fixtures/propose_write.wat" Loader.Sfi

(* Same shape Task 4's own tests already use for a protocol permitting exactly one call to
   "handle" -- see task-6-brief.md's own shared-setup section. *)
let allow_handle_from_init =
  Protocol.create ~states:[ "init"; "ready" ] ~initial:"init"
    ~transitions:[ { Protocol.from_state = "init"; on_call = "handle"; to_state = "ready" } ]

let v s = Value.Scalar (Value.String s)

(* A real 32-byte {!Riptide.Envelope.event_id} (a content hash), not a human-readable placeholder.
   Defined here rather than further down the file (where it used to live, after its first would-be
   users) because the sink calls below pass it: several of them used to pass the bare literals
   "test-causation"/"test-correlation", which are 14/16 bytes and so not valid event_ids at all --
   a Batch_commit.materialize_sink invoked directly in a test is the one place nothing validates
   them, so the wrong shape went unnoticed while this very helper already existed in the same file
   (final whole-branch review, Minor). *)
let fake_event_id name = Value.content_hash (Value.Scalar (Value.String name))

let test_causation = fake_event_id "test-causation"
let test_correlation = fake_event_id "test-correlation"

(* ── Test 1 ───────────────────────────────────────────────────────────────────────────────────── *)

let test_a_materialized_change_on_a_subscribed_key_invokes_the_module () =
  let invoked = ref [] in
  let inner_sink : Batch_commit.materialize_sink =
    { write = (fun ~merge_key ~idempotency_key:_ ~position:_ ~actor:_ ~causation:_ ~correlation:_ v -> invoked := (`inner, merge_key, v) :: !invoked) }
  in
  let reactor = Reactor.create () in
  let read ~merge_key:_ = None and propose _ = Ok () in
  Reactor.subscribe reactor ~merge_key:"k" ~module_:(verified_echo ()) ~protocol:allow_handle_from_init
    ~read ~propose;
  let wrapped = Reactor.wrap_materialize_sink reactor inner_sink in
  let log_calls_before = Reactor.For_testing.log_call_count () in
  wrapped.write ~merge_key:"k" ~idempotency_key:"test-idempotency-key" ~position:0 ~actor:"test-actor" ~causation:test_causation ~correlation:test_correlation (v "1");
  Alcotest.(check bool) "inner sink still ran" true
    (List.exists (fun (tag, _, _) -> tag = `inner) !invoked);
  (* Not just "the inner sink ran" (true regardless of any subscription at all) -- also assert the
     subscribed module's own "handle" entrypoint genuinely executed, via the one observable side
     effect echo.wat's own handle produces: a single host.log call, which this reactor wires
     internally and exposes only via Reactor.For_testing.log_call_count (see reactor.mli). *)
  Alcotest.(check bool) "the subscribed module's own handle was actually invoked (observed via its \
                        internally-wired host log call)" true
    (Reactor.For_testing.log_call_count () > log_calls_before)

(* ── Test 2 ───────────────────────────────────────────────────────────────────────────────────── *)

let test_a_change_on_an_unsubscribed_key_never_invokes_any_module () =
  let reactor = Reactor.create () in
  let inner_sink : Batch_commit.materialize_sink = { write = (fun ~merge_key:_ ~idempotency_key:_ ~position:_ ~actor:_ ~causation:_ ~correlation:_ _ -> ()) } in
  let wrapped = Reactor.wrap_materialize_sink reactor inner_sink in
  (* no subscription registered *)
  wrapped.write ~merge_key:"unrelated" ~idempotency_key:"test-idempotency-key" ~position:0 ~actor:"test-actor" ~causation:test_causation ~correlation:test_correlation (v "1")
  (* no exception, no module invocation -- nothing to assert beyond "this doesn't raise" *)

(* ── Test 3 ───────────────────────────────────────────────────────────────────────────────────── *)

let test_a_module_that_calls_propose_write_zero_times_is_not_an_error () =
  (* Review Focus: a module legitimately choosing not to act must be a clean no-op, not a
     reactor-level failure. echo.wat's own handle only logs -- it never calls propose_write. *)
  let proposed = ref 0 in
  let read ~merge_key:_ = None
  and propose _ =
    incr proposed;
    Ok ()
  in
  let reactor = Reactor.create () in
  let inner_sink : Batch_commit.materialize_sink = { write = (fun ~merge_key:_ ~idempotency_key:_ ~position:_ ~actor:_ ~causation:_ ~correlation:_ _ -> ()) } in
  Reactor.subscribe reactor ~merge_key:"k" ~module_:(verified_echo ()) ~protocol:allow_handle_from_init
    ~read ~propose;
  let wrapped = Reactor.wrap_materialize_sink reactor inner_sink in
  wrapped.write ~merge_key:"k" ~idempotency_key:"test-idempotency-key" ~position:0 ~actor:"test-actor" ~causation:test_causation ~correlation:test_correlation (v "1");
  Alcotest.(check int) "propose was never called, and nothing raised" 0 !proposed

(* ── Test 4 (written out in full -- the brief's own text was truncated with "...") ─────────────── *)

(* replica_count = 1, f = 0: propose commits synchronously, matching test_batch_commit.ml's own
   create_solo helper -- an isolated unit test of dispatch independence needs no network/quorum. *)
let create_solo () =
  let send ~to_:_ (_ : string) = () in
  Replica.create ~storage:(Replica.volatile_storage ()) ~my_id:1 ~replica_count:1 ~svc_limit:3 ~send ()

let test_one_subscribed_modules_denial_does_not_affect_a_sibling_module_on_the_same_key () =
  (* Two modules subscribed to the SAME merge_key, each wired (via its own ~propose closure) to a
     DIFFERENT Batch_commit.t handle -- one handle's ~authorize always Denies, the other's always
     Allows -- both dispatched from the same underlying materialized change. Uses
     fixtures/propose_write.wat (Task 3's own fixture) for both subscriptions: its "handle" calls
     host.propose_write unconditionally with its own `arg` bytes (here, the reactor's own
     canonical-encoded materialized value), so each dispatch genuinely attempts a real
     Batch_commit.propose through its own handle -- not a simulated outcome. *)
  let deny_replica = create_solo () in
  let deny_handle =
    Batch_commit.create ~replica:deny_replica
      ~authorize:(fun (_ : Batch_commit.write) -> Batch_commit.Deny "test always denies")
      ()
  in
  let allow_replica = create_solo () in
  let allow_handle = Batch_commit.create ~replica:allow_replica ~authorize:Batch_commit.allow_all () in
  let dispatch_counter = ref 0 in
  (* Each subscription's own ~propose closure genuinely calls Batch_commit.propose against its OWN
     handle, then reports Ok/Error back to the guest based on whether that specific call was
     actually denied -- read off Batch_commit.authorization_denials()'s own before/after delta,
     since Batch_commit.propose itself is fire-and-forget (see batch_commit.mli). Dispatch to
     sibling subscriptions happens sequentially, not concurrently (Reactor.wrap_materialize_sink's
     own List.iter), so this delta is never confused by the OTHER subscription's own denial. *)
  let propose_via handle bytes =
    let denials_before = Batch_commit.authorization_denials () in
    incr dispatch_counter;
    let idempotency_key = Printf.sprintf "reactor-dispatch-%d" !dispatch_counter in
    let event_id = fake_event_id idempotency_key in
    Batch_commit.propose handle ~idempotency_key
      [
        {
          Batch_commit.actor = "reactor";
          causation = event_id;
          correlation = event_id;
          payload = Value.Scalar (Value.Bytes (Bytes.to_string bytes));
          merge_key = None;
        };
      ];
    if Batch_commit.authorization_denials () > denials_before then Error "denied by authorize"
    else Ok ()
  in
  let no_read ~merge_key:_ = None in
  let reactor = Reactor.create () in
  let propose_write_module = verified_propose_write () in
  Reactor.subscribe reactor ~merge_key:"k" ~module_:propose_write_module ~protocol:allow_handle_from_init
    ~read:no_read ~propose:(propose_via deny_handle);
  Reactor.subscribe reactor ~merge_key:"k" ~module_:propose_write_module ~protocol:allow_handle_from_init
    ~read:no_read ~propose:(propose_via allow_handle);
  let inner_sink : Batch_commit.materialize_sink = { write = (fun ~merge_key:_ ~idempotency_key:_ ~position:_ ~actor:_ ~causation:_ ~correlation:_ _ -> ()) } in
  let wrapped = Reactor.wrap_materialize_sink reactor inner_sink in
  let denials_before_dispatch = Batch_commit.authorization_denials () in
  wrapped.write ~merge_key:"k" ~idempotency_key:"test-idempotency-key" ~position:0 ~actor:"test-actor" ~causation:test_causation ~correlation:test_correlation (v "dispatch-me");
  Alcotest.(check int) "exactly one of the two sibling modules was denied" 1
    (Batch_commit.authorization_denials () - denials_before_dispatch);
  Alcotest.(check int)
    "the Allow-wired module's write actually committed -- its own real write plus its synthetic \
     authorization-decision write"
    2 (List.length (Batch_commit.committed_envelopes allow_replica));
  Alcotest.(check int) "the Deny-wired module's write did not reach the log at all" 0
    (List.length (Batch_commit.committed_envelopes deny_replica))

(* ── Fix round 2: regression coverage for the fix-round-1 behavioral changes ─────────────────────
   The exception-scoping re-raise and the merge_key/module log-attribution format were both
   shipped as prose (this file's own comments) plus doc comments plus manual verification only --
   this repo's own CLAUDE.md "No spec without running code" rule means that isn't good enough on
   its own: nothing in the suite would previously have caught a future regression (e.g. someone
   "simplifying" dispatch's catch-all back to a blanket `with exn -> ...`, or dropping the context
   interpolation from a log call). The two tests below pin both, the same way loader.ml's own
   `cleanup` fault-injection tests (`Loader.For_testing`) already pin its own, analogous
   exception-scoping behavior in this exact codebase. *)

let string_contains ~needle haystack =
  try
    ignore (Str.search_forward (Str.regexp_string needle) haystack 0);
    true
  with Not_found -> false

(* Redirects the real fd 2 (not just the OCaml `stderr` channel's buffer) to a temp file for the
   duration of [f], then restores it -- so this captures the REAL emitted log content (this
   process's actual `Printf.eprintf` output, exactly what an operator watching this box's own log
   stream would see), not a mocked stand-in for it. Every `Printf.eprintf` call in reactor.ml
   already ends its own format string with `%!` (auto-flushing), so no extra flush is strictly
   required around [f] itself, but one is included anyway for safety/clarity. *)
let capture_stderr f =
  flush stderr;
  let saved_stderr = Unix.dup Unix.stderr in
  let tmp_path = Filename.temp_file "reactor_test_stderr" "" in
  let tmp_fd = Unix.openfile tmp_path [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
  Unix.dup2 tmp_fd Unix.stderr;
  Unix.close tmp_fd;
  Fun.protect
    ~finally:(fun () ->
      flush stderr;
      Unix.dup2 saved_stderr Unix.stderr;
      Unix.close saved_stderr)
    (fun () ->
      f ();
      flush stderr);
  let content = read_file tmp_path in
  Sys.remove tmp_path;
  content

(* Pins the exception-scoping fix (fix round 1, Finding 1): [Out_of_memory]/[Stack_overflow] must
   propagate OUT of wrap_materialize_sink's own [write], never be caught and logged like an
   ordinary dispatch failure -- matching loader.ml's own [cleanup] precedent
   (`with | (Out_of_memory | Stack_overflow) as exn -> raise exn | _ -> ...`) in this exact
   codebase. [raise Stack_overflow] here is an entirely ordinary use of a predefined exception
   constructor -- OCaml does not require the call stack to actually be exhausted to raise it, so
   this test is fast and deterministic, not a stress test.

   The closure that raises is [~propose] (reachable via `fixtures/propose_write.wat`'s own
   "handle", which calls `host.propose_write` unconditionally, per Task 3). That closure actually
   executes on the PARENT side of Loader.invoke's own fork-based containment (inside
   `supervise_child`'s `step`, servicing the guest's relayed 'P' message -- see loader.ml's own
   top comment) -- loader.ml's OWN `step` already re-raises Out_of_memory/Stack_overflow rather
   than converting them to an [Error], so this exception reaches `Loader.invoke`'s own call site
   (and therefore this reactor's `dispatch`) as a genuine raised exception, not a wrapped
   [Error] -- which is exactly the path this test needs to exercise dispatch's own re-raise. *)
let test_dispatch_reraises_out_of_memory_and_stack_overflow_rather_than_swallowing_them () =
  let reactor = Reactor.create () in
  let no_read ~merge_key:_ = None in
  Reactor.subscribe reactor ~merge_key:"k" ~module_:(verified_propose_write ())
    ~protocol:allow_handle_from_init ~read:no_read ~propose:(fun _ -> raise Stack_overflow);
  let inner_sink : Batch_commit.materialize_sink = { write = (fun ~merge_key:_ ~idempotency_key:_ ~position:_ ~actor:_ ~causation:_ ~correlation:_ _ -> ()) } in
  let wrapped = Reactor.wrap_materialize_sink reactor inner_sink in
  Alcotest.check_raises
    "Stack_overflow propagates out of wrap_materialize_sink's write rather than being caught and \
     logged like an ordinary dispatch failure"
    Stack_overflow
    (fun () -> wrapped.write ~merge_key:"k" ~idempotency_key:"test-idempotency-key" ~position:0 ~actor:"test-actor" ~causation:test_causation ~correlation:test_correlation (v "trigger"))

(* Pins BOTH the swallow-and-log behavior (an ordinary exception must NOT propagate) and the
   log-attribution format (fix round 1, Finding 2): the real, actually-emitted log line for this
   dispatch must name the responsible merge_key and module. A distinct, real merge_key
   ("distinct-merge-key-xyz", chosen to be implausible as an accidental substring match anywhere
   else in the emitted text) and the module's own real, freshly-generated `local_path` are both
   checked for, so this assertion is genuinely checking the right content, not something that
   would pass by coincidence (e.g. against a hardcoded/fixed string).

   Loader.invoke's own [step] absorbs an ordinary (non-Out_of_memory/Stack_overflow) exception
   raised from a host closure into an [Error _] result itself (see loader.ml's own generic
   catch-all) rather than letting it escape as a raised exception -- so this specific scenario
   exercises dispatch's `Error msg -> ... "module dispatch failed" ...` branch, not its outer
   `with exn -> ... "module dispatch raised" ...` branch (which fires only for a failure
   originating outside Loader.invoke's own containment, e.g. Loader.instantiate itself raising).
   Both branches share the exact same `context` construction, so this still directly verifies the
   log-attribution format fix; it just isn't the specific catch-all line the fix's own diff
   touched. *)
let test_dispatch_swallows_an_ordinary_exception_and_logs_it_with_merge_key_and_module_context () =
  let reactor = Reactor.create () in
  let no_read ~merge_key:_ = None in
  let propose_module = verified_propose_write () in
  let merge_key = "distinct-merge-key-xyz" in
  Reactor.subscribe reactor ~merge_key ~module_:propose_module ~protocol:allow_handle_from_init
    ~read:no_read ~propose:(fun _ -> failwith "boom");
  let inner_sink : Batch_commit.materialize_sink = { write = (fun ~merge_key:_ ~idempotency_key:_ ~position:_ ~actor:_ ~causation:_ ~correlation:_ _ -> ()) } in
  let wrapped = Reactor.wrap_materialize_sink reactor inner_sink in
  (* capture_stderr's own call to [f] running to completion at all -- rather than an exception
     escaping through it and failing this test via Alcotest's own uncaught-exception handling --
     is itself the proof that wrap_materialize_sink's write did not raise for an ordinary
     exception; there is no separate "did not raise" assertion form to call in addition to that. *)
  let stderr_output = capture_stderr (fun () -> wrapped.write ~merge_key ~idempotency_key:"test-idempotency-key" ~position:0 ~actor:"test-actor" ~causation:test_causation ~correlation:test_correlation (v "trigger")) in
  Alcotest.(check bool) "the emitted log line identifies the merge_key responsible" true
    (string_contains ~needle:merge_key stderr_output);
  Alcotest.(check bool) "the emitted log line identifies the module responsible" true
    (string_contains ~needle:propose_module.Admission.local_path stderr_output);
  Alcotest.(check bool) "the underlying failure's own message is still present in the log line"
    true
    (string_contains ~needle:"boom" stderr_output)

(* ── Final fix wave, findings I1 + I2 (tested together, deliberately) ─────────────────────────────
   I1: reentrant dispatch was unbounded -- a module that proposes to its own subscribed key
   retriggers itself, and every live level holds a forked child process, two pipe fds and a freshly
   compiled WASM instance until the level below returns, so nothing stopped a self-proposing guest
   from consuming processes and descriptors without limit.

   I2 is in the same test on purpose: the two interact directly. Before I2's fix, time spent in a
   nested cascade was charged against every OUTER guest's own fuel budget, so a deep chain collapsed
   from the outside in with spurious "fuel exhausted" containment failures -- which is why this test
   asserts not only that the depth bound stops the chain, but that NOTHING in the chain failed on
   the way there. Those two assertions pull in opposite directions (the first needs deep nesting;
   the second needs deep nesting to be harmless), which is exactly what makes running them together
   worth more than running either alone.

   The cascade here is driven by a ~propose closure that re-enters the very sink that dispatched it.
   That is the same shape the real chain has -- test_module_end_to_end.ml drives the genuine
   Batch_commit.propose -> commit -> materialize -> wrapped sink version for real -- with the
   consensus/materialization machinery left out so this test can push the nesting several levels
   PAST the bound (which a real chain, bounded at 4 by its own fixture, never reaches) without
   standing up a 12-deep commit chain to do it. *)
let test_reentrant_dispatch_is_bounded_by_max_dispatch_depth () =
  let reactor = Reactor.create () in
  let merge_key = "depth-chain-key" in
  let inner_writes = ref 0 in
  let inner_sink : Batch_commit.materialize_sink =
    { write = (fun ~merge_key:_ ~idempotency_key:_ ~position:_ ~actor:_ ~causation:_ ~correlation:_ _ -> incr inner_writes) }
  in
  let wrapped = Reactor.wrap_materialize_sink reactor inner_sink in
  let dispatches = ref 0 in
  let recurse = ref true in
  (* Strictly above the bound, so the closure keeps trying to recurse for several more levels after
     the reactor has already started refusing -- this test's own ceiling is a backstop against
     hanging the suite if the bound is absent entirely, NOT the thing under test. Pre-fix this test
     therefore fails with a real, finite, wrong number (that ceiling) rather than by hanging. *)
  let own_ceiling = Reactor.max_dispatch_depth + 4 in
  (* Real host-side work per level, sized off the two constants under test rather than hardcoded, so
     the I2 half of this test is PROVABLY discriminating rather than incidentally so: with
     [max_dispatch_depth] levels each spending this long inside its own relayed host call, the
     OUTERMOST level accumulates 1.5x the entire fuel budget of nested time before its own child
     ever reports back. If that time is (wrongly) charged to the guest, the outer levels are
     SIGKILLed as runaways and the assertions below see real "fuel exhausted" failures; charged
     correctly, none of them is affected at all. Without this delay the whole chain finishes well
     inside one budget, and the I2 assertion -- verified live -- passes even against an
     I2-regressed loader, which is exactly the kind of quietly-vacuous assertion this branch's own
     review history has caught more than once. *)
  let host_work_per_level =
    Loader.fuel_budget_seconds /. float_of_int Reactor.max_dispatch_depth *. 1.5
  in
  let propose _ =
    incr dispatches;
    Unix.sleepf host_work_per_level;
    if !recurse && !dispatches < own_ceiling then wrapped.write ~merge_key ~idempotency_key:"test-idempotency-key" ~position:0 ~actor:"test-actor" ~causation:test_causation ~correlation:test_correlation (v "retrigger");
    Ok ()
  in
  let no_read ~merge_key:_ = None in
  Reactor.subscribe reactor ~merge_key ~module_:(verified_propose_write ())
    ~protocol:allow_handle_from_init ~read:no_read ~propose;
  let stderr_output = capture_stderr (fun () -> wrapped.write ~merge_key ~idempotency_key:"test-idempotency-key" ~position:0 ~actor:"test-actor" ~causation:test_causation ~correlation:test_correlation (v "start")) in
  Alcotest.(check int)
    "the reentrant chain stopped at exactly the documented depth bound, not at this test's own \
     ceiling (and not never)"
    Reactor.max_dispatch_depth !dispatches;
  Alcotest.(check bool) "the refusal itself is logged, naming the limit it hit" true
    (string_contains ~needle:"maximum reentrant dispatch depth" stderr_output);
  Alcotest.(check bool) "...and naming the merge_key responsible for the chain" true
    (string_contains ~needle:merge_key stderr_output);
  (* I1 + I2 combined: every dispatch in the chain -- including the outermost, which stayed blocked
     inside its own relayed host call for the entire duration of all 7 levels below it -- must have
     completed cleanly. A spurious fuel timeout anywhere in that chain is precisely the bug I2
     fixed, and deep nesting is precisely what provokes it. *)
  Alcotest.(check bool)
    "no dispatch in the chain was reported as a containment failure (in particular, no outer level \
     was charged for the nested levels' time and SIGKILLed as a runaway)"
    false
    (string_contains ~needle:"module dispatch failed" stderr_output
    || string_contains ~needle:"module dispatch raised" stderr_output
    || string_contains ~needle:"fuel exhausted" stderr_output);
  Alcotest.(check int)
    "materialization itself was never what got skipped -- the inner sink ran once per write, \
     refused dispatch included"
    (Reactor.max_dispatch_depth + 1)
    !inner_writes;
  (* The depth counter is released on the way back out, not leaked: a fresh top-level write, after
     the chain above has fully unwound, must dispatch normally again rather than finding the reactor
     permanently wedged at its own limit. [recurse] off, so this second write is a single, plain
     dispatch and the expected count is exact rather than "at least". *)
  recurse := false;
  ignore (capture_stderr (fun () -> wrapped.write ~merge_key ~idempotency_key:"test-idempotency-key" ~position:0 ~actor:"test-actor" ~causation:test_causation ~correlation:test_correlation (v "second-top-level-write")));
  Alcotest.(check int)
    "a top-level write after the chain unwound dispatches normally -- the depth counter was \
     released on the way out, not leaked"
    (Reactor.max_dispatch_depth + 1)
    !dispatches

let tests =
  [
    ("a materialized change on a subscribed key invokes the module", `Quick,
      test_a_materialized_change_on_a_subscribed_key_invokes_the_module);
    ("a change on an unsubscribed key never invokes any module", `Quick,
      test_a_change_on_an_unsubscribed_key_never_invokes_any_module);
    ("a module that calls propose_write zero times is not an error", `Quick,
      test_a_module_that_calls_propose_write_zero_times_is_not_an_error);
    ("one subscribed module's denial does not affect a sibling module on the same key", `Quick,
      test_one_subscribed_modules_denial_does_not_affect_a_sibling_module_on_the_same_key);
    ("dispatch re-raises Out_of_memory/Stack_overflow rather than swallowing them", `Quick,
      test_dispatch_reraises_out_of_memory_and_stack_overflow_rather_than_swallowing_them);
    ("dispatch swallows an ordinary exception and logs it with merge_key/module context", `Quick,
      test_dispatch_swallows_an_ordinary_exception_and_logs_it_with_merge_key_and_module_context);
    ("reentrant dispatch is bounded by max_dispatch_depth, and nesting costs no outer level its \
      own fuel budget", `Quick,
      test_reentrant_dispatch_is_bounded_by_max_dispatch_depth);
  ]
