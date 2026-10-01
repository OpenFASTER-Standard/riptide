let request_bytes = 32
let decision_bytes = 33

let encode_request (r : Schema.transfer_request) : bytes =
  let buf = Bytes.make request_bytes '\000' in
  Bytes.set_int64_le buf 0 r.request_id;
  Bytes.set_int64_le buf 8 r.from_account;
  Bytes.set_int64_le buf 16 r.to_account;
  Bytes.set_int64_le buf 24 r.amount;
  buf

(* [at] is the offset the 32-byte request encoding starts at: 0 for a bare request, 1 for the
   request embedded in a decision after its tag byte. Every read below is within
   [at .. at + 31], which both callers have already bounds-checked by length, so no exception
   handler is needed here -- and none is wanted: a [try ... with _ -> None] around these reads
   would be structurally unreachable dead code (final whole-branch review, finding M3). *)
let decode_request_at (b : bytes) (at : int) : Schema.transfer_request =
  {
    Schema.request_id = Bytes.get_int64_le b at;
    from_account = Bytes.get_int64_le b (at + 8);
    to_account = Bytes.get_int64_le b (at + 16);
    amount = Bytes.get_int64_le b (at + 24);
  }

let decode_request (b : bytes) : Schema.transfer_request option =
  if Bytes.length b <> request_bytes then None else Some (decode_request_at b 0)

let encode_decision ~(accepted : bool) (r : Schema.transfer_request) : bytes =
  let buf = Bytes.make decision_bytes '\000' in
  Bytes.set buf 0 (if accepted then '\001' else '\000');
  Bytes.blit (encode_request r) 0 buf 1 request_bytes;
  buf

let decode_decision (b : bytes) : (bool * Schema.transfer_request) option =
  if Bytes.length b <> decision_bytes then None
  else
    match Bytes.get b 0 with
    | '\000' -> Some (false, decode_request_at b 1)
    | '\001' -> Some (true, decode_request_at b 1)
    | _ -> None

(* The SAME 33 bytes [encode_decision] hands the host, carried verbatim as a Value.value so a
   decision can be committed to the replicated log as its own write (Task 7, the Layer 0/Layer 2
   boundary revision -- see accumulator.mli's own account of why a DECLINE has to be durable).
   Deliberately a byte-for-byte carrier rather than a second, Record-shaped encoding of the same
   four fields: there is then exactly one decision wire format in this module, exactly one tag-byte
   validation ([decode_decision] above, the one the fuzz test hammers), and a committed decision is
   bit-identical to the bytes the guest actually produced rather than a re-serialization of them. *)
let decision_to_value ~(accepted : bool) (r : Schema.transfer_request) : Riptide.Value.value =
  Riptide.Value.Scalar (Riptide.Value.Bytes (Bytes.to_string (encode_decision ~accepted r)))

let decision_of_value (v : Riptide.Value.value) : (bool * Schema.transfer_request) option =
  match v with
  | Riptide.Value.Scalar (Riptide.Value.Bytes s) -> decode_decision (Bytes.of_string s)
  | _ -> None

let encode_balance (bal : int64) : bytes =
  let buf = Bytes.make 8 '\000' in
  Bytes.set_int64_le buf 0 bal;
  buf

let decode_balance (b : bytes) : int64 option =
  if Bytes.length b <> 8 then None else Some (Bytes.get_int64_le b 0)
