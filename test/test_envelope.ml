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

(* An alternate, well-formed 32-byte hash distinct from Envelope.genesis_marker
   and distinct from any real content_hash used in these tests, for use as
   "some other value" in the fields below. *)
let other_hash = String.make 32 '\x01'

(* M2: hash-sensitivity coverage for the five mandatory envelope fields that
   were previously untested (only `payload` was covered). Each of these
   constructs two otherwise-identical envelopes differing in exactly one
   field and asserts content_hash differs - closing the gap the review's
   fault-injection table exploited (e.g. renaming the "actor" Record key,
   or re-encoding `sequence` as a String instead of an Int, previously left
   the suite fully green). *)
let test_content_hash_changes_with_actor () =
  let e1 = make_test_envelope () in
  let e2 = { e1 with Envelope.actor = "different-actor" } in
  Alcotest.(check bool) "different actor changes the hash" false (Envelope.content_hash e1 = Envelope.content_hash e2)

let test_content_hash_changes_with_causation () =
  let e1 = make_test_envelope () in
  let e2 = { e1 with Envelope.causation = other_hash } in
  Alcotest.(check bool) "different causation changes the hash" false
    (Envelope.content_hash e1 = Envelope.content_hash e2)

let test_content_hash_changes_with_correlation () =
  let e1 = make_test_envelope () in
  let e2 = { e1 with Envelope.correlation = other_hash } in
  Alcotest.(check bool) "different correlation changes the hash" false
    (Envelope.content_hash e1 = Envelope.content_hash e2)

let test_content_hash_changes_with_predecessor_hash () =
  let e1 = make_test_envelope () in
  let e2 = { e1 with Envelope.predecessor_hash = other_hash } in
  Alcotest.(check bool) "different predecessor_hash changes the hash" false
    (Envelope.content_hash e1 = Envelope.content_hash e2)

let test_content_hash_changes_with_sequence () =
  let e1 = make_test_envelope () in
  let e2 = { e1 with Envelope.sequence = 2L } in
  Alcotest.(check bool) "different sequence changes the hash" false
    (Envelope.content_hash e1 = Envelope.content_hash e2)

let tests =
  [ ("content_hash deterministic", `Quick, test_content_hash_deterministic);
    ("content_hash changes with payload", `Quick, test_content_hash_changes_with_payload);
    ("content_hash changes with actor", `Quick, test_content_hash_changes_with_actor);
    ("content_hash changes with causation", `Quick, test_content_hash_changes_with_causation);
    ("content_hash changes with correlation", `Quick, test_content_hash_changes_with_correlation);
    ("content_hash changes with predecessor_hash", `Quick, test_content_hash_changes_with_predecessor_hash);
    ("content_hash changes with sequence", `Quick, test_content_hash_changes_with_sequence);
    ("genesis marker shape", `Quick, test_genesis_marker_is_32_zero_bytes)
  ]
