(* Task 6 (task-master), subtask 6.4 -- task-3-brief.md of the layer2-ledger-module plan: the
   real end-to-end proof that Tasks 1-2's own ledger schema/wire/legs/authorize code (Schema,
   Wire, Legs, Authorize -- already shipped, see lib/ledger/) composes against the real Layer 2
   boundary (Admission/Loader/Protocol/Reactor/Batch_commit) exactly the way
   test_module_end_to_end.ml already proved counter.wat does -- with a real domain, a real policy
   (Authorize.authorize, NOT Batch_commit.allow_all: the first task in this whole plan to use it
   end to end), and a real admission-verified guest (fixtures/ledger.wat) deciding real business
   logic (sufficient funds) instead of an arbitrary counter increment.

   ── The one piece of glue this task owns that Tasks 1-2 do not provide ──────────────────────────
   Schema/Wire/Legs/Authorize together give: a wire encoding, leg construction, and a per-write
   well-formedness check. None of them turn a committed transfer_leg write (role + amount +
   accounts) into an account's own running BALANCE -- the design spec's own Decision 2 is explicit
   that balances are "materialized state, not a new lattice/CRDT type", maintained via the same
   read-materialized-then-propose-new-total pattern counter.wat already established, just applied
   here by this test's own ~materialize sink closure (the host side) rather than inside the guest,
   because what the guest's propose_write call produces (via the trusted Legs construction) is a
   transfer_leg descriptor, not an absolute balance. This file's own inner_sink is that glue: for
   every committed write at an "ledger.account.*" key, it decodes the leg, reads the account's
   current materialized balance, applies the leg's own signed delta (-amount for Debit, +amount
   for Credit), and writes the new absolute total back as a plain Value.Scalar (Value.Int _) --
   analogous to test_module_end_to_end.ml's own lww_to_value/lww_of_value codec helpers, just
   doing real accumulation instead of a pure encoding conversion, since Last_write_wins has no
   accumulation of its own.

   ── Why that accumulation needs an explicit dedup guard, found while writing this test, not
      assumed ──────────────────────────────────────────────────────────────────────────────────
   Batch_commit.propose's own doc comment states plainly that its materialize step "happen[s] on
   EVERY call, not only the call that itself performs the durable commit" -- so a client retrying
   the SAME transfer_request under the SAME idempotency_key genuinely re-runs materialize.write
   for both of that transfer's already-committed legs a second time, with the bit-identical
   payload each time (decoded from the committed bytes, never from a call's own writes argument).
   A naive "read current, add delta, write new total" sink is NOT idempotent under that replay --
   it would apply the delta twice. inner_sink therefore tracks which (transfer_id, this_account,
   role) triples it has already applied, in a plain Hashtbl captured by its own closure, and skips
   a repeat. This is exactly what
   test_the_same_request_id_proposed_twice_does_not_double_apply below proves empirically, not
   just by code inspection -- see that test's own comment for how the scenario is constructed so a
   missing guard would actually be caught (an amount small enough that the SECOND, replayed
   dispatch still independently decides "sufficient funds" and genuinely attempts a second
   propose_write, rather than being saved by the business check alone). *)
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

let verified_module fixture_relpath tier =
  let dir = make_temp_dir "ledger_e2e_test" in
  let artifact = Filename.concat dir (Filename.basename fixture_relpath) in
  write_file artifact (read_file fixture_relpath);
  let key = sign_with_fresh_keypair ~dir artifact in
  match
    Admission.verify ~cosign_path ~key ~digest:(sha256_hex artifact) ~tier ~artifact_path:artifact
  with
  | Ok verified -> verified
  | Error e -> Alcotest.failf "test setup: Admission.verify failed: %s" e

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

let account_prefix = "ledger.account."

let is_account_key mk =
  String.length mk >= String.length account_prefix
  && String.sub mk 0 (String.length account_prefix) = account_prefix

(* ── The full real wiring: one replica, one Batch_commit.t (real Authorize.authorize policy, not
   allow_all), one Materializer, one Reactor subscribed to "ledger.requests" with ledger.wat --
   built fresh per test, matching this codebase's own test-isolation convention. ────────────────── *)

type env_handles = {
  handle : Batch_commit.t;
  replica : Replica.t;
  materializer : M.t;
  wrapped_sink : Batch_commit.materialize_sink;
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
      (* This test's own idempotent-accumulation guard -- see this file's own top comment for the
         real materialize-replay scenario that makes it necessary, not optional. Keyed by
         (transfer_id, this_account, role): that triple is stable and identical across however
         many times the SAME already-committed leg write is handed back to this sink. *)
      let applied_legs : (string, unit) Hashtbl.t = Hashtbl.create 16 in
      let inner_sink : Batch_commit.materialize_sink =
        {
          write =
            (fun ~merge_key payload ->
              if merge_key = Schema.requests_merge_key then
                (* The request itself is stored as-is -- re-storing identical content under a
                   fresh timestamp on a replay is harmless, since Last_write_wins converges to the
                   same value regardless of which identical-content write "won". *)
                M.write materializer ~merge_key
                  { Last_write_wins.value = payload; timestamp = next_ts () }
              else if is_account_key merge_key then (
                match Schema.transfer_leg_of_value payload with
                | None ->
                  (* Can't happen via this module's own trusted ~propose closure below (Legs
                     always produces a well-formed leg, and Authorize already denied anything else
                     before this sink ever sees it) -- defensively a no-op, not a crash. *)
                  ()
                | Some leg ->
                  let dedup_key =
                    Printf.sprintf "%Ld|%Ld|%s" leg.Schema.transfer_id leg.Schema.this_account
                      (match leg.Schema.role with
                      | Schema.Debit -> "debit"
                      | Schema.Credit -> "credit")
                  in
                  if not (Hashtbl.mem applied_legs dedup_key) then (
                    Hashtbl.add applied_legs dedup_key ();
                    let delta =
                      match leg.Schema.role with
                      | Schema.Debit -> Int64.neg leg.Schema.amount
                      | Schema.Credit -> leg.Schema.amount
                    in
                    let current = M.read materializer ~merge_key in
                    let current_balance =
                      if current = Last_write_wins.bottom then 0L
                      else
                        match current.Last_write_wins.value with
                        | Value.Scalar (Value.Int n) -> n
                        | _ -> 0L
                    in
                    let new_balance = Int64.add current_balance delta in
                    M.write materializer ~merge_key
                      {
                        Last_write_wins.value = Value.Scalar (Value.Int new_balance);
                        timestamp = next_ts ();
                      }))
              else
                (* This module has no opinion on any other merge_key shape -- matches Authorize's
                   own "anything else: allow, untouched" framing. *)
                ());
        }
      in
      let reactor = Reactor.create () in
      let wrapped_sink = Reactor.wrap_materialize_sink reactor inner_sink in
      (* host.read_materialized's own half of this module's wire convention (Decision 3): the
         guest asks for either "ledger.requests" (32 bytes, Wire.encode_request) or
         "ledger.account.<id>" (8 bytes, Wire.encode_balance) -- [None] from this closure means
         the guest sees a zero-length read, its own "no value yet" convention. *)
      let read_for_module ~merge_key =
        if merge_key = Schema.requests_merge_key then (
          let v = M.read materializer ~merge_key in
          if v = Last_write_wins.bottom then None
          else
            match Schema.transfer_request_of_value v.Last_write_wins.value with
            | Some r -> Some (Wire.encode_request r)
            | None -> None)
        else if is_account_key merge_key then (
          let v = M.read materializer ~merge_key in
          if v = Last_write_wins.bottom then None
          else
            match v.Last_write_wins.value with
            | Value.Scalar (Value.Int bal) -> Some (Wire.encode_balance bal)
            | _ -> None)
        else None
      in
      (* host.propose_write's own half: the guest forwards the SAME 32 bytes it read for
         "ledger.requests" (Decision 3). This is the one piece of trusted host code that ever
         builds a ledger transfer's two legs (Legs.legs_of_bytes, Task 2) and proposes them
         together, atomically, under the exact idempotency-key convention the brief's own Global
         Constraints section states: "ledger-transfer-" ^ Int64.to_string request_id. *)
      let propose_for_module (bytes : bytes) : (unit, string) result =
        match Wire.decode_request bytes with
        | None -> Error "propose closure: payload does not decode as a well-formed transfer_request"
        | Some r ->
          let idempotency_key = "ledger-transfer-" ^ Int64.to_string r.Schema.request_id in
          let event_id = fake_event_id idempotency_key in
          (match
             Legs.legs_of_bytes ~actor:"ledger-module" ~causation:event_id ~correlation:event_id
               bytes
           with
          | Error e -> Error e
          | Ok legs ->
            Batch_commit.propose handle ~idempotency_key ~materialize:wrapped_sink legs;
            Ok ())
      in
      Reactor.subscribe reactor ~merge_key:Schema.requests_merge_key ~module_:(verified_ledger ())
        ~protocol:allow_handle_from_init ~read:read_for_module ~propose:propose_for_module;
      f { handle; replica; materializer; wrapped_sink })

(* This task's own documented test-setup convention (per task-3-brief.md step 6 and the design
   spec's own non-goals: no "mint"/account-opening flow exists in this focused-core scope) --
   seeding a starting balance proposes a transfer_leg-shaped write DIRECTLY to the account's own
   merge_key, bypassing the request/module flow entirely. other_account = 0L is simply an
   unused/placeholder counterparty for this synthetic, test-only leg -- never itself seeded or
   asserted on. *)
let seed_account env account amount =
  let idempotency_key = Printf.sprintf "seed-%Ld" account in
  let event_id = fake_event_id idempotency_key in
  let leg =
    Schema.{ transfer_id = 0L; role = Credit; this_account = account; other_account = 0L; amount }
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

let tests =
  [
    ( "a request with sufficient funds commits both legs and updates both balances",
      `Quick, test_a_request_with_sufficient_funds_commits_both_legs_and_updates_both_balances );
    ("insufficient funds is a clean no-op", `Quick, test_insufficient_funds_is_a_clean_no_op);
    ( "the same request_id proposed twice does not double-apply",
      `Quick, test_the_same_request_id_proposed_twice_does_not_double_apply );
  ]
