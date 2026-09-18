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

let test_float_zero_and_negative_zero_hash_differently () =
  (* M5: 0.0 and -0.0 are equal under both OCaml `=` and `compare`, but
     Float is content-addressed by its raw IEEE-754 bit pattern (see
     value.mli's Float doc comment), and the sign bit differs between
     them - so they must hash (and encode) differently here, regardless of
     what OCaml's own equality operators say. This is the behavior a
     replicated log actually needs pinned: two nodes deriving -0.0 vs 0.0
     from different arithmetic paths must not silently agree that they
     wrote "the same" event. *)
  let zero = Value.Scalar (Value.Float 0.0) in
  let negative_zero = Value.Scalar (Value.Float (-0.0)) in
  Alcotest.(check bool) "0.0 and -0.0 are OCaml-equal (sanity check on the premise)" true (0.0 = -0.0);
  Alcotest.(check bool) "0.0 and -0.0 encode to different bytes" false
    (Value.canonical_encode zero = Value.canonical_encode negative_zero);
  Alcotest.(check bool) "0.0 and -0.0 have different content_hash" false
    (Value.content_hash zero = Value.content_hash negative_zero)

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

(* M4: the previous property here (`canonical_encode v1 = canonical_encode
   v2 ==> v1 = v2`, using raw OCaml structural equality) is false by the
   module's own documented behavior, in direct contradiction with
   `test_record_field_order_independent` above: canonical_encode
   deliberately normalizes Record/Map entry order (value.mli), so two
   permuted-but-logically-identical values legitimately encode identically
   while being structurally unequal under `=`. Float nan is a second,
   independent way the old property was false: two values with identical
   NaN bit patterns encode identically (encoding is bit-exact, per M5), but
   OCaml's structural `=` on the float type follows IEEE754, where
   `nan = nan` is `false`. The old test only stayed green because the
   generator rarely draws a colliding permutation or a same-bits NaN pair.

   The fix below replaces raw `=` with `canonical_equal`, an equivalence
   relation that matches exactly what canonical_encode is actually
   injective over: Record fields and Map entries compared as sets (sorted
   the same way the encoder itself sorts them, so permutations compare
   equal), and Float compared by IEEE-754 bit pattern (so identical-bits
   NaNs compare equal, matching M5's bit-pattern content-addressing rule -
   distinct NaN payload bits still compare unequal, and are still covered
   separately by `test_float_nan_collisions_fixed` above). This is a
   genuinely true invariant, not a restriction to a special-cased subset of
   values. *)
let rec canonical_equal (v1 : Value.value) (v2 : Value.value) : bool =
  match (v1, v2) with
  | Value.Scalar (Value.Float f1), Value.Scalar (Value.Float f2) -> Int64.bits_of_float f1 = Int64.bits_of_float f2
  | Value.Scalar s1, Value.Scalar s2 -> s1 = s2
  | Value.Record fs1, Value.Record fs2 ->
    let by_key = List.stable_sort (fun (k1, _) (k2, _) -> String.compare k1 k2) in
    let fs1 = by_key fs1 and fs2 = by_key fs2 in
    List.length fs1 = List.length fs2
    && List.for_all2 (fun (k1, v1) (k2, v2) -> k1 = k2 && canonical_equal v1 v2) fs1 fs2
  | Value.Sum (t1, v1), Value.Sum (t2, v2) -> t1 = t2 && canonical_equal v1 v2
  | Value.Sequence l1, Value.Sequence l2 ->
    List.length l1 = List.length l2 && List.for_all2 canonical_equal l1 l2
  | Value.Map m1, Value.Map m2 ->
    (* Mirrors canonical_encode's own Map ordering: sort by the encoded
       bytes of the key, not the key's own structural order. *)
    let by_encoded_key = List.stable_sort (fun (k1, _) (k2, _) ->
        String.compare (Value.canonical_encode k1) (Value.canonical_encode k2))
    in
    let m1 = by_encoded_key m1 and m2 = by_encoded_key m2 in
    List.length m1 = List.length m2
    && List.for_all2 (fun (k1, v1) (k2, v2) -> canonical_equal k1 k2 && canonical_equal v1 v2) m1 m2
  | _ -> false

let value_injective_prop =
  QCheck2.Test.make
    ~name:"canonical_encode is injective up to Record/Map order and Float bit-pattern equality"
    ~count:200
    (QCheck2.Gen.pair value_gen value_gen)
    (fun (v1, v2) -> if Value.canonical_encode v1 = Value.canonical_encode v2 then canonical_equal v1 v2 else true)

(* Keeps only the first entry for each distinct key. Permutation invariance
   below is only claimed for maps/records with distinct keys: canonical_encode
   sorts by key with List.stable_sort (L4), so if two entries share a key,
   their relative order is a stable-sort tie-break that depends on their
   order in the *input* list - shuffling the input can therefore legitimately
   change the output bytes when duplicate keys are present. That is a
   pre-existing, documented-as-open question about duplicate-key handling
   (L4/final-review.md), not something this property is meant to test. *)
let dedup_by_key key_of entries =
  List.fold_left (fun acc x -> if List.exists (fun y -> key_of y = key_of x) acc then acc else acc @ [ x ]) [] entries

(* Separately: the canonicality guarantee itself, generated rather than the
   single hand-written example in test_record_field_order_independent
   above - any permutation of a Record's fields, or a Map's entries, must
   encode identically. *)
let record_permutation_gen =
  let open QCheck2.Gen in
  list_size (int_range 0 5) (pair (string_size (int_range 1 4)) value_gen) >>= fun raw_fields ->
  let fields = dedup_by_key fst raw_fields in
  shuffle_list fields >>= fun shuffled -> return (fields, shuffled)

let record_permutation_invariance_prop =
  QCheck2.Test.make ~name:"canonical_encode is invariant under Record field permutation" ~count:100
    record_permutation_gen (fun (fields, shuffled) ->
        Value.canonical_encode (Value.Record fields) = Value.canonical_encode (Value.Record shuffled))

let map_permutation_gen =
  let open QCheck2.Gen in
  list_size (int_range 0 5) (pair value_gen value_gen) >>= fun raw_entries ->
  let entries = dedup_by_key (fun (k, _) -> Value.canonical_encode k) raw_entries in
  shuffle_list entries >>= fun shuffled -> return (entries, shuffled)

let map_permutation_invariance_prop =
  QCheck2.Test.make ~name:"canonical_encode is invariant under Map entry permutation" ~count:100
    map_permutation_gen (fun (entries, shuffled) ->
        Value.canonical_encode (Value.Map entries) = Value.canonical_encode (Value.Map shuffled))

(* ---- canonical_decode ----

   Raw byte-level helpers to hand-construct encodings independently of
   [Value.canonical_encode] itself, so the decode tests below check against
   the wire format (as documented by [encode_into]'s tag bytes and 8-byte
   big-endian length/count prefixes), not just "whatever the encoder
   happens to produce." *)

let u64_be (n : int) : string =
  let b = Bytes.create 8 in
  for i = 0 to 7 do
    Bytes.set b (7 - i) (Char.chr ((n lsr (8 * i)) land 0xff))
  done;
  Bytes.to_string b

let i64_be (v : int64) : string =
  let b = Bytes.create 8 in
  for i = 0 to 7 do
    Bytes.set b (7 - i) (Char.chr (Int64.to_int (Int64.logand (Int64.shift_right_logical v (8 * i)) 0xffL)))
  done;
  Bytes.to_string b

let len_prefixed (s : string) : string = u64_be (String.length s) ^ s

let raw_bool b = "\x00" ^ (if b then "\x01" else "\x00")
let raw_int i = "\x01" ^ i64_be i
let raw_float f = "\x02" ^ i64_be (Int64.bits_of_float f)
let raw_string s = "\x03" ^ len_prefixed s
let raw_bytes b = "\x04" ^ len_prefixed b

let test_decode_bool () =
  Alcotest.(check bool) "decodes Bool" true (Value.canonical_decode (raw_bool true) = Value.Scalar (Value.Bool true))

let test_decode_int () =
  Alcotest.(check bool) "decodes Int" true
    (Value.canonical_decode (raw_int 42L) = Value.Scalar (Value.Int 42L))

let test_decode_float () =
  let decoded = Value.canonical_decode (raw_float 3.5) in
  Alcotest.(check bool) "decodes Float" true (decoded = Value.Scalar (Value.Float 3.5))

let test_decode_string () =
  Alcotest.(check bool) "decodes String" true
    (Value.canonical_decode (raw_string "hello") = Value.Scalar (Value.String "hello"))

let test_decode_bytes () =
  Alcotest.(check bool) "decodes Bytes" true
    (Value.canonical_decode (raw_bytes "\x00\x01\x02") = Value.Scalar (Value.Bytes "\x00\x01\x02"))

let test_decode_record () =
  (* Fields already in sorted order ("a" < "b"), so this is unambiguous
     regardless of any canonicalization decode might or might not do. *)
  let raw = "\x05" ^ u64_be 2 ^ len_prefixed "a" ^ raw_bool true ^ len_prefixed "b" ^ raw_string "x" in
  let expected = Value.Record [ ("a", Value.Scalar (Value.Bool true)); ("b", Value.Scalar (Value.String "x")) ] in
  Alcotest.(check bool) "decodes Record" true (Value.canonical_decode raw = expected)

let test_decode_sum () =
  let raw = "\x06" ^ len_prefixed "Envelope" ^ raw_bool true in
  let expected = Value.Sum ("Envelope", Value.Scalar (Value.Bool true)) in
  Alcotest.(check bool) "decodes Sum" true (Value.canonical_decode raw = expected)

let test_decode_sequence () =
  let raw = "\x07" ^ u64_be 2 ^ raw_bool true ^ raw_int 5L in
  let expected = Value.Sequence [ Value.Scalar (Value.Bool true); Value.Scalar (Value.Int 5L) ] in
  Alcotest.(check bool) "decodes Sequence" true (Value.canonical_decode raw = expected)

let test_decode_map () =
  (* A Map entry's key is stored as a length-prefixed blob containing the
     key's OWN recursively-encoded bytes, not encoded inline - this is the
     asymmetry the brief calls out as the easiest place to get wrong. *)
  let key_encoded = raw_string "k" in
  let raw = "\x08" ^ u64_be 1 ^ len_prefixed key_encoded ^ raw_int 7L in
  let expected = Value.Map [ (Value.Scalar (Value.String "k"), Value.Scalar (Value.Int 7L)) ] in
  Alcotest.(check bool) "decodes Map" true (Value.canonical_decode raw = expected)

(* Malformed-input tests: each of these must raise [Invalid_argument]
   promptly - never read out of bounds, loop, or crash with some other
   unhandled exception. *)
let expect_invalid_argument name (f : unit -> Value.value) =
  ( name,
    `Quick,
    fun () ->
      match f () with
      | (_ : Value.value) -> Alcotest.failf "%s: expected Invalid_argument, but decode succeeded with a value" name
      | exception Invalid_argument _ -> ()
      | exception exn -> Alcotest.failf "%s: expected Invalid_argument, got %s" name (Printexc.to_string exn) )

let malformed_input_tests =
  [ expect_invalid_argument "empty input" (fun () -> Value.canonical_decode "");
    expect_invalid_argument "truncated mid-length-prefix (string)" (fun () ->
        Value.canonical_decode ("\x03" ^ "\x00\x00\x00"));
    expect_invalid_argument "truncated mid-count-prefix (record)" (fun () ->
        Value.canonical_decode ("\x05" ^ "\x00\x00\x00"));
    expect_invalid_argument "truncated mid-payload (string body shorter than claimed length)" (fun () ->
        Value.canonical_decode ("\x03" ^ u64_be 10 ^ "abc"));
    expect_invalid_argument "claimed length exceeds remaining bytes" (fun () ->
        Value.canonical_decode ("\x04" ^ u64_be 1_000_000 ^ "x"));
    expect_invalid_argument "claimed count exceeds remaining bytes (sequence)" (fun () ->
        Value.canonical_decode ("\x07" ^ u64_be 1_000_000));
    expect_invalid_argument "unknown tag byte" (fun () -> Value.canonical_decode "\xff");
    expect_invalid_argument "trailing garbage after a complete value" (fun () ->
        Value.canonical_decode (raw_bool true ^ "\xff"));
    expect_invalid_argument "truncated int payload" (fun () -> Value.canonical_decode ("\x01" ^ "\x00\x00\x00"));
    expect_invalid_argument "invalid bool byte" (fun () -> Value.canonical_decode ("\x00" ^ "\x02"));
    expect_invalid_argument "trailing garbage inside a map key blob" (fun () ->
        (* The key blob claims to hold one extra byte beyond a complete
           encoded value - decode_value_exact must reject this even though
           the outer stream's own bookkeeping stays consistent. *)
        let key_encoded_plus_garbage = raw_string "k" ^ "\xff" in
        Value.canonical_decode ("\x08" ^ u64_be 1 ^ len_prefixed key_encoded_plus_garbage ^ raw_int 7L))
  ]

let round_trip_prop =
  QCheck2.Test.make ~name:"canonical_decode inverts canonical_encode (round-trips to the same bytes)" ~count:200
    value_gen (fun v ->
        let encoded = Value.canonical_encode v in
        let decoded = Value.canonical_decode encoded in
        Value.canonical_encode decoded = encoded)

let tests =
  [ ("encode deterministic", `Quick, test_encode_deterministic);
    ("record field order independent", `Quick, test_record_field_order_independent);
    ("no concatenation ambiguity", `Quick, test_no_concatenation_ambiguity);
    ("content_hash deterministic", `Quick, test_content_hash_deterministic);
    ("content_hash differs for different values", `Quick, test_content_hash_differs_for_different_values);
    ("float nan collisions fixed", `Quick, test_float_nan_collisions_fixed);
    ("float zero and negative zero hash differently", `Quick, test_float_zero_and_negative_zero_hash_differently);
    ("decode bool", `Quick, test_decode_bool);
    ("decode int", `Quick, test_decode_int);
    ("decode float", `Quick, test_decode_float);
    ("decode string", `Quick, test_decode_string);
    ("decode bytes", `Quick, test_decode_bytes);
    ("decode record", `Quick, test_decode_record);
    ("decode sum", `Quick, test_decode_sum);
    ("decode sequence", `Quick, test_decode_sequence);
    ("decode map", `Quick, test_decode_map);
    QCheck_alcotest.to_alcotest value_injective_prop;
    QCheck_alcotest.to_alcotest record_permutation_invariance_prop;
    QCheck_alcotest.to_alcotest map_permutation_invariance_prop;
    QCheck_alcotest.to_alcotest round_trip_prop
  ]
  @ malformed_input_tests
