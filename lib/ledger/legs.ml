let legs_of_request ~actor ~causation ~correlation (r : Schema.transfer_request) :
    Riptide_batch_commit.Batch_commit.write list =
  let debit_leg =
    Schema.
      {
        transfer_id = r.request_id;
        role = Debit;
        actor;
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
        actor;
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

let decision_of_bytes ~actor ~causation ~correlation (b : bytes) :
    (bool * Schema.transfer_request * Riptide_batch_commit.Batch_commit.write list, string) result
    =
  match Wire.decode_decision b with
  | None ->
    Error
      (Printf.sprintf
         "decision_of_bytes: %d bytes do not decode as a well-formed %d-byte decision payload \
          (tag byte must be 0 or 1)"
         (Bytes.length b) Wire.decision_bytes)
  | Some (accepted, r) -> Ok (accepted, r, legs_of_request ~actor ~causation ~correlation r)
