(* Task 6 (task-master), subtask 6.4 -- task-3-brief.md of the layer2-ledger-module plan: the
   real end-to-end proof that Tasks 1-2's own ledger schema/wire/legs/authorize code (Schema,
   Wire, Legs, Authorize -- already shipped, see lib/ledger/) composes against the real Layer 2
   boundary (Admission/Loader/Protocol/Reactor/Batch_commit) exactly the way
   test_module_end_to_end.ml already proved counter.wat does -- with a real domain, a real policy
   (Authorize.authorize, NOT Batch_commit.allow_all: the first task in this whole plan to use it
   end to end), and a real admission-verified guest (fixtures/ledger.wat) deciding real business
   logic (sufficient funds) instead of an arbitrary counter increment.

   ── Where this module's host half actually lives ────────────────────────────────────────────────
   Schema/Wire/Legs/Authorize give a wire encoding, leg construction, and a per-write
   well-formedness check. None of them turn a committed transfer_leg write (role + amount +
   accounts) into an account's own running BALANCE, decide whether a request happens at all, or
   implement the host side of this module's byte convention. All three of those now live in
   Accumulator (lib/ledger/) -- real, documented library code with a single owner.

   They did not, originally: they lived here, as roughly 50 lines of inline closure duplicated
   verbatim between this file and test_ledger_dst_load.ml, carrying a load-bearing correctness
   guard that no .mli documented anywhere. The final whole-branch review called that out (finding
   I3), and it was the right call for a reason the fix made obvious: two of the three bugs this fix
   wave closed (C1, a declined decision that was not durable; I4, a dedup key that silently
   destroyed money) were defects in exactly that undocumented, duplicated logic. Logic that decides
   whether money moves is not test scaffolding.

   What is left in this file is what genuinely belongs to a test: the real stack wired together
   (real solo replica, real Batch_commit.t with ~authorize:Authorize.authorize -- the first use of
   the real policy end to end in this whole plan -- real Materializer, real admission-verified
   ledger.wat, Reactor.subscribe), plus four small closures naming this test's own choice of lattice
   (Last_write_wins) and KV backend (File_kv_store). *)
open Riptide
open Riptide_ledger
open Riptide_module
open Riptide_batch_commit
open Riptide_vsr
open Riptide_lattice
open Riptide_storage

let () = Mirage_crypto_rng_unix.use_default ()

module M = Riptide_materialize.Materializer.Make (Last_write_wins) (File_kv_store)

(* ── Admission-verification helpers -- mirrored verbatim from test_module_end_to_end.ml's own
   pattern (that file's own top comment already establishes these as test-local, per-file helpers,
   not shared library code -- reused here the same way, adjusted for ledger.wat). ──────────────── *)

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

(* Returns the temp dir alongside the verified artifact (not just the artifact) so a caller can
   clean it up once it's no longer needed -- see Reactor.subscribe's own doc comment: module_'s
   bytes are read ONCE, at subscribe time, never re-read from disk on any later dispatch, so this
   directory's lifetime only needs to span "until subscribe returns", not the whole test. Fixed
   here (Minor finding, fix round 1): this directory was previously never removed at all --
   confirmed live, 6 leftover /tmp/ledger_e2e_test* dirs after 2 full suite runs. *)
let verified_module fixture_relpath tier =
  let dir = make_temp_dir "ledger_e2e_test" in
  let artifact = Filename.concat dir (Filename.basename fixture_relpath) in
  write_file artifact (read_file fixture_relpath);
  let key = sign_with_fresh_keypair ~dir artifact in
  let verified =
    match
      Admission.verify ~cosign_path ~key ~digest:(sha256_hex artifact) ~tier ~artifact_path:artifact
    with
    | Ok verified -> verified
    | Error e -> Alcotest.failf "test setup: Admission.verify failed: %s" e
  in
  (verified, dir)

let verified_ledger () = verified_module "fixtures/ledger.wat" Loader.Sfi

(* Same protocol shape as test_module_end_to_end.ml's own allow_handle_from_init -- a fresh
   checker is seeded from this SAME Protocol.t on every single dispatch (Reactor.subscribe's own
   contract), so "exactly one handle call per dispatch" is the right protocol for a guest invoked
   repeatedly, once per retrigger, not just once ever. *)
let allow_handle_from_init =
  Protocol.create ~states:[ "init"; "ready" ] ~initial:"init"
    ~transitions:[ { Protocol.from_state = "init"; on_call = "handle"; to_state = "ready" } ]

(* Same Last_write_wins <-> Value.value codec test_module_end_to_end.ml's own worked example
   already establishes -- reused verbatim rather than inventing a second one. *)
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
  let dir = Filename.temp_file "riptide_ledger_e2e_test" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o700;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () -> f dir)

let fake_event_id name = Value.content_hash (Value.Scalar (Value.String name))

(* replica_count = 1, f = 0: Replica.propose commits synchronously -- same create_solo_volatile
   precedent test_module_end_to_end.ml/test_batch_commit_materialize.ml already establish. *)
let create_solo_volatile () =
  Replica.create ~storage:(Replica.volatile_storage ()) ~my_id:1 ~replica_count:1 ~svc_limit:10
    ~send:(fun ~to_:_ (_ : string) -> ())
    ()

(* ── The full real wiring: one replica, one Batch_commit.t (real Authorize.authorize policy, not
   allow_all), one Materializer, one Reactor subscribed to "ledger.requests" with ledger.wat --
   built fresh per test, matching this codebase's own test-isolation convention. ────────────────── *)

type env_handles = {
  handle : Batch_commit.t;
  replica : Replica.t;
  materializer : M.t;
  wrapped_sink : Batch_commit.materialize_sink;
  accumulator : Accumulator.t;
}

let with_ledger_env (f : env_handles -> unit) =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun kv_dir ->
      Eio.Switch.run @@ fun sw ->
      let replica = create_solo_volatile () in
      let handle = Batch_commit.create ~replica ~authorize:Authorize.authorize () in
      let kv = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"materializer" kv_dir in
      let materializer =
        M.create ~kv ~owner:"materializer"
          ~decode:(fun s -> lww_of_value (Value.canonical_decode s))
          ~encode:(fun w -> Value.canonical_encode (lww_to_value w))
      in
      let ts_counter = ref 0L in
      let next_ts () =
        ts_counter := Int64.add !ts_counter 1L;
        !ts_counter
      in
      (* Everything that used to be ~50 lines of balance-accumulation, dedup-guarding and
         wire-encoding inline here is now real library code (Accumulator, lib/ledger/) -- see
         finding I3. What is left below is exactly the part that genuinely belongs to a test: four
         tiny closures naming THIS test's own choice of lattice (Last_write_wins) and KV backend
         (File_kv_store). Nothing about the ledger's own semantics lives in this file any more,
         which is the point: it was never test logic. *)
      let accumulator = Accumulator.create () in
      let read_balance ~merge_key =
        let v = M.read materializer ~merge_key in
        if v = Last_write_wins.bottom then None
        else match v.Last_write_wins.value with Value.Scalar (Value.Int n) -> Some n | _ -> None
      in
      let write_balance ~merge_key balance =
        M.write materializer ~merge_key
          { Last_write_wins.value = Value.Scalar (Value.Int balance); timestamp = next_ts () }
      in
      (* The request is stored as-is -- re-storing identical content under a fresh timestamp on a
         replay is harmless, since Last_write_wins converges to the same value regardless of which
         identical-content write "won". *)
      let store_request payload =
        M.write materializer ~merge_key:Schema.requests_merge_key
          { Last_write_wins.value = payload; timestamp = next_ts () }
      in
      let read_request () =
        let v = M.read materializer ~merge_key:Schema.requests_merge_key in
        if v = Last_write_wins.bottom then None
        else Schema.transfer_request_of_value v.Last_write_wins.value
      in
      let inner_sink =
        Accumulator.materialize_sink accumulator ~read_balance ~write_balance ~store_request
      in
      let reactor = Reactor.create () in
      let wrapped_sink = Reactor.wrap_materialize_sink reactor inner_sink in
      let read_for_module = Accumulator.read_for_guest ~read_request ~read_balance in
      (* host.propose_write's own half, now a single library call: the guest hands back 33 bytes (a
         decision tag plus the request), and Accumulator.handle_guest_decision is what decides --
         once and for all, per request_id -- whether that becomes a pair of committed legs. *)
      let propose_for_module (bytes : bytes) : (unit, string) result =
        Accumulator.handle_guest_decision accumulator ~actor:"ledger-module"
          ~propose:(fun ~idempotency_key writes ->
            Batch_commit.propose handle ~idempotency_key ~materialize:wrapped_sink writes)
          bytes
      in
      let verified_artifact, verification_dir = verified_ledger () in
      (* Same Fun.protect ~finally idiom as with_tmp_dir above, applied to the admission-
         verification temp directory: runs the subscribe call and the whole test body under it, so
         cleanup happens whether the body returns normally or raises (e.g. a failed Alcotest
         assertion). module_'s bytes are already resident in memory by the time subscribe returns
         (see verified_module's own comment above), so removing the directory here never races
         anything this test still needs. *)
      Fun.protect
        ~finally:(fun () ->
          ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote verification_dir))))
        (fun () ->
          Reactor.subscribe reactor ~merge_key:Schema.requests_merge_key ~module_:verified_artifact
            ~protocol:allow_handle_from_init ~read:read_for_module ~propose:propose_for_module;
          f { handle; replica; materializer; wrapped_sink; accumulator }))

(* This task's own documented test-setup convention (per task-3-brief.md step 6 and the design
   spec's own non-goals: no "mint"/account-opening flow exists in this focused-core scope) --
   seeding a starting balance proposes a transfer_leg-shaped write DIRECTLY to the account's own
   merge_key, bypassing the request/module flow entirely. other_account = 0L is simply an
   unused/placeholder counterparty for this synthetic, test-only leg -- never itself seeded or
   asserted on. *)
let seed_account ?key env account amount =
  let idempotency_key =
    match key with Some k -> k | None -> Printf.sprintf "seed-%Ld" account
  in
  let event_id = fake_event_id idempotency_key in
  let leg =
    Schema.
      {
        transfer_id = 0L;
        role = Credit;
        actor = "test-seed";
        this_account = account;
        other_account = 0L;
        amount;
      }
  in
  Batch_commit.propose env.handle ~idempotency_key ~materialize:env.wrapped_sink
    [
      {
        Batch_commit.actor = "test-seed";
        causation = event_id;
        correlation = event_id;
        payload = Schema.transfer_leg_to_value leg;
        merge_key = Some (Schema.account_merge_key account);
      };
    ]

let propose_request env ~idempotency_key (r : Schema.transfer_request) =
  let event_id = fake_event_id idempotency_key in
  Batch_commit.propose env.handle ~idempotency_key ~materialize:env.wrapped_sink
    [
      {
        Batch_commit.actor = "client";
        causation = event_id;
        correlation = event_id;
        payload = Schema.transfer_request_to_value r;
        merge_key = Some Schema.requests_merge_key;
      };
    ]

let balance_of env account =
  match
    (M.read env.materializer ~merge_key:(Schema.account_merge_key account)).Last_write_wins.value
  with
  | Value.Scalar (Value.Int n) -> n
  | _ -> 0L

(* Only ever the ledger module's own propose_for_module closure proposes a write with
   actor = "ledger-module" (seeding above uses "test-seed"; a client's own request uses
   "client") -- so this is exactly "the legs the WASM guest itself caused to be committed". *)
let module_leg_envelopes env =
  Batch_commit.committed_envelopes env.replica
  |> List.filter (fun (e : Envelope.envelope) -> e.actor = "ledger-module")

let test_a_request_with_sufficient_funds_commits_both_legs_and_updates_both_balances () =
  with_ledger_env (fun env ->
      seed_account env 100L 1000L;
      seed_account env 200L 500L;
      propose_request env ~idempotency_key:"req-1"
        Schema.{ request_id = 1L; from_account = 100L; to_account = 200L; amount = 300L };
      Alcotest.(check int)
        "both legs of the approved transfer committed, attributed to the module" 2
        (List.length (module_leg_envelopes env));
      Alcotest.(check int64) "the debited account's balance decreased by the transfer amount" 700L
        (balance_of env 100L);
      Alcotest.(check int64) "the credited account's balance increased by the transfer amount" 800L
        (balance_of env 200L))

let test_insufficient_funds_is_a_clean_no_op () =
  with_ledger_env (fun env ->
      seed_account env 300L 50L;
      let log_calls_before = Reactor.For_testing.log_call_count () in
      propose_request env ~idempotency_key:"req-2"
        Schema.{ request_id = 2L; from_account = 300L; to_account = 400L; amount = 999_999L };
      let log_calls_after = Reactor.For_testing.log_call_count () in
      Alcotest.(check int)
        "the module's handle genuinely ran exactly once, observed via its host.log call" 1
        (log_calls_after - log_calls_before);
      Alcotest.(check int) "no leg was committed -- a clean no-op, no propose_write call at all" 0
        (List.length (module_leg_envelopes env));
      Alcotest.(check int64) "the would-be-debited account's balance is unchanged" 50L
        (balance_of env 300L))

(* The scenario deliberately leaves enough balance after ONE application for the module to STILL
   decide "sufficient funds" on a second, replayed dispatch (1000 - 100 = 900 >= 100) -- if that
   weren't true, the module's own business check would mask a missing materialize-idempotency
   guard by independently refusing the second attempt on its own merits, and this test would prove
   nothing about the guard this file's own top comment describes. 600L is never seeded, relying on
   an unreferenced account's documented implicit balance of 0. *)
let test_the_same_request_id_proposed_twice_does_not_double_apply () =
  with_ledger_env (fun env ->
      seed_account env 500L 1000L;
      let r = Schema.{ request_id = 3L; from_account = 500L; to_account = 600L; amount = 100L } in
      propose_request env ~idempotency_key:"req-3" r;
      propose_request env ~idempotency_key:"req-3" r;
      Alcotest.(check int)
        "exactly 2 legs committed, not 4 -- the retried client proposal commits nothing new" 2
        (List.length (module_leg_envelopes env));
      Alcotest.(check int64) "the debit applied exactly once, despite the replayed materialize call"
        900L (balance_of env 500L);
      Alcotest.(check int64)
        "the credit applied exactly once, despite the replayed materialize call" 100L
        (balance_of env 600L))

(* ── Final whole-branch review, finding C1 (Critical): a DECLINED decision must be durable ─────
   The scenario, reproduced here exactly as the reviewer found it: a request is declined for
   insufficient funds, the sender's balance later rises for an entirely unrelated reason, and then
   the SAME already-committed "ledger.requests" write is re-materialized -- which is not an exotic
   act but one of three routine, documented idioms (the empty-writes drain used below,
   Batch_commit.propose's own unconditional-on-retry materialize step, or
   Batch_commit.materialize_up_to). Re-materializing re-dispatches the guest, which re-reads the
   CURRENT balance; before this fix nothing recorded that the request had already been decided, so
   the guest legitimately decided ACCEPT the second time and the host dutifully committed both legs
   -- real money movement with no new client request behind it.

   Note what the balance top-up here is NOT: no seeding trick, no hand-made leg. It is an ordinary
   accepted transfer from a second seeded account, i.e. exactly the everyday traffic that makes a
   stale decline dangerous in the first place. *)
let test_a_declined_request_cannot_be_accepted_by_a_later_re_materialization () =
  with_ledger_env (fun env ->
      seed_account env 700L 50L;
      seed_account env 701L 1000L;
      let declined =
        Schema.{ request_id = 10L; from_account = 700L; to_account = 800L; amount = 500L }
      in
      propose_request env ~idempotency_key:"req-10" declined;
      Alcotest.(check int) "request 10 was declined: no leg committed yet" 0
        (List.length (module_leg_envelopes env));
      (* Ordinary, unrelated traffic lifts account 700 well past the declined amount. *)
      propose_request env ~idempotency_key:"req-11"
        Schema.{ request_id = 11L; from_account = 701L; to_account = 700L; amount = 1000L };
      Alcotest.(check int) "request 11 was accepted: exactly its own two legs committed" 2
        (List.length (module_leg_envelopes env));
      Alcotest.(check int64) "the sender now has far more than enough for the declined transfer"
        1050L (balance_of env 700L);
      let flips_before = Accumulator.prevented_flips env.accumulator in
      (* The empty-writes drain idiom, verbatim from batch_commit.mli's own documented contract: a
         pure "is it committed now? if so, materialize it" probe against an already-committed key.
         Nothing here proposes any new content whatsoever. *)
      Batch_commit.propose env.handle ~idempotency_key:"req-10" ~materialize:env.wrapped_sink [];
      (* Positive evidence that the mechanism FIRED, not just that the outcome looks right: without
         this, the test would pass equally well if the guest had simply declined a second time for
         its own reasons, which would prove nothing about C1 at all. *)
      Alcotest.(check int)
        "the re-dispatched guest genuinely decided ACCEPT, and the first-decision-wins rule \
         overrode it"
        1
        (Accumulator.prevented_flips env.accumulator - flips_before);
      Alcotest.(check int)
        "still only request 11's two legs -- request 10's decline survived the replay" 2
        (List.length (module_leg_envelopes env));
      Alcotest.(check int64) "the sender's balance is untouched by the replay" 1050L
        (balance_of env 700L);
      Alcotest.(check int64) "the would-be recipient never received anything" 0L
        (balance_of env 800L))

(* ── Final whole-branch review, finding I4 (Important): the accumulator's dedup key must not
   collide across two genuinely different legs ───────────────────────────────────────────────────
   Live-reproduced by the reviewer and again here: this file's own documented seeding convention
   builds its synthetic leg with transfer_id = 0L, so before this fix a REAL transfer carrying
   request_id = 0L shared the dedup key (0, account, role) with the seed leg of whichever account
   it credited -- the accumulator saw the key already applied and silently skipped the credit. The
   committed log stays perfectly correct (both legs are there), while the materialized balances
   stop conserving value: the debit lands, the credit vanishes. Money destroyed, nothing raised.

   request_id = 0L is a perfectly ordinary client-chosen identifier, not a reserved value, which is
   what makes this a real defect rather than a theoretical one. *)
let test_a_request_id_of_zero_does_not_collide_with_the_seeding_convention () =
  with_ledger_env (fun env ->
      seed_account env 910L 500L;
      seed_account env 911L 300L;
      propose_request env ~idempotency_key:"req-0"
        Schema.{ request_id = 0L; from_account = 910L; to_account = 911L; amount = 100L };
      Alcotest.(check int) "both legs of the transfer committed" 2
        (List.length (module_leg_envelopes env));
      Alcotest.(check int64) "the debit landed" 400L (balance_of env 910L);
      Alcotest.(check int64) "the credit landed too -- not swallowed by the seed leg's dedup key"
        400L (balance_of env 911L);
      Alcotest.(check int64) "value is conserved across the two accounts" 800L
        (Int64.add (balance_of env 910L) (balance_of env 911L)))

let tests =
  [
    ( "a request with sufficient funds commits both legs and updates both balances",
      `Quick, test_a_request_with_sufficient_funds_commits_both_legs_and_updates_both_balances );
    ("insufficient funds is a clean no-op", `Quick, test_insufficient_funds_is_a_clean_no_op);
    ( "the same request_id proposed twice does not double-apply",
      `Quick, test_the_same_request_id_proposed_twice_does_not_double_apply );
    ( "a declined request cannot be accepted by a later re-materialization",
      `Quick, test_a_declined_request_cannot_be_accepted_by_a_later_re_materialization );
    ( "a request_id of zero does not collide with the seeding convention",
      `Quick, test_a_request_id_of_zero_does_not_collide_with_the_seeding_convention );
  ]
