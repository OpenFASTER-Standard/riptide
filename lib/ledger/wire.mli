val encode_request : Schema.transfer_request -> bytes   (* exactly 32 bytes *)
val decode_request : bytes -> Schema.transfer_request option  (* None on wrong length *)
val encode_balance : int64 -> bytes                      (* exactly 8 bytes *)
val decode_balance : bytes -> int64 option                (* None on wrong length *)
