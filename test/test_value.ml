(* test/test_value.ml *)
open Riptide

let test_encode_deterministic () =
  let v = Value.Record [ ("a", Value.Scalar (Value.Int 1L)); ("b", Value.Scalar (Value.String "x")) ] in
  Alcotest.(check string) "same value encodes identically"
    (Value.canonical_encode v) (Value.canonical_encode v)

let test_record_field_order_independent () =
  let v1 = Value.Record [ ("a", Value.Scalar (Value.Int 1L)); ("b", Value.Scalar (Value.Int 2L)) ] in
  let v2 = Value.Record [ ("b", Value.Scalar (Value.Int 2L)); ("a", Value.Scalar (Value.Int 1L)) ] in
  Alcotest.(check string) "field order does not affect canonical encoding"
    (Value.canonical_encode v1) (Value.canonical_encode v2)

let test_no_concatenation_ambiguity () =
  (* The classic length-prefixing correctness case: two different sequences
     of strings must never encode identically just because their
     concatenated bytes happen to match. *)
  let v1 = Value.Sequence [ Value.Scalar (Value.String "ab"); Value.Scalar (Value.String "c") ] in
  let v2 = Value.Sequence [ Value.Scalar (Value.String "a"); Value.Scalar (Value.String "bc") ] in
  Alcotest.(check bool) "no concatenation-collision between distinct sequences"
    false (Value.canonical_encode v1 = Value.canonical_encode v2)

let test_content_hash_deterministic () =
  let v = Value.Scalar (Value.String "hello") in
  Alcotest.(check bool) "same value hashes identically"
    true (Value.content_hash v = Value.content_hash v)

let test_content_hash_differs_for_different_values () =
  let v1 = Value.Scalar (Value.Int 1L) in
  let v2 = Value.Scalar (Value.Int 2L) in
  Alcotest.(check bool) "different values hash differently"
    false (Value.content_hash v1 = Value.content_hash v2)

let test_float_nan_collisions_fixed () =
  (* Two different NaN bit patterns must encode differently.
     This validates the fix: Float encoding uses Int64.bits_of_float,
     not Printf.sprintf "%h" which collapses all NaNs to "nan". *)
  let canonical_nan = Value.Scalar (Value.Float nan) in
  let alternate_nan = Value.Scalar (Value.Float (Int64.float_of_bits 0x7ff8000000000001L)) in
  Alcotest.(check bool) "different NaN bit patterns encode differently"
    false (Value.canonical_encode canonical_nan = Value.canonical_encode alternate_nan)

(* Property: for any two QCheck-generated values, if they encode to the
   same canonical bytes, they must be structurally equal (no accidental
   collisions from the encoding scheme itself — this is checked over the
   generator's actual output, not a cryptographic collision-resistance
   proof). *)
let value_gen =
  let open QCheck2.Gen in
  let scalar_gen =
    oneof
      [ map (fun b -> Value.Scalar (Value.Bool b)) bool;
        map (fun i -> Value.Scalar (Value.Int (Int64.of_int i))) int_small;
        map (fun f -> Value.Scalar (Value.Float f)) float;
        map (fun s -> Value.Scalar (Value.String s)) (string_size (int_range 0 8))
      ]
  in
  sized
    (fix (fun self n ->
         match n with
         | 0 -> scalar_gen
         | n ->
           oneof_weighted
             [ (3, scalar_gen);
               ( 1,
                 map
                   (fun l -> Value.Record l)
                   (list_size (int_range 0 3) (pair (string_size (int_range 1 4)) (self (n / 2)))) );
               (1, map (fun l -> Value.Sequence l) (list_size (int_range 0 3) (self (n / 2))));
               (1, map (fun (tag, v) -> Value.Sum (tag, v))
                  (pair (string_size (int_range 1 4)) (self (n / 2))));
               (1, map (fun l -> Value.Map l)
                  (list_size (int_range 0 3) (pair (self (n / 2)) (self (n / 2)))))
             ]))

let value_arb = QCheck2.Test.make ~name:"canonical_encode is injective on generated values" ~count:200
    (QCheck2.Gen.pair value_gen value_gen)
    (fun (v1, v2) ->
       if Value.canonical_encode v1 = Value.canonical_encode v2 then v1 = v2 else true)

let tests =
  [ ("encode deterministic", `Quick, test_encode_deterministic);
    ("record field order independent", `Quick, test_record_field_order_independent);
    ("no concatenation ambiguity", `Quick, test_no_concatenation_ambiguity);
    ("content_hash deterministic", `Quick, test_content_hash_deterministic);
    ("content_hash differs for different values", `Quick, test_content_hash_differs_for_different_values);
    ("float nan collisions fixed", `Quick, test_float_nan_collisions_fixed);
    QCheck_alcotest.to_alcotest value_arb
  ]
