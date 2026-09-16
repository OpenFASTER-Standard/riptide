(* test/test_envelope.ml *)
open Riptide

let make_test_envelope () =
  {
    Envelope.actor = "test-actor";
    causation = Envelope.genesis_marker;
    correlation = Envelope.genesis_marker;
    predecessor_hash = Envelope.genesis_marker;
    sequence = 1L;
    payload = Value.Scalar (Value.String "hello");
  }

let test_content_hash_deterministic () =
  let e = make_test_envelope () in
  Alcotest.(check bool) "same envelope hashes identically"
    true (Envelope.content_hash e = Envelope.content_hash e)

let test_content_hash_changes_with_payload () =
  let e1 = make_test_envelope () in
  let e2 = { e1 with Envelope.payload = Value.Scalar (Value.String "different") } in
  Alcotest.(check bool) "different payload changes the hash"
    false (Envelope.content_hash e1 = Envelope.content_hash e2)

let test_genesis_marker_is_32_zero_bytes () =
  Alcotest.(check int) "genesis marker is 32 bytes" 32 (String.length Envelope.genesis_marker);
  Alcotest.(check bool) "genesis marker is all zero bytes" true
    (String.for_all (fun c -> c = '\x00') Envelope.genesis_marker)

let tests =
  [ ("content_hash deterministic", `Quick, test_content_hash_deterministic);
    ("content_hash changes with payload", `Quick, test_content_hash_changes_with_payload);
    ("genesis marker shape", `Quick, test_genesis_marker_is_32_zero_bytes)
  ]
