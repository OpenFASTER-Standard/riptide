(* Task 6 (task-master), subtask 6.4 -- task-3-brief.md of the layer2-ledger-module plan: the
   real end-to-end proof that Tasks 1-2's own ledger schema/wire/legs/authorize code (Schema,
   Wire, Legs, Authorize -- already shipped, see lib/ledger/) composes against the real Layer 2
   boundary (Admission/Loader/Protocol/Reactor/Batch_commit) exactly the way
   test_module_end_to_end.ml already proved counter.wat does -- with a real domain, real policy on
   BOTH of Batch_commit's authorization axes (Authorize.authorize AND Authorize.authorize_batch, not
   Batch_commit.allow_all: the first task in this whole plan to use the real policy end to end), and
   a real admission-verified guest (fixtures/ledger.wat) deciding real business logic (sufficient
   funds) instead of an arbitrary counter increment.

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
   (real solo replica, real Batch_commit.t with ~authorize:Authorize.authorize AND
   ~authorize_batch:Authorize.authorize_batch -- the first use of the real policy end to end in this
   whole plan, on both hooks; final whole-branch review, Minor: this header enumerated only
   ~authorize while the body has wired both since Task 7 -- real Materializer, real
   admission-verified ledger.wat, Reactor.subscribe), plus four small closures naming this test's own
   choice of lattice (Last_write_wins) and KV backend (File_kv_store). *)
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
         called. Note what an [Accumulator.t] is now: two observability counters and nothing else --
         no decision table, no applied-legs table (both deleted; see accumulator.mli). *)
  committed : idempotency_key:string -> Batch_commit.write list option;
      (* The committed-log query the ledger's host half asks "has this request already been decided,
         and how?" -- wired straight to Batch_commit.committed_writes_for against this env's own
         replica, exactly as accumulator.mli prescribes. Exposed so a test can ask the same question
         the production path asks, against the same durable source of truth. *)
  dispatch : Accumulator.t -> bytes -> (unit, string) result;
      (* The real host side of the guest's propose_write, parameterised by WHICH Accumulator.t it
         runs against -- the reactor's own ~propose closure is literally [dispatch] applied to the
         live instance. Exposed so a test can feed a decision in directly (the guest itself is a
         .wat fixture that decides on its own business logic, so "what if a dispatch decides
         ACCEPT for an already-declined request" is not otherwise expressible), and, crucially, so
         it can do that against a FRESH instance -- which is what a process restart leaves behind. *)
  restart : unit -> Accumulator.t;
      (* Simulate a process restart over the SAME durable state: a brand-new Accumulator.t, while
         the replica's log, the Materializer's KV directory, the WATERMARK STORE and the module
         subscription all survive untouched -- which is exactly what survives a real restart and
         what does not. The returned instance becomes the live one: the reactor's own ~propose
         closure follows the swap, so a guest dispatched after a restart runs against the restarted
         instance, not the retired one.

         Note what this no longer has to swap, and why that is the whole point of this task: the
         materialize_sink. A sink used to be built over an Accumulator.t, because it kept that
         instance's own applied-legs table; it now holds no state at all, so one sink spans the
         restart exactly as the durable watermark behind it does.

         Re-using the SAME Reactor.t (rather than re-subscribing a fresh one) is faithful rather
         than a shortcut: Reactor.subscribe reads the module's bytes once and instantiates a fresh
         Loader.t/Protocol.checker per dispatch, so the guest holds no state across dispatches for
         a restart to lose. *)
}

let with_ledger_env (f : env_handles -> unit) =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun root_dir ->
      Eio.Switch.run @@ fun sw ->
      (* Two SEPARATE File_kv_store directories, never one shared: File_kv_store.create's own
         ~owner marker (and its Dir_lock) exist precisely to refuse two unrelated consumers
         pointing at one directory, which that module documents as a confirmed real
         data-destruction bug. The materializer's accumulator and the materialization watermark are
         exactly two such unrelated consumers. *)
      let kv_dir = Filename.concat root_dir "materializer" in
      let watermark_dir = Filename.concat root_dir "watermark" in
      let replica = create_solo_volatile () in
      let watermark_store =
        File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"ledger-materialize-watermark"
          watermark_dir
      in
      (* The real policy, end to end, now on BOTH axes Batch_commit offers: ~authorize for what a
         single write can self-certify, and ~authorize_batch for the cross-write invariant that is
         the whole substance of double-entry bookkeeping (two legs, one transfer, equal and
         opposite). Before Task 7's boundary revision, only the first existed and the second had to
         be a construction-time convention in Legs; it is now a checkpoint no write can bypass. *)
      let handle =
        Batch_commit.create ~replica ~authorize:Authorize.authorize
          ~authorize_batch:Authorize.authorize_batch ()
      in
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
      let committed ~idempotency_key = Batch_commit.committed_writes_for replica ~idempotency_key in
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
      (* ONE sink, for the whole env's lifetime, restart included. Accumulator.materialize_sink no
         longer takes an Accumulator.t at all: with the applied-legs table deleted it holds no state
         whatsoever, which is exactly the property that lets the durable watermark below be the
         single source of already-applied truth.

         {b The nesting order here is correctness-critical, not stylistic} (Task 4's own review,
         Critical 1 -- live-reproduced on two DST seeds). [Batch_commit.deduplicate] wraps ONLY the
         accumulator sink, and [Reactor.wrap_materialize_sink] sits strictly OUTSIDE it:

         - the ledger's own non-idempotent read-add-write balance bookkeeping is gated, so a replay
           of an already-materialized committed leg does not move money twice (the restart doubling
           this plan's Task 1 exists to close), and
         - the reactor's guest DISPATCH, which lives inside its own [write], runs unconditionally on
           every materialize call -- because re-dispatching an already-materialized
           "ledger.requests" write is the one and only recovery path for a legs batch a VSR view
           change discarded before it committed (Accumulator.handle_guest_decision's own
           already-accepted/never-decided branches).

         Getting it backwards -- which is what a gate applied INTERNALLY by
         [Batch_commit.propose] to the whole composed sink necessarily did, i.e. this plan's own
         Task 1 shape -- silently deleted that recovery path entirely while still looking correct on
         every balance assertion. See batch_commit.mli's [deduplicate] and
         [test_batch_commit_materialize.ml]'s own
         [test_deduplicate_only_suppresses_what_it_wraps_not_an_outer_wrappers_side_effect]. *)
      let wrapped_sink =
        Reactor.wrap_materialize_sink reactor
          (Batch_commit.deduplicate ~watermark_store
             (Accumulator.materialize_sink ~read_balance ~write_balance ~store_request))
      in
      (* The currently-live accumulator, held in a ref so [restart] can swap it and the ~propose
         closure below follows the swap rather than capturing the retired instance. *)
      let live = ref accumulator in
      let read_for_module = Accumulator.read_for_guest ~read_request ~read_balance in
      (* host.propose_write's own half, now a single library call: the guest hands back 33 bytes (a
         decision tag plus the request), and Accumulator.handle_guest_decision is what decides --
         once and for all, per request_id, against the COMMITTED LOG rather than any in-memory table
         -- whether that becomes a committed decision plus a pair of committed legs.

         [Batch_commit.is_primary] is checked HERE, immediately before the one Batch_commit.propose
         call this closure can reach, and never cached (design spec Decision 5): a non-primary (or
         non-Normal) replica makes Replica.propose a silent no-op, so without this check a guest's
         decision -- accept or decline -- would be swallowed with no trace and no way for the guest
         or this test to tell that from success. Checking it before handle_guest_decision rather than
         inside the ~propose closure is deliberate: the decline path proposes too (a decline is now a
         durable record, not an absence), so there is no dispatch outcome that is exempt. The
         residual non-atomicity between the check and the call is disclosed by is_primary's own doc
         comment and is not something this closure can close. *)
      let dispatch acc (bytes : bytes) : (unit, string) result =
        if not (Batch_commit.is_primary handle) then Error "not primary, retry"
        else
          Accumulator.handle_guest_decision acc ~actor:"ledger-module" ~committed
            ~propose:(fun ~idempotency_key writes ->
              Batch_commit.propose handle ~idempotency_key ~materialize:wrapped_sink writes)
            bytes
      in
      let propose_for_module (bytes : bytes) : (unit, string) result = dispatch !live bytes in
      let restart () =
        let acc = Accumulator.create () in
        live := acc;
        acc
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
          f
            {
              handle;
              replica;
              materializer;
              wrapped_sink;
              accumulator;
              committed;
              dispatch;
              restart;
            }))

(* The account the test harness's own seeding convention moves value OUT of, so that seeding is
   itself a BALANCED, double-entry transfer rather than value appearing from nowhere. Never seeded,
   never asserted on, and never used as either side of a real request below -- it is this file's
   stand-in for the "mint"/account-opening flow the design spec's own non-goals keep out of this
   focused-core scope, and it ends every test deeply negative by construction, which is the honest
   accounting consequence of minting. *)
let mint_account = 0L

(* This file's own documented test-setup convention -- seeding a starting balance proposes a
   transfer_leg-shaped write DIRECTLY to the account's own merge_key, bypassing the request/module
   flow entirely.

   {b Why this is now a PAIR of legs rather than one} (Task 7, the Layer 0/Layer 2 boundary
   revision): before [Authorize.authorize_batch] existed, a single, individually well-formed leg
   proposed directly was necessarily ALLOWED, because [Authorize.authorize] sees one write at a time
   and nothing in one leg reveals whether it has a sibling -- a limitation authorize.mli disclosed at
   length and that this convention quietly relied on. [?authorize_batch] closes it at a checkpoint no
   write can bypass: a batch carrying transfer legs must carry exactly TWO, equal and opposite. So
   seeding now does what double-entry bookkeeping actually requires and debits [mint_account] for
   whatever it credits. That is a strictly better test fixture, not a workaround -- the previous
   convention was a live demonstration of the hole this task closes.

   [?role] defaults to [Credit], i.e. "this account starts with [amount]". [Debit] is the one thing
   this convention can express that no request flow can: driving an account NEGATIVE, which is
   what the signed-funds-check regression test below needs and cannot get any other way (a
   transfer out of an account the guest judges unaffordable is declined, by design).

   The idempotency key includes the role, so Credit- and Debit-seeding the same account are two
   distinct batches rather than the second silently colliding with the first already in the log. *)
let seed_account ?(role = Schema.Credit) env account amount =
  let role_tag = match role with Schema.Debit -> "debit" | Schema.Credit -> "credit" in
  let idempotency_key = Printf.sprintf "seed-%s-%Ld" role_tag account in
  let event_id = fake_event_id idempotency_key in
  let opposite = match role with Schema.Debit -> Schema.Credit | Schema.Credit -> Schema.Debit in
  let leg_at ~this_account ~other_account role : Schema.transfer_leg =
    { transfer_id = 0L; role; actor = "test-seed"; this_account; other_account; amount }
  in
  let write_of_leg (leg : Schema.transfer_leg) : Batch_commit.write =
    {
      Batch_commit.actor = "test-seed";
      causation = event_id;
      correlation = event_id;
      payload = Schema.transfer_leg_to_value leg;
      merge_key = Some (Schema.account_merge_key leg.this_account);
    }
  in
  Batch_commit.propose env.handle ~idempotency_key ~materialize:env.wrapped_sink
    [
      write_of_leg (leg_at ~this_account:account ~other_account:mint_account role);
      write_of_leg (leg_at ~this_account:mint_account ~other_account:account opposite);
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
   "client") -- so this is exactly "the legs the WASM guest itself caused to be committed".

   {b Why the payload is decoded rather than the actor alone being trusted} (Task 7, the Layer 0/
   Layer 2 boundary revision): the module's own batch now carries a THIRD write besides its two
   legs -- the durable decision record that makes a DECLINE survive a restart (see accumulator.mli).
   It is authored by the same actor, because the same code genuinely authors it, so "every
   ledger-module envelope is a leg" stopped being true. Filtering on "decodes as a transfer_leg"
   keeps this function meaning exactly what its name says, and is strictly more precise than the
   actor check it replaces rather than a workaround for one. *)
let module_leg_envelopes env =
  Batch_commit.committed_envelopes env.replica
  |> List.filter (fun (e : Envelope.envelope) ->
         e.actor = "ledger-module" && Schema.transfer_leg_of_value e.payload <> None)

(* The other half of the same partition: the module's own committed DECISION records, each decoded
   back into the (accepted, request) pair it durably attests to. Nothing else in this file ever
   proposes a decision-shaped payload. *)
let module_decision_envelopes env =
  Batch_commit.committed_envelopes env.replica
  |> List.filter_map (fun (e : Envelope.envelope) ->
         if e.actor <> "ledger-module" then None else Wire.decision_of_value e.payload)

(* A catch-up materialization walk over the whole committed log -- the shape a restarting node is
   documented to perform, and the shape every call in this file uses. The durable watermark is not
   optional for this ledger: its sink accumulates balances by read-add-write, which is not idempotent
   under replay, and the already-applied table that used to guard that in memory is deleted (that
   table dying with the process is exactly what used to double every balance here).

   It arrives here through [env.wrapped_sink] itself rather than as a [~watermark_store] argument to
   this function (Task 4's own review, Critical 1): the gate is composed around the accumulator sink
   at [with_ledger_env]'s own [wrapped_sink] -- INSIDE Reactor.wrap_materialize_sink, see that
   comment -- so this walk gets exactly-once balance bookkeeping AND an unconditional guest
   re-dispatch for every "ledger.requests" write it replays, which is what makes a catch-up walk a
   real recovery path for a view-change-discarded legs batch rather than a silent no-op. *)
let walk env =
  Batch_commit.materialize_up_to env.replica ~materialize:env.wrapped_sink
    ~through_commit_number:(Replica.commit_number env.replica)

(* Feed a decision in as if the guest had just produced it, against a chosen Accumulator.t. The
   guest fixture decides on its own business logic (sufficient funds), so this is the only way to
   express "a dispatch decided ACCEPT for a request that is already on record as DECLINED" -- the
   exact shape of finding C1 -- independently of whether some re-materialization idiom happens to
   re-reach the guest. *)
let dispatch_decision env acc ~accepted (r : Schema.transfer_request) =
  env.dispatch acc (Wire.encode_decision ~accepted r)

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
      (* The empty-writes drain idiom, verbatim from batch_commit.mli's own documented contract: a
         pure "is it committed now? if so, materialize it" probe against an already-committed key.
         Nothing here proposes any new content whatsoever. *)
      let flips_before_drain = Accumulator.prevented_flips env.accumulator in
      Batch_commit.propose env.handle ~idempotency_key:"req-10" ~materialize:env.wrapped_sink [];
      (* Positive evidence that the mechanism FIRED, not just that the outcome looks right: without
         this, the test would pass equally well if the guest had simply declined a second time for
         its own reasons, which would prove nothing about C1 at all.

         This evidence comes out of the DRAIN ITSELF, which is the whole point: the drain
         re-dispatches the guest, the guest re-reads the now-ample balance and genuinely decides
         ACCEPT, and the first-decision-wins rule overrides it. That is finding C1's exact shape,
         through the exact idiom the reviewer used, with nothing injected.

         {b Briefly, between this plan's Task 1 and Task 4's own review, this assertion could not be
         made and was replaced by an injected dispatch} (Critical 1): the watermark gate sat OUTSIDE
         [Reactor.wrap_materialize_sink], so the drain skipped the already-watermarked request write
         entirely and never reached the guest at all -- a delta of 0 here, and, far worse, no recovery
         path left for a view-change-discarded batch. The gate now wraps only the accumulator sink, so
         re-dispatch is back and so is this assertion. A route that silently stops reaching the guest
         fails here rather than passing quietly. *)
      Alcotest.(check int)
        "the drain re-dispatched the guest, it decided ACCEPT against the now-ample balance, and the \
         first-decision-wins rule overrode it (Task 4 review, Critical 1)"
        1
        (Accumulator.prevented_flips env.accumulator - flips_before_drain);
      (* The same rule once more, head-on and independent of any idiom: a decision deciding ACCEPT is
         fed in directly, so this assertion holds even if every re-materialization route were to
         change. *)
      let flips_before = Accumulator.prevented_flips env.accumulator in
      Alcotest.(check bool) "the injected ACCEPT dispatch was accepted as a well-formed decision"
        true
        (dispatch_decision env env.accumulator ~accepted:true declined = Ok ());
      Alcotest.(check int)
        "the injected dispatch genuinely decided ACCEPT, and was overridden too" 1
        (Accumulator.prevented_flips env.accumulator - flips_before);
      Alcotest.(check bool) "and the DURABLE record still says DECLINED" true
        (Accumulator.decision ~committed:env.committed ~request_id:10L = Some false);
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
      (* Each idiom is proven to GENUINELY REACH THE GUEST (a nonzero [repeat_dispatches] delta out of
         the idiom itself, plus a prevented flip -- the guest really does re-decide ACCEPT against the
         now-ample balance and really is overridden), and then -- separately -- a dispatch deciding
         ACCEPT is injected directly too, so the rule is also pinned independently of which idiom
         happens to reach the guest.

         {b Between this plan's Task 1 and Task 4's own review, the per-idiom half of that was
         impossible and had been removed} (Critical 1): the durable watermark was applied by
         [Batch_commit] itself to the WHOLE composed sink, so it suppressed
         [Reactor.wrap_materialize_sink]'s guest dispatch along with the balance bookkeeping, and
         none of these three idioms re-dispatched at all. The watermark now wraps only the accumulator
         sink (see [with_ledger_env]), so each idiom re-dispatches exactly as it did before Task 1 --
         while STILL not re-applying a single balance delta, which the untouched-balance assertions
         below are what prove. That is the whole shape of this plan's own goal: exactly-once
         materialization, unconditional re-dispatch. *)
      let check_idiom name run =
        let dispatches_before = Accumulator.repeat_dispatches env.accumulator in
        let flips_before_idiom = Accumulator.prevented_flips env.accumulator in
        run ();
        Alcotest.(check bool)
          (Printf.sprintf
             "%s: genuinely re-dispatched the guest -- not silently suppressed by the watermark (Task \
              4 review, Critical 1)"
             name)
          true
          (Accumulator.repeat_dispatches env.accumulator > dispatches_before);
        Alcotest.(check bool)
          (Printf.sprintf
             "%s: and the re-dispatched guest's ACCEPT was overridden by the committed DECLINE" name)
          true
          (Accumulator.prevented_flips env.accumulator > flips_before_idiom);
        Alcotest.(check int)
          (Printf.sprintf "%s: still no leg for the declined request" name)
          legs_after_funding
          (List.length (module_leg_envelopes env));
        Alcotest.(check bool)
          (Printf.sprintf "%s: the recorded decision is still DECLINED" name)
          true
          (Accumulator.decision ~committed:env.committed ~request_id:30L = Some false);
        Alcotest.(check int64)
          (Printf.sprintf "%s: the sender's balance is untouched" name)
          5040L (balance_of env 720L);
        Alcotest.(check int64)
          (Printf.sprintf "%s: the would-be recipient still has nothing" name)
          0L (balance_of env 820L);
        (* The rule itself, head-on, after this idiom has run: a dispatch decides ACCEPT and is
           overridden by the decision already on the log. *)
        let flips_before = Accumulator.prevented_flips env.accumulator in
        ignore (dispatch_decision env env.accumulator ~accepted:true declined);
        Alcotest.(check int)
          (Printf.sprintf "%s: an ACCEPT dispatch after it was genuinely overridden" name)
          1
          (Accumulator.prevented_flips env.accumulator - flips_before);
        Alcotest.(check int)
          (Printf.sprintf "%s: and still produced no leg" name)
          legs_after_funding
          (List.length (module_leg_envelopes env))
      in
      check_idiom "empty-writes drain" (fun () ->
          Batch_commit.propose env.handle ~idempotency_key:"req-30" ~materialize:env.wrapped_sink []);
      check_idiom "full re-propose under the same idempotency_key" (fun () ->
          propose_request env ~idempotency_key:"req-30" declined);
      check_idiom "materialize_up_to over the whole log" (fun () -> walk env);
      (* ── The restart half (Task 7, the Layer 0/Layer 2 boundary revision) ───────────────────────
         A FRESH Accumulator.t, which is all a process restart actually resets, must reach the SAME
         answer about request 30 -- and it does, because it is not consulting any table of its own
         any more. There is no table: it asks Batch_commit.committed_writes_for against the durable,
         replicated log, which a restart cannot lose. This is the half that was impossible before
         this task, and the reason the balance-doubling pin test that used to live in this file is
         gone rather than merely renamed. *)
      let restarted = env.restart () in
      Alcotest.(check bool)
        "a FRESH instance, with no history of its own, still sees request 30 as DECLINED" true
        (Accumulator.decision ~committed:env.committed ~request_id:30L = Some false);
      Alcotest.(check int) "and it genuinely has no history: no dispatch has reached it yet" 0
        (Accumulator.repeat_dispatches restarted);
      ignore (dispatch_decision env restarted ~accepted:true declined);
      Alcotest.(check int)
        "the fresh instance treated the ACCEPT as a REPEAT of an already-decided request, not a \
         first decision"
        1
        (Accumulator.repeat_dispatches restarted);
      Alcotest.(check int) "and overrode it, exactly as the pre-restart instance did" 1
        (Accumulator.prevented_flips restarted);
      Alcotest.(check int) "so no leg was committed for request 30 across the restart either"
        legs_after_funding
        (List.length (module_leg_envelopes env));
      Alcotest.(check int64) "and no balance moved" 5040L (balance_of env 720L);
      (* The other direction, stated explicitly rather than left implied by the leg count: the rule
         is "the first decision is final", not "declines are sticky". A transfer that legitimately
         happened must not be retroactively withdrawn by a catch-up walk any more than a declined one
         may be resurrected by it -- so a dispatch deciding DECLINE for the already-accepted request
         31 is overridden too, including from the fresh post-restart instance. *)
      Alcotest.(check bool) "the accepted request's decision also stood, unchanged, across all of it"
        true
        (Accumulator.decision ~committed:env.committed ~request_id:31L = Some true);
      let flips_before = Accumulator.prevented_flips restarted in
      ignore
        (dispatch_decision env restarted ~accepted:false
           Schema.{ request_id = 31L; from_account = 721L; to_account = 720L; amount = 5000L });
      Alcotest.(check int) "a DECLINE dispatch for the accepted request was overridden too" 1
        (Accumulator.prevented_flips restarted - flips_before);
      Alcotest.(check int64) "and its recipient kept every unit it was credited" 5040L
        (balance_of env 720L))

(* ── Value conservation for request_id = 0L, the identifier a historical dedup-key bug singled out ─
   {b Renamed and reframed by Task 4's own review (Minor).} This test and its comment were written
   around a mechanism the codebase no longer has: the accumulator's own in-memory dedup key
   [(transfer_id, this_account, role)]. Final whole-branch review finding I4 live-reproduced a real
   collision in it -- this file's seeding convention builds its synthetic leg with [transfer_id = 0L],
   so a REAL transfer carrying [request_id = 0L] (a perfectly ordinary client-chosen identifier, not a
   reserved value) shared a key with the seed leg of whichever account it credited, and had its credit
   silently skipped as a duplicate: the committed log stayed perfectly correct while the materialized
   balances stopped conserving value, money destroyed with nothing raised.

   That key is GONE. Task 7 deleted the accumulator's dedup table outright and dedup is now
   [Batch_commit.deduplicate]'s durable, per-[(idempotency_key, position)] watermark -- an identity
   that is injective by construction ([Batch_commit.redaction_event_id]'s length-prefixing) and shares
   nothing with a leg's payload content, so a seed leg and a client transfer cannot collide in it
   whatever [transfer_id]s they carry. Describing this test as guarding "the accumulator's dedup key"
   therefore describes nothing real.

   {b What it still genuinely tests, and why it is kept rather than deleted}: end-to-end VALUE
   CONSERVATION for [request_id = 0L] specifically -- both legs committed, both applied exactly once,
   total value across the two accounts unchanged. The mechanism changed; the property a reader cares
   about did not, and [request_id = 0L] remains the input that historically broke it, which is reason
   enough to keep exercising it rather than trusting that a new mechanism cannot fail on the same
   input for a new reason. (The injectivity of the replacement key is tested directly, at the unit
   level, by [test_batch_commit_materialize.ml]'s own
   [test_watermark_key_is_injective_where_a_naive_concatenation_collides] and
   [test_watermark_does_not_collide_on_a_naive_concatenation_collision] -- which use inputs that
   genuinely collide under a separator-free concatenation, and assert that they do before asserting
   the real derivation separates them. This citation used to point at
   [test_watermark_does_not_collide_across_different_idempotency_keys_same_position], which was then
   the only such test and could not fail for the reason it claimed; final whole-branch review,
   IMP-5. That test still exists as the weaker baseline it actually is.) *)
let test_value_is_conserved_for_a_request_id_of_zero () =
  with_ledger_env (fun env ->
      seed_account env 910L 500L;
      seed_account env 911L 300L;
      propose_request env ~idempotency_key:"req-0"
        Schema.{ request_id = 0L; from_account = 910L; to_account = 911L; amount = 100L };
      Alcotest.(check int) "both legs of the transfer committed" 2
        (List.length (module_leg_envelopes env));
      Alcotest.(check int64) "the debit landed" 400L (balance_of env 910L);
      Alcotest.(check int64)
        "the credit landed too -- applied exactly once, neither swallowed nor doubled" 400L
        (balance_of env 911L);
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
   unaffordable is exactly what gets declined. That is a direct, balanced pair of legs going through
   the real Authorize.authorize AND the real Authorize.authorize_batch -- not a hand-poked balance,
   and (since Task 7) not a single unpaired leg relying on a disclosed gap in the checkpoint either. *)
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
        (Accumulator.decision ~committed:env.committed ~request_id:40L = Some false);
      Alcotest.(check int) "no leg was committed for it" 0
        (List.length (module_leg_envelopes env));
      Alcotest.(check int64) "the overdrawn account was not driven deeper into the red" (-200L)
        (balance_of env 950L);
      Alcotest.(check int64) "and the would-be recipient received nothing" 0L (balance_of env 951L))

(* ── Task 7 (task-master), the Layer 0/Layer 2 boundary revision: THE PIN IS GONE, AND THIS IS WHAT
   REPLACED IT ───────────────────────────────────────────────────────────────────────────────────
   This test occupies the exact slot [test_restart_without_durable_dedup_state_doubles_balances]
   used to: same setup, same restart, same catch-up walk. The only difference is what it asserts.
   That test deliberately pinned a live-reproduced, money-destroying bug as accepted behaviour --
   a restart followed by nothing more exotic than the documented [materialize_up_to] catch-up walk
   re-applied EVERY leg in the log to balances that already contained them, so 1500 units across two
   accounts became 3000 out of nothing, silently, with the committed log staying perfectly correct
   throughout. Its own comment said that if a future change made the walk idempotent across a
   restart, the right response was to rewrite it into the positive assertion. This is that rewrite.

   What actually closed it, and why both halves are needed:
     - [Accumulator]'s own in-memory [applied_legs] table is DELETED. Nothing about "already
       applied" lives in a process's memory any more.
     - Batch_commit now offers a DURABLE, per-(idempotency_key, position) materialization watermark
       (Task 7's Decision 1), keyed on the write identity Decision 2 added, which this env composes
       around the accumulator sink via [Batch_commit.deduplicate] (see [with_ledger_env]). It
       survives the restart on the same disk the keystore already trusts for exactly this kind of
       durability.
     - [Accumulator]'s own in-memory [decided_requests] table is deleted too, which this test also
       exercises: the restarted instance's decision for request 50 comes from the committed log.

   The structure deliberately mirrors the test it replaces, so the contrast is readable:
     1. BEFORE the restart, in-process: the walk changes no balance.
     2. AFTER the restart, from a fresh Accumulator.t: the SAME walk changes no balance either.
   Before this task, step 2 doubled everything. The log itself is asserted unchanged throughout, as
   it was before -- "the log is fine" was never sufficient evidence here, and still isn't. *)
let test_restart_with_durable_watermark_leaves_balances_correct () =
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
      let committed_before = List.length (Batch_commit.committed_envelopes env.replica) in
      (* 1. The same walk, in the same process. *)
      walk env;
      Alcotest.(check int64) "in-process: the sender's balance is unchanged by the walk" 700L
        (balance_of env 960L);
      Alcotest.(check int64) "in-process: the recipient's balance is unchanged by the walk" 800L
        (balance_of env 961L);
      (* 2. THE SIMULATED RESTART. Same durable materializer, same durable watermark store, same
            log, same subscription; a fresh Accumulator.t, which is all a restart actually resets --
            and which, now that neither table exists, carries nothing a restart could lose. *)
      let restarted = env.restart () in
      Alcotest.(check bool)
        "the restarted instance still sees request 50 as ACCEPTED -- the decision lives in the \
         committed log, not in any instance's memory"
        true
        (Accumulator.decision ~committed:env.committed ~request_id:50L = Some true);
      walk env;
      Alcotest.(check int64)
        "AFTER THE RESTART: the sender's balance did NOT double (this asserted 1400 before Task 7)"
        700L (balance_of env 960L);
      Alcotest.(check int64)
        "AFTER THE RESTART: the recipient's balance did NOT double (this asserted 1600 before Task \
         7)"
        800L (balance_of env 961L);
      Alcotest.(check int64)
        "AFTER THE RESTART: still exactly 1500 units across the two accounts, not 3000" 1500L
        (Int64.add (balance_of env 960L) (balance_of env 961L));
      (* Positive evidence that the restart genuinely happened and the fresh instance is genuinely
         the one in play -- without this, every assertion above would pass equally well if [restart]
         had quietly done nothing.

         {b This assertion was `0' until Task 4's own review, Critical 1, and the change from 0 to 1
         IS that Critical's fix, observed from the inside.} With the watermark gate placed OUTSIDE
         [Reactor.wrap_materialize_sink] -- which is what a gate applied internally by
         [Batch_commit.propose]/[materialize_up_to] to the whole composed sink necessarily did -- the
         catch-up walk above skipped the already-watermarked "ledger.requests" write ENTIRELY, so the
         reactor never dispatched, so the fresh instance genuinely had no dispatch history: 0 was a
         true reading of a broken mechanism. The gate now wraps only the accumulator sink, so the
         walk re-dispatches the guest for every request it replays (while still not re-applying a
         single balance delta -- the four assertions above), and the fresh instance recognises
         request 50 as already decided from the COMMITTED LOG alone, having never seen it decided
         itself. That re-dispatch is not incidental: it is the one and only recovery path a legs
         batch a view change discarded before it committed has. *)
      Alcotest.(check int)
        "the catch-up walk re-dispatched the guest to the FRESH instance -- the recovery path the \
         watermark must not suppress (Task 4 review, Critical 1)"
        1
        (Accumulator.repeat_dispatches restarted);
      Alcotest.(check int)
        "and that re-dispatch agreed with the log's ACCEPT, so nothing was overridden by it" 0
        (Accumulator.prevented_flips restarted);
      ignore
        (dispatch_decision env restarted ~accepted:false
           Schema.{ request_id = 50L; from_account = 960L; to_account = 961L; amount = 300L });
      Alcotest.(check int) "an injected DECLINE for request 50 is recognised as a repeat too" 2
        (Accumulator.repeat_dispatches restarted);
      Alcotest.(check int) "and overridden, because the log's ACCEPT is final" 1
        (Accumulator.prevented_flips restarted);
      Alcotest.(check int64) "so the balances still did not move" 700L (balance_of env 960L);
      Alcotest.(check int64) "on either side" 800L (balance_of env 961L);
      (* The log was correct before this task too -- that is exactly what made the old bug silent --
         so asserting it stays correct is still necessary, just no longer the only thing that is. *)
      Alcotest.(check int)
        "the committed log is untouched by all of this -- nothing appended, nothing lost"
        committed_before
        (List.length (Batch_commit.committed_envelopes env.replica));
      Alcotest.(check int) "still exactly the transfer's own two module-authored legs" 2
        (List.length (module_leg_envelopes env));
      Alcotest.(check int) "and exactly one module-authored decision record, for request 50" 1
        (List.length (module_decision_envelopes env)))

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
    ( "value is conserved for a request_id of zero (the input a historical dedup-key collision broke)",
      `Quick, test_value_is_conserved_for_a_request_id_of_zero );
    ( "an overdrawn account cannot withdraw further because the funds check is signed",
      `Quick, test_an_overdrawn_account_cannot_withdraw_further_because_the_funds_check_is_signed );
    ( "a restart with a durable watermark leaves balances correct",
      `Quick, test_restart_with_durable_watermark_leaves_balances_correct );
  ]
