open Riptide

type write = {
  actor : Envelope.actor_id;
  causation : Envelope.event_id;
  correlation : Envelope.event_id;
  payload : Value.value;
  merge_key : string option;
}

(* ---- write <-> Value.value ----

   Mirrors Envelope.to_value's own field-encoding convention exactly (String for actor, Bytes for
   hash-typed fields) -- see lib/envelope.ml. Field LOOKUP on decode is by name (List.assoc_opt),
   never by list position: a value that went through Value.canonical_encode/decode (e.g. arrived
   over the wire, on a backup) has its Record fields canonically re-sorted alphabetically by key
   (lib/value.ml), but a value this same process proposed locally and is now reading back via
   Replica.entries never took that round-trip -- the two can have DIFFERENT in-memory field
   orders for the exact same logical batch. *)

(* merge_key <-> Value.value: a Sum-tagged encoding, the same tagging convention
   lib/vsr/message.ml already uses for its own variant wire shapes ("none"/"some" rather than a
   native Option case, since Value.value has none). *)
let merge_key_to_value = function
  | None -> Value.Sum ("none", Value.Record [])
  | Some k -> Value.Sum ("some", Value.Scalar (Value.String k))

let write_to_value (w : write) : Value.value =
  Value.Record
    [
      ("actor", Value.Scalar (Value.String w.actor));
      ("causation", Value.Scalar (Value.Bytes w.causation));
      ("correlation", Value.Scalar (Value.Bytes w.correlation));
      ("payload", w.payload);
      ("merge_key", merge_key_to_value w.merge_key);
    ]

let field_opt fields name = List.assoc_opt name fields

(* [None] (missing field entirely) is backward-compatible with every batch committed before this
   field existed -- decodes as [Some None], i.e. a well-formed write with no merge_key, exactly as
   if it had been proposed with [merge_key = None] all along. A field that IS present but not
   shaped like [merge_key_to_value]'s own encoding is a genuinely malformed write, same discipline
   as actor/causation/correlation/payload below: [None] here voids the whole write. *)
let merge_key_of_field = function
  | None -> Some None
  | Some (Value.Sum ("none", Value.Record [])) -> Some None
  | Some (Value.Sum ("some", Value.Scalar (Value.String k))) -> Some (Some k)
  | Some _ -> None

(* causation/correlation are Envelope.event_id = Value.hash, documented in lib/value.mli as "Raw
   32-byte SHA-256 digest" -- Value.hash_to_hex raises Invalid_argument on anything else. A
   committed entry is arbitrary VSR-replicated bytes with no payload-integrity guarantee (this
   codebase's own established threat model), so a wrong-length causation/correlation must make
   the WHOLE write fail to decode here, exactly like every other malformed-write case, rather than
   producing a well-typed write/envelope whose fields silently violate their own documented
   contract. *)
let write_of_value (v : Value.value) : write option =
  match v with
  | Value.Record fields -> (
    match
      ( field_opt fields "actor",
        field_opt fields "causation",
        field_opt fields "correlation",
        field_opt fields "payload",
        merge_key_of_field (field_opt fields "merge_key") )
    with
    | Some (Value.Scalar (Value.String actor)), Some (Value.Scalar (Value.Bytes causation)),
      Some (Value.Scalar (Value.Bytes correlation)), Some payload, Some merge_key
      when String.length causation = 32 && String.length correlation = 32 ->
      Some { actor; causation; correlation; payload; merge_key }
    | _ -> None)
  | _ -> None

(* ---- batch <-> Value.value ---- *)

let batch_to_value ~(idempotency_key : string) (writes : write list) : Value.value =
  Value.Record
    [
      ("idempotency_key", Value.Scalar (Value.String idempotency_key));
      ("writes", Value.Sequence (List.map write_to_value writes));
    ]

(* [None] if EITHER the outer shape is wrong OR any single write inside it fails to decode -- a
   batch with one malformed write is a malformed batch as a whole, never a partial batch. *)
let batch_of_value (v : Value.value) : (string * write list) option =
  match v with
  | Value.Record fields -> (
    match (field_opt fields "idempotency_key", field_opt fields "writes") with
    | Some (Value.Scalar (Value.String idempotency_key)), Some (Value.Sequence write_values) ->
      let decoded = List.map write_of_value write_values in
      if List.for_all Option.is_some decoded then Some (idempotency_key, List.filter_map Fun.id decoded)
      else None
    | _ -> None)
  | _ -> None

(* ---- read side ---- *)

let committed_batch_values (t : Riptide_vsr.Replica.t) : Value.value list =
  let all = Riptide_vsr.Replica.entries t in
  let committed_count = Riptide_vsr.Replica.commit_number t in
  List.filteri (fun i _ -> i < committed_count) all

let has_key ~(idempotency_key : string) (v : Value.value) : bool =
  match batch_of_value v with Some (key, _) -> String.equal key idempotency_key | None -> false

(* The writes of the batch that actually COMMITTED under [idempotency_key], decoded from the
   committed bytes themselves -- [None] if no well-formed committed batch carries that key.

   First-wins per key, deliberately identical to [committed_envelopes_keyed]'s own dedup rule (a
   malformed batch never claims a key, since it contributes no envelopes to skip in favour of), so
   the writes this returns are exactly the writes whose envelopes that function publishes. That
   agreement is the point of this function; see [propose]'s own materialize step for the defect
   its absence caused. *)
let committed_writes_for (t : Riptide_vsr.Replica.t) ~(idempotency_key : string) : write list option =
  let rec find = function
    | [] -> None
    | v :: rest -> (
      match batch_of_value v with
      | Some (key, writes) when String.equal key idempotency_key -> Some writes
      | _ -> find rest)
  in
  find (committed_batch_values t)

(* The membership question [committed_writes_for] above answers over the committed prefix, asked
   over the WHOLE log instead -- i.e. "has a batch under this idempotency key ever been APPENDED
   here", committed or not. Uses [Replica.entries] directly (the raw log, including the
   replicated-but-not-yet-agreed tail) rather than [committed_batch_values].

   Why this exists, and why [propose] gates on it rather than on [already_committed] (review
   finding, 2026-09-23 -- a real fault-free data-destruction path, not a hypothetical one): in any
   real [replica_count >= 3] cluster [Riptide_vsr.Replica.propose] never commits synchronously, so
   there is a genuine window in which a batch is appended to the log but [already_committed] is
   still false. A client retry inside that window is not a fault -- this layer provides no
   acknowledgment mechanism at all (see batch_commit.mli's own [propose]), so it is the ONLY kind
   of retry a client can issue, and it is expected.

   Unencrypted, such a retry is harmless: [Riptide_vsr.Replica.propose]'s own duplicate-value
   suppression ([List.exists (value_equal ...) (entries t)], replica.ml) sees a byte-identical
   value and does nothing. ENCRYPTION DEFEATS THAT SUPPRESSION: encrypting mints a fresh DEK and a
   fresh nonce, so the retry's batch value is byte-DIFFERENT, [value_equal] never matches, and a
   SECOND entry is appended -- while the keystore [put] for the same derived event_id has already
   overwritten the first entry's DEK in place. Both entries then commit;
   [committed_envelopes_keyed] keeps the first (first-wins per key), whose ciphertext the surviving
   DEK cannot open. The record is permanently unrecoverable, with no fault injected and the hash
   chain still verifying -- nothing surfaces the loss.

   Gating on log membership instead closes that window: a key already present ANYWHERE in the log
   is never re-encrypted and never re-proposed. This deliberately does not change
   [Riptide_vsr.Replica.propose]'s own [value_equal] suppression, which still covers the
   unencrypted identical-retry case exactly as before. *)
let already_in_log (t : Riptide_vsr.Replica.t) ~(idempotency_key : string) : bool =
  List.exists (has_key ~idempotency_key) (Riptide_vsr.Replica.entries t)

type materialize_sink = { write : merge_key:string -> Value.value -> unit }
type encryption_sink = { encrypt : event_id:string -> Value.value -> Value.value }

(* The keystore key for one write, derived from data available BEFORE the write enters the
   replicated log -- which is the only moment encryption can happen, since Envelope.content_hash
   covers the payload (lib/envelope.ml's to_value) and is therefore already committed to whatever
   bytes the log holds. The envelope's own event_id (= its content_hash) is unusable here: it also
   covers predecessor_hash and sequence, which only exist once the write's position in the
   committed log is settled, i.e. strictly after the payload had to be final. See
   batch_commit.mli's [redaction_event_id] and Riptide_crypto.Redaction_store's own header.

   Length-prefixing the idempotency key makes the derivation injective by construction rather than
   by argument: ("a", 1) and ("a#1", 0) produce "1:a#1" and "3:a#1#0", which cannot collide for
   any pair of inputs, whatever characters an opaque caller-supplied idempotency key contains. *)
let redaction_event_id ~idempotency_key ~index =
  Printf.sprintf "%d:%s#%d" (String.length idempotency_key) idempotency_key index

let propose (t : Riptide_vsr.Replica.t) ~(idempotency_key : string) ?(require_encryption = false)
    ?(materialize : materialize_sink option) ?(encryption : encryption_sink option) (writes : write list) : unit =
  (* Deployment-level policy: a deployment that wants to enforce "every write through this path
     must be encrypted" previously had no way to say so -- ~encryption was purely opt-in per call,
     so an ordinary caller that simply forgot it produced a silent plaintext write with no error
     anywhere. This is checked FIRST, before the pre-existing merge_key+encryption rejection below,
     so a caller who somehow triggers both sees the more fundamental policy violation
     (require_encryption with no sink at all) rather than a check that presupposes a sink exists. *)
  if require_encryption && encryption = None then
    invalid_arg "Batch_commit.propose: require_encryption is true but no ~encryption sink was supplied";
  (* An EMPTY batch is never proposed -- not here, not in any log state (review finding,
     2026-09-23). This is a real data-destruction path, previously pinned as a known behaviour by
     test_batch_commit.ml's own [test_empty_batch_permanently_burns_its_key_via_propose] and now
     closed: an empty batch is perfectly well-formed, so [batch_of_value] decodes it, it claims
     [idempotency_key] in [committed_envelopes_keyed]'s own first-wins dedup set, and
     [already_in_log] below makes every LATER propose under that key a no-op. The key is poisoned
     permanently: a real batch proposed under it afterwards is never committed, never materialized,
     and nothing raises. What it buys in exchange is nothing at all -- an empty batch contributes
     zero envelopes and zero materialization -- so there is no state in which writing one is the
     right thing to do, and the guard is unconditional rather than "only when the key is new".

     Only the PROPOSE half is suppressed; the materialize step below still runs, because
     [propose t ~idempotency_key ~materialize []] is this module's own documented way for a replica
     to drive its own committed batch into its own materializer (see batch_commit.mli), and that
     idiom must stay safe on a replica that has not yet learned of the batch -- a normal, expected
     state in any multi-replica cluster, not a caller error. Raising there instead would turn an
     ordinary replication lag into an exception.

     With NO [?materialize] either, the call can have no effect whatsoever -- nothing proposed,
     nothing materialized -- which is never what a caller meant, so that shape raises rather than
     silently doing nothing. *)
  (match (writes, materialize) with
  | [], None ->
    invalid_arg
      "Batch_commit.propose: an empty writes list with no ~materialize sink cannot do anything -- \
       an empty batch is never proposed (it would permanently claim this idempotency key while \
       contributing no envelopes, silently swallowing any later real batch under it), and with no \
       sink there is nothing to materialize either. Pass the batch's writes, or pass ~materialize \
       to drive an already-committed batch into a materializer."
  | _ -> ());
  (* Encrypted and materialized are mutually exclusive, and this fails loudly rather than
     silently: the materializer's accumulator holds joined plaintext, lives in its own KV store,
     and is structurally outside the redaction keystore -- so deleting a record's DEK would leave
     that record's contribution to the accumulator fully readable. A redaction that does not
     redact is worse than a rejected write. See batch_commit.mli for the full statement. *)
  (match encryption with
  | None -> ()
  | Some _ ->
    if List.exists (fun (w : write) -> Option.is_some w.merge_key) writes then
      invalid_arg
        "Batch_commit.propose: a write with merge_key = Some _ cannot also be encrypted \
         (~encryption): the materialized accumulator is outside the redaction keystore, so \
         deleting the DEK would not erase it");
  if writes <> [] && not (already_in_log t ~idempotency_key) then begin
    (* Encryption happens HERE, inside the "this key is not already anywhere in the log" guard,
       and not a line earlier: encrypting mints a fresh DEK and overwrites the keystore entry for
       this event_id. Doing that on a retry of a batch already in the log -- committed OR merely
       appended-and-awaiting-quorum -- would orphan the DEK for a ciphertext that is (or is about
       to become) immutably committed, permanently destroying a record nobody asked to redact.
       [already_in_log], not [already_committed], is the guard precisely because the
       appended-but-uncommitted window is the normal state of every multi-replica propose; see
       [already_in_log]'s own comment for the full failure mode this closes. *)
    let writes_to_propose =
      match encryption with
      | None -> writes
      | Some sink ->
        List.mapi
          (fun index (w : write) ->
            { w with payload = sink.encrypt ~event_id:(redaction_event_id ~idempotency_key ~index) w.payload })
          writes
    in
    Riptide_vsr.Replica.propose t (batch_to_value ~idempotency_key writes_to_propose)
  end;
  (* Deliberately NOT gated behind "did THIS call perform the durable commit" -- a batch
     committed by an earlier call (or by this call, in the degenerate replica_count = 1 case
     above) is materialized here just the same. This makes materialization safe to retry: if a
     process crashes between Replica.propose's durable commit and the materialize step below,
     the very next propose call for the SAME idempotency_key -- even though already_in_log
     above makes it skip re-proposing -- still reaches this point and re-attempts the
     materialize. Note the two guards are deliberately DIFFERENT questions and must stay so:
     re-proposing is gated on "is this key anywhere in the log at all" (see already_in_log), while
     materializing is gated on "is it COMMITTED", since materializing an entry that has not yet
     reached quorum would publish state the cluster has not agreed on. That re-attempt is safe because Materializer.write is a read-join-put over a
     lattice: joining the same value into an already-converged accumulator is a no-op by the
     lattice laws (idempotent), so re-materializing an already-materialized write changes
     nothing. See batch_commit.mli's own [propose] doc comment for the corrected, full account
     of this behavior. *)
  match materialize with
  | None -> ()
  | Some sink -> (
    (* Materialize the writes that are actually COMMITTED under this key, read back out of the
       committed bytes -- never the [writes] argument this call happened to be handed (Task 9's
       end-to-end adversarial proof, 2026-09-23; see that task's report and
       test_lattice_materialize_crypto_scenarios.ml).

       Why this is the root fix and not a hardening: the two halves of this module disagreed about
       what "the batch under key K" means. The READ half ([committed_envelopes_keyed]) says: the
       FIRST well-formed committed batch carrying K, every later one skipped. This write half used
       to say: whatever the most recent caller passed. Any difference between the two went straight
       into a durable lattice accumulator, and a lattice join can never take it back out.

       Two real consequences, both reproduced before the fix:

       - {b Permanent, unauditable divergence.} A client retry under an already-committed key
         carrying different writes (the only kind of retry this fire-and-forget layer permits a
         client to issue at all, and one the read half above explicitly defends against) folded a
         payload that appears in NO committed entry on ANY replica into one replica's accumulator.
         Two replicas driven from the same committed log then hold different accumulators forever
         -- the divergence is not something a later join repairs, because no other replica will
         ever see the value.
       - {b A redaction that does not redact.} [propose] rejects [merge_key] together with
         [~encryption] precisely because a materialized accumulator lives outside the redaction
         keystore. That guard is per-call, and this step read the caller's argument, so the two
         could be split across two calls sharing one idempotency key: call one commits the payload
         as ciphertext under [~encryption], call two (same key, no [~encryption], so nothing is
         re-proposed and the guard never fires) hands the PLAINTEXT to a [merge_key] write and this
         step folds it durably into the accumulator. [Redaction_store.redact] then genuinely
         destroys the ciphertext's recoverability while the plaintext stays readable on disk
         forever.

       Reading the committed bytes closes both structurally rather than case by case: a committed
       batch's own [merge_key]s and payloads are the only thing that can ever be materialized, so
       the accumulator is a function of the committed log alone -- the same input every replica
       agrees on -- and an encrypted batch (whose committed writes all carry [merge_key = None],
       enforced by the guard above at the only moment encryption can happen) can contribute
       nothing to it no matter what a later caller passes.

       [None] here is exactly the "not committed on this replica (yet)" case the old
       [already_committed t = false] test covered before this function replaced it: nothing to
       materialize, try again on a later call. Note the consequence that makes this
       strictly more capable rather than merely safer: because the payloads come from the log
       rather than the argument, ANY replica holding the committed batch can materialize its own
       commit stream -- including with an empty [writes] list -- which is what lets each replica
       feed its own materializer and converge. *)
    match committed_writes_for t ~idempotency_key with
    | None -> ()
    | Some committed_writes ->
      List.iter
        (fun (w : write) ->
          match w.merge_key with None -> () | Some merge_key -> sink.write ~merge_key w.payload)
        committed_writes)

let committed_envelopes_keyed (t : Riptide_vsr.Replica.t) : (string * Envelope.envelope) list =
  let seen_keys = Hashtbl.create 16 in
  let _final_sequence, _final_predecessor_hash, envelopes_rev =
    List.fold_left
      (fun (sequence, predecessor_hash, acc) batch_value ->
        match batch_of_value batch_value with
        | None -> (sequence, predecessor_hash, acc)
        | Some (idempotency_key, writes) ->
          if Hashtbl.mem seen_keys idempotency_key then (sequence, predecessor_hash, acc)
          else begin
            Hashtbl.add seen_keys idempotency_key ();
            let _final_index, folded =
              List.fold_left
                (fun (index, (sequence, predecessor_hash, acc)) (w : write) ->
                  let sequence = Int64.add sequence 1L in
                  let envelope : Envelope.envelope =
                    {
                      actor = w.actor;
                      causation = w.causation;
                      correlation = w.correlation;
                      predecessor_hash;
                      sequence;
                      payload = w.payload;
                    }
                  in
                  ( index + 1,
                    ( sequence,
                      Envelope.content_hash envelope,
                      (redaction_event_id ~idempotency_key ~index, envelope) :: acc ) ))
                (0, (sequence, predecessor_hash, acc))
                writes
            in
            folded
          end)
      (0L, Envelope.genesis_marker, [])
      (committed_batch_values t)
  in
  List.rev envelopes_rev

let committed_envelopes (t : Riptide_vsr.Replica.t) : Envelope.envelope list =
  List.map snd (committed_envelopes_keyed t)
