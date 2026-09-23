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

let already_committed (t : Riptide_vsr.Replica.t) ~(idempotency_key : string) : bool =
  List.exists
    (fun v -> match batch_of_value v with Some (key, _) -> String.equal key idempotency_key | None -> false)
    (committed_batch_values t)

type materialize_sink = { write : merge_key:string -> Value.value -> unit }

let propose (t : Riptide_vsr.Replica.t) ~(idempotency_key : string) ?(materialize : materialize_sink option)
    (writes : write list) : unit =
  if not (already_committed t ~idempotency_key) then
    Riptide_vsr.Replica.propose t (batch_to_value ~idempotency_key writes);
  (* Deliberately NOT gated behind "did THIS call perform the durable commit" -- a batch
     committed by an earlier call (or by this call, in the degenerate replica_count = 1 case
     above) is materialized here just the same. This makes materialization safe to retry: if a
     process crashes between Replica.propose's durable commit and the materialize step below,
     the very next propose call for the SAME idempotency_key -- even though already_committed
     above makes it skip re-proposing -- still reaches this point and re-attempts the
     materialize. That re-attempt is safe because Materializer.write is a read-join-put over a
     lattice: joining the same value into an already-converged accumulator is a no-op by the
     lattice laws (idempotent), so re-materializing an already-materialized write changes
     nothing. See batch_commit.mli's own [propose] doc comment for the corrected, full account
     of this behavior. *)
  match materialize with
  | None -> ()
  | Some sink ->
    if already_committed t ~idempotency_key then
      List.iter
        (fun (w : write) ->
          match w.merge_key with None -> () | Some merge_key -> sink.write ~merge_key w.payload)
        writes

let committed_envelopes (t : Riptide_vsr.Replica.t) : Envelope.envelope list =
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
            List.fold_left
              (fun (sequence, predecessor_hash, acc) (w : write) ->
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
                (sequence, Envelope.content_hash envelope, envelope :: acc))
              (sequence, predecessor_hash, acc) writes
          end)
      (0L, Envelope.genesis_marker, [])
      (committed_batch_values t)
  in
  List.rev envelopes_rev
