(* test/test_log.ml *)
open Riptide

let test_append_computes_sequence_and_predecessor () =
  let log = Log.create () in
  let e1 = Log.append log ~actor:"a" ~causation:Envelope.genesis_marker ~correlation:Envelope.genesis_marker
      ~payload:(Value.Scalar (Value.String "first")) in
  Alcotest.(check int64) "first entry is sequence 1" 1L e1.sequence;
  Alcotest.(check bool) "first entry's predecessor is the genesis marker" true
    (e1.predecessor_hash = Envelope.genesis_marker);
  let e2 = Log.append log ~actor:"a" ~causation:(Envelope.content_hash e1) ~correlation:(Envelope.content_hash e1)
      ~payload:(Value.Scalar (Value.String "second")) in
  Alcotest.(check int64) "second entry is sequence 2" 2L e2.sequence;
  Alcotest.(check bool) "second entry's predecessor is the first entry's hash" true
    (e2.predecessor_hash = Envelope.content_hash e1)

let test_verify_chain_accepts_untampered_log () =
  let log = Log.create () in
  let e1 = Log.append log ~actor:"a" ~causation:Envelope.genesis_marker ~correlation:Envelope.genesis_marker
      ~payload:(Value.Scalar (Value.Int 1L)) in
  let _e2 = Log.append log ~actor:"a" ~causation:(Envelope.content_hash e1) ~correlation:(Envelope.content_hash e1)
      ~payload:(Value.Scalar (Value.Int 2L)) in
  Alcotest.(check bool) "untampered chain verifies" true (Log.verify_chain log)

let test_verify_chain_rejects_tampered_payload () =
  let log = Log.create () in
  let e1 = Log.append log ~actor:"a" ~causation:Envelope.genesis_marker ~correlation:Envelope.genesis_marker
      ~payload:(Value.Scalar (Value.Int 1L)) in
  let e2 = Log.append log ~actor:"a" ~causation:(Envelope.content_hash e1) ~correlation:(Envelope.content_hash e1)
      ~payload:(Value.Scalar (Value.Int 2L)) in
  (* Simulate tampering: swap entry 1's payload after the fact, leaving
     entry 2's recorded predecessor_hash pointing at the ORIGINAL
     (now-stale) hash of entry 1. This is exactly the class of corruption
     the old Riptide's unsafeguarded force_delete could cause with zero
     detection - here it must be caught. *)
  let tampered_e1 = { e1 with Envelope.payload = Value.Scalar (Value.Int 999L) } in
  Alcotest.(check bool) "tampered chain is rejected" false
    (Log.verify_chain_list [ tampered_e1; e2 ])

let tests =
  [ ("append computes sequence and predecessor", `Quick, test_append_computes_sequence_and_predecessor);
    ("verify_chain accepts untampered log", `Quick, test_verify_chain_accepts_untampered_log);
    ("verify_chain rejects tampered payload", `Quick, test_verify_chain_rejects_tampered_payload)
  ]
