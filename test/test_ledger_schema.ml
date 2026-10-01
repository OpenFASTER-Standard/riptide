open Riptide_ledger

let test_transfer_request_round_trips_through_value () =
  let r = Schema.{ request_id = 7L; from_account = 100L; to_account = 200L; amount = 5000L } in
  match Schema.transfer_request_of_value (Schema.transfer_request_to_value r) with
  | None -> Alcotest.fail "expected Some"
  | Some r' -> Alcotest.(check bool) "round trip" true (r = r')

let test_transfer_leg_round_trips_through_value () =
  let l =
    Schema.
      {
        transfer_id = 7L;
        role = Debit;
        actor = "ledger-module";
        this_account = 100L;
        other_account = 200L;
        amount = 5000L;
      }
  in
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

(* ── Coverage for what this fix wave added to Schema/Wire ──────────────────────────────────────── *)

let test_wire_decision_round_trips_on_both_outcomes () =
  let r = Schema.{ request_id = 7L; from_account = 100L; to_account = 200L; amount = 5000L } in
  Alcotest.(check int) "a decision payload is exactly 33 bytes" 33
    (Bytes.length (Wire.encode_decision ~accepted:true r));
  Alcotest.(check bool) "an accepted decision round-trips" true
    (Wire.decode_decision (Wire.encode_decision ~accepted:true r) = Some (true, r));
  Alcotest.(check bool) "a declined decision round-trips, and is not confused with accepted" true
    (Wire.decode_decision (Wire.encode_decision ~accepted:false r) = Some (false, r))

(* The tag byte is validated, not merely read: "anything nonzero means accepted" would silently
   turn a corrupt payload into an authorisation to move money. *)
let test_wire_decode_decision_rejects_a_bad_tag_or_length () =
  let good = Wire.encode_decision ~accepted:true
    Schema.{ request_id = 1L; from_account = 2L; to_account = 3L; amount = 4L }
  in
  let with_tag c =
    let b = Bytes.copy good in
    Bytes.set b 0 c;
    b
  in
  Alcotest.(check bool) "tag byte 2 is rejected outright" true
    (Wire.decode_decision (with_tag '\002') = None);
  Alcotest.(check bool) "tag byte 255 is rejected outright" true
    (Wire.decode_decision (with_tag '\255') = None);
  Alcotest.(check bool) "32 bytes (a bare request, no tag) is rejected" true
    (Wire.decode_decision (Bytes.make 32 '\000') = None);
  Alcotest.(check bool) "34 bytes is rejected" true (Wire.decode_decision (Bytes.make 34 '\000') = None)

(* account_of_merge_key must be a genuine inverse of account_merge_key, not merely compatible with
   it -- otherwise two different merge_key strings could name the same account. *)
let test_account_merge_key_round_trips_and_rejects_non_canonical_forms () =
  List.iter
    (fun id ->
      Alcotest.(check bool)
        (Printf.sprintf "account %Ld round-trips through its merge_key" id)
        true
        (Schema.account_of_merge_key (Schema.account_merge_key id) = Some id))
    [ 0L; 7L; 100L; Int64.max_int; Int64.min_int; -42L ];
  Alcotest.(check bool) "a non-canonical decimal form is not accepted" true
    (Schema.account_of_merge_key "ledger.account.007" = None);
  Alcotest.(check bool) "a hex form is not accepted" true
    (Schema.account_of_merge_key "ledger.account.0x10" = None);
  Alcotest.(check bool) "an unparseable suffix is not accepted" true
    (Schema.account_of_merge_key "ledger.account.abc" = None);
  Alcotest.(check bool) "a wholly unrelated key is not accepted" true
    (Schema.account_of_merge_key "ledger.requests" = None);
  Alcotest.(check bool) "is_account_key agrees on the prefix" true
    (Schema.is_account_key "ledger.account.5" && not (Schema.is_account_key "ledger.requests"))

let test_transfer_idempotency_key_format () =
  Alcotest.(check string) "exact format" "ledger-transfer-42"
    (Schema.transfer_idempotency_key 42L)

let tests =
  [
    ("transfer_request round-trips through value", `Quick, test_transfer_request_round_trips_through_value);
    ("transfer_leg round-trips through value", `Quick, test_transfer_leg_round_trips_through_value);
    ("transfer_leg_of_value rejects malformed record", `Quick, test_transfer_leg_of_value_rejects_a_malformed_record);
    ("account_merge_key format", `Quick, test_account_merge_key_format);
    ("wire: request round-trips", `Quick, test_wire_request_round_trips);
    ("wire: decode_request rejects wrong length", `Quick, test_wire_decode_request_rejects_wrong_length);
    ("wire: balance round-trips", `Quick, test_wire_balance_round_trips);
    ( "wire: a decision round-trips on both outcomes",
      `Quick, test_wire_decision_round_trips_on_both_outcomes );
    ( "wire: decode_decision rejects a bad tag byte or wrong length",
      `Quick, test_wire_decode_decision_rejects_a_bad_tag_or_length );
    ( "account_merge_key and account_of_merge_key are genuine inverses",
      `Quick, test_account_merge_key_round_trips_and_rejects_non_canonical_forms );
    ("transfer_idempotency_key format", `Quick, test_transfer_idempotency_key_format);
  ]
