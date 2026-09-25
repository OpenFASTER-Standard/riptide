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

(* THE materializer constructor for this file -- every materializer below is built through it, and
   it is the shape any real caller would follow, since {!Riptide_materialize.Materializer.create}
   takes its [kv] already built and materializer.mli's own doc tells the caller building that [kv]
   to pass [~owner:"materializer"]. It is tagged here rather than at each call site precisely so
   the collision test below can exercise the guard against the REAL construction path instead of a
   bare, test-only [File_kv_store.create ~owner:"materializer"] written just to make the guard
   fire (which is what it did before: an artificial call that proved the guard existed but not
   that anything in this repo actually opted into it). *)
let make_materializer ~sw ~fs dir =
  M.create
    ~kv:(File_kv_store.create ~sw ~fs ~owner:"materializer" dir)
    ~decode:(fun s -> G_set.of_value (Riptide.Value.canonical_decode s))
    ~encode:(fun g -> Riptide.Value.canonical_encode (G_set.to_value g))

(* The deliberately UNPROTECTED counterpart, used by exactly one test below
   ([test_omitting_owner_on_the_materializer_side_alone_still_destroys_a_wrapped_dek]) and nothing
   else. It exists to keep file_kv_store.mli's own honest disclosure -- that an untagged
   [File_kv_store.create] is a no-op with respect to the marker check, regardless of what's already
   claimed on disk -- backed by running code rather than prose alone. Its [decode] is TOTAL
   (unparseable bytes decode as [bottom] rather than raising), which is a legitimate, even
   defensive, caller choice and is what makes the collision below silent rather than loud. *)
let make_unowned_lenient_materializer ~sw ~fs dir =
  M.create
    ~kv:(File_kv_store.create ~sw ~fs dir)
    ~decode:(fun s ->
      try G_set.of_value (Riptide.Value.canonical_decode s) with Invalid_argument _ -> G_set.bottom)
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
          corruption, as counted by {!Replica.append_refusals}'s [fault_injection_cap] --
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
   [fault_injection_cap] rather than propagating -- see replica.mli's [append_refusals]).
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
      ~kv:(File_kv_store.create ~sw ~fs ~owner:Redaction_store.owner_tag keystore_dir)
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
            Queue.add (to_, bytes) inflight) ())
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
        acc + (try List.assoc "fault_injection_cap" (Replica.append_refusals r) with Not_found -> 0))
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
   limitation with its own test in test_dst_scenarios.ml) is not what this test ends up measuring.

   The seed is CHOSEN, not arbitrary, and re-chosen during this task's review round (2026-09-24):
   one seed means one drawn workload, and the first seed used here (101) happened to draw no
   regenerated retry against an already-committed key at all -- so it verified the fix's behaviour
   against the real WAL without independently detecting the bug the way the memory-backed sweep
   above does. Seed 102 draws two such retries and fails pre-fix with the bug's exact signature
   ("replica 1's accumulator at mk-alpha is [REGENERATED-102-2-0,...] but its own committed log says
   [...]", 8 violations across phases 2, 3, final and re-drain), while dominating seed 101 on every
   non-vacuity count this test asserts (22 committed batches vs 21, 6 real storage faults vs 2, 21
   marker decryptions vs 16). Every regression test in this file now discriminates the defect it is
   about; if this one's seed is ever changed again, re-check that property against a reverted
   [Batch_commit.propose] rather than assuming it. *)
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
  let r = run_scenario ~env ~sw ~seed:102 ~phases:3 ~make_fault_storage in
  Alcotest.(check bool) "the fault injector never had to decline a fault" true (r.fault_cap_hits = 0);
  Alcotest.(check bool) "batches actually committed (measured: 22 replica-batch commits)" true
    (r.committed_batches > 12);
  Alcotest.(check bool) "real storage faults fired against the real WAL (measured: 6)" true
    (r.storage_faults_observed > 0);
  Alcotest.(check bool) "the marker was genuinely recoverable by real decryption (measured: 21)" true
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
          ~send:(fun ~to_ bytes -> Queue.add (to_, bytes) inflight) ())
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
   SUBTASK 3.7's GENERAL CASE, WIRED END TO END (Task 6 of the ring-eviction-watermark plan).

   WHAT WAS STILL OPEN, and it is a narrow, precise gap rather than a vague one. Task 4 of the
   PREVIOUS plan (test_batch_commit_materialize.ml's own
   [test_materialized_writes_survive_ring_eviction_that_destroys_the_raw_wal]) already closed the
   SCOPED case: a SOLO ([replica_count = 1], [f = 0]) replica, where {!Batch_commit.propose} itself
   commits synchronously, so the very call that commits a [merge_key] write also materializes it --
   strictly before any LATER [propose] on that same replica could evict its slot. That argument does
   not survive contact with a real cluster, for a reason stated in batch_commit.mli's own [propose]
   doc: at [replica_count >= 3] nothing commits synchronously, and a FOLLOWER never calls [propose]
   at all. A follower learns a commit purely by receiving the next [Prepare], appends under a ring
   that evicts [op_number - ring_capacity] on every append, and had nothing whatsoever driving its
   own materializer. Every ingredient of silent loss was present with no fault injected: committed,
   quorum-acknowledged, [merge_key]-carrying data destroyed on a follower's disk having never
   reached that follower's accumulator.

   WHAT CLOSES IT, and this is the whole of Task 6 -- three real mechanisms from Tasks 3-5 composed,
   with nothing new added to [lib/]:

   - {!Riptide_vsr.Replica.create}'s [?on_commit_advanced] (Task 3) fires synchronously and inline
     at every genuine commit advance, INCLUDING the one a follower learns from a piggybacked
     [Prepare] inside {!Riptide_vsr.Replica.handle_message}. That is the trigger a follower never
     had.
   - {!Riptide_batch_commit.Batch_commit.materialize_up_to} (Task 5) drains a replica's own
     committed prefix into its own materializer, needing no writes in hand and no [propose] call.
   - {!Riptide_storage.File_storage.create}'s [?may_evict] (Task 4) turns "materialization fell
     behind" from silent loss into refusable backpressure, counted as [eviction_blocked] in
     {!Riptide_vsr.Replica.append_refusals}.

   The watermark closure below is the whole wiring, per replica, and it is deliberately ALL there is
   to it: [on_commit_advanced] materializes through the new commit number and records it;
   [may_evict] permits an eviction iff the evicted op-number is at or below that recorded number, or
   never asked for materialization's protection in the first place. That closure is what a real
   caller would write; there is still no [bin/] entrypoint in this repo, which is why it lives here
   (this plan's own explicit non-goal).

   HOW THIS SCENARIO DIFFERS FROM THE SWEEP ABOVE, deliberately:
   - Every materializer here is fed EXCLUSIVELY by its own [?on_commit_advanced] hook. Nothing below
     ever passes [~materialize] to {!Batch_commit.propose}, and [propose] is only ever called on the
     primary -- so a follower's accumulator being correct is proof the hook fired on its own, off
     [handle_message] processing a piggybacked commit, with no external call anywhere.
   - No injected storage or network faults at all. A missing entry must have exactly one possible
     explanation, and under faults there is always an innocent one (the sweep above is where faults
     belong). The ring itself is the adversary here, and [ring_capacity = 4] makes it a very
     effective one.
   - The ring is deliberately TINY, where [test_sweep_against_real_file_storage] above deliberately
     sets [ring_capacity] far above its op count so eviction is not what it measures. Here eviction
     is the entire subject.

   THE ONE RE-ENTRANCY THIS RELIES ON, stated because it is load-bearing: [may_evict] is consulted
   from inside [wal_append], i.e. from inside the replica's own [handle_prepare]/[propose] action,
   and it calls {!Batch_commit.write_at_op_number_has_merge_key} which reads
   {!Riptide_vsr.Replica.entries} back. That is safe for the op-numbers it is ever asked about:
   [entries] is a pure read of the in-memory log, the asked-about op-number is [ring_capacity]
   behind the one being appended, and replica.mli's own hook-time settledness note confirms
   [entries]/[op_number]/[commit_number] are always final when re-entered this way. What it is NOT
   safe against is [adopt_durable_log]'s truncate-then-re-append repair window (replica.ml's own
   [durable_append] comment says as much, and warns that a [?may_evict] predicate must stay
   permissive enough not to starve adoption traffic) -- which this file already excludes by its own
   stated scope: no view changes, no restarts. Restart recovery for this same mechanism is covered
   in test_dst_scenarios.ml, where the harness that has restarts lives.
   --------------------------------------------------------------------------------------------- *)

(* Which pieces of the closure are wired, so the non-vacuity controls are permanent RUNNING tests
   rather than an experiment someone once did by hand and wrote down. [Full] is the mechanism;
   the other two are the two worlds it replaced, each still reachable and each asserted to exhibit
   exactly the damage [Full] prevents. *)
type watermark_wiring =
  | Full  (** [?on_commit_advanced] and [?may_evict] both wired -- the mechanism under test. *)
  | Hook_disabled
      (** [?may_evict] wired, [?on_commit_advanced] NOT. The gate with nothing to relent it: every
          watermark stays at 0 forever, so the first eviction of a [merge_key] entry is refused and
          the log can never grow past [ring_capacity]. Nothing is LOST, but nothing progresses
          either -- which is what makes the hook, not the gate, the part that closes 3.7. *)
  | Ungated
      (** Neither wired: the pre-subtask-3.7 world, byte-for-byte (file_storage.mli: omitting
          [?may_evict] "preserves this module's exact pre-existing behavior"). This is the variant
          that genuinely LOSES committed, acknowledged, [merge_key]-carrying data. *)

let wm_ring_capacity = 4

(* Op-numbers whose single write carries [merge_key = None]. They are the "existing, disclosed
   boundary" assertion 3 is about (batch_commit.mli's own [write] doc: [None] leaves a write exactly
   as evictable as before this mechanism existed), and their placement is CHOSEN, not incidental:
   op 8 is what the stalled follower below is asked about while its watermark sits at 7, so its
   eviction is permitted by the merge_key half of the predicate ALONE, with the watermark half
   failing. Without an entry in exactly that position, assertion 3 would only ever observe
   no-merge_key evictions that the watermark half would have permitted anyway -- true, but no
   evidence about the second half at all. *)
let wm_no_merge_key_ops = [ 4; 8 ]
let wm_has_merge_key n = not (List.mem n wm_no_merge_key_ops)
let wm_merge_key = "mk-watermark"
let wm_value n = Printf.sprintf "v%d" n

(* Deliberately a value that WOULD show up in the accumulator if a no-merge_key write were ever
   materialized: the G-set's join is union, so a bug that folded one in is directly visible in the
   same assertion that checks the expected contents, rather than needing its own. *)
let wm_unmaterialized_value n = Printf.sprintf "NEVER-MATERIALIZED-v%d" n

(* Every question [?may_evict] was ever asked, with the watermark AS IT WAS at that moment -- which
   is what makes the two halves of the predicate distinguishable after the fact. Without
   [ask_watermark] recorded, a permitted eviction is ambiguous between "already materialized" and
   "never claimed materialization", and assertion 3 is exactly the claim that it was the second. *)
type evict_ask = { ask_replica : int; ask_op_number : int; ask_watermark : int; ask_verdict : bool }

type wm_ctx = {
  wm_replicas : Replica.t array;
  wm_storages : File_storage.t array;
  wm_materializers : M.t array;
  wm_watermarks : int ref array;  (** each replica's OWN watermark -- never shared *)
  wm_stalled : bool ref array;
      (** A materialize sink that cannot keep up, modelled as the hook declining to drain rather
          than as a raising sink. The distinction is forced by the real code, not a softening:
          [?on_commit_advanced] is invoked inline from the middle of [handle_prepare], and nothing
          in [Replica] catches an exception out of it (replica.mli says the hook runs on the
          caller's own stack, exactly like [send]), so a raising sink would tear the protocol action
          in half and escape [handle_message] -- which is a statement about an ill-behaved consumer,
          not about materialization lag. A hook that simply does not advance its watermark is what a
          genuinely backlogged consumer looks like from the ring's point of view, and it is the
          state [?may_evict] exists to make safe. *)
  wm_asks : evict_ask list ref;
  wm_tap : (int * string) list ref;
      (** Every message this harness has DELIVERED, newest first, as [(destination_replica_id,
          bytes)] -- recorded at delivery time, not at send time, so a message that was delivered
          and then had no effect (e.g. a [Prepare] whose append the eviction gate refused) is still
          here afterwards, verbatim. This is what makes the RETRY half of the mechanism testable at
          all: this VSR subset has no retransmission timer (VSR.tla deliberately models none, and
          [Replica]'s only re-drive is [check_timeout]'s view change), so nothing in the protocol
          would ever re-offer a refused [Prepare] on its own -- the test has to hand the very same
          bytes back, which is exactly what a real deployment's transport-level retry would do. *)
  wm_propose : int -> unit;  (** propose op-number [n]'s batch, on the primary, with no sink *)
  wm_deliver : unit -> unit;
  wm_clear_stall : int -> unit;
      (** The backlog clearing: drain everything this replica holds committed and republish the
          watermark -- exactly what the hook itself does, which is the point. *)
}

let refusal_count r name =
  try List.assoc name (Replica.append_refusals r) with Not_found -> 0

(* The exact bytes of the [Prepare] for op-number [n] that this harness delivered to replica [to_],
   found by DECODING the tap rather than by position, so "this is the message that carried op 13" is
   proven from the wire format itself and not inferred from delivery order. *)
let wm_find_prepare tap ~to_ ~n =
  List.find_map
    (fun (dest, bytes) ->
      if dest <> to_ then None
      else
        match Message.decode bytes with
        | Message.Prepare { n = prepared; _ } when prepared = n -> Some bytes
        | _ -> None
        | exception Message.Malformed_message _ -> None)
    (List.rev !tap)

let wm_expected_accumulator ~through =
  G_set.of_list
    (List.filter_map
       (fun n -> if wm_has_merge_key n then Some (wm_value n) else None)
       (List.init (max through 0) (fun i -> i + 1)))

(* THE WIRING CLOSURE (Step 1), built per replica over its own real [File_storage] ring, its own
   real on-disk [Materializer], and its own watermark. Nothing is shared across replicas except the
   in-process message queue. *)
let with_watermark_cluster ~env ~sw ~wiring f =
  let fs = Eio.Stdenv.fs env in
  let wal_root = make_tmp_dir "riptide_wm_wal" in
  let mat_root = make_tmp_dir "riptide_wm_mat" in
  Fun.protect
    ~finally:(fun () ->
      rm_rf wal_root;
      rm_rf mat_root)
  @@ fun () ->
  let inflight : (int * string) Queue.t = Queue.create () in
  let asks = ref [] in
  let watermarks = Array.init replica_count (fun _ -> ref 0) in
  let stalled = Array.init replica_count (fun _ -> ref false) in
  let materializers =
    Array.init replica_count (fun i ->
        let d = Filename.concat mat_root (string_of_int i) in
        Unix.mkdir d 0o700;
        make_materializer ~sw ~fs d)
  in
  let sinks = Array.map mat_sink materializers in
  (* The knot: [?may_evict] is handed to [File_storage.create], which must exist BEFORE the
     [Replica.t] that both the predicate and the hook need to read back. A per-replica slot resolves
     it in the only direction that is actually safe -- the predicate is consulted only from inside
     an append, and no append can happen before the replica exists. *)
  let slots = Array.init replica_count (fun _ -> ref None) in
  let storages =
    Array.init replica_count (fun i ->
        let d = Filename.concat wal_root (string_of_int i) in
        Unix.mkdir d 0o700;
        let may_evict =
          match wiring with
          | Ungated -> None
          | Full | Hook_disabled ->
            Some
              (fun ~op_number ->
                let watermark = !(watermarks.(i)) in
                let verdict =
                  match !(slots.(i)) with
                  | None -> true (* unreachable: nothing appends before the replica exists *)
                  | Some r ->
                    op_number <= watermark
                    || not (Batch_commit.write_at_op_number_has_merge_key r ~op_number)
                in
                asks :=
                  { ask_replica = i; ask_op_number = op_number; ask_watermark = watermark;
                    ask_verdict = verdict }
                  :: !asks;
                verdict)
        in
        File_storage.create ~sw ~fs ~ring_capacity:wm_ring_capacity ?may_evict d)
  in
  let replicas =
    Array.init replica_count (fun i ->
        let on_commit_advanced =
          match wiring with
          | Hook_disabled | Ungated -> None
          | Full ->
            Some
              (fun ~old_commit:_ ~new_commit ->
                if not !(stalled.(i)) then
                  match !(slots.(i)) with
                  | None -> () (* unreachable: the hook is never invoked retroactively at create *)
                  | Some r ->
                    Batch_commit.materialize_up_to r ~materialize:sinks.(i)
                      ~through_commit_number:new_commit;
                    watermarks.(i) := new_commit)
        in
        let r =
          Replica.create ?on_commit_advanced
            ~storage:(Replica.storage_of_module (module File_storage) storages.(i))
            ~my_id:(i + 1) ~replica_count ~svc_limit:3
            ~send:(fun ~to_ bytes -> Queue.add (to_, bytes) inflight)
            ()
        in
        slots.(i) := Some r;
        (* DECISION 2's restart-recovery mechanism, run at construction on every replica: a
           freshly-built consumer re-materializes its replica's already-recovered committed prefix
           and seeds its watermark from [commit_number], because replica.mli states plainly that
           the hook is "not invoked retroactively" and a restart-time consumer must read
           [commit_number] itself. On a fresh replica that prefix is empty and this is a no-op --
           asserted rather than assumed by the caller below, which is the only honest way to claim
           the mechanism is safe to run unconditionally at every construction. *)
        Batch_commit.materialize_up_to r ~materialize:sinks.(i)
          ~through_commit_number:(Replica.commit_number r);
        watermarks.(i) := Replica.commit_number r;
        r)
  in
  (* Same view pin, for the same reason, as every other cluster harness in this file. *)
  Array.iter (fun r -> Replica.for_test_set_view_number r 1) replicas;
  let tap = ref [] in
  let deliver () =
    while not (Queue.is_empty inflight) do
      let to_, bytes = Queue.pop inflight in
      tap := (to_, bytes) :: !tap;
      Replica.handle_message replicas.(to_ - 1) bytes
    done
  in
  let propose n =
    let payload, merge_key =
      if wm_has_merge_key n then (G_set.to_value (G_set.of_list [ wm_value n ]), Some wm_merge_key)
      else (G_set.to_value (G_set.of_list [ wm_unmaterialized_value n ]), None)
    in
    (* No [~materialize] anywhere, ever, and only ever against the primary: every accumulator below
       is populated exclusively by [?on_commit_advanced]. *)
    Batch_commit.propose replicas.(0)
      ~idempotency_key:(Printf.sprintf "k%d" n)
      [ write_of ?merge_key payload ]
  in
  let clear_stall i =
    stalled.(i) := false;
    Batch_commit.materialize_up_to replicas.(i) ~materialize:sinks.(i)
      ~through_commit_number:(Replica.commit_number replicas.(i));
    watermarks.(i) := Replica.commit_number replicas.(i)
  in
  f
    {
      wm_replicas = replicas;
      wm_storages = storages;
      wm_materializers = materializers;
      wm_watermarks = watermarks;
      wm_stalled = stalled;
      wm_asks = asks;
      wm_tap = tap;
      wm_propose = propose;
      wm_deliver = deliver;
      wm_clear_stall = clear_stall;
    }

(* Every replica's accumulator must always be exactly the [merge_key] writes of ops
   [1 .. its own watermark] -- the single invariant the whole closure exists to maintain, and
   strictly stronger than "the evicted entry survived": it catches a MISSING contribution, an EXTRA
   one (a no-merge_key payload folded in, a write materialized past the watermark it was recorded
   at), and any divergence between two replicas that reached the same watermark. *)
let wm_check_accumulators ~phase ctx =
  Array.iteri
    (fun i m ->
      let expected = wm_expected_accumulator ~through:!(ctx.wm_watermarks.(i)) in
      Alcotest.(check (list string))
        (Printf.sprintf "[%s] replica %d's accumulator is exactly the merge_key writes through its \
                         own watermark %d"
           phase (i + 1) !(ctx.wm_watermarks.(i)))
        (G_set.elements expected)
        (G_set.elements (M.read m ~merge_key:wm_merge_key)))
    ctx.wm_materializers

let test_a_followers_ring_eviction_is_gated_by_its_own_watermark () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  with_watermark_cluster ~env ~sw ~wiring:Full @@ fun ctx ->
  let primary = ctx.wm_replicas.(0) in
  let follower = 1 in
  (* Step 1's own claim, asserted rather than assumed: the construction-time re-materialize every
     replica just ran is a safe no-op on a fresh replica. *)
  Array.iteri
    (fun i r ->
      Alcotest.(check int) (Printf.sprintf "replica %d starts at commit_number 0" (i + 1)) 0
        (Replica.commit_number r);
      Alcotest.(check int) "...and at watermark 0" 0 !(ctx.wm_watermarks.(i));
      Alcotest.(check (list string))
        "...and the construction-time re-materialize folded nothing in" []
        (G_set.elements (M.read ctx.wm_materializers.(i) ~merge_key:wm_merge_key)))
    ctx.wm_replicas;
  Alcotest.(check int) "...and [?may_evict] has not been consulted at all yet" 0
    (List.length !(ctx.wm_asks));

  (* ---- PHASE A: run the ring right past its capacity, with everything healthy ---- *)
  for n = 1 to 8 do
    ctx.wm_propose n;
    ctx.wm_deliver ()
  done;
  Alcotest.(check int) "the primary committed all 8 batches" 8 (Replica.commit_number primary);
  (* A follower learns commit [n-1] from the [Prepare] carrying op [n] (there is no Commit message
     in this VSR subset), so it necessarily trails the primary by exactly one here. *)
  Alcotest.(check int) "every follower learned commit 7 from the last Prepare it processed" 7
    !(ctx.wm_watermarks.(follower));
  wm_check_accumulators ~phase:"phase-A" ctx;

  (* ASSERTION 1: the ring genuinely evicted -- and it is the FOLLOWER's own durable slot, not the
     primary's, that matters here. Op 1..4's slots were physically overwritten by ops 5..8. *)
  Array.iteri
    (fun i s ->
      for op_number = 1 to 4 do
        Alcotest.(check bool)
          (Printf.sprintf "replica %d's ring genuinely evicted op %d" (i + 1) op_number)
          true
          (File_storage.wal_read s ~op_number = None)
      done)
    ctx.wm_storages;
  Alcotest.(check bool) "...and the follower's own replica-level durable read agrees" true
    (Replica.for_test_wal_read ctx.wm_replicas.(follower) ~op_number:1 = None);
  Alcotest.(check bool) "...while the four most recent slots are all still readable" true
    (Array.for_all
       (fun s ->
         List.for_all (fun op_number -> File_storage.wal_read s ~op_number <> None) [ 5; 6; 7; 8 ])
       ctx.wm_storages);

  (* ASSERTION 2: the evicted entry's contribution survives, on the FOLLOWER, converged -- with no
     [propose ~materialize] and no [materialize_up_to] ever called against that follower by this
     test. The only thing that could have put it there is its own [?on_commit_advanced] hook firing
     off [handle_message]. *)
  Alcotest.(check bool)
    "the follower's accumulator still holds op 1's contribution, whose durable slot is gone" true
    (List.mem (wm_value 1) (G_set.elements (M.read ctx.wm_materializers.(follower) ~merge_key:wm_merge_key)));
  for i = 1 to replica_count - 1 do
    Alcotest.(check (list string))
      (Printf.sprintf "replica %d converged to the same accumulator as replica 2" (i + 1))
      (G_set.elements (M.read ctx.wm_materializers.(1) ~merge_key:wm_merge_key))
      (G_set.elements (M.read ctx.wm_materializers.(i) ~merge_key:wm_merge_key))
  done;

  (* ASSERTION 3, first half: no-merge_key writes are in the run and are genuinely evicted, and none
     of them ever caused a refusal. Their payloads must also appear in no accumulator at all. *)
  Alcotest.(check int) "no eviction has been refused anywhere yet" 0
    (Array.fold_left (fun acc r -> acc + refusal_count r "eviction_blocked") 0 ctx.wm_replicas);
  Alcotest.(check bool) "[?may_evict] was genuinely consulted, repeatedly (not a vacuous gate)" true
    (List.length !(ctx.wm_asks) >= 4 * replica_count);
  Array.iteri
    (fun i m ->
      let elements = G_set.elements (M.read m ~merge_key:wm_merge_key) in
      Alcotest.(check bool)
        (Printf.sprintf "replica %d never materialized a no-merge_key payload" (i + 1))
        false
        (List.exists
           (fun n -> List.mem (wm_unmaterialized_value n) elements)
           wm_no_merge_key_ops))
    ctx.wm_materializers;

  (* ---- PHASE B: one follower's materialize sink stalls, and its watermark falls behind ---- *)
  let blocked_before = refusal_count ctx.wm_replicas.(follower) "eviction_blocked" in
  ctx.wm_stalled.(follower) := true;
  let watermark_at_stall = !(ctx.wm_watermarks.(follower)) in
  Alcotest.(check int) "the stall begins with the follower's watermark at 7" 7 watermark_at_stall;
  for n = 9 to 13 do
    ctx.wm_propose n;
    ctx.wm_deliver ()
  done;
  Alcotest.(check int) "the stalled follower's watermark genuinely froze" watermark_at_stall
    !(ctx.wm_watermarks.(follower));
  Alcotest.(check int) "...while the cluster kept committing without it (3 of 5 is a quorum)" 13
    (Replica.commit_number primary);
  wm_check_accumulators ~phase:"phase-B-backlog" ctx;

  (* ASSERTION 4(b): the promoted refusal counter genuinely rises, on exactly the replica whose
     materialization fell behind and nowhere else -- replica.mli's own "intended production use" for
     it. Exactly ONE refusal, and that is a property of the protocol rather than a coincidence:
     [handle_prepare]'s refusal is a total no-op, so this follower's [op_number] never advances to
     13, and every later [Prepare] is dropped by the [n = op_number + 1] ordering guard BEFORE the
     backend is reached at all. Asserting the exact value pins that, where [>= 1] would not. *)
  Alcotest.(check int) "the stalled follower refused exactly one eviction" (blocked_before + 1)
    (refusal_count ctx.wm_replicas.(follower) "eviction_blocked");
  Array.iteri
    (fun i r ->
      if i <> follower then
        Alcotest.(check int)
          (Printf.sprintf "replica %d, whose materialization kept up, refused nothing" (i + 1))
          0
          (refusal_count r "eviction_blocked"))
    ctx.wm_replicas;
  (* And no OTHER refusal shape anywhere: no fault injector in this scenario, no oversized entry,
     and (because a refusal stops this follower appending rather than leaving a rewritten hole) no
     out-of-sequence append either. A non-zero count in any of these would mean this scenario is
     measuring something other than eviction. *)
  Array.iteri
    (fun i r ->
      List.iter
        (fun name ->
          Alcotest.(check int)
            (Printf.sprintf "replica %d recorded no %s refusal" (i + 1) name)
            0 (refusal_count r name))
        [ "fault_injection_cap"; "entry_rejected"; "out_of_sequence" ])
    ctx.wm_replicas;

  (* ASSERTION 4(a), first half: NOTHING WAS LOST. The entry the refusal protected (op 9, a
     merge_key write this follower has committed but not yet materialized) is still durably
     readable on its own disk -- while the very same op-number has ALREADY been evicted on every
     replica that did materialize it. Same op, same ring, same capacity: retained exactly where it
     was still needed, reclaimed exactly where it was not. *)
  Alcotest.(check bool) "op 9 is still durably readable on the stalled follower" true
    (File_storage.wal_read ctx.wm_storages.(follower) ~op_number:9 <> None);
  Alcotest.(check bool)
    "...and op 9 has NOT yet been materialized there (which is precisely why it is still there)"
    false
    (List.mem (wm_value 9)
       (G_set.elements (M.read ctx.wm_materializers.(follower) ~merge_key:wm_merge_key)));
  Array.iteri
    (fun i s ->
      if i <> follower then
        Alcotest.(check bool)
          (Printf.sprintf "op 9 WAS evicted on replica %d, which had already materialized it"
             (i + 1))
          true
          (File_storage.wal_read s ~op_number:9 = None))
    ctx.wm_storages;

  (* ASSERTION 3, second half -- the part that needs the stall to be observable at all. During the
     backlog the predicate was asked about op 8, a NO-merge_key entry, with the watermark at 7: the
     watermark half of the predicate said no and the eviction went ahead anyway, purely because that
     write never claimed materialization's protection. That is the disclosed boundary proven intact
     under exactly the conditions that would refuse a protected entry, rather than under conditions
     where the watermark would have permitted it regardless. *)
  let asks = !(ctx.wm_asks) in
  Alcotest.(check bool)
    "a no-merge_key entry ABOVE the watermark was still freely evicted (the disclosed boundary is \
     untouched by the new gate)"
    true
    (List.exists
       (fun a ->
         a.ask_verdict && (not (wm_has_merge_key a.ask_op_number))
         && a.ask_op_number > a.ask_watermark)
       asks);
  Alcotest.(check bool)
    "...and NO no-merge_key entry was ever refused, on any replica, at any watermark" true
    (List.for_all (fun a -> a.ask_verdict || wm_has_merge_key a.ask_op_number) asks);
  Alcotest.(check bool)
    "...while every refusal there was concerned a merge_key entry above that replica's watermark"
    true
    (List.for_all
       (fun a -> a.ask_verdict || (wm_has_merge_key a.ask_op_number && a.ask_op_number > a.ask_watermark))
       asks);

  (* ASSERTION 4(a), second half: the backlog clears, and the write that was held durable
     materializes. This is the same drain the hook itself performs -- the owner re-reads its own
     committed prefix and republishes its watermark. *)
  ctx.wm_clear_stall follower;
  Alcotest.(check int) "the cleared follower's watermark caught up to its own commit_number"
    (Replica.commit_number ctx.wm_replicas.(follower))
    !(ctx.wm_watermarks.(follower));
  Alcotest.(check bool) "op 9 -- durable throughout the backlog -- is now materialized" true
    (List.mem (wm_value 9)
       (G_set.elements (M.read ctx.wm_materializers.(follower) ~merge_key:wm_merge_key)));
  wm_check_accumulators ~phase:"backlog-cleared" ctx;

  (* ---- PHASE C: the cluster keeps working afterwards ---- *)
  let blocked_after_clearing =
    Array.fold_left (fun acc r -> acc + refusal_count r "eviction_blocked") 0 ctx.wm_replicas
  in
  for n = 14 to 15 do
    ctx.wm_propose n;
    ctx.wm_deliver ()
  done;
  Alcotest.(check int) "the cluster committed the later batches too" 15
    (Replica.commit_number primary);
  Alcotest.(check int) "and refused no further eviction anywhere" blocked_after_clearing
    (Array.fold_left (fun acc r -> acc + refusal_count r "eviction_blocked") 0 ctx.wm_replicas);
  wm_check_accumulators ~phase:"phase-C" ctx;
  (* WHY THAT FOLLOWER IS BEHIND, stated precisely (fix round 1, review finding 5 -- the earlier
     wording here claimed it "stays behind until a [Start_view] repairs its durable hole", which
     describes a state this scenario never reaches). It is NOT holding a durable hole:
     [handle_prepare]'s eviction refusal returns BEFORE the in-memory [Replica_log.append], so
     nothing was half-applied -- its WAL, its [op_number] and its in-memory log all still agree
     exactly at op 12, and every entry it holds is readable (that is the [Replica_log.length <>
     op_number] state replica.mli's own [out_of_sequence]/restart-time guidance is about, and this
     follower is not in it). What it lost is one MESSAGE: the [Prepare] carrying op 13, which this
     harness never retransmits because this VSR subset has no retransmission timer at all. Every
     LATER [Prepare] is then dropped by [handle_prepare]'s own [n = op_number + 1] ordering guard --
     by message ordering, not by any storage state. So the cost of a refusal is exactly "this replica
     needs that one [Prepare] again", which phase D below proves is all it needs. *)
  Alcotest.(check bool) "the follower that refused an append is genuinely behind the others" true
    (Replica.commit_number ctx.wm_replicas.(follower) < Replica.commit_number primary);
  for i = 2 to replica_count - 1 do
    Alcotest.(check (list string))
      (Printf.sprintf "replicas 3 and %d, both caught up, hold identical accumulators" (i + 1))
      (G_set.elements (M.read ctx.wm_materializers.(2) ~merge_key:wm_merge_key))
      (G_set.elements (M.read ctx.wm_materializers.(i) ~merge_key:wm_merge_key))
  done;

  (* ---- PHASE D (fix round 1, review finding I1): THE REFUSAL IS A RETRIED NO-OP, not merely a
     traceless one.

     WHAT WAS MISSING. This plan's own Review Focus requires a blocked eviction to be "a silent,
     RETRIED no-op". Everything above -- and test_file_storage.ml's own refusal tests -- proves only
     the SILENT/traceless half: the refusal changed nothing, anywhere, so a retry COULD be safe.
     Nothing anywhere re-offered the refused append after the gate's predicate relented, so "the same
     op_number succeeds on retry" was asserted in prose and demonstrated nowhere.

     WHY IT IS DONE BY RE-DELIVERING THE ORIGINAL BYTES, which is the real mechanism and not an
     artificial one. The natural cluster flow CANNOT produce this retry by itself, and that is a
     property of the protocol rather than of this harness: [handle_prepare]'s refusal is a total
     no-op, so this follower's [op_number] stays at 12 and every subsequent [Prepare] (14, 15, ...)
     is dropped by the [n = op_number + 1] ordering guard -- phase C above asserts exactly that
     stall. There is no retransmission timer in this VSR subset (VSR.tla models none), and the only
     re-drive [Replica] has is [check_timeout]'s view change, which this file excludes by its own
     stated scope. The retry a real deployment supplies is therefore a transport-level redelivery of
     the same [Prepare], and that is precisely what this does: the identical bytes the harness
     already delivered once, taken from [wm_tap] and re-decoded to confirm which op they carry, fed
     back into the SAME replica. Nothing is synthesised, no state is reached into. *)
  let follower_r = ctx.wm_replicas.(follower) in
  let refused_op = 13 in
  let prepare_bytes =
    match wm_find_prepare ctx.wm_tap ~to_:(follower + 1) ~n:refused_op with
    | Some bytes -> bytes
    | None ->
      Alcotest.fail
        (Printf.sprintf "harness precondition: no Prepare for op %d was ever delivered to replica %d"
           refused_op (follower + 1))
  in
  (* The preconditions that make this a genuine RETRY of the refused append rather than a fresh one:
     the entry is still absent durably, the replica is still exactly where the refusal left it, and
     the predicate that refused now permits -- its watermark has passed op 9, the entry whose
     eviction it was protecting. *)
  Alcotest.(check int) "the stalled follower is still exactly where the refusal left it" 12
    (Replica.op_number follower_r);
  Alcotest.(check bool)
    (Printf.sprintf "op %d is not durable on it (the refusal is why -- nothing was written)"
       refused_op)
    true
    (File_storage.wal_read ctx.wm_storages.(follower) ~op_number:refused_op = None);
  Alcotest.(check bool)
    "...and the predicate that refused has now relented: this replica's watermark has passed op 9, \
     the entry whose eviction op 13's append needs"
    true
    (!(ctx.wm_watermarks.(follower)) >= 9);
  let refusals_before_retry = refusal_count follower_r "eviction_blocked" in
  let watermark_after_clearing = !(ctx.wm_watermarks.(follower)) in
  (* THE NEGATIVE CONTROL, permanent rather than an experiment someone once ran by hand -- the same
     discipline assertion 5's two controls above already follow. It is the RELENTING that makes the
     retry succeed, not the redelivery: with this consumer's own watermark rolled back to where the
     stall left it (7 -- a plain in-memory value it owns, so rolling it back is modelling a consumer
     that has not caught up, not reaching into any protocol state), the identical bytes are refused
     all over again, leaving the identical traceless no-op. Without this, "the retry succeeded"
     would be equally consistent with the gate having become inert. *)
  ctx.wm_watermarks.(follower) := watermark_at_stall;
  Replica.handle_message follower_r prepare_bytes;
  Alcotest.(check int)
    "negative control: redelivered to a consumer still behind, the SAME bytes are refused again"
    (refusals_before_retry + 1)
    (refusal_count follower_r "eviction_blocked");
  Alcotest.(check int) "...leaving the replica exactly where it was, again" 12
    (Replica.op_number follower_r);
  Alcotest.(check bool) "...and op 13 still not durable" true
    (File_storage.wal_read ctx.wm_storages.(follower) ~op_number:refused_op = None);
  ctx.wm_watermarks.(follower) := watermark_after_clearing;
  let refusals_before_retry = refusal_count follower_r "eviction_blocked" in
  let asks_before_retry = List.length !(ctx.wm_asks) in
  (* THE RETRY: byte-identical redelivery, one message, no other stimulus. *)
  Replica.handle_message follower_r prepare_bytes;
  ctx.wm_deliver () (* let the [Prepare_ok] it now sends reach the primary, as normal *);
  Alcotest.(check bool)
    (Printf.sprintf
       "the gate was consulted again on the retry (so this is a real second pass through it)" )
    true
    (List.length !(ctx.wm_asks) > asks_before_retry);
  Alcotest.(check int)
    (Printf.sprintf "THE SAME op_number %d now appends successfully on retry" refused_op)
    refused_op (Replica.op_number follower_r);
  Alcotest.(check bool)
    (Printf.sprintf "...and op %d is now genuinely DURABLE on the replica that refused it" refused_op)
    true
    (File_storage.wal_read ctx.wm_storages.(follower) ~op_number:refused_op <> None);
  Alcotest.(check int)
    "...with no NEW refusal recorded: the retry was accepted, not refused a second time"
    refusals_before_retry
    (refusal_count follower_r "eviction_blocked");
  (* And the eviction the gate had been holding back happened, exactly now that it is safe: op 9's
     slot is what op 13 reuses, and op 9 has been materialized since [clear_stall]. Retained exactly
     while it was needed, reclaimed as soon as it was not -- the whole mechanism, in one op-number. *)
  Alcotest.(check bool)
    "op 9's slot -- held back by the refusal, materialized since -- was reclaimed by op 13's append"
    true
    (File_storage.wal_read ctx.wm_storages.(follower) ~op_number:9 = None);
  Alcotest.(check bool) "...and op 9's contribution is still in the accumulator, unaffected" true
    (List.mem (wm_value 9)
       (G_set.elements (M.read ctx.wm_materializers.(follower) ~merge_key:wm_merge_key)));
  wm_check_accumulators ~phase:"phase-D-retry-after-relent" ctx

(* ASSERTION 5, NON-VACUITY, as two permanent running controls rather than an experiment.

   This whole plan's established discipline is to prove a test discriminates by making the defect
   reappear, not by reasoning that it would. Both controls below run the SAME workload as phase A
   above through the SAME harness, with one piece of the closure removed each, and assert the exact
   damage that piece prevents. If [test_a_followers_ring_eviction_is_gated_by_its_own_watermark]
   above ever becomes vacuous, these two are what still fail.

   [Ungated] is the one that matters most: it is the pre-subtask-3.7 world exactly (file_storage.mli
   guarantees omitting [?may_evict] is byte-identical to the old behaviour), and it loses committed,
   quorum-acknowledged, merge_key-carrying data on every replica at once with no fault injected. *)

let test_without_the_watermark_hook_the_same_scenario_loses_the_entry () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  with_watermark_cluster ~env ~sw ~wiring:Ungated @@ fun ctx ->
  for n = 1 to 8 do
    ctx.wm_propose n;
    ctx.wm_deliver ()
  done;
  Alcotest.(check int) "the cluster committed all 8 batches, exactly as in the gated run" 8
    (Replica.commit_number ctx.wm_replicas.(0));
  (* THE LOSS, in both places at once: op 1 was a committed, acknowledged merge_key write, and it is
     now durably readable on NO replica and present in NO accumulator. Nothing raised, nothing was
     counted, and the cluster looks perfectly healthy. *)
  Alcotest.(check bool)
    "with neither the hook nor the gate, op 1's durable slot is gone on EVERY replica" true
    (Array.for_all (fun s -> File_storage.wal_read s ~op_number:1 = None) ctx.wm_storages);
  Array.iteri
    (fun i m ->
      Alcotest.(check (list string))
        (Printf.sprintf "...and replica %d's accumulator never received it (nothing drove it)"
           (i + 1))
        []
        (G_set.elements (M.read m ~merge_key:wm_merge_key)))
    ctx.wm_materializers;
  Alcotest.(check int) "...and not one eviction was refused, because nothing was asked" 0
    (Array.fold_left (fun acc r -> acc + refusal_count r "eviction_blocked") 0 ctx.wm_replicas);
  Alcotest.(check int) "...indeed [?may_evict] was never consulted at all" 0
    (List.length !(ctx.wm_asks))

let test_the_gate_without_the_hook_is_a_brake_rather_than_a_mechanism () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  with_watermark_cluster ~env ~sw ~wiring:Hook_disabled @@ fun ctx ->
  for n = 1 to 8 do
    ctx.wm_propose n;
    ctx.wm_deliver ()
  done;
  (* With no hook, every watermark stays at 0 forever, so the FIRST eviction of a merge_key entry is
     refused -- on the primary, inside its own [propose], before any [Prepare] is ever sent. The log
     therefore stops dead at [ring_capacity]. *)
  Alcotest.(check int) "the log never grew past the ring's capacity" wm_ring_capacity
    (Replica.op_number ctx.wm_replicas.(0));
  Alcotest.(check int) "...and commit stopped there too" wm_ring_capacity
    (Replica.commit_number ctx.wm_replicas.(0));
  Alcotest.(check bool) "the primary refused every later proposal's append" true
    (refusal_count ctx.wm_replicas.(0) "eviction_blocked" >= 1);
  (* Nothing is LOST -- that is what the gate buys, and it is a real improvement over [Ungated]
     above. But nothing is materialized either, so the committed prefix is protected by a promise
     no consumer is keeping. The hook is what makes the gate relent, which is why Task 6 needs both
     and why this file's main test wires both. *)
  Alcotest.(check bool) "every committed entry is still durably readable (nothing was lost)" true
    (Array.for_all
       (fun s ->
         List.for_all
           (fun op_number -> File_storage.wal_read s ~op_number <> None)
           [ 1; 2; 3; 4 ])
       ctx.wm_storages);
  Array.iteri
    (fun i m ->
      Alcotest.(check (list string))
        (Printf.sprintf "replica %d materialized nothing, having no hook to do it" (i + 1))
        []
        (G_set.elements (M.read m ~merge_key:wm_merge_key)))
    ctx.wm_materializers

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
    ~send:(fun ~to_:_ (_ : string) -> ()) ()

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
      ~kv:(File_kv_store.create ~sw ~fs ~owner:Redaction_store.owner_tag keystore_dir)
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
      ~kv:(File_kv_store.create ~sw ~fs:(Eio.Stdenv.fs env) ~owner:Redaction_store.owner_tag keystore_dir)
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
  (* The [Invalid_argument] escapes the whole loop, so there is no in-loop guard to write: the
     [for] simply stops where the cap is hit. *)
  (try
     for n = 1 to 400 do
       propose n
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

(* ---------------------------------------------------------------------------------------------
   A THIRD FINDING, ONCE PINNED RATHER THAN FIXED, NOW CLOSED AT CONSTRUCTION TIME (subtask 4.6):
   one {!Riptide_storage.File_kv_store} directory shared between a {!Riptide_crypto.Redaction_store}
   keystore and a {!Riptide_materialize.Materializer} accumulator store used to let an ORDINARY
   materialized write destroy an encrypted record's wrapped DEK, with no error anywhere and nothing
   about either store looking broken afterwards.

   Why it was reachable rather than theoretical: [File_kv_store]'s key space is flat and untyped
   (one file per key, named by the hash of the key), the keystore's keys are exactly the plain
   strings {!Batch_commit.redaction_event_id} derives, and a materializer's keys are caller-chosen
   [merge_key]s -- so a single [merge_key] shaped like "{length}:{idempotency_key}#{index}" was the
   whole exploit. Nothing in either module's type or contract stopped it on its own, and the
   derivation is public and documented, so the colliding shape was not even hard to produce by
   accident.

   {!Riptide_storage.File_kv_store.create}'s new [?owner] (subtask 4.6) closes it, FOR CALLERS WHO
   PASS IT: this test builds the keystore's [kv] with [~owner:Redaction_store.owner_tag] and then
   attempts to build a real materializer -- through this file's own [make_materializer], the same
   constructor every other materializer here is built with -- pointed at the exact same directory,
   and asserts that the [File_kv_store.create] inside that helper raises [Invalid_argument] before
   [Materializer.create], any [M.write], or any decode strategy ever enters the picture.

   Going through [make_materializer] rather than a bare, inline [File_kv_store.create
   ~owner:"materializer"] is deliberate and was a review finding against this test's first form.
   An inline, correctly-tagged call proves the guard fires when someone passes the tag; it proves
   nothing about whether any materializer this repo actually constructs passes it -- and at the
   time, none did, on any of the four real materializer-side call sites, so the guard was inert
   everywhere it mattered while this test still passed. Routing through the real helper ties the
   assertion to the production-shaped call path, so it fails the moment that path stops opting in.

   The protection is strictly opt-in and this file proves BOTH halves of that: see
   [test_omitting_owner_on_the_materializer_side_alone_still_destroys_a_wrapped_dek] at the end of
   this file for the running negative control showing the hazard is entirely undiminished for a
   materializer that omits [~owner], even though (subtask 4.8) the keystore side there is, and now
   must be, correctly tagged -- exactly as file_kv_store.mli's own [?owner] doc, and
   redaction_store.mli's own [create] doc, both disclose.

   {b What the guard buys, stated against what this hazard used to cost} -- and note this is an
   improvement ON TOP OF the reproduction, not a replacement for it: an opted-in pair can never
   both come into existence pointed at the same directory at all. Construction fails immediately,
   synchronously, with a message naming exactly which owner already holds the directory, regardless
   of decode strategy -- so for such a pair there is no longer a "silent" corruption direction to
   distinguish from a "loud" one, because no materializer variant can be built in the first place
   to produce either. Previously the only recourse was to run the full exploit and observe the
   damage after the fact, and in the silent direction nothing short of noticing an unopenable
   record much later would ever reveal it. The keystore itself, and the record already stored in
   it, are provably untouched by the rejected attempt (checked below) -- not merely presumed safe
   because nothing crashed. *)

let test_a_shared_kv_directory_is_rejected_at_construction () =
  Eio_main.run @@ fun env ->
  with_tmp_dir @@ fun shared_dir ->
  Eio.Switch.run @@ fun sw ->
  let fs = Eio.Stdenv.fs env in
  (* ONE directory, two consumers -- exactly what redaction_store.mli warns callers not to do
     without opting into [?owner]. This test opts in on the keystore side. *)
  let store =
    Redaction_store.create
      ~kv:(File_kv_store.create ~sw ~fs ~owner:Redaction_store.owner_tag shared_dir)
      ~kek:(Kek.of_raw (Mirage_crypto_rng.generate 32))
  in
  let replica = create_solo () in
  let payload = secret_payload_with "RIPTIDE-COLLISION-VICTIM" in
  Batch_commit.propose replica ~idempotency_key:"k1" ~encryption:(enc_sink store) [ write_of payload ];
  let event_id, envelope = List.hd (Batch_commit.committed_envelopes_keyed replica) in
  Alcotest.(check string) "the keystore key is a plain, publicly derivable string" "2:k1#0" event_id;
  Alcotest.(check bool) "the record really is recoverable while its wrapped DEK is intact" true
    (Redaction_store.decrypt_value store ~event_id envelope.Riptide.Envelope.payload
    = Some (canonical payload));
  (* The exploit attempt, made THROUGH THIS FILE'S REAL MATERIALIZER CONSTRUCTOR rather than
     through a bare [File_kv_store.create ~owner:"materializer"] written inline here. That
     distinction is the whole point and was the substance of a review finding against this test's
     first form: a hand-written, correctly-tagged [create] proves only that the guard fires when
     someone passes the tag, not that any materializer this repo actually builds passes it. Going
     through [make_materializer] means this assertion fails the moment that helper -- the shape a
     real caller follows -- stops opting in, which is exactly the regression worth catching.
     Note also that the raise comes from strictly inside [make_materializer]: the [kv] argument is
     evaluated before [Materializer.create] is entered, so no materializer, no decode strategy and
     no [M.write] ever exists to do damage. *)
  Alcotest.check_raises
    "building a real materializer over the keystore's own directory is rejected at construction"
    (Invalid_argument
       (Printf.sprintf "File_kv_store.create: %s is owned by \"redaction-keystore\", not \
                         \"materializer\""
          shared_dir))
    (fun () -> ignore (make_materializer ~sw ~fs shared_dir));
  (* Non-vacuity: the keystore and the record it already holds are completely untouched by the
     rejected attempt -- construction failed strictly before either consumer could touch the shared
     directory's data at all, not merely before the materialized write that used to do the damage. *)
  Alcotest.(check bool) "the record is still fully recoverable after the rejected collision attempt"
    true
    (Redaction_store.decrypt_value store ~event_id envelope.Riptide.Envelope.payload
    = Some (canonical payload));
  Alcotest.(check int) "the committed log still holds exactly the one record" 1
    (List.length (Batch_commit.committed_envelopes replica))

(* ---------------------------------------------------------------------------------------------
   THE SAME HAZARD, STILL LIVE FOR A MATERIALIZER THAT OPTS OUT -- a running proof of the
   limitation file_kv_store.mli's [?owner] doc states in prose: an untagged
   [File_kv_store.create] is a pure no-op with respect to the marker check, REGARDLESS of what
   marker, if any, already sits on disk from a correctly-tagged co-claimant.

   {b Narrowed by subtask 4.8, from what it used to demonstrate.} Before subtask 4.8,
   [Redaction_store.create] accepted whatever [kv] it was handed on faith, so this test's keystore
   side could -- and did -- omit [~owner] too, matching the "if EITHER side ... omits [owner] --
   not just both" phrasing that sentence still uses about {!Riptide_storage.File_kv_store.create}'s
   own, generic guard. Subtask 4.8 changed what's reachable through {!Redaction_store.create}
   specifically: it now REQUIRES [kv]'s owner to read back as [Some Redaction_store.owner_tag], so
   a redaction store whose own [kv] omits [~owner] can no longer be constructed at all -- that
   half of the original two-sided omission is gone, and the test below reflects that: its keystore
   is built with [~owner:Redaction_store.owner_tag], exactly like every other keystore in this
   file. What subtask 4.8 does NOT and cannot close is the other side: a SECOND consumer (here, a
   materializer) pointing its own {!Riptide_storage.File_kv_store.create} at the same directory
   with no [~owner] at all skips the marker check on ITS OWN call entirely, independent of
   anything already claimed there -- so that omission, alone, still reproduces the full hazard.

   This test exists because that residual, one-sided gap is a real, load-bearing fact about the
   shape of subtask 4.6+4.8 together, not a caveat: the guard is a marker file compared between two
   CLAIMING callers, so it cannot possibly protect a directory that a second caller never claims,
   no matter how correctly the first caller claimed it. An earlier fix round deleted this file's
   original three-direction reproduction of the hazard on the grounds that construction now fails
   first -- which is true only on the opted-in path, and left the documented opted-out path
   asserted in prose with nothing running behind it. This is the reduced restoration: two of the
   original three directions, enough to show the destruction is real and bidirectional, without
   re-litigating the partial-vs-total [decode] distinction the opted-in test above already makes
   moot for every protected caller.

   Read it as the negative control for
   [test_a_shared_kv_directory_is_rejected_at_construction] above: same directory-sharing setup,
   same collision, the only difference being that the materializer side doesn't pass [~owner] --
   and the outcome flips from "rejected at construction, data provably intact" back to "silent,
   total destruction with nothing raising anywhere," even though the keystore side is, and now must
   be, correctly tagged. That contrast is what shows the guard's protection comes from BOTH sides
   claiming the directory, not from either side alone, however correctly that one side claims it.
   --------------------------------------------------------------------------------------------- *)

let test_omitting_owner_on_the_materializer_side_alone_still_destroys_a_wrapped_dek () =
  Eio_main.run @@ fun env ->
  with_tmp_dir @@ fun shared_dir ->
  Eio.Switch.run @@ fun sw ->
  let fs = Eio.Stdenv.fs env in
  (* The keystore side is correctly tagged -- subtask 4.8 makes this mandatory, not optional, for
     any [kv] passed to [Redaction_store.create]. Only the materializer below, built through the
     deliberately untagged [make_unowned_lenient_materializer], omits [~owner]. That single
     omission, on the one side subtask 4.8 cannot reach, is enough on its own. *)
  let store =
    Redaction_store.create
      ~kv:(File_kv_store.create ~sw ~fs ~owner:Redaction_store.owner_tag shared_dir)
      ~kek:(Kek.of_raw (Mirage_crypto_rng.generate 32))
  in
  let replica = create_solo () in
  let payload = secret_payload_with "RIPTIDE-COLLISION-VICTIM" in
  Batch_commit.propose replica ~idempotency_key:"k1" ~encryption:(enc_sink store) [ write_of payload ];
  let event_id, envelope = List.hd (Batch_commit.committed_envelopes_keyed replica) in
  Alcotest.(check string) "the keystore key is a plain, publicly derivable string" "2:k1#0" event_id;
  Alcotest.(check bool) "the record really is recoverable before the collision" true
    (Redaction_store.decrypt_value store ~event_id envelope.Riptide.Envelope.payload
    = Some (canonical payload));
  (* The unowned materializer constructs FINE -- this is the first half of the finding: no marker
     was ever written, so there is nothing for [create] to compare against and nothing to reject. *)
  let mat = make_unowned_lenient_materializer ~sw ~fs shared_dir in
  (* DIRECTION 1, the silent one: an ordinary materialized write whose [merge_key] happens to equal
     that [event_id]. Not a redaction, not a fault, not an error -- and with a total [decode], not
     even a raise. *)
  M.write mat ~merge_key:event_id (G_set.of_list [ "innocent-accumulator-value" ]);
  Alcotest.(check bool)
    "the encrypted record is now permanently unreadable, and nothing raised to say so" true
    (Redaction_store.decrypt_value store ~event_id envelope.Riptide.Envelope.payload = None);
  (* Non-vacuity, and the reason this is silent rather than merely destructive: everything else
     looks perfectly healthy afterwards. The accumulator holds exactly what it was asked to hold,
     and the committed log is untouched -- the loss is indistinguishable from a deliberate
     redaction of that one record. *)
  Alcotest.(check (list string)) "while the accumulator write itself succeeded normally"
    [ "innocent-accumulator-value" ]
    (G_set.elements (M.read mat ~merge_key:event_id));
  Alcotest.(check int) "and the committed log still holds the (now unopenable) record" 1
    (List.length (Batch_commit.committed_envelopes replica));
  (* DIRECTION 2, silent in the other direction and true for ANY [decode]: the keystore's own [put]
     never reads first, so encrypting a record whose derived [event_id] collides with an EXISTING
     [merge_key] overwrites that accumulator with wrapped-DEK bytes, with no error and no read. *)
  M.write mat ~merge_key:"2:k2#0" (G_set.of_list [ "accumulated-before-the-collision" ]);
  Batch_commit.propose replica ~idempotency_key:"k2" ~encryption:(enc_sink store)
    [ write_of (secret_payload_with "RIPTIDE-COLLISION-VICTIM-2") ];
  Alcotest.(check (list string))
    "the accumulator's value is silently gone, replaced by a wrapped DEK" []
    (G_set.elements (M.read mat ~merge_key:"2:k2#0"));
  Alcotest.(check bool) "...while that record itself decrypts perfectly well" true
    (Redaction_store.decrypt_value store ~event_id:"2:k2#0"
       (List.assoc "2:k2#0" (Batch_commit.committed_envelopes_keyed replica))
         .Riptide.Envelope.payload
    <> None)

let tests =
  Lattice_conformance.tests (module G_set) g_set_arb "G_set"
  @ [
      ("adversarial sweep: materialization + redaction + storage faults, many seeds", `Slow,
       test_adversarial_sweep);
      ("the same scenario against the real on-disk ring WAL", `Slow, test_sweep_against_real_file_storage);
      ("a primary-side storage fault halts materialization exactly with commit", `Quick,
       test_a_primary_storage_fault_halts_materialization_exactly_with_commit);
      ("subtask 3.7's general case: a FOLLOWER's ring eviction is gated by its own materialization \
        watermark, driven only by ?on_commit_advanced", `Slow,
       test_a_followers_ring_eviction_is_gated_by_its_own_watermark);
      ("...and without either piece, the same scenario genuinely loses the committed entry \
        (non-vacuity control)", `Slow,
       test_without_the_watermark_hook_the_same_scenario_loses_the_entry);
      ("...while ?may_evict without the hook only brakes: nothing lost, nothing materialized, the \
        log stops at ring_capacity (non-vacuity control)", `Slow,
       test_the_gate_without_the_hook_is_a_brake_rather_than_a_mechanism);
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
      ("sharing one KV directory between a keystore and a materializer is now rejected at \
        construction (subtask 4.6)", `Quick,
       test_a_shared_kv_directory_is_rejected_at_construction);
      ("...but a materializer alone opting out of ?owner still silently destroys a wrapped DEK, \
        even with a correctly-tagged keystore (negative control)", `Quick,
       test_omitting_owner_on_the_materializer_side_alone_still_destroys_a_wrapped_dek);
    ]
