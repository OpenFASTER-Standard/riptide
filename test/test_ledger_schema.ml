open Riptide_ledger

let test_transfer_request_round_trips_through_value () =
  let r = Schema.{ request_id = 7L; from_account = 100L; to_account = 200L; amount = 5000L } in
  match Schema.transfer_request_of_value (Schema.transfer_request_to_value r) with
  | None -> Alcotest.fail "expected Some"
  | Some r' -> Alcotest.(check bool) "round trip" true (r = r')

let test_transfer_leg_round_trips_through_value () =
  let l = Schema.{ transfer_id = 7L; role = Debit; this_account = 100L; other_account = 200L; amount = 5000L } in
  match Schema.transfer_leg_of_value (Schema.transfer_leg_to_value l) with
  | None -> Alcotest.fail "expected Some"
  | Some l' -> Alcotest.(check bool) "round trip" true (l = l')

let test_transfer_leg_of_value_rejects_a_malformed_record () =
  Alcotest.(check bool) "garbage Value.value is rejected" true
    (Schema.transfer_leg_of_value (Riptide.Value.Scalar (Riptide.Value.String "not a leg")) = None)

let test_account_merge_key_format () =
  Alcotest.(check string) "exact format" "ledger.account.100" (Schema.account_merge_key 100L)

let test_wire_request_round_trips () =
  let r = Schema.{ request_id = 7L; from_account = 100L; to_account = 200L; amount = 5000L } in
  Alcotest.(check bool) "round trip" true (Wire.decode_request (Wire.encode_request r) = Some r)

let test_wire_decode_request_rejects_wrong_length () =
  Alcotest.(check bool) "31 bytes is rejected" true
    (Wire.decode_request (Bytes.make 31 '\000') = None)

let test_wire_balance_round_trips () =
  Alcotest.(check bool) "round trip" true (Wire.decode_balance (Wire.encode_balance (-42L)) = Some (-42L))

let tests =
  [
    ("transfer_request round-trips through value", `Quick, test_transfer_request_round_trips_through_value);
    ("transfer_leg round-trips through value", `Quick, test_transfer_leg_round_trips_through_value);
    ("transfer_leg_of_value rejects malformed record", `Quick, test_transfer_leg_of_value_rejects_a_malformed_record);
    ("account_merge_key format", `Quick, test_account_merge_key_format);
    ("wire: request round-trips", `Quick, test_wire_request_round_trips);
    ("wire: decode_request rejects wrong length", `Quick, test_wire_decode_request_rejects_wrong_length);
    ("wire: balance round-trips", `Quick, test_wire_balance_round_trips);
  ]
