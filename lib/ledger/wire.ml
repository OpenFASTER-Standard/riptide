let encode_request (r : Schema.transfer_request) : bytes =
  let buf = Bytes.make 32 '\000' in
  Bytes.set_int64_le buf 0 r.request_id;
  Bytes.set_int64_le buf 8 r.from_account;
  Bytes.set_int64_le buf 16 r.to_account;
  Bytes.set_int64_le buf 24 r.amount;
  buf

let decode_request (b : bytes) : Schema.transfer_request option =
  if Bytes.length b <> 32 then
    None
  else
    try
      Some {
        Schema.request_id = Bytes.get_int64_le b 0;
        from_account = Bytes.get_int64_le b 8;
        to_account = Bytes.get_int64_le b 16;
        amount = Bytes.get_int64_le b 24;
      }
    with _ -> None

let encode_balance (bal : int64) : bytes =
  let buf = Bytes.make 8 '\000' in
  Bytes.set_int64_le buf 0 bal;
  buf

let decode_balance (b : bytes) : int64 option =
  if Bytes.length b <> 8 then
    None
  else
    try Some (Bytes.get_int64_le b 0) with _ -> None
