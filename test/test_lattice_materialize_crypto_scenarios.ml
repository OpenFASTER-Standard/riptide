(* test/test_lattice_materialize_crypto_scenarios.ml

   Task 9 of the lattice-materialization-redaction-encryption plan
   (.superpowers/sdd/2026-09-23-lattice-materialization-redaction-encryption/): the end-to-end
   adversarial proof that Tasks 1-8 actually COMPOSE, modelled on the prior plan's own Task 11
   (test_dst_scenarios.ml) in both spirit and bar -- a real hunt's permanent residue, not a
   scripted checklist.

   It found one real, previously-undetected defect, of exactly the class that motivated the task:
   [Batch_commit.propose]'s materialize step folded the CALLER'S ARGUMENT writes rather than the
   writes that actually COMMITTED under that idempotency key. Both halves of the damage that caused
   are pinned below as regression tests ("materialization is a function of the committed log" and
   "a redacted record's plaintext cannot re-enter the accumulator"), each proven to fail against the
   pre-fix code and pass against the current one; the sweep also catches it independently, on many
   seeds, through its own general safety property. See this task's report for the full account.

   WHAT THIS FILE COMPOSES, and where each piece comes from:
   - Task 1's lattice-law contract: [G_set] below is this scenario's concrete lattice, checked
     against [Lattice_conformance.tests] here rather than assumed -- "converged" is a meaningless
     claim about a type that is not really a join-semilattice.
   - Task 2/3's [File_kv_store] + [Materializer]: one REAL, on-disk materializer per replica.
   - Task 4's [merge_key] threading through [Batch_commit.propose].
   - Task 5/6's [Dek]/[Kek]/[Redaction_store]: real AES-256-GCM envelope encryption, real
     crypto-shredding redaction, real decryption attempts (never keystore-lookup checks).
   - Task 7/8's [Ca]/[Tls_identity]/[Tcp]: a real, mutually-authenticated TLS mesh over real
     loopback sockets, with the raw TCP bytes captured off the wire by a recording proxy.
   - The prior plan's [Fault_injecting_storage]: real WAL corruption and real silent write loss,
     seeded and reproducible.

   TOPOLOGY, and why it is hand-rolled rather than [Riptide_dst.Cluster.run]. Same reason
   test_redaction.ml's own [with_store_and_cluster] gives (see that file): [Cluster.run] drives its
   replicas under [Eio_mock.Backend], which has no real filesystem, and every durable piece this
   task must compose ([File_kv_store] for both the keystore and each materializer, [File_storage]
   for the WAL) is built on [Eio_linux.Low_level]/io_uring and needs [Eio_main]'s real backend. The
   two cannot nest. What is kept is everything that matters here: five REAL [Replica.t]s at
   [replica_count = 5], real encoded Prepare/PrepareOk bytes, a real [f + 1 = 3] quorum, commit
   strictly asynchronous, real seeded storage faults, and real seeded message loss. What is
   replaced is only the fiber-based transport, by a synchronous in-process queue -- every message
   delivered is bytes a real replica actually sent. Because that queue is drained by direct
   [handle_message] calls in the caller's own fiber, a returned call means the handler is finished,
   including its io_uring I/O: test_dst_scenarios.ml's own [inflight] counter exists to solve a
   problem (handlers parked mid-I/O behind [Eio.Fiber.yield]) that this shape does not have.

   WHAT THIS FILE DELIBERATELY DOES NOT DO, stated because the omissions are choices:
   - No view changes and no restarts. Both are exhaustively covered by the prior plan's own Task 11
     over this same [Replica.t] code, and neither is new surface for THIS plan. A view change's one
     genuinely new interaction with this plan's work -- the redaction keystore is primary-local and
     unreplicated, so moving the primary splits one log's DEKs across two machines -- is already
     disclosed in batch_commit.mli's own [propose] doc as a known, out-of-scope limitation;
     exercising it here would reproduce a documented limitation rather than hunt an unknown one
     (the same reasoning test_dst_scenarios.ml gives for leaving wire corruption out of its sweep).
   - It never proposes an encrypted batch through anything but the primary. That is not a
     convenience: batch_commit.mli documents that [?encryption] against a replica that has not yet
     learned of a batch re-encrypts and orphans that record's DEK, and that a caller must therefore
     only ever encrypt through the primary. Violating a documented precondition would produce a
     "finding" that is already written down. *)

open Riptide_batch_commit
open Riptide_crypto
open Riptide_storage
open Riptide_vsr

let () = Mirage_crypto_rng_unix.use_default ()

(* ---------------------------------------------------------------------------------------------
   THIS SCENARIO'S CONCRETE LATTICE: a grow-only set of strings.

   Deliberately NOT [Last_write_wins], the only lattice this repo ships, and the choice is
   load-bearing rather than aesthetic. LWW's join keeps one winner and discards everything else, so
   an accumulator that absorbed an extra, never-committed value would be INVISIBLE to any assertion
   whenever that value lost the timestamp comparison -- precisely the defect this file exists to
   hunt. A G-set's join is union: every value ever folded in stays observable forever, so a missing
   one and an extra one are equally detectable. Defining it here rather than in [lib/] is also
   exactly the arrangement this plan's Decision 1 intends -- the caller owns its lattice,
   [Batch_commit] and [Materializer] never hardcode one.
   --------------------------------------------------------------------------------------------- *)

module G_set : sig
  include Riptide_lattice.Lattice_intf.S

  val of_list : string list -> t
  val elements : t -> string list
  val to_value : t -> Riptide.Value.value
  val of_value : Riptide.Value.value -> t
end = struct
  type t = string list (* sorted, duplicate-free -- the canonical form [join] maintains *)

  let norm l = List.sort_uniq String.compare l
  let bottom = []
  let join a b = norm (a @ b)
  let of_list = norm
  let elements t = t

  let to_value t =
    Riptide.Value.Sequence (List.map (fun s -> Riptide.Value.Scalar (Riptide.Value.String s)) t)

  let of_value = function
    | Riptide.Value.Sequence items ->
      norm
        (List.map
           (function
             | Riptide.Value.Scalar (Riptide.Value.String s) -> s
             | _ -> invalid_arg "G_set.of_value: expected a Sequence of String scalars")
           items)
    | _ -> invalid_arg "G_set.of_value: expected a Sequence"
end

module M = Riptide_materialize.Materializer.Make (G_set) (File_kv_store)

let g_set_arb =
  QCheck.map G_set.of_list
    QCheck.(list_size (Gen.int_range 0 4) (oneof_list [ "a"; "b"; "c"; "d"; "e" ]))

(* ---------------------------------------------------------------------------------------------
   Shared helpers.
   --------------------------------------------------------------------------------------------- *)

let make_tmp_dir prefix =
  let dir = Filename.temp_file prefix "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o700;
  dir

let rm_rf dir = ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)))

let with_tmp_dir f =
  let dir = make_tmp_dir "riptide_task9" in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let fake_event_id name = Riptide.Value.content_hash (Riptide.Value.Scalar (Riptide.Value.String name))

let write_of ?merge_key payload : Batch_commit.write =
  { actor = "actor-1"; causation = fake_event_id "c"; correlation = fake_event_id "r"; payload; merge_key }

let enc_sink store : Batch_commit.encryption_sink =
  { encrypt = (fun ~event_id v -> Redaction_store.encrypt_value store ~event_id v) }

let mat_sink materializer : Batch_commit.materialize_sink =
  { write = (fun ~merge_key payload -> M.write materializer ~merge_key (G_set.of_value payload)) }

let make_materializer ~sw ~fs dir =
  M.create
    ~kv:(File_kv_store.create ~sw ~fs dir)
    ~decode:(fun s -> G_set.of_value (Riptide.Value.canonical_decode s))
    ~encode:(fun g -> Riptide.Value.canonical_encode (G_set.to_value g))

(* The "raw disk read" half of property (d): every byte of every regular file the real durable
   layers actually created, concatenated, for grepping. Read off the filesystem directly, through
   no API of the module that wrote them. *)
let raw_bytes_under dir =
  let buf = Buffer.create 65536 in
  let rec walk d =
    Array.iter
      (fun name ->
        let p = Filename.concat d name in
        if Sys.is_directory p then walk p
        else
          let ic = open_in_bin p in
          Fun.protect
            ~finally:(fun () -> close_in ic)
            (fun () -> Buffer.add_channel buf ic (in_channel_length ic)))
      (Sys.readdir d)
  in
  walk dir;
  Buffer.contents buf

let contains ~needle s =
  try
    ignore (Str.search_forward (Str.regexp_string needle) s 0);
    true
  with Not_found -> false

(* Planted in exactly one ENCRYPTED record's plaintext. Must be recoverable by a real decryption
   while its DEK lives, and must appear in no VSR message, no on-disk byte, and no wire capture --
   the technique test_dek.ml's own [test_ciphertext_is_not_plaintext] established. *)
let crypto_marker = "RIPTIDE-PLAINTEXT-MARKER-4f1c9a2b"

let secret_payload_with marker =
  Riptide.Value.Record
    [ ("ssn", Riptide.Value.Scalar (Riptide.Value.String "123-45-6789"));
      ("note", Riptide.Value.Scalar (Riptide.Value.String marker))
    ]

(* What a decrypted payload actually comes back AS, which is not always the OCaml value that went
   in. [Redaction_store.encrypt_for_storage] encrypts [Value.canonical_encode v] and [decrypt]
   returns [Value.canonical_decode] of it, and canonical form sorts a [Record]'s fields
   alphabetically (lib/value.ml) -- so a payload whose fields were not already in sorted order
   round-trips to a structurally DIFFERENT, logically identical value. Every existing test of this
   path happens to use single-field or non-[Record] payloads, so nothing had surfaced it; asserting
   raw structural equality here produced 184 spurious "decrypted to the WRONG plaintext" reports on
   the first run of this sweep. Comparing against the canonical form is the correct assertion, and
   the round-trip below is itself the check that nothing but field order changed. *)
let canonical v = Riptide.Value.canonical_decode (Riptide.Value.canonical_encode v)

(* ---------------------------------------------------------------------------------------------
   THE COMBINED SWEEP.

   One run = one seed. Five real replicas, real seeded storage faults under every one of them, real
   seeded message loss, and a workload that interleaves all three of this plan's new write-path
   behaviours against each other:

     - materialized writes across several [merge_key]s (Task 4);
     - CLIENT RETRIES of an already-proposed idempotency key, some carrying REGENERATED writes --
       the adversarial ingredient, and the only kind of retry this fire-and-forget layer lets a
       client issue at all (batch_commit.mli's own [propose]);
     - encrypted, individually-redactable records (Task 6) under unrelated keys, some of which get
       genuinely redacted mid-run.

   After every phase, four properties are checked against every replica:

   (a) MATERIALIZED STATE IS A FUNCTION OF THE COMMITTED LOG. For every replica and every
       [merge_key], that replica's accumulator must equal exactly the join of the payloads of the
       committed batches THAT REPLICA holds. One assertion, catching both phantom content (an
       accumulator element that is in no committed batch anywhere -- unauditable, unredactable and
       permanently divergent, since no other replica will ever join it in) and missing content. It
       is also what makes (b) a theorem rather than a coincidence.
   (b) CONVERGENCE. Any two replicas holding the same committed batches hold identical
       accumulators -- checked directly, pairwise, and counted so it can be asserted non-vacuous.
   (c) REDACTION IS REAL AND EXACT. Every redacted record fails a real decryption, from every
       replica's own copy of the ciphertext; every non-redacted record still decrypts, to the exact
       original plaintext.
   (d) NO PLAINTEXT ANYWHERE. [crypto_marker] appears in no byte any replica ever sent, and in no
       byte on disk under the keystore or any materializer directory -- while remaining genuinely
       recoverable through a real decryption, so the check is never vacuous.
   --------------------------------------------------------------------------------------------- *)

type run_result = {
  violations : string list;
  committed_batches : int;
  redactions : int;
  storage_faults_observed : int;  (** committed ops whose own durable WAL slot can no longer be read *)
  messages_dropped : int;
  regenerated_retries : int;
  encrypted_retries : int;
      (** Retries of an already-committed ENCRYPTED batch, which must not re-encrypt (Task 6's own
          guard). Property (c) is what fails if one ever does. *)
  converged_pairs : int;
  marker_decryptions : int;  (** real decryptions that returned the marker -- (d)'s non-vacuity *)
  primary_commit_halted : int;
      (** Runs whose primary ended with [commit_number < op_number]. In this VSR subset that means
          a storage fault landed on the PRIMARY'S OWN slot: [primary_execute_op] refuses to commit
          an op it cannot itself read back (replica.ml's [readable] guard), and with no view change
          in this scenario to repair it, commit stops there for the rest of the run. That case is
          real and is exactly the "a write caught mid-materialization by a fault" question this
          task's brief asks about -- which is why it gets its own deterministic test
          ([test_a_primary_storage_fault_halts_materialization_exactly_with_commit]) rather than
          being left to chance here. In THIS sweep it must be ZERO: the primary is deliberately
          fault-free (see [fault_config_for]), so a non-zero value means that exclusion regressed
          and the sweep is quietly covering far fewer committed batches than it reports. *)
  fault_cap_hits : int;
      (** [Fault_injecting_storage]'s own ["faults_max exceeded"] guard declining to inject more
          corruption, as counted by {!Replica.for_test_append_refusals}'s [fault_injection_cap] --
          which replica.mli itself says is "worth asserting on rather than discovering by
          instrumenting", because a non-zero value means this sweep's EFFECTIVE fault rate is below
          its configured one. *)
}

let zero_result =
  {
    violations = [];
    committed_batches = 0;
    redactions = 0;
    storage_faults_observed = 0;
    messages_dropped = 0;
    regenerated_retries = 0;
    encrypted_retries = 0;
    converged_pairs = 0;
    marker_decryptions = 0;
    primary_commit_halted = 0;
    fault_cap_hits = 0;
  }

let merge_keys = [| "mk-alpha"; "mk-beta"; "mk-gamma" |]
let replica_count = 5
let replication_quorum = ((replica_count - 1) / 2) + 1
(* Deliberately low, and the reason is a real property of the protocol subset this repo implements
   rather than timidity. There is no Commit message in [Riptide_vsr.Message]: a follower learns the
   commit number only piggybacked on the NEXT [Prepare] (VSR.tla's own shape), and a follower that
   misses a [Prepare] cannot be repaired except by a view change's [Start_view] -- which this
   scenario deliberately excludes (see this file's header). So every dropped message here is
   PERMANENT damage to that follower for the rest of the run, unlike in test_dst_scenarios.ml's own
   sweep, whose timeout storms force the view changes that repair exactly this. 0.02 keeps real,
   measured loss in the run (asserted non-zero) while leaving enough replicas caught up for
   convergence to be a meaningful check rather than a vacuous one. Stragglers are expected and are
   not a violation: every property below is phrased against a replica's OWN committed log. *)
let message_drop_probability = 0.02

(* Derived the same way test_dst_scenarios.ml's own [sweep_storage_faults] derives its numbers, and
   kept below them so the configured fault rate is the rate actually delivered. At
   [replica_count = 5] the replication quorum is 3, so [Fault_injecting_storage]'s own cap is
   [faults_max = quorum - 1 = 2] simultaneously-live corrupted slots PER REPLICA, and an append
   whose corrupt decision would reach that cap declines to corrupt (raising its own
   ["faults_max exceeded"], which {!Riptide_vsr.Replica} catches and counts as
   [fault_injection_cap] rather than propagating -- see replica.mli's [for_test_append_refusals]).
   Nothing in this scenario truncates the WAL, so a replica's corrupted slots stay live for the
   whole run: the cap is a budget over the run, not an instantaneous one. 0.05 over the ~15 appends
   a replica sees here leaves that budget unspent, which [fault_cap_hits] asserts directly rather
   than assuming -- a sweep quietly running at a lower effective fault rate than it claims is
   exactly the kind of vacuity this file is supposed to rule out. *)
let storage_faults : Fault_injecting_storage.fault_config =
  { corrupt_probability = 0.05; drop_probability = 0.05; superblock_loss_probability = 0.0 }

(* Injected into every replica EXCEPT the primary, and that exclusion is a deliberate, measured
   scope decision rather than a softening. In this VSR subset [primary_execute_op] refuses to
   commit an op the primary cannot itself read back (replica.ml's own [readable] guard, correctly
   -- counting itself toward [f + 1] while its own copy is unreadable would let a cluster commit
   with only [f] readable copies), and with no view change in this scenario to repair it, ONE fault
   on the primary's own slot stops commit for the entire remainder of that run. Measured, with
   faults on all five replicas at 0.03: the primary halted in 8 of 12 seeds, most of them within
   the first two ops, so the sweep was mostly measuring "the run stopped early" rather than how
   materialization, redaction and replication compose over many committed batches.

   The case is not dropped -- it is moved somewhere it can be tested PRECISELY instead of by luck:
   [test_a_primary_storage_fault_halts_materialization_exactly_with_commit] below injects it
   deterministically at a chosen op via [Fault_injecting_storage.for_test_corrupt_entry] and
   asserts the property that actually matters (materialized state stops exactly where commit
   stopped, neither short of it nor past it). Here, every replica in every quorum can still be a
   genuinely faulty one -- a follower that silently loses a write it acknowledged, or reads back
   corruption -- which is what these faults are for. *)
let fault_config_for ~index =
  if index = 0 then Fault_injecting_storage.default_fault_config else storage_faults

let run_scenario ~env ~sw ~seed ~phases ~make_fault_storage =
  let fs = Eio.Stdenv.fs env in
  let prng = Riptide_sim.Prng.create seed in
  let result = ref zero_result in
  let note fmt =
    Printf.ksprintf (fun s -> result := { !result with violations = s :: !result.violations }) fmt
  in
  let keystore_dir = make_tmp_dir "riptide_task9_keystore" in
  let mat_dirs = Array.init replica_count (fun _ -> make_tmp_dir "riptide_task9_mat") in
  Fun.protect
    ~finally:(fun () ->
      rm_rf keystore_dir;
      Array.iter rm_rf mat_dirs)
  @@ fun () ->
  let store =
    Redaction_store.create
      ~kv:(File_kv_store.create ~sw ~fs keystore_dir)
      ~kek:(Kek.of_raw (Mirage_crypto_rng.generate 32))
  in
  (* One real, independent, on-disk materializer per replica -- (a) and (b) are meaningless against
     a single shared one. *)
  let materializers = Array.map (fun d -> make_materializer ~sw ~fs d) mat_dirs in
  (* Every byte any replica ever hands to the transport: real encoded VSR messages carrying real
     committed batch values. The application-level half of (d). *)
  let sent_bytes = Buffer.create 65536 in
  let inflight : (int * string) Queue.t = Queue.create () in
  let replicas =
    Array.init replica_count (fun i ->
        let storage =
          Replica.storage_of_module
            (module Fault_injecting_storage)
            (make_fault_storage ~index:i ~prng:(Riptide_sim.Prng.create ((seed * 1000) + i)))
        in
        Replica.create ~storage ~my_id:(i + 1) ~replica_count ~svc_limit:3 ~send:(fun ~to_ bytes ->
            Buffer.add_string sent_bytes bytes;
            Queue.add (to_, bytes) inflight))
  in
  (* Same pin, for the same reason, as every cluster harness in this repo (see
     test_redaction.ml's own [with_store_and_cluster]): at view 0 the primary would be
     [replica_count], so [replicas.(0)] would not be primary and every propose against it would be
     a silent no-op. [Primary(1) = 1] for any replica_count, and all replicas must share a view or
     they reject each other's messages outright. *)
  Array.iter (fun r -> Replica.for_test_set_view_number r 1) replicas;
  let primary = replicas.(0) in

  let deliver ~drop_probability =
    while not (Queue.is_empty inflight) do
      let to_, bytes = Queue.pop inflight in
      if Riptide_sim.Prng.bool prng drop_probability then
        result := { !result with messages_dropped = !result.messages_dropped + 1 }
      else Replica.handle_message replicas.(to_ - 1) bytes
    done
  in

  (* The materialized batches this run has proposed, in order, each paired with the writes of its
     FIRST proposal -- which is necessarily the batch that committed, since [propose] never appends
     a second batch under a key already in the log. This is the expectation (a) is checked against,
     derived from the workload rather than from the code under test. *)
  let history : (string * Batch_commit.write list) list ref = ref [] in
  (* Encrypted records: keystore event_id -> the exact plaintext that was encrypted. *)
  let secrets : (string * Riptide.Value.value) list ref = ref [] in
  let redacted : (string, unit) Hashtbl.t = Hashtbl.create 8 in

  (* Which of this run's batches a given replica holds COMMITTED, asked through the same public
     read path a real consumer would use. A batch under [key] is committed exactly when its first
     write's own keystore event_id appears among the committed envelopes. *)
  let committed_keys r =
    let keyed = Batch_commit.committed_envelopes_keyed r in
    List.filter
      (fun (key, _) ->
        List.mem_assoc (Batch_commit.redaction_event_id ~idempotency_key:key ~index:0) keyed)
      !history
    |> List.map fst
  in
  let expected_accumulator ~committed ~merge_key =
    List.fold_left
      (fun acc (key, writes) ->
        if not (List.mem key committed) then acc
        else
          List.fold_left
            (fun acc (w : Batch_commit.write) ->
              if w.merge_key = Some merge_key then G_set.join acc (G_set.of_value w.payload) else acc)
            acc writes)
      G_set.bottom !history
  in
  (* Every replica materializes from ITS OWN commit stream. Passing the writes (rather than the
     empty list the .mli also permits) is what a real client retry looks like, and post-fix they
     are ignored for materialization anyway -- which is the whole point. Against a replica that has
     not yet learned of the batch this is doubly inert: [Replica.propose] is a documented no-op off
     the primary. *)
  let drained : (int * string, unit) Hashtbl.t = Hashtbl.create 64 in
  let drain ~redrain_everything =
    Array.iteri
      (fun i r ->
        List.iter
          (fun (key, writes) ->
            if redrain_everything || not (Hashtbl.mem drained (i, key)) then begin
              Batch_commit.propose r ~idempotency_key:key
                ~materialize:(mat_sink materializers.(i)) writes;
              (* Only stop re-offering a key once it has actually been materialized, i.e. once this
                 replica really holds it committed -- offering it again while it is still
                 uncommitted is the whole point of a retry-driven mechanism. *)
              if
                List.mem_assoc
                  (Batch_commit.redaction_event_id ~idempotency_key:key ~index:0)
                  (Batch_commit.committed_envelopes_keyed r)
              then Hashtbl.replace drained (i, key) ()
            end)
          !history)
      replicas
  in

  let check ~phase =
    Array.iteri
      (fun i r ->
        let committed = committed_keys r in
        Array.iter
          (fun merge_key ->
            let expected = expected_accumulator ~committed ~merge_key in
            let actual = M.read materializers.(i) ~merge_key in
            if actual <> expected then
              note
                "seed %d [%s]: replica %d's accumulator at %s is [%s] but its own committed log \
                 says [%s]"
                seed phase (i + 1) merge_key
                (String.concat "," (G_set.elements actual))
                (String.concat "," (G_set.elements expected)))
          merge_keys)
      replicas;
    (* (b) convergence, pairwise, between replicas holding the same committed batches. *)
    for i = 0 to replica_count - 1 do
      for j = i + 1 to replica_count - 1 do
        if List.sort compare (committed_keys replicas.(i)) = List.sort compare (committed_keys replicas.(j))
        then begin
          result := { !result with converged_pairs = !result.converged_pairs + 1 };
          Array.iter
            (fun merge_key ->
              if M.read materializers.(i) ~merge_key <> M.read materializers.(j) ~merge_key then
                note
                  "seed %d [%s]: replicas %d and %d hold the same committed batches but different \
                   accumulators at %s"
                  seed phase (i + 1) (j + 1) merge_key)
            merge_keys
        end
      done
    done;
    (* (c) redaction, checked through EVERY replica's own copy of the ciphertext. *)
    Array.iteri
      (fun i r ->
        List.iter
          (fun (event_id, (e : Riptide.Envelope.envelope)) ->
            match List.assoc_opt event_id !secrets with
            | None -> ()
            | Some plaintext -> (
              let plaintext = canonical plaintext in
              let got = Redaction_store.decrypt_value store ~event_id e.payload in
              match (Hashtbl.mem redacted event_id, got) with
              | true, None -> ()
              | true, Some _ ->
                note "seed %d [%s]: replica %d: redacted record %s is STILL DECRYPTABLE" seed phase
                  (i + 1) event_id
              | false, Some v when v = plaintext ->
                if v = canonical (secret_payload_with crypto_marker) then
                  result := { !result with marker_decryptions = !result.marker_decryptions + 1 }
              | false, Some _ ->
                note "seed %d [%s]: replica %d: record %s decrypted to the WRONG plaintext" seed
                  phase (i + 1) event_id
              | false, None ->
                note "seed %d [%s]: replica %d: un-redacted record %s no longer decrypts" seed phase
                  (i + 1) event_id))
          (Batch_commit.committed_envelopes_keyed r))
      replicas;
    (* (d) no plaintext on any wire or any disk. *)
    if contains ~needle:crypto_marker (Buffer.contents sent_bytes) then
      note "seed %d [%s]: the plaintext marker appeared in replicated VSR message bytes" seed phase;
    if contains ~needle:crypto_marker (raw_bytes_under keystore_dir) then
      note "seed %d [%s]: the plaintext marker appeared on disk in the keystore" seed phase;
    Array.iteri
      (fun i d ->
        if contains ~needle:crypto_marker (raw_bytes_under d) then
          note "seed %d [%s]: the plaintext marker appeared on disk in replica %d's materializer"
            seed phase (i + 1))
      mat_dirs
  in

  (* The marker goes into the first phase's encrypted record, so it is committed early and lives
     under every later phase's faults, redactions and checks. *)
  let marker_phase = 1 in
  for phase = 1 to phases do
       let phase_name = Printf.sprintf "phase-%d" phase in
       (* 1-2 materialized batches, each 1-2 writes, across several merge_keys. *)
       for b = 1 to 1 + Riptide_sim.Prng.int prng 2 do
         let key = Printf.sprintf "m-%d-%d-%d" seed phase b in
         let writes =
           List.init
             (1 + Riptide_sim.Prng.int prng 2)
             (fun i ->
               write_of
                 ~merge_key:merge_keys.(Riptide_sim.Prng.int prng (Array.length merge_keys))
                 (G_set.to_value (G_set.of_list [ Printf.sprintf "v-%d-%d-%d-%d" seed phase b i ])))
         in
         history := !history @ [ (key, writes) ];
         Batch_commit.propose primary ~idempotency_key:key ~materialize:(mat_sink materializers.(0))
           writes
       done;
       (* THE ADVERSARIAL RETRY. A client with no acknowledgment mechanism retries; sometimes it
          regenerates the batch rather than replaying the exact bytes (a fresh timestamp, a re-read
          source row, a re-serialised structure). The log's read side already defends against this
          -- [committed_envelopes] is first-wins per key -- so the write side must agree with it. *)
       if !history <> [] && Riptide_sim.Prng.bool prng 0.5 then begin
         let key, writes = List.nth !history (Riptide_sim.Prng.int prng (List.length !history)) in
         let regenerate = Riptide_sim.Prng.bool prng 0.5 in
         let retry_writes =
           if not regenerate then writes
           else begin
             result := { !result with regenerated_retries = !result.regenerated_retries + 1 };
             List.mapi
               (fun i (w : Batch_commit.write) ->
                 {
                   w with
                   Batch_commit.payload =
                     G_set.to_value
                       (G_set.of_list [ Printf.sprintf "REGENERATED-%d-%d-%d" seed phase i ]);
                 })
               writes
           end
         in
         Batch_commit.propose primary ~idempotency_key:key
           ~materialize:(mat_sink materializers.(0)) retry_writes
       end;
       (* An unrelated record's payload, encrypted for storage and individually redactable. *)
       let ekey = Printf.sprintf "e-%d-%d" seed phase in
       let plaintext =
         secret_payload_with
           (if phase = marker_phase then crypto_marker
            else Printf.sprintf "secret-%d-%d" seed phase)
       in
       secrets :=
         (Batch_commit.redaction_event_id ~idempotency_key:ekey ~index:0, plaintext) :: !secrets;
       Batch_commit.propose primary ~idempotency_key:ekey ~encryption:(enc_sink store)
         [ write_of plaintext ];
       (* And the ENCRYPTED retry, which is Task 6's own guard exercised inside this combined
          scenario for the first time. Re-proposing an already-in-the-log encrypted batch must not
          re-run the encryption sink: that would mint a fresh DEK, overwrite the keystore entry for
          a ciphertext already committed, and leave the record permanently unopenable. Property (c)
          is what would catch it, on every replica's own copy of the ciphertext -- so this is the
          combination test_redaction.ml's own single-batch regression test could not reach (no
          storage faults, no five-replica quorum, no interleaved materialized traffic). *)
       if phase > 1 && Riptide_sim.Prng.bool prng 0.5 then begin
         result := { !result with encrypted_retries = !result.encrypted_retries + 1 };
         Batch_commit.propose primary
           ~idempotency_key:(Printf.sprintf "e-%d-%d" seed (phase - 1))
           ~encryption:(enc_sink store)
           [ write_of (secret_payload_with (Printf.sprintf "secret-%d-%d" seed (phase - 1))) ]
       end;
       deliver ~drop_probability:message_drop_probability;
       drain ~redrain_everything:false;
       (* Real redaction of an already-committed record, mid-run, while later phases keep writing.
          Never the marker's own record before the last phase -- (d)'s non-vacuity depends on it
          still being genuinely recoverable. *)
       if phase > marker_phase && Riptide_sim.Prng.bool prng 0.5 then begin
         let victim = Printf.sprintf "e-%d-%d" seed (phase - 1) in
         let event_id = Batch_commit.redaction_event_id ~idempotency_key:victim ~index:0 in
         if
           List.mem_assoc event_id (Batch_commit.committed_envelopes_keyed primary)
           && not (Hashtbl.mem redacted event_id)
         then begin
           Redaction_store.redact store ~event_id;
           Hashtbl.replace redacted event_id ();
           result := { !result with redactions = !result.redactions + 1 }
         end
       end;
    check ~phase:phase_name
  done;
  (* Final settle with no message loss at all, then one last drain and check: this is where
     convergence must actually be reached rather than merely approached. *)
  deliver ~drop_probability:0.0;
  drain ~redrain_everything:false;
  check ~phase:"final";
  (* One last pass that re-offers EVERY key to EVERY replica, including every key each replica has
     already materialized. batch_commit.mli states that re-materializing an already-materialized
     write is a no-op by the lattice laws; this is that claim exercised against real accumulators
     rather than restated, and (a) immediately below is what would catch it if it were not. *)
  drain ~redrain_everything:true;
  check ~phase:"re-drain";

  (* Tallies, for the non-vacuity assertions the callers make. *)
  let committed_batches =
    Array.fold_left (fun acc r -> acc + List.length (committed_keys r)) 0 replicas
  in
  let fault_cap_hits =
    Array.fold_left
      (fun acc r ->
        acc + (try List.assoc "fault_injection_cap" (Replica.for_test_append_refusals r) with Not_found -> 0))
      0 replicas
  in
  let storage_faults_observed =
    Array.fold_left
      (fun acc r ->
        let n = ref 0 in
        for op_number = 1 to Replica.op_number r do
          if Replica.for_test_wal_read r ~op_number = None then incr n
        done;
        acc + !n)
      0 replicas
  in
  {
    !result with
    committed_batches;
    storage_faults_observed;
    fault_cap_hits;
    primary_commit_halted =
      (if Replica.commit_number primary < Replica.op_number primary then 1 else 0);
  }

(* ---- the sweep itself ---- *)

let memory_backed_storage ~index ~prng =
  Fault_injecting_storage.create ~prng ~fault_config:(fault_config_for ~index) ~replication_quorum
    ~underlying:(module Memory_storage)
    (Memory_storage.create ())

let test_adversarial_sweep () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let seeds = 12 and phases = 4 in
  let totals = ref zero_result in
  for seed = 1 to seeds do
    let r = run_scenario ~env ~sw ~seed ~phases ~make_fault_storage:memory_backed_storage in
    totals :=
      {
        violations = r.violations @ !totals.violations;
        committed_batches = !totals.committed_batches + r.committed_batches;
        redactions = !totals.redactions + r.redactions;
        storage_faults_observed = !totals.storage_faults_observed + r.storage_faults_observed;
        messages_dropped = !totals.messages_dropped + r.messages_dropped;
        regenerated_retries = !totals.regenerated_retries + r.regenerated_retries;
        encrypted_retries = !totals.encrypted_retries + r.encrypted_retries;
        converged_pairs = !totals.converged_pairs + r.converged_pairs;
        marker_decryptions = !totals.marker_decryptions + r.marker_decryptions;
        primary_commit_halted = !totals.primary_commit_halted + r.primary_commit_halted;
        fault_cap_hits = !totals.fault_cap_hits + r.fault_cap_hits;
      }
  done;
  let t = !totals in
  (* Non-vacuity first: an all-green sweep that exercised nothing proves nothing. Every number
     below was measured, not guessed, and is asserted as a floor so it cannot silently rot to
     zero. *)
  Alcotest.(check bool) "the fault injector never had to decline a fault (measured: 0 -- retune if \
                         this fails, the configured fault rate is not the delivered one)" true
    (t.fault_cap_hits = 0);
  Alcotest.(check bool) "the primary stayed fault-free by construction (measured: 0 halts)" true
    (t.primary_commit_halted = 0);
  Alcotest.(check bool) "batches actually committed (measured: 232 replica-batch commits)" true
    (t.committed_batches > 150);
  Alcotest.(check bool) "real storage faults actually fired (measured: 40 unreadable slots)" true
    (t.storage_faults_observed > 10);
  Alcotest.(check bool) "real messages were actually dropped (measured: 22)" true (t.messages_dropped > 5);
  Alcotest.(check bool) "regenerated-payload retries actually happened (measured: 7)" true
    (t.regenerated_retries > 2);
  Alcotest.(check bool) "encrypted batches were actually retried (measured: 18) -- Task 6's DEK-orphan guard under \
                         faults, five replicas and interleaved materialized traffic" true
    (t.encrypted_retries > 3);
  Alcotest.(check bool) "records were actually redacted (measured: 15)" true (t.redactions > 5);
  Alcotest.(check bool) "replica pairs actually converged (measured: 308)" true (t.converged_pairs > 50);
  Alcotest.(check bool)
    "the marker was genuinely recoverable by real decryption (measured: 242) -- without this, (d) \
     would pass for the trivial reason that the record was never readable at all"
    true (t.marker_decryptions > 20);
  if t.violations <> [] then
    Alcotest.failf "%d violation(s) across %d seeds:\n%s" (List.length t.violations) seeds
      (String.concat "\n" (List.rev t.violations))

(* The same scenario against the REAL durable WAL, so property (d)'s "raw disk read" half covers
   the bytes [File_storage] itself writes, not only [File_kv_store]'s. One seed rather than twelve:
   this is about the on-disk artifacts being real, and every other property is already swept above.
   [ring_capacity] is set well above this run's op count so WAL eviction (a known, separate
   limitation with its own test in test_dst_scenarios.ml) is not what this test ends up measuring. *)
let test_sweep_against_real_file_storage () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  with_tmp_dir @@ fun wal_root ->
  let make_fault_storage ~index ~prng =
    let dir = Filename.concat wal_root (string_of_int index) in
    Unix.mkdir dir 0o700;
    Fault_injecting_storage.create ~prng ~fault_config:(fault_config_for ~index) ~replication_quorum
      ~underlying:(module File_storage)
      (File_storage.create ~sw ~fs:(Eio.Stdenv.fs env) ~ring_capacity:256 dir)
  in
  let r = run_scenario ~env ~sw ~seed:101 ~phases:3 ~make_fault_storage in
  Alcotest.(check bool) "the fault injector never had to decline a fault" true (r.fault_cap_hits = 0);
  Alcotest.(check bool) "batches actually committed (measured: 21 replica-batch commits)" true
    (r.committed_batches > 12);
  Alcotest.(check bool) "real storage faults fired against the real WAL (measured: 2)" true
    (r.storage_faults_observed > 0);
  Alcotest.(check bool) "the marker was genuinely recoverable by real decryption (measured: 16)" true
    (r.marker_decryptions > 5);
  (* The check this test exists for: every byte the real ring WAL put on disk, grepped directly. *)
  Alcotest.(check bool) "the plaintext marker never reached the real on-disk WAL" false
    (contains ~needle:crypto_marker (raw_bytes_under wal_root));
  Alcotest.(check bool) "...and the WAL genuinely has bytes to grep" true
    (String.length (raw_bytes_under wal_root) > 4096);
  if r.violations <> [] then
    Alcotest.failf "%d violation(s):\n%s" (List.length r.violations)
      (String.concat "\n" (List.rev r.violations))


(* ---------------------------------------------------------------------------------------------
   THE PRIMARY-SIDE STORAGE FAULT, injected deterministically rather than hoped for.

   This task's brief asks what happens under fault injection to a write caught mid-materialization.
   The answer in this VSR subset is sharp and worth pinning: [primary_execute_op] refuses to commit
   an op the primary cannot read back off its own storage, so a single corrupted slot halts commit
   there for good (no view change in this scenario to repair it). The property that must survive
   that is that materialized state halts EXACTLY with commit -- it must not race ahead of the log
   (materializing a write the cluster never agreed on) and must not fall behind it (losing a write
   that did commit). Injected with [for_test_corrupt_entry] at a chosen op rather than drawn from a
   probability, so the scenario is the same on every run.
   --------------------------------------------------------------------------------------------- *)

let test_a_primary_storage_fault_halts_materialization_exactly_with_commit () =
  Eio_main.run @@ fun env ->
  with_tmp_dir @@ fun mat_root ->
  Eio.Switch.run @@ fun sw ->
  let fs = Eio.Stdenv.fs env in
  let inflight : (int * string) Queue.t = Queue.create () in
  let fault_storages =
    Array.init replica_count (fun i ->
        Fault_injecting_storage.create
          ~prng:(Riptide_sim.Prng.create (900 + i))
          ~fault_config:Fault_injecting_storage.default_fault_config ~replication_quorum
          ~underlying:(module Memory_storage)
          (Memory_storage.create ()))
  in
  let replicas =
    Array.init replica_count (fun i ->
        Replica.create
          ~storage:(Replica.storage_of_module (module Fault_injecting_storage) fault_storages.(i))
          ~my_id:(i + 1) ~replica_count ~svc_limit:3
          ~send:(fun ~to_ bytes -> Queue.add (to_, bytes) inflight))
  in
  Array.iter (fun r -> Replica.for_test_set_view_number r 1) replicas;
  let primary = replicas.(0) in
  let materializers =
    Array.init replica_count (fun i ->
        let dir = Filename.concat mat_root (string_of_int i) in
        Unix.mkdir dir 0o700;
        make_materializer ~sw ~fs dir)
  in
  let deliver () =
    while not (Queue.is_empty inflight) do
      let to_, bytes = Queue.pop inflight in
      Replica.handle_message replicas.(to_ - 1) bytes
    done
  in
  let propose_batch n =
    Batch_commit.propose primary
      ~idempotency_key:(Printf.sprintf "b%d" n)
      ~materialize:(mat_sink materializers.(0))
      [ write_of ~merge_key:"mk" (G_set.to_value (G_set.of_list [ Printf.sprintf "v%d" n ])) ]
  in
  propose_batch 1;
  deliver ();
  propose_batch 2;
  deliver ();
  Alcotest.(check int) "two batches committed normally before any fault" 2 (Replica.commit_number primary);
  (* Op 3 is appended, and only then corrupted -- the fault is a slot going bad on a write the
     primary has already durably taken, which is what a real corruption is. *)
  propose_batch 3;
  Alcotest.(check int) "op 3 really is in the primary's log" 3 (Replica.op_number primary);
  Fault_injecting_storage.for_test_corrupt_entry fault_storages.(0) ~op_number:3;
  deliver ();
  propose_batch 4;
  deliver ();
  Array.iteri
    (fun i r ->
      List.iter
        (fun n ->
          Batch_commit.propose r
            ~idempotency_key:(Printf.sprintf "b%d" n)
            ~materialize:(mat_sink materializers.(i))
            [])
        [ 1; 2; 3; 4 ])
    replicas;
  (* The halt itself: the log grew, commit did not. *)
  Alcotest.(check int) "the primary's log grew to 4 entries" 4 (Replica.op_number primary);
  Alcotest.(check int) "but commit halted at the op before the corrupted slot" 2
    (Replica.commit_number primary);
  Alcotest.(check bool) "...because that slot genuinely cannot be read back" true
    (Replica.for_test_wal_read primary ~op_number:3 = None);
  (* The property under test, on every replica: materialized state is exactly the committed
     prefix. Not v3 or v4 (never agreed), and not short of v1/v2 (genuinely committed). *)
  Array.iteri
    (fun i r ->
      let expected =
        List.filter_map
          (fun n ->
            if
              List.mem_assoc
                (Batch_commit.redaction_event_id ~idempotency_key:(Printf.sprintf "b%d" n) ~index:0)
                (Batch_commit.committed_envelopes_keyed r)
            then Some (Printf.sprintf "v%d" n)
            else None)
          [ 1; 2; 3; 4 ]
      in
      Alcotest.(check (list string))
        (Printf.sprintf "replica %d materialized exactly its own committed prefix" (i + 1))
        expected
        (G_set.elements (M.read materializers.(i) ~merge_key:"mk")))
    replicas;
  Alcotest.(check (list string)) "and concretely, that is v1 and v2 on the primary" [ "v1"; "v2" ]
    (G_set.elements (M.read materializers.(0) ~merge_key:"mk"))

(* ---------------------------------------------------------------------------------------------
   PROPERTY (d), THE WIRE HALF: a real mutually-authenticated TLS connection, with the raw TCP
   bytes captured between the two peers.

   The sweep above already proves the CRYPTO layer hides an encrypted payload's plaintext from
   every byte a replica sends. This proves the TRANSPORT layer hides even a payload that was never
   encrypted at all -- which is the only way to make the claim about [Tcp] itself rather than about
   [Dek]. The capture is taken by a recording proxy sitting in the middle of a real loopback TCP
   connection: peer 1's membership table points at the proxy's port, the proxy dials peer 2's real
   listener, and every byte in both directions is copied through a [Buffer] on the way. Peer 2 never
   dials peer 1 (tcp.ml's lower-dials-higher topology), so this single proxied connection carries
   the whole conversation, TLS handshake included.
   --------------------------------------------------------------------------------------------- *)

let wire_marker = "RIPTIDE-WIRE-MARKER-9d4e7c31"

exception Test_mesh_torn_down

let cluster_ca = Riptide_pki.Ca.generate_root ~common_name:"riptide-task9-cluster-root"

let peer_identity id =
  let cert, priv_key =
    Riptide_pki.Ca.sign_leaf cluster_ca
      ~common_name:(Printf.sprintf "peer-%d.riptide.test" id)
      ~valid_days:1
  in
  Riptide_transport.Tls_identity.create ~trust_anchor:cluster_ca.Riptide_pki.Ca.cert ~cert ~priv_key

let test_no_plaintext_on_a_real_mtls_wire () =
  let proxy_port = 19381 and peer1_port = 19382 and peer2_port = 19383 in
  let capture = Buffer.create 65536 in
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let addr port : Eio.Net.Sockaddr.stream =
    `Tcp (Eio_unix.Net.Ipaddr.of_unix (Unix.inet_addr_of_string "127.0.0.1"), port)
  in
  (try
     Eio.Switch.run (fun sw ->
         (* The recording proxy, up before anyone dials it. *)
         let listener =
           Eio.Net.listen ~sw ~reuse_addr:true ~backlog:4 net (addr proxy_port)
         in
         let pump ~src ~dst =
           let buf = Cstruct.create 4096 in
           let rec go () =
             match Eio.Flow.single_read src buf with
             | n ->
               let chunk = Cstruct.sub buf 0 n in
               Buffer.add_string capture (Cstruct.to_string chunk);
               Eio.Flow.write dst [ chunk ];
               go ()
             | exception End_of_file -> ()
           in
           go ()
         in
         Eio.Fiber.fork ~sw (fun () ->
             Eio.Net.accept_fork ~sw listener
               ~on_error:(fun _ -> ())
               (fun client _addr ->
                 Eio.Switch.run (fun csw ->
                     let upstream = Eio.Net.connect ~sw:csw net (addr peer2_port) in
                     Eio.Fiber.both
                       (fun () -> pump ~src:client ~dst:upstream)
                       (fun () -> pump ~src:upstream ~dst:client))));
         (* Peer 1's membership table sends it to the proxy for peer 2; peer 2's own listener is on
            the real port. Peer 2 never dials peer 1, so nothing bypasses the proxy. *)
         let peers_for_1 = [ (1, "127.0.0.1", peer1_port); (2, "127.0.0.1", proxy_port) ] in
         let peers_for_2 = [ (1, "127.0.0.1", peer1_port); (2, "127.0.0.1", peer2_port) ] in
         let t1 = ref None and t2 = ref None in
         Eio.Fiber.both
           (fun () ->
             t1 :=
               Some
                 (Riptide_transport.Tcp.create ~sw ~net ~clock ~my_id:1 ~peers:peers_for_1
                    ~tls:(peer_identity 1)))
           (fun () ->
             t2 :=
               Some
                 (Riptide_transport.Tcp.create ~sw ~net ~clock ~my_id:2 ~peers:peers_for_2
                    ~tls:(peer_identity 2)));
         let t1 = Option.get !t1 and t2 = Option.get !t2 in
         let message = Printf.sprintf "{\"payload\":\"%s\"}" wire_marker in
         Riptide_transport.Tcp.send t1 ~to_:2 message;
         let received = Riptide_transport.Tcp.receive t2 in
         (* Non-vacuity, in both directions: the marker really did cross this connection at the
            application layer, and the proxy really did see the bytes it crossed on. *)
         Alcotest.(check string) "the marker-bearing message arrived verbatim" message received;
         Alcotest.(check bool) "the application message really does contain the marker" true
           (contains ~needle:wire_marker message);
         Alcotest.(check bool) "the proxy captured real traffic" true (Buffer.length capture > 512);
         Alcotest.(check bool) "...and it is a real TLS stream (record type 0x16, handshake)" true
           (Buffer.length capture > 0 && Buffer.nth capture 0 = '\022');
         (* The property itself. *)
         Alcotest.(check bool) "the marker never appears in the raw bytes on the wire" false
           (contains ~needle:wire_marker (Buffer.contents capture));
         Eio.Switch.fail sw Test_mesh_torn_down)
   with Test_mesh_torn_down -> ())

(* ---------------------------------------------------------------------------------------------
   REGRESSION TESTS for the defect this task found.

   Both fail against the pre-fix [Batch_commit.propose] (which folded the caller's argument writes)
   and pass against the current one (which folds the writes that actually committed). Both are
   deliberately single-replica and fault-free: the defect needs no faults, no cluster and no race,
   which is exactly what makes it severe.
   --------------------------------------------------------------------------------------------- *)

let create_solo () =
  Replica.create ~storage:(Replica.volatile_storage ()) ~my_id:1 ~replica_count:1 ~svc_limit:3
    ~send:(fun ~to_:_ (_ : string) -> ())

let test_materialization_is_a_function_of_the_committed_log () =
  Eio_main.run @@ fun env ->
  with_tmp_dir @@ fun dir_a ->
  with_tmp_dir @@ fun dir_b ->
  Eio.Switch.run @@ fun sw ->
  let fs = Eio.Stdenv.fs env in
  let ma = make_materializer ~sw ~fs dir_a and mb = make_materializer ~sw ~fs dir_b in
  let replica = create_solo () in
  let committed = write_of ~merge_key:"mk" (G_set.to_value (G_set.of_list [ "committed" ])) in
  let regenerated = write_of ~merge_key:"mk" (G_set.to_value (G_set.of_list [ "NEVER-COMMITTED" ])) in
  (* Replica A's client proposes, then retries the same idempotency key with a regenerated batch --
     the only kind of retry this fire-and-forget layer permits. Replica B's client only ever sends
     the original. *)
  Batch_commit.propose replica ~idempotency_key:"k1" ~materialize:(mat_sink ma) [ committed ];
  Batch_commit.propose replica ~idempotency_key:"k1" ~materialize:(mat_sink ma) [ regenerated ];
  Batch_commit.propose replica ~idempotency_key:"k1" ~materialize:(mat_sink mb) [ committed ];
  Alcotest.(check int) "the retry appended nothing: exactly one committed envelope" 1
    (List.length (Batch_commit.committed_envelopes replica));
  (* Pre-fix: A = [NEVER-COMMITTED; committed], B = [committed] -- a durable, permanent divergence
     over a payload that is in no committed entry on any replica, which no later join can undo
     because no other replica will ever see it. *)
  Alcotest.(check (list string)) "the accumulator holds exactly what committed" [ "committed" ]
    (G_set.elements (M.read ma ~merge_key:"mk"));
  Alcotest.(check (list string)) "...on both replicas" [ "committed" ]
    (G_set.elements (M.read mb ~merge_key:"mk"))

let test_a_redacted_records_plaintext_cannot_re_enter_via_materialization () =
  Eio_main.run @@ fun env ->
  with_tmp_dir @@ fun keystore_dir ->
  with_tmp_dir @@ fun mat_dir ->
  Eio.Switch.run @@ fun sw ->
  let fs = Eio.Stdenv.fs env in
  let store =
    Redaction_store.create
      ~kv:(File_kv_store.create ~sw ~fs keystore_dir)
      ~kek:(Kek.of_raw (Mirage_crypto_rng.generate 32))
  in
  let materializer = make_materializer ~sw ~fs mat_dir in
  let replica = create_solo () in
  let payload = G_set.to_value (G_set.of_list [ crypto_marker ]) in
  (* Call 1 commits the payload as CIPHERTEXT. No merge_key, so [propose]'s mutual-exclusion guard
     is satisfied and says nothing. *)
  Batch_commit.propose replica ~idempotency_key:"k1" ~encryption:(enc_sink store)
    [ write_of payload ];
  (* Call 2 is the guard's blind spot: same idempotency key, a merge_key this time, and NO
     [~encryption] -- so the guard never fires, nothing is re-proposed, and pre-fix this call
     folded the PLAINTEXT it was handed into the durable accumulator. *)
  Batch_commit.propose replica ~idempotency_key:"k1" ~materialize:(mat_sink materializer)
    [ write_of ~merge_key:"mk" payload ];
  let event_id, envelope = List.hd (Batch_commit.committed_envelopes_keyed replica) in
  Alcotest.(check bool) "the record really is recoverable before redaction" true
    (Redaction_store.decrypt_value store ~event_id envelope.Riptide.Envelope.payload = Some payload);
  Redaction_store.redact store ~event_id;
  Alcotest.(check bool) "redaction genuinely destroys recoverability of the committed record" true
    (Redaction_store.decrypt_value store ~event_id envelope.Riptide.Envelope.payload = None);
  (* Pre-fix both of these fail: the accumulator holds the marker and the bytes are on disk, so the
     redaction destroyed a ciphertext nobody could read while the plaintext stayed readable
     forever -- a redaction that does not redact. *)
  Alcotest.(check (list string)) "nothing was materialized: the committed batch is encrypted and \
                                  carries no merge_key" [] (G_set.elements (M.read materializer ~merge_key:"mk"));
  Alcotest.(check bool) "the plaintext is on no disk under the materializer" false
    (contains ~needle:crypto_marker (raw_bytes_under mat_dir))

(* The invariant the fix leans on, re-verified rather than assumed (this task's brief asks for
   exactly that): the combination is still rejected, loudly, at the one moment encryption can
   happen. *)
let test_encrypted_and_materialized_is_still_rejected () =
  Eio_main.run @@ fun env ->
  with_tmp_dir @@ fun keystore_dir ->
  Eio.Switch.run @@ fun sw ->
  let store =
    Redaction_store.create
      ~kv:(File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) keystore_dir)
      ~kek:(Kek.of_raw (Mirage_crypto_rng.generate 32))
  in
  let replica = create_solo () in
  Alcotest.check_raises "a merge_key write cannot also be encrypted"
    (Invalid_argument
       "Batch_commit.propose: a write with merge_key = Some _ cannot also be encrypted \
        (~encryption): the materialized accumulator is outside the redaction keystore, so deleting \
        the DEK would not erase it")
    (fun () ->
      Batch_commit.propose replica ~idempotency_key:"k1" ~encryption:(enc_sink store)
        [ write_of ~merge_key:"mk" (G_set.to_value (G_set.of_list [ "x" ])) ]);
  Alcotest.(check int) "and nothing was committed" 0
    (List.length (Batch_commit.committed_envelopes replica))

(* The capability the fix adds, which is what lets a replica feed its own materializer from its own
   commit stream at all (property (a) of this task's brief): materialization needs no writes in
   hand, only the committed log. *)
let test_a_replica_can_materialize_its_own_commit_stream_without_the_writes () =
  Eio_main.run @@ fun env ->
  with_tmp_dir @@ fun dir ->
  Eio.Switch.run @@ fun sw ->
  let materializer = make_materializer ~sw ~fs:(Eio.Stdenv.fs env) dir in
  let replica = create_solo () in
  Batch_commit.propose replica ~idempotency_key:"k1"
    [ write_of ~merge_key:"mk" (G_set.to_value (G_set.of_list [ "from-the-log" ])) ];
  Alcotest.(check (list string)) "nothing materialized yet -- no sink was supplied" []
    (G_set.elements (M.read materializer ~merge_key:"mk"));
  (* An empty writes list: the key is already in the log, so nothing is proposed, and everything
     materialized comes from the committed bytes. *)
  Batch_commit.propose replica ~idempotency_key:"k1" ~materialize:(mat_sink materializer) [];
  Alcotest.(check (list string)) "the committed batch's own writes were materialized"
    [ "from-the-log" ]
    (G_set.elements (M.read materializer ~merge_key:"mk"));
  Alcotest.(check int) "and the empty call proposed nothing" 1
    (List.length (Batch_commit.committed_envelopes replica))


(* ---------------------------------------------------------------------------------------------
   A SECOND FINDING, PINNED RATHER THAN FIXED: an accumulator that outgrows its KV backend.

   {!Riptide_materialize.Materializer} documents an accumulator as "the join of all values ever
   written" -- unbounded by construction for any grow-only lattice, which is most of them.
   {!Riptide_storage.File_kv_store}, its only real backend and the one every consumer in this plan
   uses, caps a single value at one aligned data slot (4096 bytes) and raises [Invalid_argument]
   past it. Neither {!Riptide_storage.Kv_store_intf.S.put}'s own contract nor materializer.mli said
   anything about a size bound before this task, so nothing connected the two.

   What actually happens, measured here rather than reasoned about, and it is worse than a loud
   failure: the batch has ALREADY COMMITTED by the time the fold runs (that ordering is deliberate
   and correct -- materializing an uncommitted write would publish state the cluster has not agreed
   on), so the exception surfaces out of [Batch_commit.propose] with the write durably in the
   replicated log and permanently absent from the accumulator. The accumulator is left at its last
   good value, so a SMALLER later write to the same merge_key succeeds and the store goes right on
   working -- the divergence does not announce itself again. Retrying the failed key does not help
   either: post-fix, materialization re-reads it from the committed bytes and hits the same cap.

   Pinned, not fixed, and deliberately so, following exactly the precedent test_dst_scenarios.ml
   sets for the ring-capacity limitation it found: a running reproduction that will fail loudly if
   the behaviour ever changes in EITHER direction. Fixing it properly means either spilling large
   values across slots in [File_kv_store] or giving [Kv_store_intf.S] a declared bound the
   materializer can enforce before it folds -- both are real design work with their own tradeoffs,
   and inventing one here, in a test task, is exactly the "policy ahead of running code" this
   repo's own CLAUDE.md warns against. The two [.mli] files now document the bound (this task's
   change), so the hazard is at least stated where a caller reads it. *)

let test_an_accumulator_outgrowing_its_kv_backend_diverges_from_the_log () =
  Eio_main.run @@ fun env ->
  with_tmp_dir @@ fun dir ->
  Eio.Switch.run @@ fun sw ->
  let materializer = make_materializer ~sw ~fs:(Eio.Stdenv.fs env) dir in
  let replica = create_solo () in
  let propose n =
    Batch_commit.propose replica
      ~idempotency_key:(Printf.sprintf "k%d" n)
      ~materialize:(mat_sink materializer)
      [ write_of ~merge_key:"mk" (G_set.to_value (G_set.of_list [ Printf.sprintf "element-%04d" n ])) ]
  in
  let failed_at = ref 0 in
  (try
     for n = 1 to 400 do
       if !failed_at = 0 then propose n
     done
   with Invalid_argument msg ->
     failed_at := List.length (G_set.elements (M.read materializer ~merge_key:"mk")) + 1;
     Alcotest.(check bool) "the failure names the backend's value-size limit" true
       (contains ~needle:"exceeds this store's max value size" msg));
  Alcotest.(check bool)
    "the fold really does hit File_kv_store's 4096-byte value cap (measured: at the 195th element)"
    true
    (!failed_at > 0 && !failed_at < 400);
  (* The part that makes this a divergence rather than a clean rejection: the overflowing write is
     durably COMMITTED, and is not in the accumulator. *)
  Alcotest.(check int) "the overflowing batch committed anyway" !failed_at
    (List.length (Batch_commit.committed_envelopes replica));
  Alcotest.(check int) "but the accumulator holds one element fewer" (!failed_at - 1)
    (List.length (G_set.elements (M.read materializer ~merge_key:"mk")));
  Alcotest.(check bool) "specifically, the committed write that overflowed is missing" false
    (List.mem
       (Printf.sprintf "element-%04d" !failed_at)
       (G_set.elements (M.read materializer ~merge_key:"mk")));
  (* And it stays silent afterwards: a shorter value fits back under the cap, so nothing about the
     store looks broken from here on. *)
  Batch_commit.propose replica ~idempotency_key:"k-small" ~materialize:(mat_sink materializer)
    [ write_of ~merge_key:"mk" (G_set.to_value (G_set.of_list [ "tiny" ])) ];
  Alcotest.(check bool) "a later, smaller write to the same merge_key succeeds silently" true
    (List.mem "tiny" (G_set.elements (M.read materializer ~merge_key:"mk")))

let tests =
  Lattice_conformance.tests (module G_set) g_set_arb "G_set"
  @ [
      ("adversarial sweep: materialization + redaction + storage faults, many seeds", `Slow,
       test_adversarial_sweep);
      ("the same scenario against the real on-disk ring WAL", `Slow, test_sweep_against_real_file_storage);
      ("a primary-side storage fault halts materialization exactly with commit", `Quick,
       test_a_primary_storage_fault_halts_materialization_exactly_with_commit);
      ("no plaintext on a real mutually-authenticated TLS wire", `Slow, test_no_plaintext_on_a_real_mtls_wire);
      ("materialization is a function of the committed log, not of the caller's argument", `Quick,
       test_materialization_is_a_function_of_the_committed_log);
      ("a redacted record's plaintext cannot re-enter through the materializer", `Quick,
       test_a_redacted_records_plaintext_cannot_re_enter_via_materialization);
      ("encrypted + materialized is still rejected", `Quick, test_encrypted_and_materialized_is_still_rejected);
      ("a replica can materialize its own commit stream without the writes", `Quick,
       test_a_replica_can_materialize_its_own_commit_stream_without_the_writes);
      ("an accumulator outgrowing its KV backend's value limit diverges from the committed log \
        (known limitation, pinned)", `Quick,
       test_an_accumulator_outgrowing_its_kv_backend_diverges_from_the_log);
    ]
