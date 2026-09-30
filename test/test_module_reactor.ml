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

(* ── Test 1 ───────────────────────────────────────────────────────────────────────────────────── *)

let test_a_materialized_change_on_a_subscribed_key_invokes_the_module () =
  let invoked = ref [] in
  let inner_sink : Batch_commit.materialize_sink =
    { write = (fun ~merge_key v -> invoked := (`inner, merge_key, v) :: !invoked) }
  in
  let reactor = Reactor.create () in
  let read ~merge_key:_ = None and propose _ = Ok () in
  Reactor.subscribe reactor ~merge_key:"k" ~module_:(verified_echo ()) ~protocol:allow_handle_from_init
    ~read ~propose;
  let wrapped = Reactor.wrap_materialize_sink reactor inner_sink in
  let log_calls_before = Reactor.For_testing.log_call_count () in
  wrapped.write ~merge_key:"k" (v "1");
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
  let inner_sink : Batch_commit.materialize_sink = { write = (fun ~merge_key:_ _ -> ()) } in
  let wrapped = Reactor.wrap_materialize_sink reactor inner_sink in
  (* no subscription registered *)
  wrapped.write ~merge_key:"unrelated" (v "1")
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
  let inner_sink : Batch_commit.materialize_sink = { write = (fun ~merge_key:_ _ -> ()) } in
  Reactor.subscribe reactor ~merge_key:"k" ~module_:(verified_echo ()) ~protocol:allow_handle_from_init
    ~read ~propose;
  let wrapped = Reactor.wrap_materialize_sink reactor inner_sink in
  wrapped.write ~merge_key:"k" (v "1");
  Alcotest.(check int) "propose was never called, and nothing raised" 0 !proposed

(* ── Test 4 (written out in full -- the brief's own text was truncated with "...") ─────────────── *)

(* replica_count = 1, f = 0: propose commits synchronously, matching test_batch_commit.ml's own
   create_solo helper -- an isolated unit test of dispatch independence needs no network/quorum. *)
let create_solo () =
  let send ~to_:_ (_ : string) = () in
  Replica.create ~storage:(Replica.volatile_storage ()) ~my_id:1 ~replica_count:1 ~svc_limit:3 ~send ()

let fake_event_id name = Value.content_hash (Value.Scalar (Value.String name))

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
  let inner_sink : Batch_commit.materialize_sink = { write = (fun ~merge_key:_ _ -> ()) } in
  let wrapped = Reactor.wrap_materialize_sink reactor inner_sink in
  let denials_before_dispatch = Batch_commit.authorization_denials () in
  wrapped.write ~merge_key:"k" (v "dispatch-me");
  Alcotest.(check int) "exactly one of the two sibling modules was denied" 1
    (Batch_commit.authorization_denials () - denials_before_dispatch);
  Alcotest.(check int)
    "the Allow-wired module's write actually committed -- its own real write plus its synthetic \
     authorization-decision write"
    2 (List.length (Batch_commit.committed_envelopes allow_replica));
  Alcotest.(check int) "the Deny-wired module's write did not reach the log at all" 0
    (List.length (Batch_commit.committed_envelopes deny_replica))

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
  ]
