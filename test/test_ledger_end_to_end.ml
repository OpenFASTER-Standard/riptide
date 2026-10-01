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
  (* Everything from here to the [(verified, dir)] below can raise -- a missing/unreadable fixture,
     a cosign failure, a verification failure -- and until it returns, no caller is holding [dir] to
     clean up. Fix-wave round 2: round 1's fix made the SUCCESS path remove this directory (the
     caller does, once subscribe has read the module's bytes), but a setup failure still orphaned
     it; confirmed live, running this binary from a cwd where "fixtures/ledger.wat" does not resolve
     left one /tmp/ledger_e2e_test* dir behind per test. On the success path this re-raises nothing
     and removes nothing -- ownership passes to the caller exactly as before. *)
  let sign_and_verify () =
    let artifact = Filename.concat dir (Filename.basename fixture_relpath) in
    write_file artifact (read_file fixture_relpath);
    let key = sign_with_fresh_keypair ~dir artifact in
    match
      Admission.verify ~cosign_path ~key ~digest:(sha256_hex artifact) ~tier ~artifact_path:artifact
    with
    | Ok verified -> verified
    | Error e -> Alcotest.failf "test setup: Admission.verify failed: %s" e
  in
  match sign_and_verify () with
  | verified -> (verified, dir)
  | exception e ->
    ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)));
    raise e

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
      (* The accumulator this env STARTED with. Still the live one unless [restart] below has been
         called, which only one test does. *)
  restart : unit -> Accumulator.t * Batch_commit.materialize_sink;
      (* Simulate a process restart over the SAME durable state: a brand-new Accumulator.t (empty
         decision table, empty applied-legs table) and a fresh materialize_sink over it, while the
         replica's log, the Materializer's KV directory and the module subscription all survive
         untouched -- which is exactly what survives a real restart and what does not (see
         accumulator.mli's own disclosure on Accumulator.t). The returned pair becomes the live
         one: the reactor's own ~propose closure follows the swap, so a guest dispatched after a
         restart decides against the restarted instance, not the retired one.

         Re-using the SAME Reactor.t (rather than re-subscribing a fresh one) is faithful rather
         than a shortcut: Reactor.subscribe reads the module's bytes once and instantiates a fresh
         Loader.t/Protocol.checker per dispatch, so the guest holds no state across dispatches for
         a restart to lose. What a restart loses is precisely the host-side tables, which is what
         this swaps. *)
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
      let reactor = Reactor.create () in
      let sink_over acc =
        Reactor.wrap_materialize_sink reactor
          (Accumulator.materialize_sink acc ~read_balance ~write_balance ~store_request)
      in
      let wrapped_sink = sink_over accumulator in
      (* The currently-live (accumulator, sink) pair, held in one ref so [restart] can swap BOTH
         at once and the ~propose closure below follows the swap rather than capturing the retired
         instance. Every test but the restart-doubling pin leaves this at its initial value. *)
      let live = ref (accumulator, wrapped_sink) in
      let read_for_module = Accumulator.read_for_guest ~read_request ~read_balance in
      (* host.propose_write's own half, now a single library call: the guest hands back 33 bytes (a
         decision tag plus the request), and Accumulator.handle_guest_decision is what decides --
         once and for all, per request_id -- whether that becomes a pair of committed legs. *)
      let propose_for_module (bytes : bytes) : (unit, string) result =
        let acc, sink = !live in
        Accumulator.handle_guest_decision acc ~actor:"ledger-module"
          ~propose:(fun ~idempotency_key writes ->
            Batch_commit.propose handle ~idempotency_key ~materialize:sink writes)
          bytes
      in
      let restart () =
        let acc = Accumulator.create () in
        let sink = sink_over acc in
        live := (acc, sink);
        (acc, sink)
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
          f { handle; replica; materializer; wrapped_sink; accumulator; restart }))

(* This task's own documented test-setup convention (per task-3-brief.md step 6 and the design
   spec's own non-goals: no "mint"/account-opening flow exists in this focused-core scope) --
   seeding a starting balance proposes a transfer_leg-shaped write DIRECTLY to the account's own
   merge_key, bypassing the request/module flow entirely. other_account = 0L is simply an
   unused/placeholder counterparty for this synthetic, test-only leg -- never itself seeded or
   asserted on.

   [?role] defaults to [Credit], i.e. "this account starts with [amount]". [Debit] is the one thing
   this convention can express that no request flow can: driving an account NEGATIVE, which is
   what the signed-funds-check regression test below needs and cannot get any other way (a
   transfer out of an account the guest judges unaffordable is declined, by design). Both roles go
   through the real Authorize.authorize unchanged -- a well-formed single leg is Allowed whatever
   its role, per authorize.mli's own finding-I6 disclosure.

   The idempotency key includes the role, so Credit- and Debit-seeding the same account are two
   distinct batches rather than the second silently colliding with the first already in the log. *)
let seed_account ?(role = Schema.Credit) env account amount =
  let role_tag = match role with Schema.Debit -> "debit" | Schema.Credit -> "credit" in
  let idempotency_key = Printf.sprintf "seed-%s-%Ld" role_tag account in
  let event_id = fake_event_id idempotency_key in
  let leg =
    Schema.
      {
        transfer_id = 0L;
        role;
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
      (* The message here used to claim "a clean no-op, no propose_write call at all", which stopped
         being true with finding C1's fix and is corrected (fix-wave round 2, re-review finding M3):
         the guest ALWAYS calls propose_write now, on both outcomes. What makes a decline a no-op is
         what the host does with it -- a decision tag of 0 records the decline and constructs no
         legs -- not the guest staying silent, which is precisely the shape that was the bug. *)
      Alcotest.(check int)
        "no leg was committed: propose_write was called, carrying decision tag 0, and the host \
         built no legs from it"
        0
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

(* C1 again, from the other direction: not "the idiom the reviewer happened to use is now handled"
   but "no route to re-materialization can resurrect a declined transfer". The fix would be
   worthless if it were shaped around one caller -- the whole point of the finding is that
   re-materialization arrives through several unrelated, individually-documented paths, each of
   which a caller is entitled to use without knowing a ledger is downstream. All three supported
   ones are exercised here against the same declined request, in sequence, on one cluster:

     1. the empty-writes drain idiom      (batch_commit.mli's documented "is it committed? then
                                           materialize it" probe)
     2. a full re-propose of the original request content, same idempotency_key (the only kind of
                                           retry this fire-and-forget layer permits a client)
     3. Batch_commit.materialize_up_to    (a replay walk from the start of the log, which takes a
                                           bare Replica.t and has no Batch_commit.t -- and
                                           therefore no ~authorize -- in scope at all)

   Each one genuinely re-dispatches the guest against a balance that is now ample, so each one is a
   real attempt at the original bug rather than a no-op dressed up as a test: prevented_flips rises
   by one per idiom, which is asserted, so a route that silently stopped reaching the guest would
   fail here rather than pass quietly. *)
let test_a_declined_decision_survives_every_rematerialization_idiom () =
  with_ledger_env (fun env ->
      seed_account env 720L 40L;
      seed_account env 721L 5000L;
      let declined =
        Schema.{ request_id = 30L; from_account = 720L; to_account = 820L; amount = 900L }
      in
      propose_request env ~idempotency_key:"req-30" declined;
      Alcotest.(check int) "request 30 was declined" 0 (List.length (module_leg_envelopes env));
      (* Lift 720 far past the declined amount, through ordinary accepted traffic. *)
      propose_request env ~idempotency_key:"req-31"
        Schema.{ request_id = 31L; from_account = 721L; to_account = 720L; amount = 5000L };
      Alcotest.(check int64) "the sender is now richly funded" 5040L (balance_of env 720L);
      let legs_after_funding = List.length (module_leg_envelopes env) in
      (* [>= 1] rather than [= 1] because the third idiom legitimately produces more: it replays the
         WHOLE log, so it re-dispatches every request in it, not only the declined one. That extra
         flip is the same rule protecting an ACCEPTED decision in the other direction -- re-dispatched
         against a balance its own transfer has since drained, request 31's guest decides DECLINE,
         and the recorded accept stands. Worth having in the assertion rather than tuned away: the
         rule is "the first decision is final", not "declines are sticky". What pins this down to a
         real re-dispatch is that the delta is nonzero at all -- a route that silently stopped
         reaching the guest would show zero and fail here. *)
      let check_idiom name run =
        let flips_before = Accumulator.prevented_flips env.accumulator in
        run ();
        Alcotest.(check bool)
          (Printf.sprintf "%s: really did re-dispatch the guest, which really did decide \
                           differently, and was overridden" name)
          true
          (Accumulator.prevented_flips env.accumulator - flips_before >= 1);
        Alcotest.(check int)
          (Printf.sprintf "%s: still no leg for the declined request" name)
          legs_after_funding
          (List.length (module_leg_envelopes env));
        Alcotest.(check bool)
          (Printf.sprintf "%s: the recorded decision is still DECLINED" name)
          true
          (Accumulator.decision env.accumulator ~request_id:30L = Some false);
        Alcotest.(check int64)
          (Printf.sprintf "%s: the sender's balance is untouched" name)
          5040L (balance_of env 720L);
        Alcotest.(check int64)
          (Printf.sprintf "%s: the would-be recipient still has nothing" name)
          0L (balance_of env 820L)
      in
      check_idiom "empty-writes drain" (fun () ->
          Batch_commit.propose env.handle ~idempotency_key:"req-30" ~materialize:env.wrapped_sink []);
      check_idiom "full re-propose under the same idempotency_key" (fun () ->
          propose_request env ~idempotency_key:"req-30" declined);
      check_idiom "materialize_up_to over the whole log" (fun () ->
          Batch_commit.materialize_up_to env.replica ~materialize:env.wrapped_sink
            ~through_commit_number:(Replica.commit_number env.replica) ?watermark_store:None);
      (* The other direction, stated explicitly rather than left implied by the leg count: the
         whole-log replay above re-dispatched the ACCEPTED request 31 too, against a balance its own
         transfer had already drained, so that dispatch decided DECLINE. Its recorded accept had to
         stand -- a transfer that legitimately happened must not be retroactively withdrawn by a
         catch-up walk any more than a declined one may be resurrected by it. *)
      Alcotest.(check bool) "the accepted request's decision also stood, unchanged, across the replay"
        true
        (Accumulator.decision env.accumulator ~request_id:31L = Some true);
      Alcotest.(check int64) "and its recipient kept every unit it was credited" 5040L
        (balance_of env 720L))

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

(* ── Fix-wave round 2, re-review finding I1-coverage (Important): the funds check must be SIGNED ──
   Fix round 1 changed ledger.wat's sufficient-funds comparison from [i64.gt_u] to [i64.gt_s]
   (finding I1) and wrote a long comment explaining why -- but nothing anywhere exercised the
   difference. The re-reviewer sabotaged the fix back to [i64.gt_u] and all 629 tests still passed,
   which means the fix was load-bearing only in the comment. This test is what makes it load-bearing
   in the suite; it was confirmed RED against an [i64.gt_u] copy of the fixture before being kept.

   The mechanism, precisely: Wire.encode_balance/decode_balance round-trip a NEGATIVE balance
   faithfully (and are tested doing so), so an overdrawn account's balance really does arrive in the
   guest as a negative i64. Read with [i64.gt_u], -200 compares as 1.8e19 -- richer than any
   conceivable transfer -- so [amount > balance] is false for every amount and the guest approves
   every further withdrawal from an account already in the red, driving it arbitrarily deeper.

   Getting an account negative in the first place needs the seeding convention's [~role:Debit]
   (see seed_account): no request flow can produce this state, because a transfer the guest judges
   unaffordable is exactly what gets declined. That is a direct, individually well-formed leg going
   through the real Authorize.authorize, not a hand-poked balance -- the same white-box technique
   this file's own account seeding already relies on, which authorize.mli documents as Allowed by
   design (finding I6). *)
let test_an_overdrawn_account_cannot_withdraw_further_because_the_funds_check_is_signed () =
  with_ledger_env (fun env ->
      seed_account ~role:Schema.Debit env 950L 200L;
      Alcotest.(check int64)
        "the account is genuinely overdrawn -- a negative balance, round-tripped through the real \
         materializer"
        (-200L) (balance_of env 950L);
      (* 50 is far less than 200, so an UNSIGNED read of -200 (1.8e19) approves this and a SIGNED
         read (50 > -200) declines it. That gap is the entire test. *)
      propose_request env ~idempotency_key:"req-40"
        Schema.{ request_id = 40L; from_account = 950L; to_account = 951L; amount = 50L };
      Alcotest.(check int) "the client's request write was committed, exactly once" 1
        (List.length
           (List.filter
              (fun (e : Envelope.envelope) -> e.actor = "client")
              (Batch_commit.committed_envelopes env.replica)));
      Alcotest.(check bool)
        "the host recorded a DECLINE: the guest's signed comparison refused an overdrawn account"
        true
        (Accumulator.decision env.accumulator ~request_id:40L = Some false);
      Alcotest.(check int) "no leg was committed for it" 0
        (List.length (module_leg_envelopes env));
      Alcotest.(check int64) "the overdrawn account was not driven deeper into the red" (-200L)
        (balance_of env 950L);
      Alcotest.(check int64) "and the would-be recipient received nothing" 0L (balance_of env 951L))

(* ── Fix-wave round 2, item 1: a KNOWN-LIMITATION PIN, deliberately asserting the BAD behaviour ──
   READ THIS BEFORE "FIXING" THIS TEST. It asserts that balances DOUBLE. That is not an oversight
   and the assertion is not backwards: restart durability for this module's host-side tables is
   real, scoped, not-yet-done work (task-master Task 7's boundary revision -- a durable
   committed-log/watermark design, see accumulator.mli's own disclosure on Accumulator.t), and this
   test exists so that the current, accepted-as-known behaviour cannot be changed silently. If a
   future change makes the walk below idempotent across a restart, this test SHOULD fail -- and the
   right response is to rewrite it into the positive assertion along with the disclosures it cites,
   not to delete it or tune the numbers.

   What it pins, and why it is worth pinning rather than merely writing down: the re-reviewer of fix
   round 1 live-reproduced a blast radius strictly larger than anything disclosed anywhere. The
   disclosures all described the DECISION table being volatile ("a declined request might be
   re-decided"). But [applied_legs] -- the guard that stops an already-folded leg being added to a
   balance a second time -- is equally in-memory, and nothing said so. So a restart followed by
   nothing more exotic than the documented [materialize_up_to] catch-up walk re-applies EVERY leg in
   the log to balances that already contain them. Not a declined request resurfacing: every account
   in the ledger silently doubles.

   The contrast is the substance of the test, which is why the same walk runs twice:
     1. BEFORE the restart, in-process: identical walk, identical log, balances unchanged. The
        in-memory guard works exactly as documented, and [repeat_dispatches] rising by one proves
        the walk really did re-dispatch the guest rather than quietly skipping it.
     2. AFTER the restart: same walk, same log, every balance doubled.
   So the doubling is attributable to the lost in-memory state specifically, not to the catch-up
   walk being wrong -- which is also why this is Task 7's to fix rather than a bug in
   materialize_up_to.

   Note what stays CORRECT throughout, and is asserted: the committed log. Exactly four leg
   envelopes exist before and after, the two seeds plus the transfer's pair -- no entry is added,
   duplicated or lost by any of this. Only the materialized balances diverge from it, which is the
   same shape as finding I4 and the reason "the log is fine" is never sufficient evidence here. *)
let test_restart_without_durable_dedup_state_doubles_balances () =
  with_ledger_env (fun env ->
      seed_account env 960L 1000L;
      seed_account env 961L 500L;
      propose_request env ~idempotency_key:"req-50"
        Schema.{ request_id = 50L; from_account = 960L; to_account = 961L; amount = 300L };
      Alcotest.(check int64) "the transfer applied: sender debited once" 700L (balance_of env 960L);
      Alcotest.(check int64) "the transfer applied: recipient credited once" 800L
        (balance_of env 961L);
      Alcotest.(check int64) "1500 units exist across the two accounts" 1500L
        (Int64.add (balance_of env 960L) (balance_of env 961L));
      let committed_legs_before = List.length (Batch_commit.committed_envelopes env.replica) in
      let walk sink =
        Batch_commit.materialize_up_to env.replica ~materialize:sink
          ~through_commit_number:(Replica.commit_number env.replica) ?watermark_store:None
      in
      (* 1. The same walk, in the same process. This is the documented, working case. *)
      let repeats_before = Accumulator.repeat_dispatches env.accumulator in
      let flips_before = Accumulator.prevented_flips env.accumulator in
      walk env.wrapped_sink;
      Alcotest.(check int)
        "in-process: the walk really did re-dispatch the guest for the already-decided request" 1
        (Accumulator.repeat_dispatches env.accumulator - repeats_before);
      Alcotest.(check int)
        "in-process: and it agreed with the recorded accept, so nothing had to be overridden" 0
        (Accumulator.prevented_flips env.accumulator - flips_before);
      Alcotest.(check int64) "in-process: the sender's balance is unchanged by the walk" 700L
        (balance_of env 960L);
      Alcotest.(check int64) "in-process: the recipient's balance is unchanged by the walk" 800L
        (balance_of env 961L);
      (* 2. THE SIMULATED RESTART. Same durable materializer, same log, same subscription; a fresh
            Accumulator.t, which is all a restart actually resets. *)
      let restarted, restarted_sink = env.restart () in
      Alcotest.(check bool)
        "the retired instance still remembers deciding request 50 -- the loss below is the \
         restart's, not a failure to record"
        true
        (Accumulator.decision env.accumulator ~request_id:50L = Some true);
      Alcotest.(check bool)
        "the restarted instance remembers nothing about request 50: the decision table is volatile"
        true
        (Accumulator.decision restarted ~request_id:50L = None);
      walk restarted_sink;
      Alcotest.(check int)
        "the restarted instance decided request 50 afresh, as a FIRST decision -- it had no record \
         to treat the dispatch as a repeat of"
        0
        (Accumulator.repeat_dispatches restarted);
      Alcotest.(check bool) "and that fresh decision was an accept" true
        (Accumulator.decision restarted ~request_id:50L = Some true);
      (* The known limitation itself: applied_legs was volatile too, so every leg in the log was
         folded into a balance that already contained it. *)
      Alcotest.(check int64) "KNOWN LIMITATION: the sender's balance DOUBLED (1000-300 applied twice)"
        1400L (balance_of env 960L);
      Alcotest.(check int64)
        "KNOWN LIMITATION: the recipient's balance DOUBLED (500+300 applied twice)" 1600L
        (balance_of env 961L);
      Alcotest.(check int64) "KNOWN LIMITATION: 1500 units became 3000 out of nothing" 3000L
        (Int64.add (balance_of env 960L) (balance_of env 961L));
      (* The log never went wrong, which is exactly what makes this silent. *)
      Alcotest.(check int)
        "the committed log is untouched by all of this -- nothing appended, nothing lost"
        committed_legs_before
        (List.length (Batch_commit.committed_envelopes env.replica));
      Alcotest.(check int) "still exactly the transfer's own two module-authored legs" 2
        (List.length (module_leg_envelopes env)))

let tests =
  [
    ( "a request with sufficient funds commits both legs and updates both balances",
      `Quick, test_a_request_with_sufficient_funds_commits_both_legs_and_updates_both_balances );
    ("insufficient funds is a clean no-op", `Quick, test_insufficient_funds_is_a_clean_no_op);
    ( "the same request_id proposed twice does not double-apply",
      `Quick, test_the_same_request_id_proposed_twice_does_not_double_apply );
    ( "a declined request cannot be accepted by a later re-materialization",
      `Quick, test_a_declined_request_cannot_be_accepted_by_a_later_re_materialization );
    ( "a declined decision survives every re-materialization idiom",
      `Quick, test_a_declined_decision_survives_every_rematerialization_idiom );
    ( "a request_id of zero does not collide with the seeding convention",
      `Quick, test_a_request_id_of_zero_does_not_collide_with_the_seeding_convention );
    ( "an overdrawn account cannot withdraw further because the funds check is signed",
      `Quick, test_an_overdrawn_account_cannot_withdraw_further_because_the_funds_check_is_signed );
    ( "KNOWN LIMITATION pin: a restart without durable dedup state doubles every balance",
      `Quick, test_restart_without_durable_dedup_state_doubles_balances );
  ]
