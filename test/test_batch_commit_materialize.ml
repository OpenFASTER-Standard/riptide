(* test/test_batch_commit_materialize.ml -- Task 4 of the lattice-materialization-redaction-
   encryption plan (.superpowers/sdd/2026-09-23-lattice-materialization-redaction-encryption/):
   closes subtask 3.7 (tracked in .taskmaster/tasks/tasks.json) for writes that opt in via a
   [merge_key]. [File_storage]'s bounded ring WAL silently destroys committed data once eviction
   outruns anything that has consumed it -- test_dst_scenarios.ml's own test_ring_capacity_boundary
   already proves the general hazard (a log longer than the ring wedges a 3-replica cluster's view
   change forever, with zero injected faults). This file proves the fix for the scoped case this
   plan closes: a write proposed with [merge_key = Some k] gets folded into the materializer's
   accumulator for [k] SYNCHRONOUSLY, as part of the very [Batch_commit.propose] call that commits
   it -- so by construction, no later WAL eviction can ever destroy content the accumulator hasn't
   already absorbed.

   TOPOLOGY CHOICE, stated explicitly because test_dst_scenarios.ml's own precedent uses a real
   3-replica cluster: this test deliberately uses a SOLO (replica_count = 1, f = 0) replica instead,
   matching test_batch_commit.ml's own established create_solo convention (see that file's own doc
   comment on why: "IsCommitted is vacuously true for every op-number, so Replica.propose commits
   synchronously, with no network/quorum needed at all"). This is not a weaker test of the same
   thing -- it is the PRECISE topology the materialization hook this task adds actually covers: the
   hook is wired into Batch_commit.propose's own call (see batch_commit.ml's [materialize_sink] and
   its use in [propose]), and re-checks [already_committed] immediately after calling the
   underlying [Riptide_vsr.Replica.propose] -- which only ever observes a same-call commit for the
   degenerate f=0 case Replica.propose's own doc comment names as the one exception. A real
   [replica_count >= 3] cluster commits a write later, asynchronously, via [handle_message]
   processing a quorum of Prepare_ok replies -- outside the scope of the hook this task wires in
   (see this task's own report for the full justification). The solo topology is therefore the
   topology under test, not a simplification of it -- and it still uses REAL [File_storage] (real
   ring WAL, real O_DIRECT/O_DSYNC-durable eviction), so (a) below is a genuine, not simulated,
   proof that eviction happened. *)

open Riptide_lattice
open Riptide_storage
open Riptide_vsr
open Riptide_batch_commit

module M = Riptide_materialize.Materializer.Make (Last_write_wins) (File_kv_store)

(* Same codec shape as test_materializer.ml's own worked example (Task 3): Last_write_wins.t
   round-tripped through a Value.value record, then Value.canonical_encode/decode. Reused here
   twice over: once as the materializer's own KV codec (String.t <-> Last_write_wins.t via
   canonical_encode/decode), and once as the [Value.value -> Last_write_wins.t] payload decoder
   [Batch_commit]'s materialize_sink needs (a write's own payload IS the lattice value being
   written, by this test's own convention -- see batch_commit.mli's [materialize_sink] doc comment
   for why this is the caller's job, not something Batch_commit derives on its own). *)
let lww_to_value (w : Last_write_wins.t) =
  Riptide.Value.Record
    [ ("value", w.value); ("timestamp", Riptide.Value.Scalar (Riptide.Value.Int w.timestamp)) ]

let lww_of_value = function
  | Riptide.Value.Record fields ->
    let value = List.assoc "value" fields in
    let timestamp =
      match List.assoc "timestamp" fields with
      | Riptide.Value.Scalar (Riptide.Value.Int i) -> i
      | _ -> invalid_arg "Last_write_wins codec: malformed timestamp field"
    in
    Last_write_wins.{ value; timestamp }
  | _ -> invalid_arg "Last_write_wins codec: expected a Record"

let with_tmp_dir f =
  let dir = Filename.temp_file "riptide_batch_commit_materialize_test" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o700;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () -> f dir)

let fake_event_id name = Riptide.Value.content_hash (Riptide.Value.Scalar (Riptide.Value.String name))

(* Deliberately smaller than [ops_past_ring] below, exactly like test_dst_scenarios.ml's own
   [small_ring]/[ops_past_ring] pair. *)
let ring_capacity = 4
let ops_past_ring = 10

let test_materialized_writes_survive_ring_eviction_that_destroys_the_raw_wal () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun wal_dir ->
      with_tmp_dir (fun kv_dir ->
          Eio.Switch.run @@ fun sw ->
          let file_storage =
            File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity wal_dir
          in
          let replica =
            Replica.create
              ~storage:(Replica.storage_of_module (module File_storage) file_storage)
              ~my_id:1 ~replica_count:1 ~svc_limit:3
              ~send:(fun ~to_:_ (_ : string) -> ())
          in
          let kv = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) kv_dir in
          let materializer =
            M.create ~kv
              ~decode:(fun s -> lww_of_value (Riptide.Value.canonical_decode s))
              ~encode:(fun w -> Riptide.Value.canonical_encode (lww_to_value w))
          in
          let sink : Batch_commit.materialize_sink =
            { write = (fun ~merge_key payload -> M.write materializer ~merge_key (lww_of_value payload)) }
          in
          let merge_key = "the-merge-key" in
          let actor = "actor-1" in
          for i = 1 to ops_past_ring do
            let payload =
              lww_to_value { Last_write_wins.value = Riptide.Value.Scalar (Riptide.Value.String (Printf.sprintf "v%d" i)); timestamp = Int64.of_int i }
            in
            Batch_commit.propose replica ~idempotency_key:(Printf.sprintf "k%d" i) ~materialize:sink
              [
                {
                  Batch_commit.actor;
                  causation = fake_event_id (Printf.sprintf "c%d" i);
                  correlation = fake_event_id (Printf.sprintf "r%d" i);
                  payload;
                  merge_key = Some merge_key;
                };
              ]
          done;

          (* (a) The raw WAL genuinely lost the old entries -- proving eviction really happened,
             not that this test is vacuous. Each propose call commits exactly one batch of one
             write, one op-number at a time (solo replica), so op-number 1 (the very first
             proposed batch) is well outside the most recent [ring_capacity] slots by the time all
             [ops_past_ring] have been proposed. *)
          Alcotest.(check bool) "op-number 1 was evicted by the ring wraparound" true
            (Option.is_none (File_storage.wal_read file_storage ~op_number:1));
          Alcotest.(check bool) "the log genuinely grew past ring_capacity" true
            (Replica.op_number replica > ring_capacity);

          (* (b) Despite that, the materializer's own read for [merge_key] still reflects every
             write, converged -- because each one was folded in synchronously at propose time,
             strictly before any LATER propose call could ever evict its own WAL slot. *)
          let converged = M.read materializer ~merge_key in
          Alcotest.(check int64) "converged to the highest timestamp seen" (Int64.of_int ops_past_ring)
            converged.timestamp;
          (match converged.value with
          | Riptide.Value.Scalar (Riptide.Value.String s) ->
            Alcotest.(check string) "converged to the value written with the highest timestamp"
              (Printf.sprintf "v%d" ops_past_ring) s
          | _ -> Alcotest.fail "unexpected converged value shape")))

(* Crash-then-retry regression test (review finding on the first cut of this task): a batch
   proposed WITHOUT a materialize sink still commits (durable_append + commit_number update
   inside Replica.propose happen regardless of ~materialize) but is never folded into the
   materializer -- exactly the state a process would be in if it crashed between
   Replica.propose's durable commit and a materialize step, on a retry that supplies
   ~materialize for the first time. A correct [propose] must not let its own
   "idempotency_key already committed, skip re-proposing" optimization also skip re-attempting
   materialization: the SAME idempotency_key, re-proposed with a sink this time, must still
   materialize the write, because the sink was never given the chance to run before. *)
let test_materialize_fires_on_a_later_retry_for_an_already_committed_batch () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun wal_dir ->
      with_tmp_dir (fun kv_dir ->
          Eio.Switch.run @@ fun sw ->
          let file_storage =
            File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity wal_dir
          in
          let replica =
            Replica.create
              ~storage:(Replica.storage_of_module (module File_storage) file_storage)
              ~my_id:1 ~replica_count:1 ~svc_limit:3
              ~send:(fun ~to_:_ (_ : string) -> ())
          in
          let kv = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) kv_dir in
          let materializer =
            M.create ~kv
              ~decode:(fun s -> lww_of_value (Riptide.Value.canonical_decode s))
              ~encode:(fun w -> Riptide.Value.canonical_encode (lww_to_value w))
          in
          let sink : Batch_commit.materialize_sink =
            { write = (fun ~merge_key payload -> M.write materializer ~merge_key (lww_of_value payload)) }
          in
          let merge_key = "retry-merge-key" in
          let idempotency_key = "retry-key-1" in
          let actor = "actor-1" in
          let payload =
            lww_to_value
              { Last_write_wins.value = Riptide.Value.Scalar (Riptide.Value.String "only-value");
                timestamp = 1L
              }
          in
          let write =
            {
              Batch_commit.actor;
              causation = fake_event_id "c1";
              correlation = fake_event_id "r1";
              payload;
              merge_key = Some merge_key;
            }
          in

          (* First call: no materialize sink at all -- simulates the state right after a crash
             between Replica.propose's durable commit and a materialize step that never got to
             run. The batch commits (solo replica, so Replica.propose commits synchronously,
             confirmed via committed_envelopes below since already_committed itself isn't
             exposed by this module's .mli) but nothing is materialized yet (confirmed via
             M.read returning Last_write_wins.bottom, its documented "never written" sentinel). *)
          Batch_commit.propose replica ~idempotency_key [ write ];
          Alcotest.(check int) "batch committed on the first (sink-less) call" 1
            (List.length (Batch_commit.committed_envelopes replica));
          Alcotest.(check int64) "nothing materialized yet for merge_key (still Last_write_wins.bottom)"
            Last_write_wins.bottom.timestamp (M.read materializer ~merge_key).timestamp;

          (* Second call: SAME idempotency_key and writes, now WITH a sink -- the crash-then-retry
             case. The "already committed" check makes this call skip re-proposing to VSR, but
             materialization must still fire, because this is the first call that ever supplied a
             sink for a batch that was already committed. *)
          Batch_commit.propose replica ~idempotency_key ~materialize:sink [ write ];
          Alcotest.(check int) "still exactly one committed batch -- the retry did not double-propose"
            1 (List.length (Batch_commit.committed_envelopes replica));
          let converged = M.read materializer ~merge_key in
          Alcotest.(check bool) "materialize fired on the retry call for an already-committed batch"
            true
            (converged.timestamp <> Last_write_wins.bottom.timestamp);
          Alcotest.(check int64) "converged to the retried write's timestamp" 1L converged.timestamp))

let tests =
  [
    ( "a write's own merge_key survives WAL ring eviction that genuinely destroys the raw entry",
      `Quick, test_materialized_writes_survive_ring_eviction_that_destroys_the_raw_wal );
    ( "materialize fires on a later retry that supplies a sink for an already-committed batch \
       (crash-then-retry)",
      `Quick, test_materialize_fires_on_a_later_retry_for_an_already_committed_batch );
  ]
