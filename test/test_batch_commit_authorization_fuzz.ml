(* The fuzzing half of Decision 7's own named test strategy (final-fix-wave finding I6).

   The Layer 0/Layer 2 boundary design spec says, for the universal authorization checkpoint: "an
   exhaustive call-site audit (grep-based, in the style `scripts/check-citations` already
   established this session for a different invariant) plus fuzzing, proving no write can bypass the
   checkpoint under any code path." Neither half had been built. The audit half is
   `scripts/check-authorization-checkpoint`, which proves the STRUCTURAL claim (exactly one
   Replica.propose caller in lib/, inside Batch_commit.propose, behind an ~authorize evaluation over
   every write in the batch). This file is the BEHAVIOURAL half: for randomly generated sequences of
   propose calls -- random batch sizes, random Allow/Deny mixes within a batch, random merge_key
   presence, random ~materialize presence, random retries of an already-used idempotency key -- no
   write a policy denied ever appears in the replicated log, and none ever reaches a materialize
   sink either.

   Why fuzzing adds something the audit doesn't: the audit proves the checkpoint is on the only path
   to the log, but says nothing about the checkpoint's own semantics under composition. The real
   behaviours that matter here are emergent -- whole-batch denial (one Deny voids its siblings'
   writes too), the deliberate interaction between denial and the already-in-log guard (a denied
   batch never claims its idempotency key, so a later batch may still use it), and first-wins key
   dedup on the read side. Hand-written tests cover each of those individually (test_batch_commit.ml
   has them); what nothing covered is arbitrary INTERLEAVINGS of them against one shared replica,
   which is exactly where a bypass would hide if one existed.

   Deliberately out of this file's scope, and why: the ~encryption path (its own real
   Redaction_store/Eio machinery, and orthogonal to authorization -- encryption happens strictly
   after the checkpoint, on writes already allowed), and a policy that CHANGES its answer for the
   same write between calls (test_batch_commit.ml's own retry-under-a-now-denying-policy regression
   test covers that exact shape deterministically; a generated version would only re-derive it). *)
open Riptide
open Riptide_vsr
open Riptide_batch_commit

let () = Mirage_crypto_rng_unix.use_default ()

(* replica_count = 1, f = 0: propose commits synchronously with no network or quorum, matching
   test_batch_commit.ml's own create_solo -- the checkpoint is a local, pre-proposal decision, so
   nothing about this property needs a real cluster. *)
let create_solo () =
  let send ~to_:_ (_ : string) = () in
  Replica.create ~storage:(Replica.volatile_storage ()) ~my_id:1 ~replica_count:1 ~svc_limit:3 ~send ()

let fake_event_id name = Value.content_hash (Value.Scalar (Value.String name))

(* ── The generated program ─────────────────────────────────────────────────────────────────────── *)

type generated_write = { allowed : bool; merge_key : string option }

type generated_step = {
  writes : generated_write list;
  (* Retry shape: propose under an idempotency key an earlier step already used, rather than a fresh
     one. This is the single most interesting axis for the checkpoint, because denial and the
     already-in-log guard interact by design (see batch_commit.ml's own comment at the guard). *)
  reuse_earlier_key : bool;
  with_materialize : bool;
}

let write_gen =
  let open QCheck2.Gen in
  let* allowed = oneof_weighted [ (2, return true); (1, return false) ] in
  (* Two keys only, shared across the whole program, so generated writes genuinely collide on a
     merge_key rather than each getting a private one. *)
  let* merge_key = oneof_weighted [ (1, return None); (1, oneof_list [ Some "mk1"; Some "mk2" ]) ] in
  return { allowed; merge_key }

let step_gen =
  let open QCheck2.Gen in
  (* 0 writes included on purpose: the documented "drain" idiom (empty writes + ~materialize), which
     is one of the three catch-up shapes batch_commit.mli names as exempt from the checkpoint. *)
  let* writes = list_size (int_range 0 4) write_gen in
  let* reuse_earlier_key = oneof_weighted [ (3, return false); (1, return true) ] in
  let* with_materialize = bool in
  return { writes; reuse_earlier_key; with_materialize }

let program_gen = QCheck2.Gen.list_size (QCheck2.Gen.int_range 1 6) step_gen

let print_program program =
  String.concat "; "
    (List.mapi
       (fun i step ->
         Printf.sprintf "step%d{%s%s%s}" i
           (String.concat ","
              (List.map
                 (fun w ->
                   (if w.allowed then "A" else "D")
                   ^ match w.merge_key with None -> "" | Some k -> "@" ^ k)
                 step.writes))
           (if step.reuse_earlier_key then " reuse-key" else "")
           (if step.with_materialize then " materialize" else ""))
       program)

(* ── Running one generated program against real machinery ──────────────────────────────────────── *)

(* The policy under test, derived from the write's own payload so it is a genuine per-write decision
   (not a per-batch or per-call one): every generated write's payload is a unique marker string
   whose first character is 'A' (allow) or 'D' (deny). That also makes the property's own check
   direct -- a marker found in the committed log names the exact step and write it came from. *)
let authorize (w : Batch_commit.write) =
  match w.payload with
  | Value.Scalar (Value.String s) when String.length s > 0 && s.[0] = 'D' ->
    Batch_commit.Deny "fuzz policy denies every write marked D"
  | _ -> Batch_commit.Allow

let marker ~step_index ~write_index ~allowed =
  Printf.sprintf "%c:step%d-write%d" (if allowed then 'A' else 'D') step_index write_index

let is_denied_marker s = String.length s > 0 && s.[0] = 'D'

(* Runs the whole program against ONE shared replica and ONE handle, and returns what actually
   happened plus the markers a correct implementation MUST have committed. That second list is what
   keeps this property from being satisfiable by an implementation that simply never commits
   anything: the model below mirrors batch_commit.ml's real rules exactly -- a batch is proposed only
   when it has writes, its key is not already in the log, and no write in it was denied; a denied
   batch never claims its key, so a later step may still use it. *)
let run_program program =
  let replica = create_solo () in
  let handle = Batch_commit.create ~replica ~authorize () in
  let materialized = ref [] in
  let sink : Batch_commit.materialize_sink =
    { write =
        (fun ~merge_key:_ ~idempotency_key:_ ~position:_ ~actor:_ ~causation:_ ~correlation:_ v ->
          materialized := v :: !materialized)
    }
  in
  let keys_used = ref [] in
  let keys_in_log = Hashtbl.create 8 in
  let must_be_committed = ref [] in
  List.iteri
    (fun step_index step ->
      let key =
        match (step.reuse_earlier_key, !keys_used) with
        | true, earlier :: _ -> earlier
        | _ -> Printf.sprintf "fuzz-key-%d" step_index
      in
      if not (List.mem key !keys_used) then keys_used := key :: !keys_used;
      let writes =
        List.mapi
          (fun write_index (gw : generated_write) ->
            let m = marker ~step_index ~write_index ~allowed:gw.allowed in
            {
              Batch_commit.actor = "fuzz";
              causation = fake_event_id m;
              correlation = fake_event_id m;
              payload = Value.Scalar (Value.String m);
              merge_key = gw.merge_key;
            })
          step.writes
      in
      (* propose raises invalid_arg for the one shape that could have no effect at all (no writes AND
         no sink) -- that guard is its own tested behavior, not this property's subject, so the
         generated shape is adjusted rather than expected to raise. *)
      let materialize = if step.with_materialize || writes = [] then Some sink else None in
      Batch_commit.propose handle ~idempotency_key:key ?materialize writes;
      if writes <> [] && not (Hashtbl.mem keys_in_log key) then
        if List.for_all (fun (gw : generated_write) -> gw.allowed) step.writes then begin
          Hashtbl.add keys_in_log key ();
          must_be_committed :=
            List.mapi
              (fun write_index (gw : generated_write) ->
                marker ~step_index ~write_index ~allowed:gw.allowed)
              step.writes
            @ !must_be_committed
        end)
    program;
  (replica, !materialized, !must_be_committed)

let committed_markers replica =
  List.filter_map
    (fun (e : Envelope.envelope) ->
      match e.payload with
      | Value.Scalar (Value.String s) -> Some s
      (* The synthetic authorization-decision write's own payload is a Record, not a Scalar String,
         so it is skipped here rather than mistaken for a generated write's marker. *)
      | _ -> None)
    (Batch_commit.committed_envelopes replica)

let no_denied_write_ever_reaches_the_log =
  QCheck2.Test.make
    ~name:
      "no write a policy denied ever reaches committed_envelopes or a materialize sink, under any \
       generated sequence of propose calls"
    ~count:200 ~print:print_program program_gen (fun program ->
      let replica, materialized, must_be_committed = run_program program in
      let committed = committed_markers replica in
      (match List.filter is_denied_marker committed with
      | [] -> ()
      | leaked ->
        QCheck2.Test.fail_reportf
          "a DENIED write reached the replicated log: %s@.program: %s@.committed: %s"
          (String.concat ", " leaked) (print_program program) (String.concat ", " committed));
      let materialized_denied =
        List.filter_map
          (fun v ->
            match v with
            | Value.Scalar (Value.String s) when is_denied_marker s -> Some s
            | _ -> None)
          materialized
      in
      (match materialized_denied with
      | [] -> ()
      | leaked ->
        QCheck2.Test.fail_reportf "a DENIED write reached a materialize sink: %s@.program: %s"
          (String.concat ", " leaked) (print_program program));
      (* The non-vacuity half, in the same property rather than a separate test: every batch that
         SHOULD have committed did. Without this, an implementation that denied everything (or
         proposed nothing at all) would pass the two checks above. *)
      (match List.filter (fun m -> not (List.mem m committed)) must_be_committed with
      | [] -> ()
      | missing ->
        QCheck2.Test.fail_reportf
          "an ALLOWED batch that should have committed did not: %s@.program: %s@.committed: %s"
          (String.concat ", " missing) (print_program program) (String.concat ", " committed));
      true)

(* A second, narrower property on the counter itself: the number of whole-batch denials the
   checkpoint reports over one program must equal the number of batches a correct implementation
   would have refused -- proving denials are neither silently dropped nor double-counted (e.g. once
   per denied WRITE rather than once per denied BATCH, which is what the counter's own doc comment
   promises). Shares run_program's own model, run against a fresh delta each time, since
   authorization_denials is a process-lifetime monotonic counter. *)
let denials_are_counted_once_per_refused_batch =
  QCheck2.Test.make
    ~name:"authorization_denials increments exactly once per whole batch the checkpoint refused"
    ~count:100 ~print:print_program program_gen (fun program ->
      let denials_before = Batch_commit.authorization_denials () in
      let _replica, _materialized, _must_be_committed = run_program program in
      let observed = Batch_commit.authorization_denials () - denials_before in
      (* Re-derive the expected count with the same rules the implementation uses: a batch is
         evaluated (and so can be denied) only when it has writes and its key is not already in the
         log. *)
      let keys_used = ref [] in
      let keys_in_log = Hashtbl.create 8 in
      let expected = ref 0 in
      List.iteri
        (fun step_index step ->
          let key =
            match (step.reuse_earlier_key, !keys_used) with
            | true, earlier :: _ -> earlier
            | _ -> Printf.sprintf "fuzz-key-%d" step_index
          in
          if not (List.mem key !keys_used) then keys_used := key :: !keys_used;
          if step.writes <> [] && not (Hashtbl.mem keys_in_log key) then
            if List.for_all (fun (gw : generated_write) -> gw.allowed) step.writes then
              Hashtbl.add keys_in_log key ()
            else incr expected)
        program;
      if observed <> !expected then
        QCheck2.Test.fail_reportf
          "expected %d whole-batch denials, the checkpoint counted %d@.program: %s" !expected
          observed (print_program program);
      true)

let tests =
  [
    QCheck_alcotest.to_alcotest no_denied_write_ever_reaches_the_log;
    QCheck_alcotest.to_alcotest denials_are_counted_once_per_refused_batch;
  ]
