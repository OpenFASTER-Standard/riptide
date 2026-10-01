let account_prefix = "ledger.account."

let authorize (w : Riptide_batch_commit.Batch_commit.write) : Riptide_batch_commit.Batch_commit.decision =
  match w.merge_key with
  | Some mk when mk = Schema.requests_merge_key -> Riptide_batch_commit.Batch_commit.Allow
  | Some mk when String.length mk >= String.length account_prefix
                 && String.sub mk 0 (String.length account_prefix) = account_prefix -> (
    match Schema.transfer_leg_of_value w.payload with
    | None -> Riptide_batch_commit.Batch_commit.Deny "transfer leg payload does not decode"
    | Some leg ->
      if leg.amount <= 0L then Riptide_batch_commit.Batch_commit.Deny "transfer leg amount is not positive"
      else if leg.this_account = leg.other_account then
        Riptide_batch_commit.Batch_commit.Deny "transfer leg names the same account on both sides"
      else if mk <> Schema.account_merge_key leg.this_account then
        Riptide_batch_commit.Batch_commit.Deny "transfer leg merge_key does not match its own this_account"
      else Riptide_batch_commit.Batch_commit.Allow)
  | Some _ | None -> Riptide_batch_commit.Batch_commit.Allow
