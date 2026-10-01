let legs_of_request ~actor ~causation ~correlation (r : Schema.transfer_request) :
    Riptide_batch_commit.Batch_commit.write list =
  let debit_leg =
    Schema.
      {
        transfer_id = r.request_id;
        role = Debit;
        this_account = r.from_account;
        other_account = r.to_account;
        amount = r.amount;
      }
  in
  let credit_leg =
    Schema.
      {
        transfer_id = r.request_id;
        role = Credit;
        this_account = r.to_account;
        other_account = r.from_account;
        amount = r.amount;
      }
  in
  let write_of_leg (leg : Schema.transfer_leg) : Riptide_batch_commit.Batch_commit.write =
    {
      actor;
      causation;
      correlation;
      payload = Schema.transfer_leg_to_value leg;
      merge_key = Some (Schema.account_merge_key leg.this_account);
    }
  in
  [ write_of_leg debit_leg; write_of_leg credit_leg ]

let legs_of_bytes ~actor ~causation ~correlation (b : bytes) :
    (Riptide_batch_commit.Batch_commit.write list, string) result =
  match Wire.decode_request b with
  | None -> Error "legs_of_bytes: bytes do not decode as a well-formed transfer_request"
  | Some r -> Ok (legs_of_request ~actor ~causation ~correlation r)
