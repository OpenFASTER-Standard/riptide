type t = {
  (* All that is left of this record (Task 7, the Layer 0/Layer 2 boundary revision): two
     observability counters. The [decided_requests] and [applied_legs] tables that used to live here
     are DELETED, not persisted in parallel -- "has this request been decided?" is now a query
     against the committed log (see [committed] below) and "has this write already been applied?" is
     a durable watermark Batch_commit itself owns. Neither is a fact a process's own memory has any
     business being the source of truth for; both being so is what made a restart double every
     balance in this ledger. *)
  mutable repeat_dispatches : int;
  mutable prevented_flips : int;
}

type committed =
  idempotency_key:string -> Riptide_batch_commit.Batch_commit.write list option

let create () = { repeat_dispatches = 0; prevented_flips = 0 }

let balance_delta (leg : Schema.transfer_leg) : int64 =
  match leg.role with Schema.Debit -> Int64.neg leg.amount | Schema.Credit -> leg.amount

let prevented_flips t = t.prevented_flips
let repeat_dispatches t = t.repeat_dispatches

(* The decision a committed batch attests to, if any: the first of its writes whose payload decodes
   as a decision record. Exactly one such write exists in any batch Legs.batch_of_decision built,
   and Authorize.authorize_batch refuses a batch carrying more than one, so "the first" is "the
   only" for anything this module can commit. Every other payload shape it commits (a
   transfer_request, a transfer_leg) is a Value.Record, so none can be misread as a decision -- see
   Wire.decision_of_value. *)
let decision_of_committed_writes (writes : Riptide_batch_commit.Batch_commit.write list) :
    (bool * Schema.transfer_request) option =
  List.find_map
    (fun (w : Riptide_batch_commit.Batch_commit.write) -> Wire.decision_of_value w.payload)
    writes

let decision ~(committed : committed) ~request_id =
  match committed ~idempotency_key:(Schema.transfer_idempotency_key request_id) with
  | None -> None
  | Some writes -> Option.map fst (decision_of_committed_writes writes)

let handle_guest_decision t ~actor ~(committed : committed) ~propose (decision_bytes : bytes) :
    (unit, string) result =
  (* Decoded exactly once, by Legs.decision_of_bytes -- the guest-facing trust boundary the fuzz
     test hammers -- and nothing here or downstream re-decodes these bytes (finding M9, and
     fix-wave round 2's re-review finding I3, which caught that this call had been left as
     duplicated inline decode logic while legs.mli already claimed to be on this path). The legs it
     hands back are not used directly any more: this function proposes a WHOLE batch
     (Legs.batch_of_decision -- the durable decision record plus, for an accept, those same two
     legs), because a decline has no legs and still has to leave a durable trace. *)
  match Legs.decision_of_bytes ~actor decision_bytes with
  | Error e -> Error e
  | Ok (accepted, r, _legs) ->
    let idempotency_key = Schema.transfer_idempotency_key r.request_id in
    (match Option.bind (committed ~idempotency_key) decision_of_committed_writes with
    | None ->
      (* No decision on record for this request. THIS one becomes the record -- committed to the
         replicated log, atomically with the legs that move the money if it is an accept, and
         entirely on its own if it is a decline. *)
      propose ~idempotency_key (Legs.batch_of_decision ~actor ~accepted r)
    | Some (already_accepted, recorded) ->
      t.repeat_dispatches <- t.repeat_dispatches + 1;
      if already_accepted <> accepted then t.prevented_flips <- t.prevented_flips + 1;
      (* The recorded decision stands. For an accepted one, re-propose its batch -- rebuilt from the
         RECORDED request read back out of the log, never from this dispatch's own bytes -- so a
         batch a view change discarded before it committed can still recover, which is the only
         recovery path that exists for one. Idempotent: Batch_commit.propose skips a batch already
         in the log, and its own durable watermark will not re-apply a write it has already handed
         to the sink. For a declined one, nothing is proposed, ever: that is finding C1's fix. *)
      if already_accepted then
        propose ~idempotency_key (Legs.batch_of_decision ~actor ~accepted:true recorded));
    Ok ()

let materialize_sink ~read_balance ~write_balance ~store_request :
    Riptide_batch_commit.Batch_commit.materialize_sink =
  {
    write =
      (fun ~merge_key ~idempotency_key:_ ~position:_ ~actor:_ ~causation:_ ~correlation:_ payload ->
        if merge_key = Schema.requests_merge_key then store_request payload
        else if Schema.is_account_key merge_key then
          match Schema.transfer_leg_of_value payload with
          (* Unreachable for anything Authorize.authorize allowed, and a sink runs after the
             commit is already durable -- so skip, never raise. See accumulator.mli. *)
          | None -> ()
          | Some leg ->
            if Schema.account_of_merge_key merge_key <> Some leg.this_account then ()
            else
              (* A plain read-add-write, with no already-applied check of its own: exactly-once is
                 Batch_commit's durable watermark's job now, not a table in this process. See
                 accumulator.mli for the one real obligation that places on a caller. *)
              let current = Option.value (read_balance ~merge_key) ~default:0L in
              write_balance ~merge_key (Int64.add current (balance_delta leg))
        else ());
  }

let read_for_guest ~read_request ~read_balance ~merge_key =
  if merge_key = Schema.requests_merge_key then Option.map Wire.encode_request (read_request ())
  else if Schema.is_account_key merge_key then
    Option.map Wire.encode_balance (read_balance ~merge_key)
  else None
