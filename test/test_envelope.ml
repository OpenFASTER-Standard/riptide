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

(* Task 3 domain separation (Decision 5): Envelope.content_hash now hashes
   Value.Sum (Envelope.domain_tag, to_value e) rather than a bare Record, so
   an envelope's hash space can never collide with a plain payload
   Value.value's hash space, even under adversarial construction. The two
   tests below prove this by construction rather than merely asserting it:
   the positive equivalence documents the exact mechanism, and the negative
   case is the actual regression test for the vulnerability this closes
   (task_003.md's carried-forward note / docs/superpowers/plans/
   2026-09-18-event-id-domain-separation.md). *)

(* Positive: a plain payload Value.value that deliberately mimics the exact
   wire shape content_hash now produces internally (Sum ("Envelope",
   to_value e)) is, by definition, the same preimage - so its Value.content_hash
   must equal Envelope.content_hash of the same envelope. This is what "domain-
   separated by construction" means: the two hash spaces coincide exactly when
   a value is literally that shape, and only then. *)
let test_crafted_sum_matches_envelope_hash () =
  let e = make_test_envelope () in
  let crafted = Value.Sum (Envelope.domain_tag, Envelope.to_value e) in
  Alcotest.(check bool)
    "Value.content_hash of Sum (domain_tag, to_value e) equals Envelope.content_hash e"
    true
    (Value.content_hash crafted = Envelope.content_hash e)

(* Negative (the actual regression test): a crafted value shaped as a bare
   Record with the envelope's exact field set - the OLD collision, when
   content_hash just did Value.content_hash (to_value e) - must now hash
   differently from Envelope.content_hash of a real envelope with the same
   field values. *)
let test_bare_record_no_longer_collides_with_envelope_hash () =
  let e = make_test_envelope () in
  let crafted_bare_record = Envelope.to_value e in
  Alcotest.(check bool)
    "Value.content_hash of the bare Record no longer equals Envelope.content_hash e"
    false
    (Value.content_hash crafted_bare_record = Envelope.content_hash e)

(* Step 3: generalize the negative case beyond hand-picked examples. For any
   generated envelope, Value.content_hash of the bare Record produced by
   to_value and Envelope.content_hash of that same envelope are never equal
   - regardless of what field values the envelope happens to carry. *)
let envelope_gen =
  let open QCheck2.Gen in
  let hash_gen = map (fun s -> String.sub (s ^ String.make 32 '\x00') 0 32) (string_size (int_range 0 32)) in
  let payload_gen =
    oneof
      [ map (fun s -> Value.Scalar (Value.String s)) (string_size (int_range 0 8));
        map (fun i -> Value.Scalar (Value.Int (Int64.of_int i))) int_small
      ]
  in
  let* actor = string_size (int_range 0 8) in
  let* causation = hash_gen in
  let* correlation = hash_gen in
  let* predecessor_hash = hash_gen in
  let* sequence = map Int64.of_int int_small in
  let* payload = payload_gen in
  return { Envelope.actor; causation; correlation; predecessor_hash; sequence; payload }

let envelope_hash_never_collides_with_bare_record_prop =
  QCheck2.Test.make
    ~name:"Value.content_hash of the bare to_value Record never equals Envelope.content_hash of the same envelope"
    ~count:200 envelope_gen (fun e ->
      Value.content_hash (Envelope.to_value e) <> Envelope.content_hash e)

let tests =
  [ ("content_hash deterministic", `Quick, test_content_hash_deterministic);
    ("content_hash changes with payload", `Quick, test_content_hash_changes_with_payload);
    ("content_hash changes with actor", `Quick, test_content_hash_changes_with_actor);
    ("content_hash changes with causation", `Quick, test_content_hash_changes_with_causation);
    ("content_hash changes with correlation", `Quick, test_content_hash_changes_with_correlation);
    ("content_hash changes with predecessor_hash", `Quick, test_content_hash_changes_with_predecessor_hash);
    ("content_hash changes with sequence", `Quick, test_content_hash_changes_with_sequence);
    ("genesis marker shape", `Quick, test_genesis_marker_is_32_zero_bytes);
    ("crafted Sum (domain_tag, to_value e) matches Envelope.content_hash e", `Quick,
     test_crafted_sum_matches_envelope_hash);
    ("crafted bare Record no longer collides with Envelope.content_hash", `Quick,
     test_bare_record_no_longer_collides_with_envelope_hash);
    QCheck_alcotest.to_alcotest envelope_hash_never_collides_with_bare_record_prop
  ]
