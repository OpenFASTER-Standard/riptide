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
              ~send:(fun ~to_:_ (_ : string) -> ()) ()
          in
          let kv = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"materializer" kv_dir in
          let materializer =
            M.create ~kv ~owner:"materializer"
              ~decode:(fun s -> lww_of_value (Riptide.Value.canonical_decode s))
              ~encode:(fun w -> Riptide.Value.canonical_encode (lww_to_value w))
          in
          let sink : Batch_commit.materialize_sink =
            { write = (fun ~merge_key ~idempotency_key:_ ~position:_ ~actor:_ ~causation:_ ~correlation:_ payload -> M.write materializer ~merge_key (lww_of_value payload)) }
          in
          let merge_key = "the-merge-key" in
          let actor = "actor-1" in
          for i = 1 to ops_past_ring do
            let payload =
              lww_to_value { Last_write_wins.value = Riptide.Value.Scalar (Riptide.Value.String (Printf.sprintf "v%d" i)); timestamp = Int64.of_int i }
            in
            Batch_commit.propose (Batch_commit.create ~replica ~authorize:Batch_commit.allow_all ())
              ~idempotency_key:(Printf.sprintf "k%d" i) ~materialize:sink
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
              ~send:(fun ~to_:_ (_ : string) -> ()) ()
          in
          let kv = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"materializer" kv_dir in
          let materializer =
            M.create ~kv ~owner:"materializer"
              ~decode:(fun s -> lww_of_value (Riptide.Value.canonical_decode s))
              ~encode:(fun w -> Riptide.Value.canonical_encode (lww_to_value w))
          in
          let sink : Batch_commit.materialize_sink =
            { write = (fun ~merge_key ~idempotency_key:_ ~position:_ ~actor:_ ~causation:_ ~correlation:_ payload -> M.write materializer ~merge_key (lww_of_value payload)) }
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
          let h = Batch_commit.create ~replica ~authorize:Batch_commit.allow_all () in
          Batch_commit.propose h ~idempotency_key [ write ];
          (* 1 real write + 1 synthetic authorization-decision write (task-master Task 5,
             subtask 5) -- see test_batch_commit.ml's own dedicated test for that write's shape. *)
          Alcotest.(check int) "batch committed on the first (sink-less) call" 2
            (List.length (Batch_commit.committed_envelopes replica));
          Alcotest.(check int64) "nothing materialized yet for merge_key (still Last_write_wins.bottom)"
            Last_write_wins.bottom.timestamp (M.read materializer ~merge_key).timestamp;

          (* Second call: SAME idempotency_key and writes, now WITH a sink -- the crash-then-retry
             case. The "already committed" check makes this call skip re-proposing to VSR, but
             materialization must still fire, because this is the first call that ever supplied a
             sink for a batch that was already committed. *)
          Batch_commit.propose h ~idempotency_key ~materialize:sink [ write ];
          Alcotest.(check int) "still exactly one committed batch -- the retry did not double-propose"
            2 (List.length (Batch_commit.committed_envelopes replica));
          let converged = M.read materializer ~merge_key in
          Alcotest.(check bool) "materialize fired on the retry call for an already-committed batch"
            true
            (converged.timestamp <> Last_write_wins.bottom.timestamp);
          Alcotest.(check int64) "converged to the retried write's timestamp" 1L converged.timestamp))

(* ---- materialize_up_to / write_at_op_number_has_merge_key (Task 5 of the ring-eviction plan,
   part 3 of subtask 3.7) ----

   These tests don't care about ring eviction at all -- that's this file's EARLIER tests' own
   concern, proven against real File_storage above. What matters here is draining a RANGE of the
   committed log, so a plain volatile (in-memory) replica is the right topology: same
   [replica_count = 1, f = 0] solo convention test_batch_commit.ml's own [create_solo] establishes
   (Replica.propose commits synchronously, no network/quorum needed), just with
   [Replica.volatile_storage ()] instead of a real [File_storage] -- matching create_solo's own
   real, current construction (`Replica.create ~storage:(Replica.volatile_storage ()) ~my_id:1
   ~replica_count:1 ~svc_limit:_ ~send ()`, note the trailing unit). No
   [Replica.for_test_set_view_number] call is needed: create_solo's own precedent proposes
   directly against a freshly-created solo replica with no view-number setup at all, and that
   already works (this file's own two tests above do the same, just via Batch_commit.propose
   rather than Replica.propose directly). *)

let create_solo_volatile () =
  Replica.create ~storage:(Replica.volatile_storage ()) ~my_id:1 ~replica_count:1 ~svc_limit:10
    ~send:(fun ~to_:_ (_ : string) -> ())
    ()

(* Proposes one single-write batch under a fresh idempotency_key, WITHOUT a materialize sink --
   so nothing is drained until materialize_up_to itself does it. Solo replica, so this commits
   synchronously; the returned Batch_commit.write is exactly what was proposed, for tests that
   want to assert against it directly. *)
let propose_one_write replica ~idempotency_key ~merge_key ~timestamp ~value_str =
  let actor = "actor-1" in
  let payload =
    lww_to_value
      { Last_write_wins.value = Riptide.Value.Scalar (Riptide.Value.String value_str);
        timestamp = Int64.of_int timestamp
      }
  in
  let write =
    {
      Batch_commit.actor;
      causation = fake_event_id (idempotency_key ^ "-c");
      correlation = fake_event_id (idempotency_key ^ "-r");
      payload;
      merge_key;
    }
  in
  Batch_commit.propose (Batch_commit.create ~replica ~authorize:Batch_commit.allow_all ()) ~idempotency_key [ write ]

let make_materializer kv_dir env sw =
  let kv = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"materializer" kv_dir in
  M.create ~kv ~owner:"materializer"
    ~decode:(fun s -> lww_of_value (Riptide.Value.canonical_decode s))
    ~encode:(fun w -> Riptide.Value.canonical_encode (lww_to_value w))

let make_sink materializer : Batch_commit.materialize_sink =
  { write = (fun ~merge_key ~idempotency_key:_ ~position:_ ~actor:_ ~causation:_ ~correlation:_ payload -> M.write materializer ~merge_key (lww_of_value payload)) }

let test_materialize_up_to_drains_the_whole_committed_prefix () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun kv_dir ->
      Eio.Switch.run @@ fun sw ->
      let replica = create_solo_volatile () in
      (* 3 batches, 3 distinct idempotency keys, all writes under the SAME merge_key "mk" with
         increasing timestamps -- Last_write_wins's join keeps the highest timestamp, so the
         converged result should be exactly the third write. *)
      propose_one_write replica ~idempotency_key:"k1" ~merge_key:(Some "mk") ~timestamp:1 ~value_str:"v1";
      propose_one_write replica ~idempotency_key:"k2" ~merge_key:(Some "mk") ~timestamp:2 ~value_str:"v2";
      propose_one_write replica ~idempotency_key:"k3" ~merge_key:(Some "mk") ~timestamp:3 ~value_str:"v3";
      (* 3 batches x (1 real write + 1 synthetic authorization-decision write each) = 6 envelopes
         -- task-master Task 5, subtask 5. *)
      Alcotest.(check int) "3 batches committed on the solo replica" 6
        (List.length (Batch_commit.committed_envelopes replica));
      let materializer = make_materializer kv_dir env sw in
      let sink = make_sink materializer in
      (* Nothing materialized yet: materialize_up_to is the only thing draining here, propose was
         called with no ~materialize sink at all. *)
      Alcotest.(check int64) "nothing materialized before materialize_up_to runs"
        Last_write_wins.bottom.timestamp (M.read materializer ~merge_key:"mk").timestamp;
      Batch_commit.materialize_up_to replica ~materialize:sink
        ~through_commit_number:(Replica.commit_number replica);
      let expected : Last_write_wins.t =
        { value = Riptide.Value.Scalar (Riptide.Value.String "v3"); timestamp = 3L }
      in
      Alcotest.(check bool) "the materializer converged to the join of all 3 writes (highest timestamp wins)"
        true
        (M.read materializer ~merge_key:"mk" = expected))

let test_materialize_up_to_is_idempotent () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun kv_dir ->
      Eio.Switch.run @@ fun sw ->
      let replica = create_solo_volatile () in
      propose_one_write replica ~idempotency_key:"k1" ~merge_key:(Some "mk") ~timestamp:1 ~value_str:"v1";
      let materializer = make_materializer kv_dir env sw in
      let sink = make_sink materializer in
      Batch_commit.materialize_up_to replica ~materialize:sink ~through_commit_number:1;
      let once = M.read materializer ~merge_key:"mk" in
      Batch_commit.materialize_up_to replica ~materialize:sink ~through_commit_number:1;
      let twice = M.read materializer ~merge_key:"mk" in
      Alcotest.(check bool) "re-materializing an already-covered range is a safe no-op" true
        (once = twice))

let test_materialize_up_to_respects_the_through_bound () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun kv_dir ->
      Eio.Switch.run @@ fun sw ->
      let replica = create_solo_volatile () in
      propose_one_write replica ~idempotency_key:"k1" ~merge_key:(Some "mk1") ~timestamp:1 ~value_str:"v1";
      propose_one_write replica ~idempotency_key:"k2" ~merge_key:(Some "mk2") ~timestamp:1 ~value_str:"v2";
      let materializer = make_materializer kv_dir env sw in
      let sink = make_sink materializer in
      Batch_commit.materialize_up_to replica ~materialize:sink ~through_commit_number:1;
      Alcotest.(check bool) "only the first batch's key materialized" true
        (M.read materializer ~merge_key:"mk1" <> Last_write_wins.bottom);
      Alcotest.(check bool) "the second batch's key, past the bound, did not" true
        (M.read materializer ~merge_key:"mk2" = Last_write_wins.bottom))

(* Fix-round-1 review finding (Task 5): an EXPLICIT binding constraint of this task was that a
   write with [merge_key = None] must be completely unaffected by materialization -- no prior test
   exercised that for [materialize_up_to] specifically (only [propose]'s own single-key path had
   coverage, via write_of_value's decode tests in test_batch_commit.ml). Uses a recording sink
   rather than a real Materializer: the assertion that matters is which merge_keys the sink's
   [write] was invoked for at all, which a plain ref list answers directly without needing a real
   lattice/KV store. *)
let test_materialize_up_to_skips_writes_with_no_merge_key () =
  Eio_main.run @@ fun _env ->
  let replica = create_solo_volatile () in
  let actor = "actor-1" in
  let payload_of value_str timestamp =
    lww_to_value
      { Last_write_wins.value = Riptide.Value.Scalar (Riptide.Value.String value_str);
        timestamp = Int64.of_int timestamp
      }
  in
  let write_with_key =
    {
      Batch_commit.actor;
      causation = fake_event_id "c-mk";
      correlation = fake_event_id "r-mk";
      payload = payload_of "v-mk" 1;
      merge_key = Some "mk";
    }
  in
  let write_without_key =
    {
      Batch_commit.actor;
      causation = fake_event_id "c-none";
      correlation = fake_event_id "r-none";
      payload = payload_of "v-none" 1;
      merge_key = None;
    }
  in
  (* One batch, one committed entry, carrying BOTH writes -- a mix within the same batch, not two
     separate batches, so a bug that materialized "everything in a committed batch regardless of
     merge_key" would be caught here. *)
  Batch_commit.propose (Batch_commit.create ~replica ~authorize:Batch_commit.allow_all ()) ~idempotency_key:"k-mixed"
    [ write_with_key; write_without_key ];
  Alcotest.(check int) "one batch (op-number) committed" 1 (Replica.commit_number replica);
  (* Both real writes, plus the batch's own synthetic authorization-decision write
     (task-master Task 5, subtask 5) -- which also carries merge_key = None, so it does not
     change the "one materialized key" assertion below. *)
  Alcotest.(check int) "both writes of the batch published as envelopes (envelope publishing is \
                         orthogonal to materialization)" 3
    (List.length (Batch_commit.committed_envelopes replica));
  let materialized_keys = ref [] in
  let sink : Batch_commit.materialize_sink =
    { write = (fun ~merge_key ~idempotency_key:_ ~position:_ ~actor:_ ~causation:_ ~correlation:_ _payload -> materialized_keys := merge_key :: !materialized_keys) }
  in
  Batch_commit.materialize_up_to replica ~materialize:sink
    ~through_commit_number:(Replica.commit_number replica);
  Alcotest.(check (list string))
    "materialize_up_to invoked the sink exactly once, only for the merge_key = Some write" [ "mk" ]
    !materialized_keys

(* Fix-round-1 review finding (Task 5): neither function had a test exercising a malformed/
   non-batch log entry -- mirrors test_batch_commit.ml's own
   test_malformed_committed_entry_is_zero_envelopes, which already establishes that a foreign
   value proposed directly via Replica.propose (bypassing Batch_commit's own encoding entirely)
   must not crash anything reading the log back out. *)
let test_materialize_up_to_and_write_at_op_number_skip_a_malformed_entry () =
  Eio_main.run @@ fun _env ->
  let replica = create_solo_volatile () in
  Replica.propose replica (Riptide.Value.Scalar (Riptide.Value.String "not-a-batch"));
  Alcotest.(check int) "the malformed value contributes zero envelopes" 0
    (List.length (Batch_commit.committed_envelopes replica));
  let materialized_keys = ref [] in
  let sink : Batch_commit.materialize_sink =
    { write = (fun ~merge_key ~idempotency_key:_ ~position:_ ~actor:_ ~causation:_ ~correlation:_ _payload -> materialized_keys := merge_key :: !materialized_keys) }
  in
  Batch_commit.materialize_up_to replica ~materialize:sink
    ~through_commit_number:(Replica.commit_number replica);
  Alcotest.(check (list string)) "materialize_up_to materializes nothing for a malformed entry" []
    !materialized_keys;
  Alcotest.(check bool) "write_at_op_number_has_merge_key is false for a malformed entry" false
    (Batch_commit.write_at_op_number_has_merge_key replica ~op_number:1)

(* write_at_op_number_has_merge_key: Task 6's own [?may_evict] predicate's second half. The
   false-for-out-of-bounds behaviour is explicitly load-bearing per this task's own brief, so it's
   tested directly here rather than only documented in the .mli. *)
let test_write_at_op_number_has_merge_key_true_and_false_within_bounds () =
  Eio_main.run @@ fun _env ->
  let replica = create_solo_volatile () in
  propose_one_write replica ~idempotency_key:"k1" ~merge_key:(Some "mk") ~timestamp:1 ~value_str:"v1";
  propose_one_write replica ~idempotency_key:"k2" ~merge_key:None ~timestamp:2 ~value_str:"v2";
  Alcotest.(check bool) "op-number 1 (merge_key = Some _) is true" true
    (Batch_commit.write_at_op_number_has_merge_key replica ~op_number:1);
  Alcotest.(check bool) "op-number 2 (merge_key = None) is false" false
    (Batch_commit.write_at_op_number_has_merge_key replica ~op_number:2)

(* Fix-round-2 review finding (Task 5): every existing test above that exercises
   [materialize_up_to] passes [~through_commit_number:(Replica.commit_number replica)] -- so the
   function's own internal `min through_commit_number (Replica.commit_number t)` clamp (added in
   fix round 1) is never actually exercised; deleting it leaves the whole suite green. Reuses
   test_batch_commit.ml's own [test_uncommitted_tail_is_excluded] harness verbatim (a 3-replica,
   no-Eio, no-transport cluster where backups 2 and 3 silently drop every reply, so the primary
   appends an entry that never reaches the f+1=2 quorum needed to commit) to get a real,
   appended-but-uncommitted op-number 1 with [commit_number = 0], then calls [materialize_up_to]
   with [~through_commit_number:1] -- deliberately >= the appended op-number, i.e. NOT already
   <=[commit_number], since a bound that were would make this test pass regardless of whether the
   clamp exists at all. Only the function's OWN internal clamp against
   [Riptide_vsr.Replica.commit_number] can be what keeps the uncommitted entry out here. *)
let test_materialize_up_to_clamps_to_commit_number_even_when_the_caller_asks_for_more () =
  let replica_count = 3 in
  let replicas = Array.make replica_count None in
  let silent_send ~to_:_ (_ : string) = () in
  (* Only ever installed as replica 1's (the primary's) own [~send] -- see
     test_batch_commit.ml's own identical pattern for why [~sender:1] is real here, not a
     placeholder. *)
  let primary_send ~to_ bytes =
    match replicas.(to_ - 1) with Some r -> Replica.handle_message r ~sender:1 bytes | None -> ()
  in
  replicas.(0) <-
    Some
      (Replica.create ~storage:(Replica.volatile_storage ()) ~my_id:1 ~replica_count ~svc_limit:3
         ~send:primary_send ());
  replicas.(1) <-
    Some
      (Replica.create ~storage:(Replica.volatile_storage ()) ~my_id:2 ~replica_count ~svc_limit:3
         ~send:silent_send ());
  replicas.(2) <-
    Some
      (Replica.create ~storage:(Replica.volatile_storage ()) ~my_id:3 ~replica_count ~svc_limit:3
         ~send:silent_send ());
  List.iter
    (fun opt -> match opt with Some r -> Replica.for_test_set_view_number r 1 | None -> ())
    (Array.to_list replicas);
  let primary = Option.get replicas.(0) in
  let actor = "actor-1" in
  let payload =
    lww_to_value
      { Last_write_wins.value = Riptide.Value.Scalar (Riptide.Value.String "uncommitted-value");
        timestamp = 1L
      }
  in
  Batch_commit.propose (Batch_commit.create ~replica:primary ~authorize:Batch_commit.allow_all ()) ~idempotency_key:"k-never-commits"
    [
      {
        Batch_commit.actor;
        causation = fake_event_id "c-uncommitted";
        correlation = fake_event_id "r-uncommitted";
        payload;
        merge_key = Some "mk-uncommitted";
      };
    ];
  Alcotest.(check int) "the entry is appended to the raw log" 1 (List.length (Replica.entries primary));
  Alcotest.(check int) "but nothing committed -- silent backups never form a quorum" 0
    (Replica.commit_number primary);
  let materialized_keys = ref [] in
  let sink : Batch_commit.materialize_sink =
    { write = (fun ~merge_key ~idempotency_key:_ ~position:_ ~actor:_ ~causation:_ ~correlation:_ _payload -> materialized_keys := merge_key :: !materialized_keys) }
  in
  (* through_commit_number:1 is >= the appended-but-uncommitted op-number (1), deliberately NOT
     <= commit_number (0) -- so a caller-side bound alone would not protect this call; only the
     function's own internal clamp against Replica.commit_number can. *)
  Batch_commit.materialize_up_to primary ~materialize:sink ~through_commit_number:1;
  Alcotest.(check (list string))
    "materialize_up_to must not materialize the uncommitted entry even though through_commit_number \
     itself reaches its op-number -- only the internal commit_number clamp protects this"
    [] !materialized_keys

(* Fix-round-2 review finding (Task 5): no test constructs two committed batches sharing one
   idempotency key, both carrying a merge_key write with different payloads, to prove
   [materialize_up_to]'s own first-wins-per-idempotency-key dedup (the `Hashtbl`-based [seen_keys]
   check added in fix round 1) actually protects the materialized accumulator -- deleting that
   Hashtbl check leaves the whole suite green. Mirrors test_batch_commit.ml's own
   [test_repeated_idempotency_key_with_different_writes_keeps_only_the_first]: uses raw
   [Riptide_vsr.Replica.propose] directly, bypassing [Batch_commit.propose]'s own [already_in_log]
   guard (which would otherwise refuse to append a second batch under a key already in the log),
   to construct a genuine duplicate -- two well-formed, separately committed batches under the SAME
   idempotency_key, each carrying one write under the SAME merge_key but with a different
   [Last_write_wins] timestamp. [Last_write_wins]'s own join always keeps the HIGHER timestamp, so
   if the dedup were removed and both batches' writes reached the sink, the converged read would
   silently flip to the second (higher-timestamp) payload -- observably different from "only the
   first materialized", which is exactly what this test pins. *)
let test_materialize_up_to_dedups_first_wins_per_idempotency_key () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun kv_dir ->
      Eio.Switch.run @@ fun sw ->
      let replica = create_solo_volatile () in
      let key = "dup-key-materialize" in
      let merge_key = "mk-dedup" in
      let make_batch_value payload_value_str timestamp =
        Riptide.Value.Record
          [
            ("idempotency_key", Riptide.Value.Scalar (Riptide.Value.String key));
            ("writes",
              Riptide.Value.Sequence
                [
                  Riptide.Value.Record
                    [
                      ("actor", Riptide.Value.Scalar (Riptide.Value.String "actor-1"));
                      ("causation",
                        Riptide.Value.Scalar (Riptide.Value.Bytes (fake_event_id (payload_value_str ^ "-c"))));
                      ("correlation",
                        Riptide.Value.Scalar (Riptide.Value.Bytes (fake_event_id (payload_value_str ^ "-r"))));
                      ("payload",
                        lww_to_value
                          { Last_write_wins.value = Riptide.Value.Scalar (Riptide.Value.String payload_value_str);
                            timestamp = Int64.of_int timestamp
                          });
                      ("merge_key",
                        Riptide.Value.Sum ("some", Riptide.Value.Scalar (Riptide.Value.String merge_key)));
                    ];
                ]);
          ]
      in
      (* Genuinely different payloads/timestamps under the SAME idempotency key -- via raw
         Replica.propose so Batch_commit.propose's own already_in_log guard never gets a chance to
         refuse the second one. *)
      Replica.propose replica (make_batch_value "first-payload" 1);
      Replica.propose replica (make_batch_value "second-payload-should-be-ignored" 99);
      Alcotest.(check int) "both batches genuinely committed as 2 separate entries" 2
        (Replica.commit_number replica);
      let materializer = make_materializer kv_dir env sw in
      let sink = make_sink materializer in
      Batch_commit.materialize_up_to replica ~materialize:sink
        ~through_commit_number:(Replica.commit_number replica);
      let expected : Last_write_wins.t =
        { value = Riptide.Value.Scalar (Riptide.Value.String "first-payload"); timestamp = 1L }
      in
      Alcotest.(check bool)
        "only the FIRST batch's write materialized -- not the second, and not a join of both (which \
         Last_write_wins's own join would resolve to the higher, second timestamp)"
        true
        (M.read materializer ~merge_key = expected))

let test_write_at_op_number_has_merge_key_false_out_of_bounds () =
  Eio_main.run @@ fun _env ->
  let replica = create_solo_volatile () in
  propose_one_write replica ~idempotency_key:"k1" ~merge_key:(Some "mk") ~timestamp:1 ~value_str:"v1";
  Alcotest.(check bool) "op-number 0 is false (never a valid op-number)" false
    (Batch_commit.write_at_op_number_has_merge_key replica ~op_number:0);
  Alcotest.(check bool) "a negative op-number is false" false
    (Batch_commit.write_at_op_number_has_merge_key replica ~op_number:(-1));
  Alcotest.(check bool) "an op-number past the end of the log is false" false
    (Batch_commit.write_at_op_number_has_merge_key replica ~op_number:2)

(* ---- Task 21 (audit-remediation): a poisoned write must not abort materialization of every
   OTHER write in its own batch (propose) or every LATER batch (materialize_up_to's replay) --
   see .superpowers/sdd/2026-09-29-audit-remediation/task-21-brief.md.

   Reproduces Materializer.write's own documented (materializer.mli's WARNING) failure shape
   directly and simply: a single oversized payload, whose LWW-record encoding alone already
   exceeds File_kv_store's 4096-byte max_value_size, raises Invalid_argument on the very FIRST
   write to its merge_key -- no need for test_lattice_materialize_crypto_scenarios.ml's own
   400-iteration accumulation approach, since one write here already overflows. *)
let oversized_value_str = String.make 4200 'x'

let poison_write ~merge_key =
  {
    Batch_commit.actor = "actor-1";
    causation = fake_event_id (merge_key ^ "-poison-c");
    correlation = fake_event_id (merge_key ^ "-poison-r");
    payload =
      lww_to_value
        { Last_write_wins.value = Riptide.Value.Scalar (Riptide.Value.String oversized_value_str);
          timestamp = 1L
        };
    merge_key = Some merge_key;
  }

let small_write ~merge_key ~value_str =
  {
    Batch_commit.actor = "actor-1";
    causation = fake_event_id (merge_key ^ "-small-c");
    correlation = fake_event_id (merge_key ^ "-small-r");
    payload =
      lww_to_value
        { Last_write_wins.value = Riptide.Value.Scalar (Riptide.Value.String value_str); timestamp = 1L };
    merge_key = Some merge_key;
  }

(* Tolerates today's pre-fix behaviour (Materializer.write's overflow exception propagating
   straight out of propose/materialize_up_to) without asserting on it either way -- this test's
   whole point is what happens to the OTHER write/batch afterwards, not whether the call itself
   raises. Post-fix, neither loop ever raises for this documented failure shape at all, so this
   becomes a no-op try around a call that always returns normally.

   Catches {!Riptide_materialize.Materializer.Value_too_large} specifically, matching
   [materialize_write_catching]'s own narrowed catch (Task 21 review fix round 1, Important 2) --
   {b not} a blanket [Invalid_argument]: this helper exists only to tolerate the one documented,
   pre-fix escape shape, and a genuinely different [Invalid_argument] (e.g. a real bug elsewhere in
   the call chain) must still fail this test loudly rather than being silently swallowed here too. *)
let tolerating_the_known_overflow_exception f =
  try f () with Riptide_materialize.Materializer.Value_too_large _ -> ()

let test_one_oversized_write_in_a_batch_does_not_block_sibling_materialization () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun kv_dir ->
      Eio.Switch.run @@ fun sw ->
      let replica = create_solo_volatile () in
      let materializer = make_materializer kv_dir env sw in
      let sink = make_sink materializer in
      let failures_before = Batch_commit.materialize_write_failures () in
      (* poison-mk deliberately listed FIRST: pre-fix, [List.iter] aborts on the first raise, so
         placing the poisoned write ahead of the sibling in the very same batch is exactly the
         shape that proves the sibling was never even attempted before this fix. *)
      tolerating_the_known_overflow_exception (fun () ->
          Batch_commit.propose (Batch_commit.create ~replica ~authorize:Batch_commit.allow_all ()) ~idempotency_key:"k-mixed-batch" ~materialize:sink
            [ poison_write ~merge_key:"poison-mk"; small_write ~merge_key:"sibling-mk" ~value_str:"sibling-value" ]);
      let sibling = M.read materializer ~merge_key:"sibling-mk" in
      Alcotest.(check bool) "the sibling key materialized despite the other write's overflow" true
        (sibling <> Last_write_wins.bottom);
      Alcotest.(check bool) "the poisoned write was counted as a materialize failure, not silently \
                             dropped uncounted"
        true
        (Batch_commit.materialize_write_failures () > failures_before))

let test_restart_replay_does_not_permanently_stop_after_one_poisoned_key () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun kv_dir ->
      Eio.Switch.run @@ fun sw ->
      let replica = create_solo_volatile () in
      (* No ~materialize sink on either propose call -- nothing is materialized synchronously.
         Everything below is drained by materialize_up_to alone, against a brand-new (empty)
         materializer, simulating a fresh replica restart re-materializing from the committed log
         with no watermark state of its own. *)
      propose_one_write replica ~idempotency_key:"k-poison" ~merge_key:(Some "poison-mk") ~timestamp:1
        ~value_str:oversized_value_str;
      propose_one_write replica ~idempotency_key:"k-late" ~merge_key:(Some "late-mk") ~timestamp:2
        ~value_str:"late-value";
      Alcotest.(check int) "both batches committed" 2 (Replica.commit_number replica);
      let materializer = make_materializer kv_dir env sw in
      let sink = make_sink materializer in
      let failures_before = Batch_commit.materialize_write_failures () in
      tolerating_the_known_overflow_exception (fun () ->
          Batch_commit.materialize_up_to replica ~materialize:sink
            ~through_commit_number:(Replica.commit_number replica));
      let late = M.read materializer ~merge_key:"late-mk" in
      Alcotest.(check bool) "a later, unrelated key materialized despite the earlier poison" true
        (late <> Last_write_wins.bottom);
      Alcotest.(check bool) "the poisoned write was counted as a materialize failure, not silently \
                             dropped uncounted"
        true
        (Batch_commit.materialize_write_failures () > failures_before))

(* Minor 1 (Task 21 review fix round 1): the test above only ever exercised materialize_up_to's
   OUTER loop continuing past a poisoned BATCH (one write per batch, across two batches) -- it
   never proved materialize_up_to's own INNER loop (the one over a single batch's own writes)
   continues past a poisoned WRITE to a SIBLING write in that SAME batch, the shape
   test_one_oversized_write_in_a_batch_does_not_block_sibling_materialization above already proves
   for [propose]'s materialize step. Deleting materialize_write_catching's use inside
   materialize_up_to's own inner [List.iter] (while leaving it in propose's) would leave every
   existing materialize_up_to test green, since none of them puts two merge_key writes in one
   batch. This closes that gap directly. *)
let test_materialize_up_to_continues_to_a_sibling_write_within_the_same_poisoned_batch () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun kv_dir ->
      Eio.Switch.run @@ fun sw ->
      let replica = create_solo_volatile () in
      (* One batch, two writes, no ~materialize sink -- nothing materialized synchronously;
         materialize_up_to alone drains it below, against a fresh materializer. *)
      Batch_commit.propose (Batch_commit.create ~replica ~authorize:Batch_commit.allow_all ()) ~idempotency_key:"k-mixed-batch-replay"
        [ poison_write ~merge_key:"poison-mk2"; small_write ~merge_key:"sibling-mk2" ~value_str:"sibling-value2" ];
      Alcotest.(check int) "one batch (op-number) committed" 1 (Replica.commit_number replica);
      let materializer = make_materializer kv_dir env sw in
      let sink = make_sink materializer in
      let failures_before = Batch_commit.materialize_write_failures () in
      tolerating_the_known_overflow_exception (fun () ->
          Batch_commit.materialize_up_to replica ~materialize:sink
            ~through_commit_number:(Replica.commit_number replica));
      let sibling = M.read materializer ~merge_key:"sibling-mk2" in
      Alcotest.(check bool)
        "the sibling write in the SAME poisoned batch still materialized via materialize_up_to's \
         own inner loop"
        true (sibling <> Last_write_wins.bottom);
      Alcotest.(check bool) "the poisoned write was counted as a materialize failure" true
        (Batch_commit.materialize_write_failures () > failures_before))

(* ---- Durable materialization watermark, via [Batch_commit.deduplicate] (Task 1 of the Layer
   0/Layer 2 boundary revision, task-master Task 7 -- see
   docs/superpowers/specs/2026-10-01-layer2-boundary-revision-design.md, which is checked in; moved
   onto [deduplicate] by Task 4's own review, Critical 1, commit b4217a3) ----

   Closes Task 6's own boundary friction item 1 (final whole-branch review finding I9): wrapping a
   sink in [Batch_commit.deduplicate ~watermark_store] makes a repeated materialize of the same
   committed write apply AT MOST ONCE, for a sink of ANY shape -- not merely a pure lattice join.

   {b These four tests originally drove [create]'s own [?materialize_watermark_store] and
   [materialize_up_to]'s own [?watermark_store]; both parameters are GONE} (Task 4's review,
   Critical 1 -- a gate [propose]/[materialize_up_to] applied internally necessarily wrapped the
   whole composed sink, including [Reactor.wrap_materialize_sink]'s guest dispatch, which destroyed
   the recovery path for a view-change-discarded batch). Same scenarios, same assertions, same
   mechanism; what changed is only that the watermark is now composed around the sink by the caller
   and the RESULT is what gets passed as [~materialize]. See [batch_commit.mli]'s [deduplicate].

   These use a plain counting sink (a [ref] incremented on every [write] call) rather than a
   real [Materializer], deliberately: the property under test is "how many times was [write]
   called", which a counter answers directly without needing a real lattice/KV accumulator to read
   back. *)

let counting_sink (counter : int ref) : Batch_commit.materialize_sink =
  { write = (fun ~merge_key:_ ~idempotency_key:_ ~position:_ ~actor:_ ~causation:_ ~correlation:_ _payload -> incr counter) }

let make_write ~merge_key ~tag : Batch_commit.write =
  {
    Batch_commit.actor = "actor-1";
    causation = fake_event_id (tag ^ "-c");
    correlation = fake_event_id (tag ^ "-r");
    payload = Riptide.Value.Scalar (Riptide.Value.String ("payload-" ^ tag));
    merge_key;
  }

let test_watermark_makes_repeated_materialize_exactly_once () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun watermark_dir ->
      Eio.Switch.run @@ fun sw ->
      let replica = create_solo_volatile () in
      let watermark_store = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"watermark" watermark_dir in
      let counter = ref 0 in
      let sink = Batch_commit.deduplicate ~watermark_store (counting_sink counter) in
      let h = Batch_commit.create ~replica ~authorize:Batch_commit.allow_all () in
      let write = make_write ~merge_key:(Some "mk") ~tag:"wm1" in
      Batch_commit.propose h ~idempotency_key:"wm-key-1" ~materialize:sink [ write ];
      Alcotest.(check int) "materialized once on the proposing call" 1 !counter;
      (* The documented empty-[writes] drain idiom: same idempotency_key, same sink, same store. *)
      Batch_commit.propose h ~idempotency_key:"wm-key-1" ~materialize:sink [];
      Alcotest.(check int) "the watermark makes the repeated drain a no-op -- not materialized twice" 1 !counter)

let test_materialize_up_to_deduplicated_is_exactly_once_across_two_calls () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun watermark_dir ->
      Eio.Switch.run @@ fun sw ->
      let replica = create_solo_volatile () in
      let watermark_store = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"watermark" watermark_dir in
      propose_one_write replica ~idempotency_key:"k1" ~merge_key:(Some "mk1") ~timestamp:1 ~value_str:"v1";
      propose_one_write replica ~idempotency_key:"k2" ~merge_key:(Some "mk2") ~timestamp:1 ~value_str:"v2";
      let counter = ref 0 in
      let sink = Batch_commit.deduplicate ~watermark_store (counting_sink counter) in
      (* Overlapping ranges: the first call covers op 1, the second covers ops 1-2. *)
      Batch_commit.materialize_up_to replica ~materialize:sink ~through_commit_number:1;
      Batch_commit.materialize_up_to replica ~materialize:sink ~through_commit_number:2;
      Alcotest.(check int)
        "exactly the 2 distinct merge_key-carrying writes materialized, not double-counted on the \
         overlap"
        2 !counter)

let test_no_watermark_store_preserves_todays_double_apply () =
  Eio_main.run @@ fun _env ->
  let replica = create_solo_volatile () in
  let counter = ref 0 in
  (* [deduplicate] with NO store, exercising its documented transparent-pass-through contract --
     which is also what every pre-Task-1 call site gets by simply not wrapping at all. Written as an
     explicit [deduplicate] call rather than a bare sink precisely so the pass-through claim in
     [batch_commit.mli] is a tested fact rather than an assertion about a code path nothing runs. *)
  let sink = Batch_commit.deduplicate (counting_sink counter) in
  let h = Batch_commit.create ~replica ~authorize:Batch_commit.allow_all () in
  let write = make_write ~merge_key:(Some "mk") ~tag:"wm2" in
  Batch_commit.propose h ~idempotency_key:"wm-key-2" ~materialize:sink [ write ];
  Batch_commit.propose h ~idempotency_key:"wm-key-2" ~materialize:sink [];
  Alcotest.(check int)
    "without a watermark store, the drain idiom double-applies exactly as before this mechanism \
     existed"
    2 !counter

(* ── Watermark-key injectivity: the genuinely ambiguous naive scheme, and inputs that really do
   collide under it ───────────────────────────────────────────────────────────────────────────────
   Rewritten by the final whole-branch review's IMP-5. The previous version of the test below
   proposed ["key-a"]/["key-b"], both at position 0, and its own comment named a delimiter-joined
   [idempotency_key ^ "|" ^ string_of_int position] as the non-injective scheme it was ruling out.
   Those inputs cannot collide under that scheme (or under any derivation that includes the
   idempotency key at all), so the test could only ever prove that two distinct keys are two distinct
   keys -- it could not fail for the reason it claimed, and nothing else covered the property.

   Worse, the named counterexample scheme was not even a counterexample. A separator-joined
   [ik ^ "|" ^ string_of_int pos] is INJECTIVE: if two pairs produced the same string, the two "|"
   -prefixed decimal suffixes would both be suffixes of it, so the longer would have to contain the
   shorter -- i.e. a [string_of_int] output would have to contain a "|", which it never does. No
   inputs whatsoever could have exercised it.

   The scheme that genuinely IS ambiguous, and therefore the real mistake the length prefix in
   [redaction_event_id] defends against, is separator-free concatenation: with no delimiter at all,
   the boundary between an opaque key's trailing digits and the position's own digits is lost.
   Defined here as real code rather than described in prose, so the inputs below are PROVEN to
   exercise the collision class instead of merely asserted to -- which is exactly what the old
   version of this test failed to do. *)
let naive_watermark_key ~idempotency_key ~index = idempotency_key ^ string_of_int index

(* ("wm-collide-1", 0) and ("wm-collide-", 10): naive gives "wm-collide-10" for BOTH.
   [redaction_event_id] gives "12:wm-collide-1#0" and "11:wm-collide-#10". *)
let collide_key_a, collide_pos_a = ("wm-collide-1", 0)
let collide_key_b, collide_pos_b = ("wm-collide-", 10)

let test_watermark_key_is_injective_where_a_naive_concatenation_collides () =
  (* Precondition, asserted rather than assumed: these two (key, position) pairs really are a
     collision under the naive scheme. Without this check the test below could silently stop
     exercising the collision class -- the exact defect IMP-5 found. *)
  Alcotest.(check string)
    "the chosen inputs genuinely collide under a separator-free concatenation"
    (naive_watermark_key ~idempotency_key:collide_key_a ~index:collide_pos_a)
    (naive_watermark_key ~idempotency_key:collide_key_b ~index:collide_pos_b);
  (* And the real, length-prefixed derivation tells them apart. *)
  Alcotest.(check bool)
    "redaction_event_id keeps them distinct" true
    (Batch_commit.redaction_event_id ~idempotency_key:collide_key_a ~index:collide_pos_a
    <> Batch_commit.redaction_event_id ~idempotency_key:collide_key_b ~index:collide_pos_b)

let test_watermark_does_not_collide_on_a_naive_concatenation_collision () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun watermark_dir ->
      Eio.Switch.run @@ fun sw ->
      let replica = create_solo_volatile () in
      let watermark_store = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"watermark" watermark_dir in
      let counter = ref 0 in
      let sink = Batch_commit.deduplicate ~watermark_store (counting_sink counter) in
      let h = Batch_commit.create ~replica ~authorize:Batch_commit.allow_all () in
      (* Batch A: one materializing write, at position 0, under [collide_key_a]. *)
      Batch_commit.propose h ~idempotency_key:collide_key_a ~materialize:sink
        [ make_write ~merge_key:(Some "mk-a") ~tag:"collide-a" ];
      Alcotest.(check int) "batch A's position-0 write applied" 1 !counter;
      (* Batch B: [collide_pos_b] non-materializing writes (merge_key = None, which propose's own
         materialize loop skips while still counting their positions) followed by the materializing
         one, so it lands at exactly position [collide_pos_b] -- the position that collides with
         batch A's under a separator-free concatenation. *)
      let padding =
        List.init collide_pos_b (fun i ->
            make_write ~merge_key:None ~tag:(Printf.sprintf "collide-pad-%d" i))
      in
      Batch_commit.propose h ~idempotency_key:collide_key_b ~materialize:sink
        (padding @ [ make_write ~merge_key:(Some "mk-b") ~tag:"collide-b" ]);
      (* Under the naive scheme batch B's write would find batch A's watermark already present and
         be skipped, leaving this at 1. *)
      Alcotest.(check int)
        "batch B's colliding-under-naive write ALSO applied -- the length prefix keeps the two \
         watermark keys apart"
        2 !counter)

let test_watermark_does_not_collide_across_different_idempotency_keys_same_position () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun watermark_dir ->
      Eio.Switch.run @@ fun sw ->
      let replica = create_solo_volatile () in
      let watermark_store = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"watermark" watermark_dir in
      let counter = ref 0 in
      let sink = Batch_commit.deduplicate ~watermark_store (counting_sink counter) in
      let h = Batch_commit.create ~replica ~authorize:Batch_commit.allow_all () in
      (* Two DIFFERENT idempotency_key batches, each with a single write at position 0 carrying a
         DIFFERENT merge_key. Kept as the plain, weaker baseline it actually is -- that the watermark
         is keyed on the idempotency key at all, not merely on the position -- with the real
         collision class covered by the two tests above. *)
      Batch_commit.propose h ~idempotency_key:"key-a" ~materialize:sink [ make_write ~merge_key:(Some "mk-a") ~tag:"a" ];
      Batch_commit.propose h ~idempotency_key:"key-b" ~materialize:sink [ make_write ~merge_key:(Some "mk-b") ~tag:"b" ];
      Alcotest.(check int) "both batches' own position-0 writes applied -- no cross-key collision" 2 !counter)

(* ── Task 4's own review, Critical 1: WHERE [deduplicate] sits in a composed sink is load-bearing,
   and the whole reason it is a composable wrapper rather than a [create]/[materialize_up_to]
   parameter ──────────────────────────────────────────────────────────────────────────────────────
   A real [materialize_sink] is composed out of layers, and at least one of them carries a side
   effect that MUST keep firing on every replay rather than being deduplicated:
   [Riptide_module.Reactor.wrap_materialize_sink]'s [write] runs its inner sink and then dispatches
   every subscribed guest module, and that re-dispatch is the one and only recovery path a batch a
   VSR view change discarded before it committed has.

   This test is the mechanism in isolation -- a two-line stand-in for the reactor wrapper (bump a
   counter, then call inner), composed BOTH ways around the same [deduplicate] gate -- so the
   ordering rule is pinned by a test that needs no WASM guest, no cluster and no view change to
   state it. [test_ledger_end_to_end.ml] and [test_ledger_dst_load.ml] then prove the same property
   through the real reactor and a real view-change-discarded legs batch respectively.

   It fails against the shape this plan's Task 1 shipped: there, the gate was applied internally by
   [propose] to the WHOLE sink it was handed, which is exactly the "outside" arm below -- 1 effect,
   not 2. *)
let test_deduplicate_only_suppresses_what_it_wraps_not_an_outer_wrappers_side_effect () =
  Eio_main.run @@ fun env ->
  with_tmp_dir (fun watermark_dir ->
      Eio.Switch.run @@ fun sw ->
      let watermark_store = File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"watermark" watermark_dir in
      (* Stand-in for Reactor.wrap_materialize_sink: run the inner sink, THEN perform a side effect
         that has to happen on every single call regardless of whether the inner one did anything.
         Same ordering as the real one (reactor.mli: "calls the wrapped inner sink FIRST"). *)
      let dispatching_wrapper (effects : int ref) (inner : Batch_commit.materialize_sink) :
          Batch_commit.materialize_sink =
        {
          write =
            (fun ~merge_key ~idempotency_key ~position ~actor ~causation ~correlation payload ->
              inner.write ~merge_key ~idempotency_key ~position ~actor ~causation ~correlation payload;
              incr effects);
        }
      in
      let drain_twice sink =
        let replica = create_solo_volatile () in
        let h = Batch_commit.create ~replica ~authorize:Batch_commit.allow_all () in
        Batch_commit.propose h ~idempotency_key:"compose-key" ~materialize:sink
          [ make_write ~merge_key:(Some "mk") ~tag:"compose" ];
        (* The documented empty-[writes] drain idiom -- i.e. a replay of an already-materialized
           committed write, which is precisely what a catch-up/recovery path performs. *)
        Batch_commit.propose h ~idempotency_key:"compose-key" ~materialize:sink []
      in
      (* INSIDE (the correct composition): the gate wraps only the business-logic sink. *)
      let applied_inside = ref 0 and effects_inside = ref 0 in
      drain_twice
        (dispatching_wrapper effects_inside
           (Batch_commit.deduplicate ~watermark_store (counting_sink applied_inside)));
      Alcotest.(check int) "gate INSIDE: the accumulating write applied exactly once" 1 !applied_inside;
      Alcotest.(check int)
        "gate INSIDE: the outer wrapper's own side effect STILL fired on the replay -- this is the \
         re-dispatch a view-change-discarded batch recovers through"
        2 !effects_inside;
      (* OUTSIDE (the broken composition this plan's Task 1 shipped, via an internal gate): the gate
         wraps the dispatch-carrying wrapper too, so the replay reaches neither. *)
      let watermark_store_2 =
        File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:"watermark" (Filename.concat watermark_dir "outer")
      in
      let applied_outside = ref 0 and effects_outside = ref 0 in
      drain_twice
        (Batch_commit.deduplicate ~watermark_store:watermark_store_2
           (dispatching_wrapper effects_outside (counting_sink applied_outside)));
      Alcotest.(check int) "gate OUTSIDE: the accumulating write still applied exactly once" 1
        !applied_outside;
      Alcotest.(check int)
        "gate OUTSIDE: the outer wrapper's side effect was SUPPRESSED on the replay -- the liveness \
         bug Critical 1 reported, pinned here so the ordering rule cannot silently regress"
        1 !effects_outside)

(* ---- committed_writes_for (newly exported; implementation unchanged from before this task) ---- *)

let test_committed_writes_for_returns_none_when_never_committed () =
  Eio_main.run @@ fun _env ->
  let replica = create_solo_volatile () in
  Alcotest.(check bool) "None when the key was never committed" true
    (Option.is_none (Batch_commit.committed_writes_for replica ~idempotency_key:"never-committed"))

let test_committed_writes_for_returns_the_committed_writes () =
  Eio_main.run @@ fun _env ->
  let replica = create_solo_volatile () in
  propose_one_write replica ~idempotency_key:"k1" ~merge_key:(Some "mk") ~timestamp:1 ~value_str:"v1";
  match Batch_commit.committed_writes_for replica ~idempotency_key:"k1" with
  | None -> Alcotest.fail "expected Some writes for a committed key"
  | Some writes ->
    (* 1 real write + 1 synthetic authorization-decision write (task-master Task 5, subtask 5) --
       see test_batch_commit.ml's own dedicated test for that write's shape; propose_one_write goes
       through Batch_commit.propose, which always appends that extra write to a successfully
       proposed batch. *)
    Alcotest.(check int) "the real write plus the synthetic authorization-decision write come back" 2
      (List.length writes);
    Alcotest.(check bool) "the real write (position 0) carries the proposed merge_key" true
      (match writes with { Batch_commit.merge_key = Some "mk"; _ } :: _ -> true | _ -> false)

let test_committed_writes_for_is_first_wins_per_key () =
  Eio_main.run @@ fun _env ->
  let replica = create_solo_volatile () in
  let key = "dup-key-cwf" in
  (* Raw Replica.propose, bypassing Batch_commit.propose's own already_in_log guard, to construct a
     genuine duplicate -- two well-formed, separately committed batches under the SAME
     idempotency_key, mirroring test_materialize_up_to_dedups_first_wins_per_idempotency_key above. *)
  let make_batch_value payload_str =
    Riptide.Value.Record
      [
        ("idempotency_key", Riptide.Value.Scalar (Riptide.Value.String key));
        ("writes",
          Riptide.Value.Sequence
            [
              Riptide.Value.Record
                [
                  ("actor", Riptide.Value.Scalar (Riptide.Value.String "actor-1"));
                  ("causation", Riptide.Value.Scalar (Riptide.Value.Bytes (fake_event_id (payload_str ^ "-c"))));
                  ("correlation", Riptide.Value.Scalar (Riptide.Value.Bytes (fake_event_id (payload_str ^ "-r"))));
                  ("payload", Riptide.Value.Scalar (Riptide.Value.String payload_str));
                  ("merge_key", Riptide.Value.Sum ("none", Riptide.Value.Record []));
                ];
            ]);
      ]
  in
  Replica.propose replica (make_batch_value "first-payload");
  Replica.propose replica (make_batch_value "second-payload-should-be-ignored");
  Alcotest.(check int) "both batches genuinely committed as 2 separate entries" 2 (Replica.commit_number replica);
  match Batch_commit.committed_writes_for replica ~idempotency_key:key with
  | None -> Alcotest.fail "expected Some writes"
  | Some [ w ] -> (
    match w.payload with
    | Riptide.Value.Scalar (Riptide.Value.String s) ->
      Alcotest.(check string) "the FIRST batch's write comes back, not the second" "first-payload" s
    | _ -> Alcotest.fail "unexpected payload shape")
  | Some _ -> Alcotest.fail "expected exactly one write back"

(* Layer 0/Layer 2 boundary revision, Task 3 (spec Decision 2): sink.write must receive the
   committing write's own identity -- idempotency_key, position, actor, causation, correlation --
   not just merge_key/payload. Proposes a real 2-write batch via Batch_commit.propose (which
   always appends a synthetic authorization-decision write at the end -- actor =
   "riptide.module.authz", merge_key = None -- see test_batch_commit.ml's own dedicated test for
   that write's shape); a sink that records every argument it is called with must see EXACTLY the
   two real writes' own identities at positions 0 and 1, and must never be called for the
   synthetic write at all (merge_key = None writes never reach a sink -- Review Focus item 5). *)
let test_sink_write_receives_the_committing_writes_own_identity () =
  Eio_main.run @@ fun _env ->
  let replica = create_solo_volatile () in
  let idempotency_key = "identity-key" in
  let actor = "author-x" in
  let causation0 = fake_event_id "identity-c0" in
  let correlation0 = fake_event_id "identity-r0" in
  let causation1 = fake_event_id "identity-c1" in
  let correlation1 = fake_event_id "identity-r1" in
  let write0 : Batch_commit.write =
    { actor; causation = causation0; correlation = correlation0;
      payload = Riptide.Value.Scalar (Riptide.Value.String "payload-0");
      merge_key = Some "mk0"
    }
  in
  let write1 : Batch_commit.write =
    { actor; causation = causation1; correlation = correlation1;
      payload = Riptide.Value.Scalar (Riptide.Value.String "payload-1");
      merge_key = Some "mk1"
    }
  in
  let calls = ref [] in
  let sink : Batch_commit.materialize_sink =
    { write =
        (fun ~merge_key:_ ~idempotency_key ~position ~actor ~causation ~correlation (_ : Riptide.Value.value) ->
          calls := (idempotency_key, position, actor, causation, correlation) :: !calls)
    }
  in
  Batch_commit.propose
    (Batch_commit.create ~replica ~authorize:Batch_commit.allow_all ())
    ~idempotency_key ~materialize:sink [ write0; write1 ];
  let calls = List.rev !calls in
  Alcotest.(check int) "sink.write was called exactly twice -- never for the synthetic authz write"
    2 (List.length calls);
  (match calls with
  | [ (ik0, pos0, a0, c0, r0); (ik1, pos1, a1, c1, r1) ] ->
    Alcotest.(check string) "position 0's idempotency_key is the batch's own key" idempotency_key ik0;
    Alcotest.(check int) "position 0 is 0" 0 pos0;
    Alcotest.(check string) "position 0's actor is write0's own actor, not the synthetic authz actor" actor a0;
    Alcotest.(check bool) "position 0's causation matches write0's own causation" true
      (String.equal c0 causation0);
    Alcotest.(check bool) "position 0's correlation matches write0's own correlation" true
      (String.equal r0 correlation0);
    Alcotest.(check string) "position 1's idempotency_key is the batch's own key" idempotency_key ik1;
    Alcotest.(check int) "position 1 is 1" 1 pos1;
    Alcotest.(check string) "position 1's actor is write1's own actor, not the synthetic authz actor" actor a1;
    Alcotest.(check bool) "position 1's causation matches write1's own causation" true
      (String.equal c1 causation1);
    Alcotest.(check bool) "position 1's correlation matches write1's own correlation" true
      (String.equal r1 correlation1)
  | _ -> Alcotest.fail "expected exactly two recorded calls")

let tests =
  [
    ( "a write's own merge_key survives WAL ring eviction that genuinely destroys the raw entry",
      `Quick, test_materialized_writes_survive_ring_eviction_that_destroys_the_raw_wal );
    ( "materialize fires on a later retry that supplies a sink for an already-committed batch \
       (crash-then-retry)",
      `Quick, test_materialize_fires_on_a_later_retry_for_an_already_committed_batch );
    ( "materialize_up_to drains the whole committed prefix",
      `Quick, test_materialize_up_to_drains_the_whole_committed_prefix );
    ("materialize_up_to is idempotent over a repeated range", `Quick, test_materialize_up_to_is_idempotent);
    ( "materialize_up_to respects the through_commit_number bound",
      `Quick, test_materialize_up_to_respects_the_through_bound );
    ( "materialize_up_to skips a write with merge_key = None even inside an otherwise-materialized \
       batch",
      `Quick, test_materialize_up_to_skips_writes_with_no_merge_key );
    ( "materialize_up_to and write_at_op_number_has_merge_key both skip a malformed/non-batch entry",
      `Quick, test_materialize_up_to_and_write_at_op_number_skip_a_malformed_entry );
    ( "materialize_up_to clamps to commit_number even when the caller's own through_commit_number \
       asks for more (fix round 2)",
      `Quick, test_materialize_up_to_clamps_to_commit_number_even_when_the_caller_asks_for_more );
    ( "materialize_up_to dedups first-wins per idempotency_key across two committed batches sharing \
       one key (fix round 2)",
      `Quick, test_materialize_up_to_dedups_first_wins_per_idempotency_key );
    ( "write_at_op_number_has_merge_key is true/false correctly within the log's bounds",
      `Quick, test_write_at_op_number_has_merge_key_true_and_false_within_bounds );
    ( "write_at_op_number_has_merge_key is false for any out-of-bounds op-number",
      `Quick, test_write_at_op_number_has_merge_key_false_out_of_bounds );
    ( "one oversized write in a batch does not block materialization of a sibling write in the \
       same batch (Task 21)",
      `Quick, test_one_oversized_write_in_a_batch_does_not_block_sibling_materialization );
    ( "materialize_up_to's restart replay does not permanently stop after one poisoned key -- a \
       later batch still materializes (Task 21)",
      `Quick, test_restart_replay_does_not_permanently_stop_after_one_poisoned_key );
    ( "materialize_up_to's own inner loop continues to a sibling write within the same poisoned \
       batch (Task 21 review fix round 1, Minor 1)",
      `Quick, test_materialize_up_to_continues_to_a_sibling_write_within_the_same_poisoned_batch );
    ( "a deduplicate-wrapped sink makes propose's repeated-drain idiom exactly-once \
       (Task 1, layer2-boundary-revision)",
      `Quick, test_watermark_makes_repeated_materialize_exactly_once );
    ( "a deduplicate-wrapped sink makes materialize_up_to exactly-once across two overlapping calls \
       (Task 1)",
      `Quick, test_materialize_up_to_deduplicated_is_exactly_once_across_two_calls );
    ( "deduplicate with no watermark store is a transparent pass-through, preserving today's \
       double-apply on repeated drain (Task 1, Review Focus item 1)",
      `Quick, test_no_watermark_store_preserves_todays_double_apply );
    ( "the watermark key is injective on a (key, position) pair that a separator-free concatenation \
       collides on (final whole-branch review, IMP-5)",
      `Quick, test_watermark_key_is_injective_where_a_naive_concatenation_collides );
    ( "the watermark applies BOTH writes of a pair that a separator-free concatenation would have \
       collided (final whole-branch review, IMP-5)",
      `Quick, test_watermark_does_not_collide_on_a_naive_concatenation_collision );
    ( "the watermark does not collide across different idempotency_keys sharing the same write \
       position (Task 1, Review Focus item 4)",
      `Quick, test_watermark_does_not_collide_across_different_idempotency_keys_same_position );
    ( "deduplicate suppresses only what it wraps: an OUTER wrapper's own side effect (the reactor's \
       guest dispatch) still fires on a replay (Task 4 review, Critical 1)",
      `Quick, test_deduplicate_only_suppresses_what_it_wraps_not_an_outer_wrappers_side_effect );
    ( "committed_writes_for returns None when the key was never committed",
      `Quick, test_committed_writes_for_returns_none_when_never_committed );
    ("committed_writes_for returns the committed writes", `Quick, test_committed_writes_for_returns_the_committed_writes);
    ( "committed_writes_for is first-wins per idempotency_key",
      `Quick, test_committed_writes_for_is_first_wins_per_key );
    ( "sink.write receives the committing write's own identity, never the synthetic authz write's \
       (Task 3, layer2-boundary-revision)",
      `Quick, test_sink_write_receives_the_committing_writes_own_identity );
  ]
