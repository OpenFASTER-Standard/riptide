open Riptide_batch_commit

(* Every [Deny] reason below names the one check that failed, not a generic "malformed" --
   batch_commit.mli's own [decision] doc comment is explicit that this string is for
   logs/debugging only and is never parsed, compared or persisted anywhere, so it costs nothing
   to make it specific. *)

let authorize (w : Batch_commit.write) : Batch_commit.decision =
  match w.merge_key with
  | Some mk when mk = Schema.requests_merge_key -> (
    (* A transfer request. Nothing here judges the business question (can the sender afford it?)
       -- that is the WASM guest's whole job -- and nothing here rejects a self-transfer request
       either, whose two legs are each independently denied by the account-key case below. What IS
       checked is that the request is a well-formed one at all, and that its account ids are in
       the non-negative range host and guest actually agree on (final whole-branch review, finding
       I2: before this, nothing validated a request's own account fields anywhere). *)
    match Schema.transfer_request_of_value w.payload with
    | None -> Batch_commit.Deny "transfer request payload does not decode"
    | Some r ->
      if r.from_account < 0L then
        Batch_commit.Deny "transfer request from_account is negative"
      else if r.to_account < 0L then Batch_commit.Deny "transfer request to_account is negative"
      else Batch_commit.Allow)
  | Some mk when Schema.is_account_key mk -> (
    match Schema.transfer_leg_of_value w.payload with
    | None -> Batch_commit.Deny "transfer leg payload does not decode"
    | Some leg ->
      if leg.amount <= 0L then Batch_commit.Deny "transfer leg amount is not positive"
      else if leg.this_account = leg.other_account then
        Batch_commit.Deny "transfer leg names the same account on both sides"
      else if leg.this_account < 0L then Batch_commit.Deny "transfer leg this_account is negative"
      else if leg.other_account < 0L then
        Batch_commit.Deny "transfer leg other_account is negative"
      else if mk <> Schema.account_merge_key leg.this_account then
        Batch_commit.Deny "transfer leg merge_key does not match its own this_account"
      else if leg.actor <> w.actor then
        (* The leg payload's own declared author must be the actual author of the write carrying
           it. This is what makes Schema.transfer_leg's [actor] field trustworthy at rest, in a
           materialized balance that has no envelope of its own -- see that field's own doc comment,
           which also records why its ORIGINAL justification (a materialize_sink that never got to
           see the write's own actor, plus Accumulator's content-keyed dedup table; final
           whole-branch review, finding I4) stopped applying in Task 7. *)
        Batch_commit.Deny "transfer leg actor does not match the actor of the write carrying it"
      else Batch_commit.Allow)
  | Some _ | None -> Batch_commit.Allow

(* ── The batch-level checkpoint (Task 7, the Layer 0/Layer 2 boundary revision, spec Decision 4) ──
   Everything below is a CROSS-WRITE property: something no single write can self-certify, and
   therefore something [authorize] above is structurally incapable of checking. This is where the
   actual substance of double-entry bookkeeping is enforced -- that a transfer's two legs are both
   present in the same atomic batch, reference the same transfer, move the same amount, and move it
   in opposite directions between the same two accounts. It used to be a construction-time
   convention in Legs; it is now a checkpoint no committed write bypasses. *)

(* The legs a batch carries, in batch order: one entry per write whose merge_key is an account key,
   [None] if that write's payload does not decode as a leg at all. A non-decoding leg write is
   already denied by [authorize] above -- either hook denying refuses the whole batch -- but this
   hook is evaluated independently and must reach its own correct verdict rather than relying on
   that. *)
let legs_of_batch (writes : Batch_commit.write list) : Schema.transfer_leg option list =
  List.filter_map
    (fun (w : Batch_commit.write) ->
      match w.merge_key with
      | Some mk when Schema.is_account_key mk -> Some (Schema.transfer_leg_of_value w.payload)
      | Some _ | None -> None)
    writes

let decisions_of_batch (writes : Batch_commit.write list) :
    (bool * Schema.transfer_request) list =
  List.filter_map
    (fun (w : Batch_commit.write) ->
      match w.merge_key with
      (* A decision record carries no merge_key, by Legs.decision_write's own contract -- checked
         here rather than assumed, so a leg or request payload can never be read as a decision even
         if some future payload shape made the two decodes overlap. *)
      | None -> Wire.decision_of_value w.payload
      | Some _ -> None)
    writes

(* The pairing itself: [a] and [b] are a matched, balancing pair of legs. Every clause names the one
   invariant it enforces, in the same style as the per-write reasons above. *)
let pairing_verdict (a : Schema.transfer_leg) (b : Schema.transfer_leg) : Batch_commit.decision =
  if a.transfer_id <> b.transfer_id then
    Batch_commit.Deny "the batch's two transfer legs reference different transfer_ids"
  else if a.actor <> b.actor then
    Batch_commit.Deny "the batch's two transfer legs declare different actors"
  else
    match (a.role, b.role) with
    | Schema.Debit, Schema.Debit | Schema.Credit, Schema.Credit ->
      Batch_commit.Deny "the batch's two transfer legs share a role instead of being opposite"
    | (Schema.Debit, Schema.Credit | Schema.Credit, Schema.Debit) ->
      if a.amount <> b.amount then
        Batch_commit.Deny "the batch's two transfer legs move different amounts"
      else if a.this_account <> b.other_account || a.other_account <> b.this_account then
        Batch_commit.Deny
          "the batch's two transfer legs do not name each other's accounts: they are not two sides \
           of one transfer"
      else Batch_commit.Allow

let authorize_batch (writes : Batch_commit.write list) : Batch_commit.decision =
  let legs = legs_of_batch writes in
  let legs_verdict () =
    match legs with
    (* A batch carrying no transfer leg at all: a client's transfer_request, this module's own
       decision-only decline batch, or any write shape this module has no opinion on. Nothing
       cross-write to check. *)
    | [] -> Batch_commit.Allow
    | [ Some a; Some b ] -> pairing_verdict a b
    | [ None; _ ] | [ _; None ] ->
      Batch_commit.Deny "a transfer leg in this batch does not decode as a transfer leg"
    | _ ->
      Batch_commit.Deny
        "a batch carrying transfer legs must carry exactly two, one debit and one credit"
  in
  match decisions_of_batch writes with
  | [] -> legs_verdict ()
  | [ (accepted, r) ] -> (
    (* The batch also carries this module's own decision record, so the legs are not merely required
       to be a matched pair -- they must be the matched pair THAT decision authorises, and a DECLINE
       must authorise none. This is what makes the log's decision record and the money it moves
       inseparable: no committed state exists in which a transfer is on record as accepted while its
       legs are missing, or in which legs exist that no committed decision ever authorised. *)
    if not accepted then
      match legs with
      | [] -> Batch_commit.Allow
      | _ -> Batch_commit.Deny "a DECLINED decision's batch must carry no transfer legs"
    else
      match legs_verdict () with
      | Batch_commit.Deny reason -> Batch_commit.Deny reason
      | Batch_commit.Allow -> (
        match legs with
        | [] -> Batch_commit.Deny "an ACCEPTED decision's batch must carry its transfer's two legs"
        | [ Some a; Some b ] ->
          let debit, credit = match a.role with Schema.Debit -> (a, b) | Schema.Credit -> (b, a) in
          if debit.transfer_id <> r.request_id then
            Batch_commit.Deny "the batch's transfer legs do not belong to the decided request"
          else if debit.amount <> r.amount then
            Batch_commit.Deny "the batch's transfer legs do not move the decided request's amount"
          else if debit.this_account <> r.from_account then
            Batch_commit.Deny "the batch debits an account the decided request does not debit"
          else if credit.this_account <> r.to_account then
            Batch_commit.Deny "the batch credits an account the decided request does not credit"
          else Batch_commit.Allow
        (* Unreachable: [legs_verdict ()] returned [Allow], which only the two-decoding-legs case
           above and the empty case can produce, and the empty case is handled just above. [Deny]
           rather than [Allow] so that if it ever DID become reachable (a future change to
           [legs_verdict]'s own cases), the failure mode is a refused batch rather than an
           unexamined one. *)
        | _ ->
          Batch_commit.Deny
            "an ACCEPTED decision's batch carries transfer legs this check cannot verify"))
  | _ :: _ :: _ ->
    Batch_commit.Deny "a batch must carry at most one decision record"
