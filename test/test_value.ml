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

let tests =
  [ ("encode deterministic", `Quick, test_encode_deterministic);
    ("record field order independent", `Quick, test_record_field_order_independent);
    ("no concatenation ambiguity", `Quick, test_no_concatenation_ambiguity);
    ("content_hash deterministic", `Quick, test_content_hash_deterministic);
    ("content_hash differs for different values", `Quick, test_content_hash_differs_for_different_values);
    ("float nan collisions fixed", `Quick, test_float_nan_collisions_fixed);
    ("float zero and negative zero hash differently", `Quick, test_float_zero_and_negative_zero_hash_differently);
    QCheck_alcotest.to_alcotest value_injective_prop;
    QCheck_alcotest.to_alcotest record_permutation_invariance_prop;
    QCheck_alcotest.to_alcotest map_permutation_invariance_prop
  ]
