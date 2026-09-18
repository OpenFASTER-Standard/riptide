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

let test_round_trip_do_view_change () =
  let m =
    Message.Do_view_change { v = 4; log = sample_log (); last_normal_view = 3; n = 7; k = 5; i = 1 }
  in
  Alcotest.(check bool) "Do_view_change round-trips" true (Message.decode (Message.encode m) = m)

let test_round_trip_start_view () =
  let m = Message.Start_view { v = 4; log = sample_log (); n = 7; k = 5 } in
  Alcotest.(check bool) "Start_view round-trips" true (Message.decode (Message.encode m) = m)

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
    expect_malformed "Do_view_change 'log' field has the wrong shape (Int instead of Sequence)" (fun () ->
        Message.decode
          (Value.canonical_encode
             (Value.Sum
                ( "DoViewChange",
                  Value.Record
                    [
                      ("v", Value.Scalar (Value.Int 4L));
                      ("log", Value.Scalar (Value.Int 1L));
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
        (fun (v, log, last_normal_view, n, k, i) -> Message.Do_view_change { v; log; last_normal_view; n; k; i })
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
    ("round-trip Start_view", `Quick, test_round_trip_start_view);
    QCheck_alcotest.to_alcotest round_trip_prop;
  ]
  @ malformed_input_tests
