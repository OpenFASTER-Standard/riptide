(* Task 7 (task-master, this branch's final task): the end-to-end proof that the whole Layer
   0/Layer 2 boundary (Tasks 1-6) composes together for real, per this repo's own CLAUDE.md
   "Expect the first extension mechanism to need real revision" -- Task 6 already pressure-tested
   the boundary with one real module (the reactor dispatch loop itself, test_module_reactor.ml)
   and disclosed friction points that lib/module/reactor.mli's own "Known, disclosed residual gap"
   and "CLOSED by task-master Task 7" paragraphs now enumerate in full -- that interface is the
   durable record of which of them survived and which Task 7 closed. (Final whole-branch review,
   Minor: this used to cite a task-7-brief.md and "this file's own bottom comment", neither of which
   exists -- the brief lived in an untracked .superpowers/ workspace that does not survive a clone,
   and this file has no bottom comment at all.) This test's own job is ONLY to wire Tasks 1-6's
   already-real interfaces together -- no new library code unless this test reveals a genuine
   compositional gap.

   Full chain this test drives, all real, none stubbed (design spec's own "Data flow end to end"):
   a real Batch_commit.t (authorize = allow_all) over a real, solo (replica_count = 1, f = 0)
   Riptide_vsr.Replica.t (Replica.volatile_storage ()) -- the same create_solo_volatile precedent
   test_batch_commit_materialize.ml already establishes for exactly this topology -- paired with a
   real Riptide_materialize.Materializer (Last_write_wins over a real File_kv_store, the same
   codec convention test_batch_commit_materialize.ml's own lww_to_value/lww_of_value already use),
   and a real, cosign-admission-verified counter.wat guest (fixtures/counter.wat, this task's own
   new fixture) subscribed via Reactor.subscribe to merge_key "count". One initial write is
   proposed through Batch_commit.propose with ?materialize wrapped by
   Reactor.wrap_materialize_sink -- everything downstream (the module's own handle running,
   reaching back into the real replica via propose_write, and that new commit re-materializing and
   re-triggering the SAME guest on its own output) happens because the real wiring makes it
   happen, not because this test drives it by hand. *)
open Riptide
open Riptide_module
open Riptide_batch_commit
open Riptide_vsr
open Riptide_lattice
open Riptide_storage

let () = Mirage_crypto_rng_unix.use_default ()

module M = Riptide_materialize.Materializer.Make (Last_write_wins) (File_kv_store)

(* ── Admission-verification helpers -- mirrored from test_module_reactor.ml's own pattern
   (kept self-contained here rather than reaching into that other test file's internals, matching
   that file's own stated precedent for test_module_admission.ml). ──────────────────────────────── *)

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

let verified_module fixture_relpath tier =
  let dir = make_temp_dir "e2e_test" in
  let artifact = Filename.concat dir (Filename.basename fixture_relpath) in
  write_file artifact (read_file fixture_relpath);
  let key = sign_with_fresh_keypair ~dir artifact in
  match
    Admission.verify ~cosign_path ~key ~digest:(sha256_hex artifact) ~tier ~artifact_path:artifact
  with
  | Ok verified -> verified
  | Error e -> Alcotest.failf "test setup: Admission.verify failed: %s" e

let verified_counter () = verified_module "fixtures/counter.wat" Loader.Sfi

(* Same shape Task 4/6's own tests already use for a protocol permitting exactly one call to
   "handle" -- see task-6-brief.md's own shared-setup section, reused verbatim here since
   Reactor.subscribe seeds a FRESH checker (from this SAME Protocol.t) on every single dispatch
   (reactor.mli), so "exactly one handle call per dispatch" is the right protocol for a guest that
   is invoked repeatedly, once per retrigger, not just once ever. *)
let allow_handle_from_init =
  Protocol.create ~states:[ "init"; "ready" ] ~initial:"init"
    ~transitions:[ { Protocol.from_state = "init"; on_call = "handle"; to_state = "ready" } ]

(* Same Last_write_wins <-> Value.value codec test_batch_commit_materialize.ml's own worked example
   already establishes (Task 3/4 of the lattice-materialization plan) -- reused verbatim rather
   than inventing a second one, per this task's own "no new abstraction" brief. *)
let lww_to_value (w : Last_write_wins.t) =
  Value.Record [ ("value", w.value); ("timestamp", Value.Scalar (Value.Int w.timestamp)) ]

let lww_of_value = function
  | Value.Record fields ->
    let value = List.assoc "value" fields in
    let timestamp =
      match List.assoc "timestamp" fields with
      | Value.Scalar (Value.Int i) -> i
      | _ -> invalid_arg "Last_write_wins codec: malformed timestamp field"
    in
    Last_write_wins.{ value; timestamp }
  | _ -> invalid_arg "Last_write_wins codec: expected a Record"

let with_tmp_dir f =
  let dir = Filename.temp_file "riptide_e2e_test" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o700;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () -> f dir)

let fake_event_id name = Value.content_hash (Value.Scalar (Value.String name))

(* replica_count = 1, f = 0: Replica.propose commits synchronously, matching
   test_batch_commit_materialize.ml's own create_solo_volatile helper -- the "Setup precedent"
   this task's own brief points at directly, reused verbatim. *)
let create_solo_volatile () =
  Replica.create ~storage:(Replica.volatile_storage ()) ~my_id:1 ~replica_count:1 ~svc_limit:10
    ~send:(fun ~to_:_ (_ : string) -> ())
    ()

(* The merge_key's own value bytes are a single raw little-endian i32 -- counter.wat's own chosen
   convention (see its own top comment); the host.read_materialized/host.propose_write closures
   below are this test's half of that agreement. *)
let int32_le_bytes n =
  let b = Bytes.create 4 in
  Bytes.set_int32_le b 0 n;
  b

let test_a_real_module_reacts_commits_and_can_retrigger_itself () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun kv_dir ->
      Eio.Switch.run @@ fun sw ->
      let replica = create_solo_volatile () in
      let handle = Batch_commit.create ~replica ~authorize:Batch_commit.allow_all () in
      let kv = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"materializer" kv_dir in
      let materializer =
        M.create ~kv ~owner:"materializer"
          ~decode:(fun s -> lww_of_value (Value.canonical_decode s))
          ~encode:(fun w -> Value.canonical_encode (lww_to_value w))
      in
      let inner_sink : Batch_commit.materialize_sink =
        { write =
            (fun ~merge_key ~idempotency_key:_ ~position:_ ~actor:_ ~causation:_ ~correlation:_ payload ->
              M.write materializer ~merge_key (lww_of_value payload))
        }
      in
      let reactor = Reactor.create () in
      let wrapped_sink = Reactor.wrap_materialize_sink reactor inner_sink in

      (* host.read_materialized's own half of counter.wat's raw-i32 convention: the current
         Last_write_wins.t's own `.value` (never its `.timestamp` -- the guest has no use for that)
         encoded as 4 raw little-endian bytes, or [None] if nothing has been materialized for
         "count" yet at all (the un-reached, defensive branch: this test's own initial write below
         always lands before the first dispatch ever calls this). *)
      let read_count ~merge_key:(_ : string) =
        let current = M.read materializer ~merge_key:"count" in
        if current = Last_write_wins.bottom then None
        else
          match current.Last_write_wins.value with
          | Value.Scalar (Value.Int n) -> Some (int32_le_bytes (Int64.to_int32 n))
          | _ -> None
      in

      (* Bounded retrigger mechanism (this test's own, per the brief's own "your call on the
         cleanest mechanism" -- counter.wat itself always increments and always re-proposes; NO
         library-level rate limit exists anywhere in Reactor/Batch_commit, and none should, so this
         bound lives entirely here): the first [max_retriggers] guest-initiated propose_write calls
         genuinely propose (through the SAME wrapped_sink, so each one re-materializes and
         re-dispatches counter.wat on its own output, same as the very first write did); every call
         past that returns [Error] instead of calling Batch_commit.propose at all, so nothing new
         commits, nothing re-materializes, and the chain terminates -- deliberately, not because of
         any real system limit. *)
      let max_retriggers = 3 in
      let retrigger_count = ref 0 in
      let ts_counter = ref 0 in
      let propose_count bytes =
        if !retrigger_count >= max_retriggers then
          Error "test: retrigger bound reached, stopping the counter chain deliberately"
        else (
          incr retrigger_count;
          incr ts_counter;
          let n32 = Bytes.get_int32_le bytes 0 in
          let payload =
            lww_to_value
              { Last_write_wins.value = Value.Scalar (Value.Int (Int64.of_int32 n32));
                timestamp = Int64.of_int !ts_counter
              }
          in
          let idempotency_key = Printf.sprintf "counter-retrigger-%d" !retrigger_count in
          let event_id = fake_event_id idempotency_key in
          Batch_commit.propose handle ~idempotency_key ~materialize:wrapped_sink
            [
              {
                Batch_commit.actor = "counter-module";
                causation = event_id;
                correlation = event_id;
                payload;
                merge_key = Some "count";
              };
            ];
          Ok ())
      in

      Reactor.subscribe reactor ~merge_key:"count" ~module_:(verified_counter ())
        ~protocol:allow_handle_from_init ~read:read_count ~propose:propose_count;

      (* ── Step: propose the initial write to "count", through Batch_commit.propose with
         ?materialize wrapped by Reactor.wrap_materialize_sink -- exactly the brief's own text. *)
      let log_calls_before = Reactor.For_testing.log_call_count () in
      let initial_payload =
        lww_to_value { Last_write_wins.value = Value.Scalar (Value.Int 0L); timestamp = 0L }
      in
      let initial_event_id = fake_event_id "counter-initial" in
      Batch_commit.propose handle ~idempotency_key:"counter-initial" ~materialize:wrapped_sink
        [
          {
            Batch_commit.actor = "test-seed";
            causation = initial_event_id;
            correlation = initial_event_id;
            payload = initial_payload;
            merge_key = Some "count";
          };
        ];

      (* ── Assertion 1: the module's own handle genuinely ran, exactly the deterministic number of
         times this chain always produces -- observable via its host.log call. One initial dispatch
         (from the write just above) plus exactly `max_retriggers` bounded retriggers (from each
         dispatch's own propose_write reaching back into the real replica and re-materializing) is
         the whole point of this test: the write-triggers-materialize-triggers-dispatch loop closing
         a fixed, known number of times, not merely "more than once". *)
      let log_calls_after_dispatch = Reactor.For_testing.log_call_count () in
      Alcotest.(check int)
        "the module's handle ran exactly 4 times -- once for the initial write, plus once for each \
         of the 3 bounded retriggers on its own output (observed via its internally-wired host.log \
         call)"
        4
        (log_calls_after_dispatch - log_calls_before);

      (* ── Assertion 2: its propose_write genuinely reached the real replica -- committed_envelopes
         shows real, actor-attributed envelopes for every guest-initiated write, each carrying the
         correctly-incremented value (1, 2, 3, ... in commit order), not merely that SOME envelope
         exists. *)
      let module_envelopes =
        Batch_commit.committed_envelopes replica
        |> List.filter (fun (e : Envelope.envelope) -> e.actor = "counter-module")
      in
      Alcotest.(check int)
        "exactly max_retriggers guest-initiated writes committed -- proving the chain ran the full \
         bounded length, not zero and not unboundedly"
        max_retriggers (List.length module_envelopes);
      let module_values =
        List.map
          (fun (e : Envelope.envelope) ->
            match (lww_of_value e.payload).Last_write_wins.value with
            | Value.Scalar (Value.Int n) -> n
            | _ -> Alcotest.fail "unexpected guest-written payload shape")
          module_envelopes
      in
      Alcotest.(check (list int64))
        "each guest-initiated commit carries the correctly incremented count, in commit order"
        [ 1L; 2L; 3L ] module_values;

      (* ── Assertion 3: the chain genuinely terminated (this test's own bound, not a library-level
         limit -- see propose_count's own comment above) -- the materializer converged to exactly
         max_retriggers, not something higher a runaway loop would have produced. *)
      let converged = M.read materializer ~merge_key:"count" in
      Alcotest.(check bool) "the materializer converged to the final, correctly-incremented value"
        true
        (match converged.Last_write_wins.value with
        | Value.Scalar (Value.Int n) -> Int64.equal n (Int64.of_int max_retriggers)
        | _ -> false))

let tests =
  [
    ( "a real module reacts, commits, and can retrigger itself (end-to-end Layer 0/Layer 2)",
      `Quick, test_a_real_module_reacts_commits_and_can_retrigger_itself );
  ]
