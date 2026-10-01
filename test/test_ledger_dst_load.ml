(* Task 6 (task-master), subtask 6.4 -- task-4-brief.md of the layer2-ledger-module plan: the
   real pressure test this whole plan exists for. Tasks 1-3 already proved the ledger's schema,
   wire encoding, leg construction, the authorization checkpoint, and a real admission-verified
   WASM guest (fixtures/ledger.wat) compose correctly end to end against a SOLO (replica_count=1)
   stack (test_ledger_end_to_end.ml). This file drives the SAME real stack through a real
   replica_count=3 Riptide_dst.Cluster, with injected node crashes and network faults, and proves
   the ledger's invariant and liveness properties hold under real adversarial conditions.

   ── Why this needs its own, genuinely different driving loop, not just a bigger solo test ──────
   test_ledger_end_to_end.ml's env wraps a SOLO replica (replica_count = 1, f = 0): every single
   Batch_commit.propose call there commits synchronously (quorum = 1), so one client call to
   propose_request completes the WHOLE chain -- request materializes, the module dispatches,
   reads it back, decides accept/decline, and (if accepted) proposes both legs, which themselves
   also commit and materialize synchronously -- all inside that one OCaml call, no further driving
   needed.

   Against a real replica_count = 3 cluster (quorum = 2), none of that is synchronous any more:
   Replica.propose is fire-and-forget (it appends to the proposer's own log and broadcasts, but
   does not wait for a quorum of Prepare_ok before returning), and Batch_commit.propose's own
   materialize step only fires "if and only if the batch is committed" (batch_commit.mli's own
   documented contract). So a single propose_request call here only gets the request APPENDED,
   uncommitted; nothing materializes, and the module never dispatches, until a later call
   re-checks commit status. batch_commit.mli's own doc comment names the supported idiom for that
   re-check directly: [propose t ~idempotency_key ~materialize:sink []] -- an empty-writes batch,
   which can never itself be proposed (committed_envelopes' own first-wins dedup already owns that
   key, or it does not exist yet, either way this is a pure "is it committed now? if so,
   materialize it" probe) -- safe to call as many times as needed, including before the batch
   exists at all (a pure no-op then) and after it is already materialized (a lattice-join no-op,
   per the same doc comment). [pump] below is exactly that idiom, used to re-drive BOTH the
   request's own commit-to-dispatch step and the (separately committed) legs' own
   commit-to-balance-update step, however many real network/settle rounds each actually needs. *)
open Riptide
open Riptide_ledger
open Riptide_module
open Riptide_batch_commit
open Riptide_vsr
open Riptide_lattice

let () = Mirage_crypto_rng_unix.use_default ()

(* A plain, process-local, in-memory Riptide_storage.Kv_store_intf.S implementer -- this file's
   own test-local stand-in for Riptide_storage.File_kv_store, per this codebase's established
   per-test-file-helpers convention (no shared test-support library exists). Durability/crash
   semantics are irrelevant here: this backs the TEST's own materializer, a plain bookkeeping
   accumulator the test reads directly to check outcomes, never anything Riptide_vsr.Replica
   itself persists or recovers -- the real replicas' own durability is exercised separately, via
   Riptide_storage.Fault_injecting_storage/Memory_storage inside Riptide_dst.Cluster.run itself.
   See [with_ledger_dst_env]'s own top comment for why this file uses this instead of a real
   File_kv_store (and Cluster.run instead of Cluster.run_on_file_storage) at all. *)
module Memory_kv_store = struct
  type t = { owner : string; table : (string, string) Hashtbl.t }

  let create ~owner = { owner; table = Hashtbl.create 256 }
  let owner t = t.owner
  let get t ~key = Hashtbl.find_opt t.table key
  let put t ~key value = Hashtbl.replace t.table key value
  let delete t ~key = Hashtbl.remove t.table key
  let fold t ~init f = Hashtbl.fold (fun key _ acc -> f ~key acc) t.table init
end

module M = Riptide_materialize.Materializer.Make (Last_write_wins) (Memory_kv_store)

(* ── Admission-verification + protocol helpers -- mirrored verbatim from
   test_ledger_end_to_end.ml's own test-local helpers (that file's own top comment, and this
   codebase's established per-test-file-helpers convention: no shared test-support library
   exists). ──────────────────────────────────────────────────────────────────────────────────── *)

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
  let dir = make_temp_dir "ledger_dst_load_test" in
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

(* Signed ONCE, at the top of the whole test, not per-request -- see this task's own brief. *)
let verified_ledger () = verified_module "fixtures/ledger.wat" Loader.Sfi

let allow_handle_from_init =
  Protocol.create ~states:[ "init"; "ready" ] ~initial:"init"
    ~transitions:[ { Protocol.from_state = "init"; on_call = "handle"; to_state = "ready" } ]

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

let fake_event_id name = Value.content_hash (Value.Scalar (Value.String name))

let account_prefix = "ledger.account."

let is_account_key mk =
  String.length mk >= String.length account_prefix
  && String.sub mk 0 (String.length account_prefix) = account_prefix

(* ── The real multi-node wiring: one Riptide_dst.Cluster.run cluster (real replica_count
   replicas, each with its own Fault_injecting_storage over Memory_storage, driven under
   Eio_mock.Backend.run's virtual clock -- NOT Cluster.run_on_file_storage/real File_storage: this
   file's own Materializer is backed by Memory_kv_store below, a plain in-memory, test-local
   Kv_store_intf.S implementer, specifically so nothing here needs a real ~fs/io_uring scope at
   all. Confirmed necessary live, not merely preferred: an earlier version of this file used real
   File_kv_store + Cluster.run_on_file_storage (mirroring test_ledger_end_to_end.ml's own
   File_kv_store use), and real wall-clock I/O time, multiplied across 50+ requests each
   potentially needing several real settle rounds to recover from injected faults, routinely blew
   test_riptide.ml's own 15s per-test watchdog (arm_watchdog) -- intermittently, since real I/O
   timing is NOT reproducible from [seed] the way every protocol-level DECISION in
   [Riptide_dst.Cluster.run] is (cluster.mli's own doc comment on [run_on_file_storage] already
   discloses this exact tradeoff: "orders of magnitude slower... prefer [run] for seed sweeps").
   Module dispatch itself (Riptide_module.Loader) has no such constraint either way -- it sandboxes
   via plain [Unix.fork]/pipes, never through any Eio-specific API, so it runs identically under
   [Eio_mock.Backend.run] as it did under a real [Eio_main.run]. One Batch_commit.t wrapping
   whichever replica is CURRENTLY primary (see [current_handle]'s own doc comment -- NOT a handle
   fixed to replicas.(0), since this run's own storm-driven recovery can genuinely move the
   primary), one Materializer, one Reactor subscribed to "ledger.requests" with ledger.wat --
   otherwise identical wiring to test_ledger_end_to_end.ml's own with_ledger_env. ── *)

type env_handles = {
  replicas : Replica.t array;
  is_down : bool array;
  materializer : M.t;
  wrapped_sink : Batch_commit.materialize_sink;
  settle : unit -> unit;
  restart :
    ?lose_superblock:bool -> ?repair_superblock:Riptide_dst.Cluster.superblock_repair -> int -> bool;
}

(* NOT a fixed handle over replicas.(0) -- unlike test_ledger_end_to_end.ml's own solo env (where
   the one replica is permanently the only replica, hence permanently primary), this cluster's
   primary can genuinely MOVE once this file's own [timeout_storm] (see below) ever drives a real
   view change to recover a dropped message: cluster.mli's own "replicas.(0) is always the
   primary" guarantee holds only for view 1, and nothing stops this run's own injected faults plus
   the timeout-driven recovery they require from advancing the view past it. A handle fixed to a
   stale former primary would make every later [Batch_commit.propose] through it a silent,
   permanent no-op (exactly [Replica.propose]'s own documented behavior for a non-primary) --
   confirmed live while writing this test: hard-coding [replicas.(0)] here is exactly what made a
   transfer's own legs batch, proposed correctly, never converge after a storm-driven view change
   moved the real primary elsewhere. [current_handle] is re-derived, fresh, on every single
   proposal instead, exactly as a real client would re-discover the current primary rather than
   caching it. *)
let current_handle replicas is_down =
  let primary = ref None in
  Array.iteri
    (fun i r ->
      if (not is_down.(i)) && Replica.is_primary r && Replica.status r = Replica.Normal then
        primary := Some r)
    replicas;
  Option.map (fun r -> Batch_commit.create ~replica:r ~authorize:Authorize.authorize ()) !primary

(* [None] (no live, Normal-status primary known right now) is treated exactly like
   [Replica.propose] treats a non-primary call: a silent no-op, never an error -- a later round's
   settle/pump will simply retry once a primary exists again. *)
let propose_batch replicas is_down ~idempotency_key ?materialize writes =
  match current_handle replicas is_down with
  | None -> ()
  | Some handle -> Batch_commit.propose handle ~idempotency_key ?materialize writes

let with_ledger_dst_env ~seed ~replica_count ~net_fault_config (f : env_handles -> unit) =
  let kv = Memory_kv_store.create ~owner:"materializer" in
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
  (* Same idempotent-accumulation dedup guard as test_ledger_end_to_end.ml's own inner_sink, and
     for the same reason: a client retrying the same transfer_request under the same
     idempotency_key re-runs materialize.write for both already-committed legs a second time,
     with bit-identical payload, and a naive accumulator would double apply. Keyed by
     (transfer_id, this_account, role), exactly as Task 3 established. *)
  let applied_legs : (string, unit) Hashtbl.t = Hashtbl.create 256 in
  let inner_sink : Batch_commit.materialize_sink =
    {
      write =
        (fun ~merge_key payload ->
          if merge_key = Schema.requests_merge_key then
            M.write materializer ~merge_key { Last_write_wins.value = payload; timestamp = next_ts () }
          else if is_account_key merge_key then (
            match Schema.transfer_leg_of_value payload with
            | None -> ()
            | Some leg ->
              let dedup_key =
                Printf.sprintf "%Ld|%Ld|%s" leg.Schema.transfer_id leg.Schema.this_account
                  (match leg.Schema.role with Schema.Debit -> "debit" | Schema.Credit -> "credit")
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
                  { Last_write_wins.value = Value.Scalar (Value.Int new_balance); timestamp = next_ts () }))
          else ());
    }
  in
  let reactor = Reactor.create () in
  let wrapped_sink = Reactor.wrap_materialize_sink reactor inner_sink in
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
  let verified_artifact, verification_dir = verified_ledger () in
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote verification_dir))))
    (fun () ->
      (* [svc_limit] raised well past Cluster.run's own default (3): that default bounds how many
         view-change attempts a replica may make before a successful return to Normal resets it
         (replica.mli's own [check_timeout] doc comment) -- a reasonable default for a short
         scenario, but this run deliberately drives 50+ requests, each capable of needing its own
         genuine recovery under real injected drops/duplicates, over a single long-lived cluster.
         Confirmed live while writing this test: at the default, a long run eventually exhausts it
         on some replica with no live Normal primary left to reset it, permanently wedging the
         rest of the run -- raised generously here for the same reason a noisier real network
         would call for a higher retry budget operationally. *)
      Riptide_dst.Cluster.run ~seed ~replica_count ~svc_limit:100 ~net_fault_config
        (fun ~replicas ~settle ~restart ->
          let is_down = Array.make replica_count false in
          (* This module's own trusted propose closure -- the one piece of host code that ever
             turns a committed transfer_request into its two legs. Identical to
             test_ledger_end_to_end.ml's own propose_for_module except for routing through
             [propose_batch]/[current_handle] (see their own doc comment above) instead of a
             handle fixed to one replica, since this nested call can itself run after a
             storm-driven view change has moved the primary. *)
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
                propose_batch replicas is_down ~idempotency_key ~materialize:wrapped_sink legs;
                Ok ())
          in
          Reactor.subscribe reactor ~merge_key:Schema.requests_merge_key ~module_:verified_artifact
            ~protocol:allow_handle_from_init ~read:read_for_module ~propose:propose_for_module;
          f { replicas; is_down; materializer; wrapped_sink; settle; restart }))

let seed_account env account amount =
  let idempotency_key = Printf.sprintf "seed-%Ld" account in
  let event_id = fake_event_id idempotency_key in
  let leg =
    Schema.{ transfer_id = 0L; role = Credit; this_account = account; other_account = 0L; amount }
  in
  propose_batch env.replicas env.is_down ~idempotency_key ~materialize:env.wrapped_sink
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
  propose_batch env.replicas env.is_down ~idempotency_key ~materialize:env.wrapped_sink
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

(* The live replica with the highest commit_number -- NOT always [env.replicas.(0)]. Confirmed
   live while writing this test: after a storm-driven view change, the OLD primary (index 0) can
   lag the NEW primary's own commit_number for several rounds (it has already replicated the
   latest entries into its own log, via ordinary Prepare delivery, but has not yet locally
   advanced its own commit_number, which only happens on a later Prepare/Commit message) --
   reading [committed_envelopes] from a fixed, possibly-lagging replica under-reports what the
   cluster has genuinely agreed on, exactly the kind of false negative this file's own convergence
   loops must not produce. Any LIVE replica's own committed prefix is valid ground truth by VSR's
   agreement property; this just picks the most historically advanced one currently available. *)
let best_live_replica env =
  let best = ref None in
  Array.iteri
    (fun i r ->
      if not env.is_down.(i) then
        match !best with
        | None -> best := Some r
        | Some b -> if Replica.commit_number r > Replica.commit_number b then best := Some r)
    env.replicas;
  match !best with Some r -> r | None -> env.replicas.(0)

let module_leg_envelopes env =
  Batch_commit.committed_envelopes (best_live_replica env)
  |> List.filter (fun (e : Envelope.envelope) -> e.actor = "ledger-module")

(* The empty-writes re-check idiom this file's own top comment explains -- safe to call for a key
   whose batch does not exist yet (pure no-op) or is already materialized (lattice-join no-op). As
   a plain closure (an "action") so it composes uniformly with [reproposal] below in the same
   action list. *)
let materialize_only env key () =
  propose_batch env.replicas env.is_down ~idempotency_key:key ~materialize:env.wrapped_sink []

(* The OTHER half of robust re-driving, not redundant with [materialize_only] above: a REAL,
   content-bearing [propose_request]/[seed_account] call, safe to repeat for the same reason
   [materialize_only] is (batch_commit.mli's own "already in my log" skip makes a repeat of the
   SAME content a no-op once the first attempt has genuinely landed) -- but unlike
   [materialize_only] (which only ever re-checks a batch that already exists somewhere in the
   log), this can also supply the batch for the VERY FIRST time. Load-bearing, confirmed live
   while writing this test: the original, single, unretried [propose_request] call before this
   file's drive loops existed could land at the exact moment [current_handle] finds no live
   [Normal] primary (e.g. mid-view-change, which this run's own storm-driven recovery induces
   routinely) -- [propose_batch]'s own documented no-op in that case means the request is silently
   never proposed at all, and nothing empty-writes-only [materialize_only] ever does can retroactively
   create a batch that was never appended in the first place. Repeating the real call here closes
   that gap the same way [materialize_only] closes the analogous gap for an inherited, view-change
   -discarded tail entry (see [drive_legs]'s own doc comment). *)
let pump_actions actions = List.iter (fun action -> action ()) actions

(* [Replica.check_timeout] is NOT a lightweight "retry the last message" primitive -- for a
   healthy [Normal]-status replica it is VSR.tla's own [TimerSendSVC], which BROADCASTS a real
   [StartViewChange] (replica.mli's own doc comment, quoted here because getting this wrong
   silently wedges the whole cluster rather than raising): calling it unconditionally on every
   single replica, every single round, drives real, unnecessary view changes even when nothing is
   actually stuck, exactly matching test_dst_scenarios.ml's own scenario/storm precedent, which
   only ever fires it CONDITIONALLY (on a probability draw, or when no primary is currently known)
   -- never unconditionally on every round. Confirmed live while writing this test: firing it on
   every round wedges the cluster in a churn of unnecessary view changes and nothing ever commits.
   [storm] here follows the same discipline: only invoked once plain delivery has already been
   given a real chance (see [drive_until] below) and has not converged. *)
(* ONE live replica at a time, round-robin, NOT every live replica simultaneously. Confirmed live
   while writing this test: with one backup permanently down (replica_count = 3, so only 2
   replicas remain live), firing check_timeout on BOTH live replicas in the same instant lets them
   repeatedly bid for DIFFERENT, competing views at once (each immediately re-bidding again on the
   next storm before the other's StartViewChange has had a chance to land and be adopted) -- a real
   dueling-candidates livelock, observed never resolving across 7+ consecutive storms in one run.
   test_dst_scenarios.ml's own [storm] fires every live replica at once and does not hit this,
   but that sweep always has at least 3 live replicas (5-replica cluster, at most 2 crashed) so a
   losing candidate always has a THIRD replica around to break the tie; a 2-live-replica cluster
   has no such tiebreaker. Driving one replica's timer at a time gives its broadcast a real chance
   to be observed and adopted (via ReceiveHigherSVC/ReceiveMatchingSVC) before the other replica's
   own timer could compete with it. *)
let timeout_storm_cursor = ref 0

let timeout_storm env =
  let n = Array.length env.replicas in
  let rec find_live attempts i =
    if attempts >= n then None
    else if not env.is_down.(i) then Some i
    else find_live (attempts + 1) ((i + 1) mod n)
  in
  match find_live 0 (!timeout_storm_cursor mod n) with
  | None -> ()
  | Some i ->
    Replica.check_timeout env.replicas.(i);
    timeout_storm_cursor := (i + 1) mod n

(* A trivial, content-distinct, merge_key = None batch (ignored by both Authorize.authorize --
   "anything else: Allow" -- and this file's own inner_sink, which has no opinion on an unknown
   merge_key either) proposed fresh every round. Load-bearing, not cosmetic: confirmed live while
   writing this test that a genuinely NEW Prepare/Prepare_ok round is the only thing that reliably
   unsticks a tail entry a view change has already fully replicated (present in every replica's
   own [entries]) but left short of [commit_number] -- VSR.tla's own SendSV (replica.mli's own
   doc comment on [commit_number]) carries [commit_number] forward only as the DVC quorum's own
   previously-agreed value, never extended to cover the newly-adopted tail, and re-pumping the
   SAME already-logged idempotency_key is a documented no-op (batch_commit.mli's own "already in
   my log" skip) that sends nothing new at all. A fresh Prepare_ok for a LATER op number implies
   the backup also holds every earlier op, so once this nudge's own op reaches quorum, standard
   VSR commit-advancement carries the stuck earlier tail forward with it -- exactly matching
   test_dst_scenarios.ml's own sweep, which never hits this stall in the first place because its
   own scenario keeps a continuous stream of new, distinct proposals flowing every round; this
   file's own per-request convergence loops do not have that for free, so they supply it here. *)
let nudge_counter = ref 0

let nudge env =
  incr nudge_counter;
  let idempotency_key = Printf.sprintf "nudge-%d" !nudge_counter in
  let event_id = fake_event_id idempotency_key in
  propose_batch env.replicas env.is_down ~idempotency_key
    [
      {
        Batch_commit.actor = "test-nudge";
        causation = event_id;
        correlation = event_id;
        payload = Value.Scalar (Value.Int (Int64.of_int !nudge_counter));
        merge_key = None;
      };
    ]

let max_rounds = 14

(* This file's progress signals (see each [drive_until] call site's own [~progress] argument)
   deliberately favor [commit_number]/[module_leg_envelopes]-shaped observables over any other
   available one -- both provably downstream of a
   real quorum having acknowledged something, unlike every OTHER observable this file has access
   to, which can each individually keep moving forever with zero real progress behind them:
   - NOT [Replica.entries]'s own length: a primary can keep accepting (and locally appending)
     this file's own [nudge] proposals forever even while genuinely isolated from both backups.
   - NOT [Reactor.For_testing.log_call_count]: re-materializing an already-committed request
     re-dispatches the module every round BY DESIGN (see [drive_legs]'s own doc comment) --
     re-dispatching is not evidence its own resulting [propose_write] ever committed.
   Both confirmed live while writing this test, independently, as the exact same failure shape:
   including either one made [stall_rounds] permanently 0 for an entire run where [commit_number]
   itself never moved at all, silently disabling the storm escalation below for the one case it
   exists to catch.

   {b Not even [commit_number]/[module_leg_envelopes] GLOBALLY is specific enough}, confirmed by a
   THIRD live failure while writing this test: a global sum keeps climbing forever as long as
   ANYTHING in the whole cluster is still committing -- this file's own [nudge] included -- which
   can fully mask a stall in the ONE thing a particular [drive_until] call actually cares about
   (one specific transfer's own 2 legs, stuck forever while unrelated nudges kept the global sum
   moving every round). [drive_until] below therefore takes the progress signal as a per-call
   argument, scoped to exactly what that call's own [converged] predicate reads, rather than any
   one shared global proxy. *)

(* Shared retry shape for every convergence loop below: give plain delivery (settle + pump) two
   full rounds on its own first -- which is all a healthy cluster under this run's modest
   drop/duplicate rates should ever need -- and only escalate to forcing a real timeout storm
   (see [timeout_storm]'s own doc comment for why that is a real view-change, not a cheap retry)
   once that has genuinely failed to make progress. *)
let drive_until ?(max_rounds = max_rounds) env ~actions ~progress ~converged =
  let ok = ref false in
  let round = ref 0 in
  (* [check_timeout]'s own [svc_limit] budget (replica.mli's own doc comment: "all three budgets
     are reset by a successful return to Normal") is NOT free to spend every round: a replica
     whose own view change has not yet completed does not reset it, so storming every single round
     can genuinely EXHAUST it before the cluster ever gets back to Normal, wedging it permanently
     (confirmed live while writing this test, twice: once storming unconditionally every round,
     and again storming every round a primary happened to be momentarily unknown -- in BOTH cases
     entries/commit froze solid for many consecutive storm rounds with zero further progress,
     which is exactly what a replica with no [check_timeout] budget left and no primary in
     [Normal] status looks like). Also confirmed live: firing an extra, UNNECESSARY storm purely
     because some number of rounds had elapsed -- even while the cluster was actively making real
     progress on its own -- is itself what KICKED a healthy, progressing cluster into an
     unnecessary view change at the worst possible moment (immediately after a backup had just
     been permanently crashed, leaving no spare quorum margin to absorb it). This loop storms only
     when [progress] above has gone genuinely STALE for two full rounds in a row (never
     back-to-back, so a storm's own view change always gets at least one full settle round to
     complete and reset its budget before this loop risks spending more of it) -- never merely
     because a primary is momentarily unknown (that alone, with no stall, is just a view change
     already in flight) and never merely because some number of rounds have passed while things
     were still moving. *)
  let rounds_since_storm = ref 1000 in
  let last_progress = ref (-1) in
  let stall_rounds = ref 0 in
  while (not !ok) && !round < max_rounds do
    incr round;
    let p = progress () in
    if p = !last_progress then incr stall_rounds else stall_rounds := 0;
    last_progress := p;
    let want_storm = !stall_rounds >= 2 && !rounds_since_storm >= 2 in
    if want_storm then (
      timeout_storm env;
      rounds_since_storm := 0)
    else incr rounds_since_storm;
    env.settle ();
    (* [nudge] only once genuinely stalled, not every round: the common case (most
       requests/legs/seeds converge within a round or two of plain delivery, confirmed by this
       file's own measured traces) never needs it, and skipping it there is a real wall-clock
       saving -- a nudge is its own full propose-and-settle round trip -- that matters for a
       scenario this file's own suite runs 50+ of under a 15s per-test watchdog
       (test_riptide.ml's own [arm_watchdog]). *)
    if !stall_rounds >= 1 then (
      nudge env;
      env.settle ());
    pump_actions actions;
    if converged () then ok := true
  done;
  !ok

(* Drives [idempotency_key] (a transfer_request's own batch, merge_key = "ledger.requests") until
   the module has genuinely dispatched for it (observed via Reactor.For_testing.log_call_count,
   exactly test_ledger_end_to_end.ml's own test_insufficient_funds_is_a_clean_no_op's technique for
   telling "the guest really ran" apart from "nothing happened yet") -- deliberately pumping ONLY
   this one key, not any other pending key, so a caller choosing to inject a fault right after this
   returns knows precisely what has and has not happened yet: this request's own commit and
   dispatch (which, if the module decided "sufficient funds", already means
   Legs.legs_of_bytes ran and a *separate*, still-uncommitted legs batch was just appended to the
   primary's own log via propose_for_module's nested Batch_commit.propose above) but NOT that legs
   batch's own commit or materialization, which needs its own, separate drive. *)
let drive_request_dispatch env ~idempotency_key (req : Schema.transfer_request) =
  let log_before = Reactor.For_testing.log_call_count () in
  drive_until env
    ~actions:[ (fun () -> propose_request env ~idempotency_key req) ]
    ~progress:Reactor.For_testing.log_call_count
    ~converged:(fun () -> Reactor.For_testing.log_call_count () > log_before)

(* Drives [transfer_key] (the legs batch a dispatched, accepted request produced) until both legs
   are committed and materialized, observed via module_leg_envelopes' own count -- the same
   ground truth this file's final correctness assertions read. [expected_delta] is 2 for an
   accepted request (debit + credit) and 0 for a declined one (nothing was ever proposed under
   this key, so this immediately "converges" doing nothing, which is correct: there is nothing to
   wait for). *)
(* Pumps BOTH [idempotency_key] (the request's own, already-committed batch) and [transfer_key]
   (the legs it produced) -- not [transfer_key] alone. This is load-bearing, not redundant: an
   uncommitted tail entry with no quorum evidence behind it yet is exactly what a real VSR view
   change is entitled to discard (a write nobody could yet have assumed was durable), and this
   run's own storm-driven recovery from dropped messages (see [timeout_storm]'s doc comment)
   genuinely triggers view changes -- confirmed live while writing this test: a legs batch
   proposed via propose_for_module's nested call, still uncommitted when a view change landed,
   was cleanly discarded by it (entries dropped from 9 to 8 across all three replicas). Since
   nothing else ever re-proposes it, the ONLY way to recover is to re-trigger the dispatch that
   produced it in the first place -- re-pumping [idempotency_key] does exactly that:
   materializing an already-committed batch is a safe, idempotent re-check (batch_commit.mli's own
   documented contract), but Reactor's own dispatch fires on every materialize call regardless
   (Task 3's own test_insufficient_funds_is_a_clean_no_op already established this), so a lost
   legs batch gets a fresh, genuine propose_for_module attempt on the very next round -- never a
   double-apply, since Batch_commit.propose's own "already in my log" check only skips
   re-appending when the PRIOR attempt is still actually present. *)
let drive_legs env ~idempotency_key ~transfer_key ~expected_delta (req : Schema.transfer_request) =
  if expected_delta = 0 then ()
  else (
    let before = List.length (module_leg_envelopes env) in
    let ok =
      drive_until env
        ~actions:
          [ (fun () -> propose_request env ~idempotency_key req); materialize_only env transfer_key ]
        ~progress:(fun () -> List.length (module_leg_envelopes env))
        ~converged:(fun () -> List.length (module_leg_envelopes env) >= before + expected_delta)
    in
    if not ok then
      Alcotest.failf "transfer %s: legs did not converge after %d rounds (have %d, want >= %d)"
        transfer_key max_rounds
        (List.length (module_leg_envelopes env))
        (before + expected_delta))

let drive_seed env ~account ~amount =
  let ok =
    drive_until env
      ~actions:[ (fun () -> seed_account env account amount) ]
      ~progress:(fun () -> Int64.to_int (balance_of env account))
      ~converged:(fun () -> balance_of env account = amount)
  in
  if not ok then
    Alcotest.failf "seeding account %Ld: balance did not converge to %Ld after %d rounds (have %Ld)"
      account amount max_rounds (balance_of env account)

(* ---------------------------------------------------------------------------------------------
   The reference model: a plain, independently-maintained ledger the test itself keeps, used both
   to DECIDE which requests should be accepted/declined (so the request mix below is a genuine,
   evolving mix rather than hand-picked) and, afterward, as the ground truth every real outcome is
   checked against.
   --------------------------------------------------------------------------------------------- *)

let accounts = [| 101L; 102L; 103L; 104L; 105L |]
let seed_amounts = [| 1000L; 2000L; 1500L; 500L; 800L |]
let num_requests = 50

(* Deterministic, not hand-picked: cycles through every account as both sender and receiver, and
   alternates a guaranteed-oversized amount (every third request) with a moderate, pseudo-varied
   amount that starts out affordable and, as the sender's own balance is driven down by earlier
   accepted transfers in the same run, naturally starts failing too -- a genuine, evolving mix of
   accept/decline, not an artificial 50/50 split chosen in advance. *)
let build_requests () =
  let ref_balances = Hashtbl.create 8 in
  Array.iteri (fun i acct -> Hashtbl.replace ref_balances acct seed_amounts.(i)) accounts;
  let requests = ref [] in
  for idx = 1 to num_requests do
    let from_i = idx mod Array.length accounts in
    let to_i =
      let t = (idx + 1 + (idx / Array.length accounts)) mod Array.length accounts in
      if t = from_i then (t + 1) mod Array.length accounts else t
    in
    let from_acc = accounts.(from_i) and to_acc = accounts.(to_i) in
    let current = Hashtbl.find ref_balances from_acc in
    let amount =
      if idx mod 3 = 0 then Int64.add current 500L
      else Int64.of_int (80 + ((idx * 37) mod 420))
    in
    let request_id = Int64.of_int idx in
    let req = Schema.{ request_id; from_account = from_acc; to_account = to_acc; amount } in
    let accepted = current >= amount in
    if accepted then (
      Hashtbl.replace ref_balances from_acc (Int64.sub current amount);
      let to_current = Hashtbl.find ref_balances to_acc in
      Hashtbl.replace ref_balances to_acc (Int64.add to_current amount));
    requests := (req, accepted) :: !requests
  done;
  (List.rev !requests, ref_balances)

let test_the_ledger_invariant_holds_under_injected_failures () =
  let requests, expected_balances = build_requests () in
  (* The designated crash-timing request: the first ACCEPTED request at or past position 20 (well
     into the run, so there is real prior history -- both committed state on every replica and a
     genuinely non-empty WAL on the backup about to be crashed, which is exactly what makes the
     crash below land in finding C1's own documented territory rather than a vacuous empty-WAL
     case). Must be accepted, not declined, or there would be no legs batch for the crash to land
     in front of at all. *)
  let crash_idx =
    let found = ref None in
    List.iteri
      (fun i (_, accepted) -> if !found = None && i + 1 >= 20 && accepted then found := Some (i + 1))
      requests;
    match !found with
    | Some i -> i
    | None -> Alcotest.fail "test setup: no accepted request at or past position 20 to crash around"
  in
  let net_fault_config =
    Riptide_sim.Network.
      { drop_probability = 0.1; duplicate_probability = 0.2; corrupt_probability = 0.0;
        min_delay = 0.0; max_delay = 0.01 }
  in
  let crash_outcome = ref None in
  let repair_outcome = ref None in
  with_ledger_dst_env ~seed:4242 ~replica_count:3 ~net_fault_config (fun env ->
      Array.iteri (fun i acct -> drive_seed env ~account:acct ~amount:seed_amounts.(i)) accounts;
      List.iteri
        (fun i (req, accepted) ->
          let n = i + 1 in
          let idempotency_key = Printf.sprintf "req-%d" n in
          let transfer_key = "ledger-transfer-" ^ Int64.to_string req.Schema.request_id in
          let dispatched = drive_request_dispatch env ~idempotency_key req in
          Alcotest.(check bool)
            (Printf.sprintf "request %d: the module genuinely dispatched" n)
            true dispatched;
          if n = crash_idx then (
            (* THE DELIBERATE CRASH, landing exactly here: the request has just materialized and
               the module has just dispatched for it -- for an ACCEPTED request (which this one
               is, by construction of crash_idx above), that dispatch already called
               propose_for_module, which already ran Legs.legs_of_bytes and already called
               Batch_commit.propose to APPEND both legs to the primary's own log -- but neither
               leg has been driven to commit/materialize yet (drive_legs for this request has not
               been called). This is "between a request materializing and its corresponding
               propose_write landing", chosen deliberately rather than merely "sometime": the gap
               between propose_write being CALLED (legs appended, uncommitted) and its effect
               actually LANDING (legs committed and folded into balances).

               A replica that is NOT the current primary is crashed -- crashing the primary would
               introduce a view change, which is real but genuinely out of this task's scope (see
               this task's own brief) -- but WHICH index that is cannot be hard-coded. By request
               20, this run's own continuous network-fault injection has already driven the
               cluster through several real view changes on its own (confirmed live: view 5, not
               view 1, by this point), so "index 1" is no longer reliably a backup -- a fixed
               index is exactly the kind of claim that looks safe by construction and silently
               stops being true once the scenario it describes evolves. [find_live_non_primary]
               queries [Replica.is_primary] across the actually-live replicas AT THIS MOMENT and
               picks one that genuinely is not currently primary; the assertion right after it is
               what makes "never the primary" a verified fact about this specific run rather than
               an assumption baked into a constant. *)
            let find_live_non_primary () =
              let found = ref None in
              Array.iteri
                (fun i r ->
                  if !found = None && (not env.is_down.(i)) && not (Replica.is_primary r) then
                    found := Some i)
                env.replicas;
              !found
            in
            let backup_idx =
              match find_live_non_primary () with
              | Some i -> i
              | None ->
                Alcotest.fail
                  "test setup: every live replica is currently primary (of its own view) -- no \
                   genuine non-primary replica is available to crash at this point"
            in
            Alcotest.(check bool)
              (Printf.sprintf
                 "replica %d (chosen to crash) is genuinely NOT the current primary at the moment \
                  of the crash"
                 backup_idx)
              false
              (Replica.is_primary env.replicas.(backup_idx));
            (* The operator's own out-of-band knowledge for the repair below -- this backup's OWN
               real prior durable view/commit state, read off it BEFORE crashing it (never from a
               live peer; see Riptide_dst.Cluster.superblock_repair's own doc comment for why that
               would be unsafe in general). *)
            let truth =
              Riptide_dst.Cluster.
                {
                  view_number = Replica.view_number env.replicas.(backup_idx);
                  last_normal_view = Replica.last_normal_view env.replicas.(backup_idx);
                  commit_number = Replica.commit_number env.replicas.(backup_idx);
                }
            in
            let came_back = env.restart ~lose_superblock:true backup_idx in
            if not came_back then env.is_down.(backup_idx) <- true;
            crash_outcome := Some came_back;
            env.settle ();
            (* THE REPAIR, as a genuinely separate operator act from the crash itself (never
               folded into one call -- see cluster.mli's own reasoning): this is deliberately not
               optional set dressing. Leaving the cluster at 2-of-3 live replicas for the
               remaining ~30 requests hits a real, separately-confirmed liveness gap in this VSR
               subset: Primary(v) cycles through all three replicas regardless of which are live,
               so roughly one view in three lands on the now-permanently-down replica as its
               primary-elect -- a dead end neither live replica can ever escape via
               [check_timeout] alone (TimerSendSVC only fires from [Normal], and
               ForfeitViewChange only fires for a replica that is ITSELF the stuck view's
               primary-elect with a full quorum it still can't complete -- neither condition is
               ever true for a plain backup waiting on a [StartView] from a primary that will
               never send one). Confirmed live while writing this test: both live replicas parked
               in [View_change] at a dead-end view for 20+ rounds with zero further progress.
               Repairing promptly, the way a real operator would, keeps all three replicas live
               for the rest of the run and avoids re-exercising that gap on every later request --
               this is not this task's own scope to fix or further characterize. *)
            if not came_back then (
              let repaired = env.restart ~repair_superblock:truth backup_idx in
              if repaired then env.is_down.(backup_idx) <- false;
              repair_outcome := Some repaired;
              env.settle ()));
          let expected_delta = if accepted then 2 else 0 in
          drive_legs env ~idempotency_key ~transfer_key ~expected_delta req)
        requests;
      (* A final mop-up: every key has already individually converged above (per [drive_legs]'s own
         ground truth at the time), but [best_live_replica] can still legitimately lag a round or
         two behind the cluster's true commit state right after the LAST request's own driving
         loop ends (see its own doc comment) -- so this drives everything once more, with the same
         storm-aware [drive_until] logic (never a blind fixed-round loop, for the same
         svc_limit-exhaustion reason documented there), until the GLOBALLY expected total leg
         count is reached. *)
      (* Deliberately ONLY [materialize_only] here -- NEVER the real [propose_request] re-call
         [drive_legs] itself uses. That re-call is safe INSIDE one request's own narrow
         convergence window (no LATER request has touched its [from_account]'s balance yet, so
         the guest decides the same way every time it is re-dispatched), but is NOT safe here: by
         the time this global mop-up/catch-up runs, every account's balance has moved on from
         whatever it was when an EARLIER, already-resolved request was first dispatched.
         Confirmed live while writing this test, the hard way: re-proposing old request content
         here re-triggered the module's dispatch for already-settled requests, including ones
         this test's own reference model had already correctly recorded as DECLINED -- against
         the now-later, higher balance, the SAME guest legitimately re-decided ACCEPT on one of
         them, creating a real transfer that should never have existed and silently doubling one
         account's own final balance relative to the reference model. Every request's own
         ACCEPT/DECLINE outcome is already final by this point ([drive_legs] already raised, by
         its own [Alcotest.failf], if a request's own dispatch/legs never converged) -- nothing
         further is needed from the request side, only from the legs that outcome already
         produced, which is exactly what materializing [transfer_key] (and nothing else) does. *)
      let all_actions =
        List.map
          (fun (req, _) -> materialize_only env ("ledger-transfer-" ^ Int64.to_string req.Schema.request_id))
          requests
      in
      let expected_total_legs = 2 * List.length (List.filter snd requests) in
      let fully_converged =
        drive_until env ~actions:all_actions
          ~progress:(fun () -> List.length (module_leg_envelopes env))
          ~converged:(fun () -> List.length (module_leg_envelopes env) >= expected_total_legs)
      in
      if not fully_converged then
        Alcotest.failf "final mop-up: expected %d total legs, have %d after %d rounds"
          expected_total_legs
          (List.length (module_leg_envelopes env))
          max_rounds;

      (* Catch up every LIVE replica -- not just whichever one [best_live_replica] already
         favors -- to the same committed LEDGER-MODULE state, before the cross-replica agreement
         check below reads them directly. The repaired replica (whichever index
         [find_live_non_primary] picked above) rejoins via normal, strictly sequential
         replication in this VSR subset (no bulk state-transfer --
         replica.mli's own disclosed scope boundary, cited in [with_ledger_dst_env]'s own top
         comment), so it can keep lagging the rest of the cluster for a while even after the
         cluster AS A WHOLE has stopped needing anything further from it (every balance and every
         transfer's own legs already checked out above, against [best_live_replica] alone).

         Deliberately NOT raw [Replica.commit_number] parity: once every real request/transfer
         action above has converged, the only further traffic this file's own [nudge] can
         generate is content-free no-op batches (merge_key = None) -- a replica can legitimately
         keep lagging the rest of the cluster by exactly one or two of THOSE forever, with
         [commit_number] parity never quite closing, while already agreeing on every real
         ledger-module envelope that actually matters. Converging on the real, final comparison
         (every live replica's own ledger-module envelope list matches the primary's) is both the
         thing this step exists to guarantee and immune to that red herring. *)
      let module_leg_envelopes_of r =
        Batch_commit.committed_envelopes r
        |> List.filter (fun (e : Envelope.envelope) -> e.actor = "ledger-module")
      in
      let canon_envs (es : Envelope.envelope list) =
        List.map (fun e -> Value.canonical_encode (Envelope.to_value e)) es
      in
      let live_agree () =
        let primary_canon = canon_envs (module_leg_envelopes_of env.replicas.(0)) in
        let ok = ref true in
        Array.iteri
          (fun i r -> if (not env.is_down.(i)) && canon_envs (module_leg_envelopes_of r) <> primary_canon then ok := false)
          env.replicas;
        !ok
      in
      let caught_up =
        drive_until ~max_rounds:20 env ~actions:all_actions
          ~progress:(fun () ->
            let m = ref max_int in
            Array.iteri
              (fun i r -> if not env.is_down.(i) then m := min !m (List.length (module_leg_envelopes_of r)))
              env.replicas;
            !m)
          ~converged:live_agree
      in
      if not caught_up then
        Alcotest.failf
          "final catch-up: live replicas never converged on the same ledger-module envelope list \
           (lengths: [%s], is_down=[%s], commit=[%s])"
          (String.concat "," (Array.to_list (Array.map (fun r -> string_of_int (List.length (module_leg_envelopes_of r))) env.replicas)))
          (String.concat "," (Array.to_list (Array.map string_of_bool env.is_down)))
          (String.concat "," (Array.to_list (Array.map (fun r -> string_of_int (Replica.commit_number r)) env.replicas)));

      (* ── (a): every committed ledger.account.*-prefixed envelope independently satisfies
         Authorize.authorize, re-derived from committed_envelopes directly -- not merely "nothing
         was denied during the run". Envelopes carry no merge_key of their own (envelope.mli has
         no such field; merge_key is a Batch_commit.write-level routing fact, not part of an
         envelope's identity), so each is reconstructed into the write Authorize.authorize actually
         consumes: decode the leg, rebuild merge_key as Schema.account_merge_key leg.this_account
         (exactly how Authorize.authorize itself defines a "ledger.account.*" write), and check. ── *)
      let module_envelopes = module_leg_envelopes env in
      Alcotest.(check bool) "the run produced real ledger-module envelopes (not a vacuous pass)"
        true
        (List.length module_envelopes > 0);
      List.iter
        (fun (e : Envelope.envelope) ->
          match Schema.transfer_leg_of_value e.payload with
          | None -> Alcotest.fail "a committed ledger-module envelope failed to decode as a transfer_leg"
          | Some leg ->
            let w =
              {
                Batch_commit.actor = e.actor;
                causation = e.causation;
                correlation = e.correlation;
                payload = e.payload;
                merge_key = Some (Schema.account_merge_key leg.Schema.this_account);
              }
            in
            (match Authorize.authorize w with
            | Batch_commit.Allow -> ()
            | Batch_commit.Deny reason ->
              Alcotest.failf
                "committed ledger.account.%Ld envelope (transfer %Ld) fails its own re-derived \
                 Authorize.authorize check: %s"
                leg.Schema.this_account leg.Schema.transfer_id reason))
        module_envelopes;

      (* ── (b): every account's final materialized balance equals the reference model's own
         independently-computed total. ── *)
      Array.iter
        (fun acct ->
          let expected = Hashtbl.find expected_balances acct in
          Alcotest.(check int64)
            (Printf.sprintf "account %Ld's final balance matches the reference model" acct)
            expected (balance_of env acct))
        accounts;

      (* ── (c): no transfer is lost or double-applied -- per request_id, exactly the legs the
         reference model says should exist, no more and no fewer, despite the injected crash and
         network faults. ── *)
      let legs_by_transfer : (int64, Schema.role list) Hashtbl.t = Hashtbl.create 64 in
      List.iter
        (fun (e : Envelope.envelope) ->
          match Schema.transfer_leg_of_value e.payload with
          | None -> ()
          | Some leg ->
            let prev = try Hashtbl.find legs_by_transfer leg.Schema.transfer_id with Not_found -> [] in
            Hashtbl.replace legs_by_transfer leg.Schema.transfer_id (leg.Schema.role :: prev))
        module_envelopes;
      let role_str = function Schema.Debit -> "debit" | Schema.Credit -> "credit" in
      List.iter
        (fun (req, accepted) ->
          let roles =
            try Hashtbl.find legs_by_transfer req.Schema.request_id with Not_found -> []
          in
          if accepted then
            Alcotest.(check (list string))
              (Printf.sprintf "transfer %Ld: exactly one debit and one credit leg, no more, no fewer"
                 req.Schema.request_id)
              [ "credit"; "debit" ]
              (List.sort compare (List.map role_str roles))
          else
            Alcotest.(check int)
              (Printf.sprintf "transfer %Ld: declined, so no leg was ever committed"
                 req.Schema.request_id)
              0 (List.length roles))
        requests;

      (* ── Optional (d): cross-replica agreement, across all three replicas -- the crashed-and-
         repaired replica (whichever index was genuinely non-primary at crash time) included,
         since the repair above (not merely the crash) is this test's own deliberate choice (see
         its own doc comment). Proves VSR replication
         itself -- not just this test's own single-replica bookkeeping -- preserved every
         invariant-bearing entry cluster-wide, including on the replica that was actually
         crashed. *)
      Array.iteri
        (fun i r ->
          if i <> 0 then
            Alcotest.(check (list string))
              (Printf.sprintf
                 "replica %d agrees, byte for byte, with the primary on every committed \
                  ledger-module envelope"
                 i)
              (canon_envs module_envelopes) (canon_envs (module_leg_envelopes_of r)))
        env.replicas;

      (* The crash itself really happened, and really landed where intended: a backup with
         real, non-empty prior committed state, crashed with a torn superblock, which by
         Riptide_vsr.Replica.restart's own semantics deterministically REFUSES to come back
         over a non-empty WAL. Asserted rather than merely logged, so this test fails loudly if
         a future change to the request mix/timing ever makes the WAL empty at this point
         (which would make this a vacuous, uninteresting crash instead of finding C1's real
         condition) or otherwise changes this deterministic outcome. *)
      (match !crash_outcome with
      | None -> Alcotest.fail "test setup: the deliberate crash was never actually injected"
      | Some came_back ->
        Alcotest.(check bool)
          "the crashed backup had a non-empty WAL at crash time (real prior committed state), so \
           it deterministically refused to come back over its lost superblock -- finding C1's own \
           documented condition, not a vacuous empty-WAL crash"
          false came_back);
      (* THE REPAIR really happened too, and really brought the backup back for real -- not just
         logged, the same discipline as the crash assertion above. *)
      (match !repair_outcome with
      | None ->
        Alcotest.fail "test setup: the crashed backup refused, but the repair was never attempted"
      | Some repaired ->
        Alcotest.(check bool)
          "the repair -- supplying the crashed backup's own real prior view/commit state -- \
           brought it back for real, restoring all three replicas to live for the remainder of \
           the run"
          true repaired))

let tests =
  [
    ( "a realistic request mix commits correctly through real VSR replication, injected network \
       faults, and a verified-non-primary replica crash timed between a request materializing \
       and its legs landing",
      `Slow, test_the_ledger_invariant_holds_under_injected_failures );
  ]
