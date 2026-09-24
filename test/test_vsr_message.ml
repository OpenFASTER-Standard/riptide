(* test/test_vsr_message.ml *)
open Riptide
open Riptide_vsr

let sample_value () = Value.Scalar (Value.String "hello-vsr")

let sample_log () =
  [ Value.Scalar (Value.String "a"); Value.Scalar (Value.Int 2L); Value.Record [ ("x", Value.Scalar (Value.Bool true)) ] ]

(* ---- round-trip: encode then decode recovers the original, one hand-written example per
   constructor (the minimum bar per the task brief; the QCheck2 property below generalizes
   this beyond hand-picked examples). ---- *)

let test_round_trip_prepare () =
  let m = Message.Prepare { view = 3; n = 7; v = sample_value (); k = 5 } in
  Alcotest.(check bool) "Prepare round-trips" true (Message.decode (Message.encode m) = m)

let test_round_trip_prepare_ok () =
  let m = Message.Prepare_ok { view = 3; n = 7; i = 2 } in
  Alcotest.(check bool) "Prepare_ok round-trips" true (Message.decode (Message.encode m) = m)

let test_round_trip_start_view_change () =
  let m = Message.Start_view_change { v = 4; i = 1 } in
  Alcotest.(check bool) "Start_view_change round-trips" true (Message.decode (Message.encode m) = m)

(* [entries] is deliberately PARTIAL and NOT a prefix here (ops 1 and 3, no op 2), and [nacks]
   sits strictly above [n] -- exactly the shape a replica with one corrupt slot produces, and the
   shape a [Value.Sequence] of values could not have expressed at all. See message.mli's own note
   on the two fields. *)
let test_round_trip_do_view_change () =
  let m =
    Message.Do_view_change
      {
        v = 4;
        entries = (match sample_log () with a :: b :: _ -> [ (1, a); (3, b) ] | _ -> []);
        nacks = [ 8; 9 ];
        last_normal_view = 3;
        n = 7;
        k = 5;
        i = 1;
      }
  in
  Alcotest.(check bool) "Do_view_change round-trips" true (Message.decode (Message.encode m) = m)

let test_round_trip_do_view_change_with_empty_evidence () =
  let m = Message.Do_view_change { v = 4; entries = []; nacks = []; last_normal_view = 3; n = 0; k = 0; i = 1 } in
  Alcotest.(check bool) "Do_view_change with no readable entries and no nacks round-trips" true
    (Message.decode (Message.encode m) = m)

let test_round_trip_start_view () =
  let m = Message.Start_view { v = 4; log = sample_log (); n = 7; k = 5 } in
  Alcotest.(check bool) "Start_view round-trips" true (Message.decode (Message.encode m) = m)

(* ---- wire-integrity checksum (subtask 3.6): decode must reject a corrupted encoding rather than
   silently accept it as a different, well-formed message. Defense-in-depth only -- the real
   network-corruption case is already closed for production by Riptide_transport.Tcp's mandatory
   mutual TLS; this catches corruption from other sources (a local encoding bug, bytes already
   corrupted before retransmission) and keeps DST's own fault-injection testing meaningful. ---- *)

let test_decode_rejects_a_corrupted_encoding () =
  let msg = Message.Prepare { view = 1; n = 1; v = Value.Scalar (Value.String "x"); k = 0 } in
  let encoded = Message.encode msg in
  (* Flip one byte roughly in the middle of the encoding -- avoids the length-prefix bytes at the
     very start most canonical encodings carry, so this is a real content-corruption test, not a
     length-field corruption test (a different failure mode). *)
  let corrupted = Bytes.of_string encoded in
  let mid = Bytes.length corrupted / 2 in
  Bytes.set corrupted mid (Char.chr (Char.code (Bytes.get corrupted mid) lxor 0xFF));
  let corrupted = Bytes.to_string corrupted in
  (* This codebase's own established convention for asserting on an exception carrying a payload
     (see test_redaction.ml's test_encryption_with_merge_key_is_rejected) is to assert the real,
     exact message via Alcotest.check_raises -- NOT a placeholder payload. Alcotest 1.9.1's
     check_raises compares the raised exception for structural equality (`e <> exn`), so a
     placeholder string would not match and this test would fail for the wrong reason. *)
  Alcotest.check_raises "a corrupted encoding is rejected as malformed"
    (Message.Malformed_message "checksum mismatch -- message corrupted in transit or at rest")
    (fun () -> ignore (Message.decode corrupted))

let test_encode_decode_roundtrips_with_the_new_checksum () =
  let msg = Message.Prepare_ok { view = 2; n = 5; i = 1 } in
  Alcotest.(check bool) "a clean encoding still decodes to the same message" true
    (Message.decode (Message.encode msg) = msg)

(* ---- malformed-input tests: decode must raise Message.Malformed_message, never crash or
   succeed on garbage. ---- *)

let expect_malformed name (f : unit -> Message.t) =
  ( name,
    `Quick,
    fun () ->
      match f () with
      | (_ : Message.t) -> Alcotest.failf "%s: expected Malformed_message, but decode succeeded" name
      | exception Message.Malformed_message _ -> ()
      | exception exn -> Alcotest.failf "%s: expected Malformed_message, got %s" name (Printexc.to_string exn) )

let malformed_input_tests =
  [
    expect_malformed "not a value at all (garbage bytes)" (fun () -> Message.decode "\xff\xff\xff");
    expect_malformed "empty input" (fun () -> Message.decode "");
    expect_malformed "unknown Sum tag" (fun () ->
        Message.decode (Value.canonical_encode (Value.Sum ("NotAVsrMessage", Value.Record []))));
    expect_malformed "top-level value is not a Sum at all" (fun () ->
        Message.decode (Value.canonical_encode (Value.Record [ ("view", Value.Scalar (Value.Int 1L)) ])));
    expect_malformed "Sum body is not a Record" (fun () ->
        Message.decode (Value.canonical_encode (Value.Sum ("Prepare", Value.Scalar (Value.Int 1L)))));
    expect_malformed "Prepare missing the 'k' field" (fun () ->
        Message.decode
          (Value.canonical_encode
             (Value.Sum
                ( "Prepare",
                  Value.Record
                    [
                      ("view", Value.Scalar (Value.Int 3L));
                      ("n", Value.Scalar (Value.Int 7L));
                      ("v", sample_value ());
                    ] ))));
    expect_malformed "Prepare 'view' field has the wrong shape (String instead of Int)" (fun () ->
        Message.decode
          (Value.canonical_encode
             (Value.Sum
                ( "Prepare",
                  Value.Record
                    [
                      ("view", Value.Scalar (Value.String "not-an-int"));
                      ("n", Value.Scalar (Value.Int 7L));
                      ("v", sample_value ());
                      ("k", Value.Scalar (Value.Int 5L));
                    ] ))));
    expect_malformed "Do_view_change 'entries' field has the wrong shape (Int instead of Sequence)" (fun () ->
        Message.decode
          (Value.canonical_encode
             (Value.Sum
                ( "DoViewChange",
                  Value.Record
                    [
                      ("v", Value.Scalar (Value.Int 4L));
                      ("entries", Value.Scalar (Value.Int 1L));
                      ("nacks", Value.Sequence []);
                      ("last_normal_view", Value.Scalar (Value.Int 3L));
                      ("n", Value.Scalar (Value.Int 7L));
                      ("k", Value.Scalar (Value.Int 5L));
                      ("i", Value.Scalar (Value.Int 1L));
                    ] ))));
    expect_malformed "Start_view_change missing the 'i' field" (fun () ->
        Message.decode
          (Value.canonical_encode (Value.Sum ("StartViewChange", Value.Record [ ("v", Value.Scalar (Value.Int 4L)) ]))));
  ]

(* ---- QCheck2 round-trip property, one generator per constructor, matching Task 1's own
   discipline (a random generator, not just hand-picked examples). ---- *)

let small_value_gen =
  let open QCheck2.Gen in
  oneof
    [
      map (fun s -> Value.Scalar (Value.String s)) (string_size (int_range 0 8));
      map (fun i -> Value.Scalar (Value.Int (Int64.of_int i))) int_small;
      map (fun b -> Value.Scalar (Value.Bool b)) bool;
    ]

let log_gen =
  let open QCheck2.Gen in
  list_size (int_range 0 4) small_value_gen

let nonneg_int_gen =
  let open QCheck2.Gen in
  map abs int_small

let message_gen =
  let open QCheck2.Gen in
  oneof
    [
      map
        (fun (view, n, v, k) -> Message.Prepare { view; n; v; k })
        (tup4 nonneg_int_gen nonneg_int_gen small_value_gen nonneg_int_gen);
      map (fun (view, n, i) -> Message.Prepare_ok { view; n; i }) (tup3 nonneg_int_gen nonneg_int_gen nonneg_int_gen);
      map (fun (v, i) -> Message.Start_view_change { v; i }) (pair nonneg_int_gen nonneg_int_gen);
      map
        (fun (v, log, last_normal_view, n, k, i) ->
          Message.Do_view_change
            {
              v;
              entries = List.mapi (fun idx value -> (idx + 1, value)) log;
              nacks = [ n + 1; n + 2 ];
              last_normal_view;
              n;
              k;
              i;
            })
        (tup6 nonneg_int_gen log_gen nonneg_int_gen nonneg_int_gen nonneg_int_gen nonneg_int_gen);
      map (fun (v, log, n, k) -> Message.Start_view { v; log; n; k })
        (tup4 nonneg_int_gen log_gen nonneg_int_gen nonneg_int_gen);
    ]

let round_trip_prop =
  QCheck2.Test.make ~name:"Message.decode inverts Message.encode for any generated message" ~count:200
    message_gen (fun m -> Message.decode (Message.encode m) = m)

let tests =
  [
    ("round-trip Prepare", `Quick, test_round_trip_prepare);
    ("round-trip Prepare_ok", `Quick, test_round_trip_prepare_ok);
    ("round-trip Start_view_change", `Quick, test_round_trip_start_view_change);
    ("round-trip Do_view_change", `Quick, test_round_trip_do_view_change);
    ( "round-trip Do_view_change with empty entries/nacks",
      `Quick,
      test_round_trip_do_view_change_with_empty_evidence );
    ("round-trip Start_view", `Quick, test_round_trip_start_view);
    QCheck_alcotest.to_alcotest round_trip_prop;
    ("decode rejects a corrupted encoding", `Quick, test_decode_rejects_a_corrupted_encoding);
    ( "encode/decode round-trips with the new checksum",
      `Quick,
      test_encode_decode_roundtrips_with_the_new_checksum );
  ]
  @ malformed_input_tests
