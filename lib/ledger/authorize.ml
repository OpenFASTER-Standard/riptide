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
           it. This is what makes Schema.transfer_leg's [actor] field trustworthy downstream, in
           a materialize_sink that never gets to see the write's own actor -- see that field's own
           doc comment and Accumulator's dedup key (final whole-branch review, finding I4). *)
        Batch_commit.Deny "transfer leg actor does not match the actor of the write carrying it"
      else Batch_commit.Allow)
  | Some _ | None -> Batch_commit.Allow
