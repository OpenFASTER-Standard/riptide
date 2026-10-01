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
     carry transfer_id = 0.

     Why this is injective despite "|" being a perfectly legal character in an actor id
     (fix-wave round 2, re-review finding M2 -- the comment here previously credited
     String.escaped, which does NOT escape "|" and so was simply a false explanation of a key
     that nonetheless works): every segment except the actor is a fixed-arity rendering of an
     int64 or of one of the two role tags, and NONE of those renderings can contain "|". So any
     two legs whose keys are equal must split into the same number of "|"-separated segments, with
     the SAME five non-actor segments at the same positions -- the first two segments (transfer_id,
     role_tag) and the last three (this_account, other_account, amount) -- which forces the
     remaining middle span, i.e. the actor, to match too. A "|" inside an
     actor id can only ever add segments in the middle, never move a numeric field across a
     delimiter boundary, because there are always exactly five numeric/tag segments pinned to the
     two ends. String.escaped is kept purely so a key is printable/diffable when debugging. *)
  Printf.sprintf "%Ld|%s|%s|%Ld|%Ld|%Ld" leg.transfer_id (role_tag leg.role)
    (String.escaped leg.actor) leg.this_account leg.other_account leg.amount

let propose_legs ~actor ~propose (r : Schema.transfer_request) =
  let idempotency_key = Schema.transfer_idempotency_key r.request_id in
  let event_id = Legs.event_id_of_request r in
  let legs = Legs.legs_of_request ~actor ~causation:event_id ~correlation:event_id r in
  propose ~idempotency_key legs

let handle_guest_decision t ~actor ~propose (decision_bytes : bytes) : (unit, string) result =
  (* Decoded exactly once, by Legs.decision_of_bytes -- the guest-facing trust boundary the fuzz
     test hammers -- and nothing here or downstream re-decodes these bytes (finding M9, and
     fix-wave round 2's re-review finding I3, which caught that this call had been left as
     duplicated inline decode logic while legs.mli already claimed to be on this path). The legs
     handed back are already built under exactly the causation/correlation an accepted first
     decision proposes them with, so that branch can propose what it was handed directly. *)
  match Legs.decision_of_bytes ~actor decision_bytes with
  | Error e -> Error e
  | Ok (accepted, r, legs) -> (
    match Hashtbl.find_opt t.decided_requests r.request_id with
    | None ->
      Hashtbl.replace t.decided_requests r.request_id (accepted, r);
      if accepted then
        propose ~idempotency_key:(Schema.transfer_idempotency_key r.request_id) legs;
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
