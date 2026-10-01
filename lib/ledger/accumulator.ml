open Riptide

type t = {
  (* request_id -> the first decision ever recorded for it, plus the request that decision was
     made about. Both halves matter: the bool is what can never flip, and the request is what a
     later re-proposal rebuilds its legs from, so a later dispatch cannot alter the transfer's
     amount or accounts either. See accumulator.mli's own doc comment on handle_guest_decision. *)
  decided_requests : (int64, bool * Schema.transfer_request) Hashtbl.t;
  (* The legs already folded into a balance, keyed by full leg content -- see
     accumulator.mli's doc comment on materialize_sink for why the key is the whole leg and not
     the (transfer_id, this_account, role) triple it used to be. *)
  applied_legs : (string, unit) Hashtbl.t;
  mutable repeat_dispatches : int;
  mutable prevented_flips : int;
}

let create () =
  {
    decided_requests = Hashtbl.create 64;
    applied_legs = Hashtbl.create 256;
    repeat_dispatches = 0;
    prevented_flips = 0;
  }

let balance_delta (leg : Schema.transfer_leg) : int64 =
  match leg.role with Schema.Debit -> Int64.neg leg.amount | Schema.Credit -> leg.amount

let decision t ~request_id = Option.map fst (Hashtbl.find_opt t.decided_requests request_id)
let prevented_flips t = t.prevented_flips
let repeat_dispatches t = t.repeat_dispatches

let role_tag = function Schema.Debit -> "debit" | Schema.Credit -> "credit"

let leg_key (leg : Schema.transfer_leg) : string =
  (* Every field of the leg, with the actor included -- Authorize.authorize guarantees the actor
     recorded in the payload is the real author of the committing write, so this genuinely
     separates (say) a module-authored leg from a test harness's own seeding leg even when both
     carry transfer_id = 0. String.escaped on the actor so an actor containing the separator
     cannot forge another actor's key. *)
  Printf.sprintf "%Ld|%s|%s|%Ld|%Ld|%Ld" leg.transfer_id (role_tag leg.role)
    (String.escaped leg.actor) leg.this_account leg.other_account leg.amount

(* Deterministic from the idempotency key alone, so a re-proposal of the same transfer produces a
   byte-identical batch rather than a merely equivalent one. *)
let event_id_of_key (idempotency_key : string) : Envelope.event_id =
  Value.content_hash (Value.Scalar (Value.String idempotency_key))

let propose_legs ~actor ~propose (r : Schema.transfer_request) =
  let idempotency_key = Schema.transfer_idempotency_key r.request_id in
  let event_id = event_id_of_key idempotency_key in
  let legs = Legs.legs_of_request ~actor ~causation:event_id ~correlation:event_id r in
  propose ~idempotency_key legs

let handle_guest_decision t ~actor ~propose (decision_bytes : bytes) : (unit, string) result =
  let idempotency_key_of r = Schema.transfer_idempotency_key r.Schema.request_id in
  let event_id r = event_id_of_key (idempotency_key_of r) in
  (* Decoded exactly once, here; nothing downstream re-decodes these bytes (finding M9). The
     causation/correlation handed to decision_of_bytes are the ones the legs would be proposed
     under, so an accepted first decision can propose what it was handed directly. *)
  match Wire.decode_decision decision_bytes with
  | None ->
    Error
      (Printf.sprintf
         "ledger propose closure: %d bytes do not decode as a well-formed %d-byte decision \
          payload (tag byte must be 0 or 1)"
         (Bytes.length decision_bytes) Wire.decision_bytes)
  | Some (accepted, r) -> (
    match Hashtbl.find_opt t.decided_requests r.request_id with
    | None ->
      Hashtbl.replace t.decided_requests r.request_id (accepted, r);
      if accepted then (
        let key = idempotency_key_of r in
        let eid = event_id r in
        propose ~idempotency_key:key (Legs.legs_of_request ~actor ~causation:eid ~correlation:eid r));
      Ok ()
    | Some (already_accepted, recorded) ->
      t.repeat_dispatches <- t.repeat_dispatches + 1;
      if already_accepted <> accepted then t.prevented_flips <- t.prevented_flips + 1;
      (* The recorded decision stands. For an accepted one, re-propose its legs -- rebuilt from
         the RECORDED request, never from this dispatch's own bytes -- so a legs batch a view
         change discarded before it committed can still recover, which is the only recovery path
         that exists for one. Idempotent: Batch_commit.propose skips a batch already in the log,
         and materialize_sink below will not re-apply a leg it has already folded in. For a
         declined one, nothing is proposed, ever: that is finding C1's fix. *)
      if already_accepted then propose_legs ~actor ~propose recorded;
      Ok ())

let materialize_sink t ~read_balance ~write_balance ~store_request :
    Riptide_batch_commit.Batch_commit.materialize_sink =
  {
    write =
      (fun ~merge_key payload ->
        if merge_key = Schema.requests_merge_key then store_request payload
        else if Schema.is_account_key merge_key then
          match Schema.transfer_leg_of_value payload with
          (* Unreachable for anything Authorize.authorize allowed, and a sink runs after the
             commit is already durable -- so skip, never raise. See accumulator.mli. *)
          | None -> ()
          | Some leg ->
            if Schema.account_of_merge_key merge_key <> Some leg.this_account then ()
            else
              let key = leg_key leg in
              if not (Hashtbl.mem t.applied_legs key) then (
                Hashtbl.add t.applied_legs key ();
                let current = Option.value (read_balance ~merge_key) ~default:0L in
                write_balance ~merge_key (Int64.add current (balance_delta leg)))
        else ());
  }

let read_for_guest ~read_request ~read_balance ~merge_key =
  if merge_key = Schema.requests_merge_key then Option.map Wire.encode_request (read_request ())
  else if Schema.is_account_key merge_key then
    Option.map Wire.encode_balance (read_balance ~merge_key)
  else None
