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
  let m = Message.Prepare { view = 3; n = 7; v = sample_value (); k = 5; source = 1 } in
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
  let m = Message.Start_view { v = 4; log = sample_log (); n = 7; k = 5; source = 1 } in
  Alcotest.(check bool) "Start_view round-trips" true (Message.decode (Message.encode m) = m)

(* ---- wire-integrity checksum (subtask 3.6): decode must reject a corrupted encoding rather than
   silently accept it as a different, well-formed message. Defense-in-depth only -- the real
   network-corruption case is already closed for production by Riptide_transport.Tcp's mandatory
   mutual TLS; this catches corruption from other sources (a local encoding bug, bytes already
   corrupted before retransmission) and keeps DST's own fault-injection testing meaningful. ---- *)

let test_decode_rejects_a_corrupted_encoding () =
  let msg = Message.Prepare { view = 1; n = 1; v = Value.Scalar (Value.String "x"); k = 0; source = 1 } in
  let encoded = Message.encode msg in
  (* Flip the LAST byte of the checksummed BODY (i.e. the byte right before the 8-byte trailing
     checksum {!Message.encode} appends) -- the last thing any canonical encoder writes for a
     record is real field content, never a length prefix (those always precede the bytes they
     measure), so this reliably lands on content and reproduces the checksum-mismatch path this
     test is actually about, unlike a fixed "middle" offset (this record's own byte layout shifted
     once audit-remediation Task 3 added the `source` field, and "the middle" landed on a
     length-prefix byte instead, producing a decode error from THAT, a different and less specific
     failure mode than the one this test names). *)
  let corrupted = Bytes.of_string encoded in
  (* 8 = the trailing checksum's own length (message.mli's "Wire-integrity checksum" section) --
     not exposed as a value from this module, so restated here as the same literal that section
     documents. *)
  let target = String.length encoded - 8 - 1 in
  Bytes.set corrupted target (Char.chr (Char.code (Bytes.get corrupted target) lxor 0xFF));
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

(* [decode] strips the LAST 8 bytes of whatever it is given as a claimed checksum before doing
   anything else (see message.mli's "Wire-integrity checksum" section). A bare
   [Value.canonical_encode v] therefore has 8 real content bytes stripped off its end by [decode],
   so the truncated remainder dies inside [Value.canonical_decode] with a generic truncation
   error -- BEFORE ever reaching [of_value]'s own shape-validation code. [expect_malformed] only
   checks for [Malformed_message _] generically, so a case built with a bare [canonical_encode]
   still "passes", just for the wrong reason (truncation, not the shape defect the test name
   claims to cover). [enc] appends a real checksum, exactly as [Message.encode] does, so decode's
   checksum-stripping step consumes real checksum bytes and the (still-malformed) body actually
   reaches [of_value]'s shape validation as each of these tests intends. *)
let enc v = Value.canonical_encode v ^ String.sub (Value.content_hash v) 0 8

let malformed_input_tests =
  [
    (* These two are genuinely testing the "too short to carry a checksum" / immediate-garbage
       path, not [of_value]'s shape validation -- kept as raw, un-checksummed input on purpose. *)
    expect_malformed "not a value at all (garbage bytes)" (fun () -> Message.decode "\xff\xff\xff");
    expect_malformed "empty input" (fun () -> Message.decode "");
    expect_malformed "unknown Sum tag" (fun () ->
        Message.decode (enc (Value.Sum ("NotAVsrMessage", Value.Record []))));
    expect_malformed "top-level value is not a Sum at all" (fun () ->
        Message.decode (enc (Value.Record [ ("view", Value.Scalar (Value.Int 1L)) ])));
    expect_malformed "Sum body is not a Record" (fun () ->
        Message.decode (enc (Value.Sum ("Prepare", Value.Scalar (Value.Int 1L)))));
    expect_malformed "Prepare missing the 'k' field" (fun () ->
        Message.decode
          (enc
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
          (enc
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
          (enc
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
        Message.decode (enc (Value.Sum ("StartViewChange", Value.Record [ ("v", Value.Scalar (Value.Int 4L)) ]))));
    (* ---- Review Focus (audit-remediation Task 3): a Prepare/Start_view encoded in the OLD,
       pre-Task-3 shape (every field this constructor carried before [source] was added, but no
       [source] field at all) must fail decode LOUDLY as Malformed_message, not silently default
       [source] to some placeholder (e.g. 0) and let a stale/replayed old-format message sail
       through the new sender cross-check by accident. [int_of_field]'s own [field_exn] call
       already makes a missing field a hard [Malformed_message] for every OTHER field on every
       other constructor (see the 'k' and 'i' cases above) -- these two pin that the newly added
       [source] field gets exactly the same treatment, not an accidental default via e.g.
       [List.assoc_opt ... |> Option.value ~default:0]. *)
    expect_malformed "old-shaped Prepare (pre-Task-3, no 'source' field) is rejected, not silently accepted" (fun () ->
        Message.decode
          (enc
             (Value.Sum
                ( "Prepare",
                  Value.Record
                    [
                      ("view", Value.Scalar (Value.Int 3L));
                      ("n", Value.Scalar (Value.Int 7L));
                      ("v", sample_value ());
                      ("k", Value.Scalar (Value.Int 5L));
                    ] ))));
    expect_malformed "old-shaped Start_view (pre-Task-3, no 'source' field) is rejected, not silently accepted"
      (fun () ->
        Message.decode
          (enc
             (Value.Sum
                ( "StartView",
                  Value.Record
                    [
                      ("v", Value.Scalar (Value.Int 4L));
                      ("log", Value.Sequence (sample_log ()));
                      ("n", Value.Scalar (Value.Int 7L));
                      ("k", Value.Scalar (Value.Int 5L));
                    ] ))));
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
        (fun (view, n, v, k, source) -> Message.Prepare { view; n; v; k; source })
        (tup5 nonneg_int_gen nonneg_int_gen small_value_gen nonneg_int_gen nonneg_int_gen);
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
      map
        (fun (v, log, n, k, source) -> Message.Start_view { v; log; n; k; source })
        (tup5 nonneg_int_gen log_gen nonneg_int_gen nonneg_int_gen nonneg_int_gen);
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
