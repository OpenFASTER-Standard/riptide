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

let test_mutating_original_bytes_buffer_does_not_corrupt_committed_entry () =
  (* Regression for M1: Value.Bytes used to carry OCaml's mutable `bytes`
     type by reference, so a caller who retained the buffer they built a
     payload from could mutate a committed log entry in place after the
     fact - silently changing content that had already been hashed and
     chained. Value.Bytes is now `string` (immutable), so constructing a
     payload from a caller's buffer requires an explicit Bytes.to_string
     copy at the call site - the caller can no longer hand the log a live
     mutable alias. *)
  let buffer = Bytes.of_string "AAAA" in
  let log = Log.create () in
  let e1 =
    Log.append log ~actor:"a" ~causation:Envelope.genesis_marker ~correlation:Envelope.genesis_marker
      ~payload:(Value.Scalar (Value.Bytes (Bytes.to_string buffer)))
  in
  let hash_before = Envelope.content_hash e1 in
  Alcotest.(check bool) "chain verifies before mutation" true (Log.verify_chain log);
  (* Mutate the ORIGINAL buffer the caller still holds - not anything
     returned from the log. *)
  Bytes.set buffer 0 'Z';
  let committed = List.hd (Log.to_list log) in
  Alcotest.(check bool) "committed entry's payload is unaffected by mutating the caller's original buffer"
    true
    (committed.payload = Value.Scalar (Value.Bytes "AAAA"));
  Alcotest.(check bool) "committed entry's content_hash is unaffected by mutating the caller's original buffer"
    true
    (Envelope.content_hash committed = hash_before);
  Alcotest.(check bool) "chain still verifies after mutating the caller's original buffer" true
    (Log.verify_chain log)

let tests =
  [ ("append computes sequence and predecessor", `Quick, test_append_computes_sequence_and_predecessor);
    ("verify_chain accepts untampered log", `Quick, test_verify_chain_accepts_untampered_log);
    ("verify_chain rejects tampered payload", `Quick, test_verify_chain_rejects_tampered_payload);
    ( "mutating original bytes buffer does not corrupt committed entry",
      `Quick,
      test_mutating_original_bytes_buffer_does_not_corrupt_committed_entry )
  ]
