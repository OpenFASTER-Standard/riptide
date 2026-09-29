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
   below is only claimed for maps/records with distinct keys: a value with a
   duplicate key is no longer just an "order is a stable-sort tie-break"
   open question (M6, task-6 review, correcting this comment's own earlier
   claim) - Task 6 closed that question outright, and canonical_encode now
   raises Invalid_argument on any duplicate-keyed Record/Map outright,
   before any ordering could even matter. This generator still dedups its
   own top-level output so these two properties can keep testing genuine
   permutation invariance rather than merely re-deriving "duplicate keys
   raise" (already covered directly by
   test_encode_rejects_an_in_memory_duplicate_key_record/_map below);
   value_gen itself does not yet dedup at every nesting level, which
   is what makes the four QCheck properties below it fail post-Task-6 - see
   this task's report for why that's Task 7's scope, not this comment's. *)
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

(* Hand-constructs the wire bytes for a value nested [depth] levels deep via
   Map keys: a Map whose single entry's key is itself a Map whose single
   entry's key is itself a Map ... bottoming out at a plain Scalar Int, each
   level's (throwaway) value a cheap Scalar Bool. Built directly from raw
   bytes, not via [Value.canonical_encode], because constructing the
   equivalent in-memory [Value.value] first would itself take O(depth) stack
   frames of unavoidable but unrelated overhead at this depth - the point is
   to isolate decode's own cost.

   Levels nest as: level_i = tag_map ++ count(1) ++ len_prefixed(level_(i-1))
   ++ dummy_value, bottoming out at level_0 = raw_int 0L. Expanding that
   recurrence gives level_depth = P_depth ++ P_(depth-1) ++ ... ++ P_1 ++
   level_0 ++ dummy_value * depth, where P_i is level_i's fixed-size header
   (tag + count + inner length prefix, 17 bytes) - which lets this be built
   with one O(depth) pass (each level's required length prefix computed
   directly from the known linear-growth formula, not by re-measuring an
   already-built string) instead of restaging an O(depth^2) copy in the test
   helper itself. *)
let build_nested_map_key_wire_bytes ~depth =
  let innermost = raw_int 0L in
  let dummy_value = raw_bool true in
  let header_len = 1 + 8 + 8 (* tag + count(1) prefix + inner length prefix *) in
  let per_level_growth = header_len + String.length dummy_value in
  let buf = Buffer.create (String.length innermost + (per_level_growth * depth)) in
  for i = depth downto 1 do
    let inner_len = String.length innermost + (per_level_growth * (i - 1)) in
    Buffer.add_char buf '\x08';
    Buffer.add_string buf (u64_be 1);
    Buffer.add_string buf (u64_be inner_len)
  done;
  Buffer.add_string buf innermost;
  for _ = 1 to depth do
    Buffer.add_string buf dummy_value
  done;
  Buffer.contents buf

(* Builds the equivalent in-memory [Value.value] (same shape as
   [build_nested_map_key_wire_bytes] above, but as a real value tree rather
   than raw bytes) via an O(depth) tail-recursive loop, bottom-up - no deep
   *construction*-time recursion, so this isolates encode's own cost the
   same way the wire-bytes helper isolates decode's. *)
let build_nested_map_key_value ~depth =
  let rec loop i acc = if i = 0 then acc else loop (i - 1) (Value.Map [ (acc, Value.Scalar (Value.Bool true)) ]) in
  loop depth (Value.Scalar (Value.Int 0L))

(* Finding I2 (task-5 fix round): fixed wall-clock thresholds (`elapsed <
   1.0`) had ~200-300x slack against actual measured times (~0.006s/0.003s
   at depth 20,000), so a 100x regression would still pass, and are also
   coupled to this box's own CPU speed (a hard cgroup quota, not a real
   core count - see /work/CLAUDE.md's "cpu.max" note), which can make an
   absolute-time assertion fail for reasons unrelated to the code under
   test. Fixed by asserting on how time SCALES with depth instead of an
   absolute bound.

   Round-2 correction (Finding 1, task-5 fix loop): the first version of
   this fix compared t(2D) against t(D) with a 4.0x factor - independently
   re-derived by reconstructing the pre-Task-5 quadratic decoder and
   measuring it at these exact depths, that gave a *measured* ratio of
   3.81x, which PASSES a 4.0x bound. At only a 2x depth span, a genuinely
   quadratic algorithm's ratio (nominally 4x) sits close enough to a
   linear algorithm's ratio (nominally 2x, but with real lower-order-term
   noise pushing it up) that a single factor can't cleanly separate them -
   the test would not have caught a reintroduction of the exact bug it
   exists to prevent.

   Fix: widen the span to 4x (compare t(4D) against t(D) instead of t(2D)
   against t(D)). At a 4x span the two hypotheses separate widely: linear
   cost gives a ~4x ratio (with noise), quadratic gives a ~16x ratio - a
   16x/4x = 4x gap between the two nominal ratios, vs. only a 4x/2x = 2x
   gap at the old 2x span. asserting the 4x-depth time stays within an 8x
   bound (plus a small additive floor to stay non-flaky when both
   measurements are too fast for the ratio itself to be meaningful) gives
   real margin on both sides: comfortably above a linear algorithm's noisy
   ~4x, comfortably below a quadratic algorithm's ~16x. Verified directly
   (see the fix-round report): the reconstructed quadratic decoder measures
   ~15-16x at this span and FAILS an 8x bound; the current linear
   implementation measures ~2.3-2.6x and passes with a wide margin. *)
let scaling_bound ~t_d ~factor ~floor = (t_d *. factor) +. floor

let test_deeply_nested_map_keys_encode_in_linear_time () =
  (* Correctness pin, independent of timing: cross-check against the
     independently hand-built wire bytes for the exact same structure, byte
     for byte, at the same depth (20,000) the original audit finding used.
     Timing alone can't catch an off-by-one in the backpatched Map-key
     length prefix (see [Wbuf.reserve]/[Wbuf.patch_u64_be] in [lib/value.ml])
     - a mismatch there would silently produce a corrupt frame with a wrong
     length prefix, only surfacing as a decode failure elsewhere. *)
  let v20k = build_nested_map_key_value ~depth:20_000 in
  Alcotest.(check string) "encodes to the same bytes as the hand-built wire format"
    (build_nested_map_key_wire_bytes ~depth:20_000) (Value.canonical_encode v20k);
  let time_at depth =
    let v = build_nested_map_key_value ~depth in
    let start = Unix.gettimeofday () in
    ignore (Value.canonical_encode v);
    Unix.gettimeofday () -. start
  in
  let d = 20_000 in
  let t_d = time_at d in
  let t_4d = time_at (4 * d) in
  let bound = scaling_bound ~t_d ~factor:8.0 ~floor:0.1 in
  Alcotest.(check bool)
    (Printf.sprintf
       "encode time scales ~linearly with depth, not quadratically (t(%d)=%.4fs, t(%d)=%.4fs, bound=%.4fs)"
       d t_d (4 * d) t_4d bound)
    true (t_4d <= bound)

let test_deeply_nested_map_keys_decode_in_linear_time () =
  let time_at depth =
    let wire = build_nested_map_key_wire_bytes ~depth in
    let start = Unix.gettimeofday () in
    ignore (Value.canonical_decode wire);
    Unix.gettimeofday () -. start
  in
  let d = 20_000 in
  let t_d = time_at d in
  let t_4d = time_at (4 * d) in
  let bound = scaling_bound ~t_d ~factor:8.0 ~floor:0.1 in
  Alcotest.(check bool)
    (Printf.sprintf
       "decode time scales ~linearly with depth, not quadratically (t(%d)=%.4fs, t(%d)=%.4fs, bound=%.4fs)"
       d t_d (4 * d) t_4d bound)
    true (t_4d <= bound)

(* Finding C1/C2 (task-5 fix round): [encode_into]'s Map case is only
   copy-free for the single-entry ("nothing to sort") fast path - a Map
   with 2+ entries at a nesting level still materializes each key's bytes
   via a fresh buffer to compare them (see the "Two or more entries..."
   comment in [lib/value.ml]'s [encode_into]). When *every* level of a deep
   chain has 2+ entries (not just the outermost - an attacker controls a
   Map's shape at every level, not just its depth), that materialization
   compounds across nesting exactly like the original audited bug did:
   Θ(depth x size), i.e. still quadratic in depth. The reviewer measured
   this directly reachable from raw wire bytes (Message.decode ->
   Value.canonical_decode -> checksum/content_hash, before any
   protocol-level validation) and, at the original finding's own reproduction
   depth (20,000), WORSE than the finding this task was created to fix
   (14.5GB/~7s vs the audited 5.3GB/1.64s).

   Per the controller ruling recorded in this task's fix-round report:
   fully closing this (a byte-lexicographic structural comparator across
   all 5 constructors, needed to make the general case copy-free) is
   explicitly out of scope here - consensus-safety-critical canonical
   ordering is a much higher-risk place to introduce a subtle bug than this
   DoS is to leave in place a little longer, and Task 8 (depth-bounded
   decode/encode, capping nesting at 1000) is the intended mitigation.

   This test is a pinning/regression baseline, not a fix: it measures the
   *current* cost of this residual at Task 8's own future cap (depth 1000,
   NOT the 20,000 used to demonstrate the blowup - that takes ~7s and would
   make the suite unbearably slow), so Task 8's depth-cap work has a
   concrete "must not regress past this" number, and so the residual is
   something the suite actually knows about rather than only something
   described in a report file. The reviewer measured ~19ms/37MB at depth
   1000 (matching the doc comment in [lib/value.ml] that Task 8 threads a
   depth counter through both [decode_value] and [encode_into] and is
   expected to neutralize this as a practical DoS even though the
   underlying algorithm stays quadratic in the abstract) - 500ms leaves
   generous real headroom above that as a genuine trip-wire, not a
   hair-trigger flaky bound. *)
let build_two_entry_per_level_deep_map_value ~depth =
  let rec loop i acc =
    if i = 0 then acc
    else
      loop (i - 1)
        (Value.Map
           [ (acc, Value.Scalar (Value.Bool true));
             (Value.Scalar (Value.Int (Int64.of_int i)), Value.Scalar (Value.Bool true))
           ])
  in
  loop depth (Value.Scalar (Value.Int 0L))

(* Unlike the two scaling tests above, this one is deliberately NOT a
   scaling assertion: its whole point is that this specific shape is
   *still* quadratic on purpose (deferred to Task 8), so there is no
   "linear" hypothesis to discriminate against here - it's pinning "still
   fast enough to be a viable Task-8 baseline" at one fixed, bounded depth,
   which is exactly what an absolute wall-clock threshold is for. Widened
   from an earlier 0.5s bound (flagged as fragile: only ~26x headroom over
   the ~19ms locally-measured cost, not much margin on this box's
   CPU-quota-throttled environment - see /work/CLAUDE.md's "cpu.max" note)
   to 2.0s (~100x headroom) for real safety margin on a slow/loaded
   machine, while staying far under the suite's 15s per-test watchdog. *)
let test_two_entries_per_level_deep_map_encode_hash_residual_bounded () =
  let v = build_two_entry_per_level_deep_map_value ~depth:1000 in
  let start = Unix.gettimeofday () in
  ignore (Value.content_hash v);
  let elapsed = Unix.gettimeofday () -. start in
  Alcotest.(check bool)
    (Printf.sprintf
       "2-entries-per-level Map with a 1000-deep chain (Task 8's future depth cap) content_hashes \
        in well under 2.0s (residual pinning baseline for Task 8 not to regress past; took %.4fs)"
       elapsed)
    true (elapsed < 2.0)

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
           encoded value - decode_value's Map case must reject this (the
           nested, bounded decode of the key lands short of kblob_end) even
           though the outer stream's own bookkeeping stays consistent. *)
        let key_encoded_plus_garbage = raw_string "k" ^ "\xff" in
        Value.canonical_decode ("\x08" ^ u64_be 1 ^ len_prefixed key_encoded_plus_garbage ^ raw_int 7L))
  ]

(* Task 6: canonical_decode enforces strict canonical ordering (Record
   fields / Map keys must arrive strictly increasing per the same
   comparator canonical_encode sorts by) and rejects duplicate keys
   outright - two byte-different wire encodings must never decode to
   values that could disagree on content_hash while representing "the same"
   Record/Map. Reusing [expect_invalid_argument] (already typed for
   [unit -> Value.value]) for the decode-side cases below; a separate,
   generic helper for the encode-side cases, which never touch
   canonical_decode at all. *)

let test_decode_rejects_a_non_canonically_ordered_record () =
  (* Fields deliberately reversed: "b" before "a". *)
  let unsorted_wire = "\x05" ^ u64_be 2 ^ len_prefixed "b" ^ raw_bool false ^ len_prefixed "a" ^ raw_bool true in
  Alcotest.check_raises "non-canonical Record field order is rejected on decode"
    (Invalid_argument "canonical_decode: record fields are not in canonical order (\"a\" after \"b\")")
    (fun () -> ignore (Value.canonical_decode unsorted_wire))

let test_decode_rejects_a_duplicate_key_record () =
  let dup_wire = "\x05" ^ u64_be 2 ^ len_prefixed "k" ^ raw_bool true ^ len_prefixed "k" ^ raw_bool false in
  Alcotest.check_raises "duplicate Record field keys are rejected on decode"
    (Invalid_argument "canonical_decode: duplicate record field key \"k\"")
    (fun () -> ignore (Value.canonical_decode dup_wire))

let test_decode_rejects_a_non_canonically_ordered_map () =
  (* Map keys are stored as length-prefixed blobs of their own encoded
     bytes (see test_decode_map above); "b"'s blob sorts after "a"'s, so
     storing "b" first is out of canonical order. *)
  let key_b = raw_string "b" and key_a = raw_string "a" in
  let unsorted_wire =
    "\x08" ^ u64_be 2 ^ len_prefixed key_b ^ raw_bool false ^ len_prefixed key_a ^ raw_bool true
  in
  (* M8 (task-6 review): the error now carries the offending entry's 0-based index and
     byte offset (a Map key's raw bytes generally aren't printable the way a Record
     field's `%S` name is) - computed here by hand from the wire layout above: tag(1) +
     count(8) + [len_prefix(8) + key_b blob(10)] + raw_bool(2) puts key_a's blob (the
     second entry, index 1) at byte offset 1+8+8+10+2+8 = 37. *)
  Alcotest.check_raises "non-canonical Map key order is rejected on decode"
    (Invalid_argument "canonical_decode: map entries are not in canonical (key-sorted) order (entry index 1, byte offset 37)")
    (fun () -> ignore (Value.canonical_decode unsorted_wire))

let test_decode_rejects_a_duplicate_key_map () =
  let key_k = raw_string "k" in
  let dup_wire = "\x08" ^ u64_be 2 ^ len_prefixed key_k ^ raw_int 1L ^ len_prefixed key_k ^ raw_int 2L in
  (* M8 (task-6 review): same offset-computation as the ordering test above, but both
     entries here use key_k's blob (10 bytes), so the second entry (index 1) starts at
     byte offset 1+8+8+10+9+8 = 44 (raw_int is 9 bytes, not raw_bool's 2). *)
  Alcotest.check_raises "duplicate Map keys are rejected on decode"
    (Invalid_argument "canonical_decode: duplicate map key (entry index 1, byte offset 44)")
    (fun () -> ignore (Value.canonical_decode dup_wire))

(* Finding 1 (task-6 review): the four tests above are all REJECT-side coverage of the
   new Map/Record ordering check. Before this test, no currently-passing test exercised
   the ACCEPT side of the new Map check on a legitimate, multi-entry, correctly-ordered
   Map: test_decode_map above has exactly one entry, so prev_kblob threading and
   compare_byte_range are never walked across real multi-byte content by any green test.
   (The four QCheck properties that *did* cover this - round_trip_prop,
   value_injective_prop, record/map_permutation_invariance_prop - are the ones this task
   correctly turns red, per this task's own report; they're not a substitute here.) A
   future bug that made compare_byte_range (or the `c > 0` branch in decode_value's Map
   arm) wrongly REJECT a legitimately-ordered Map would ship with a fully green suite
   without this test.

   Keys are chosen to force compare_byte_range to actually walk a multi-byte shared
   prefix rather than diverge at byte 0: Scalar (String "a")'s and Scalar (String "ab")'s
   encoded blobs ([\x03][00 00 00 00 00 00 00 01]['a'] and
   [\x03][00 00 00 00 00 00 00 02]['a']['b']) share their first 8 bytes (the tag plus 7
   leading zero bytes of the big-endian length prefix) and diverge only at the 9th byte -
   the one byte of the length prefix that actually encodes their differing lengths (0x01
   vs 0x02). Scalar (Int 1L) diverges from both at byte 0 (a different tag byte
   entirely), giving a second, trivial case in the same Map. Building the wire bytes via
   [Value.canonical_encode] itself (rather than hand-rolling them, unlike the reject-side
   tests above) is deliberate: it's the only way to also pin the round-trip fixpoint this
   task's whole guarantee rests on and which, before this test, had no passing coverage
   for any value at all - [canonical_encode (canonical_decode (canonical_encode v)) =
   canonical_encode v]. *)
let test_decode_accepts_a_correctly_ordered_multi_entry_map () =
  let v =
    Value.Map
      [ (Value.Scalar (Value.String "a"), Value.Scalar (Value.Bool true));
        (Value.Scalar (Value.Int 1L), Value.Scalar (Value.Bool false));
        (Value.Scalar (Value.String "ab"), Value.Scalar (Value.Bool true))
      ]
  in
  let encoded = Value.canonical_encode v in
  let decoded = Value.canonical_decode encoded in
  Alcotest.(check bool)
    "decode accepts a correctly-ordered, multi-entry Map (does not wrongly reject it) and \
     reproduces its logical content"
    true (canonical_equal decoded v);
  Alcotest.(check string)
    "canonical_encode (canonical_decode (canonical_encode v)) = canonical_encode v"
    encoded (Value.canonical_encode decoded)

(* M5 (task-6 review): this used to be a bespoke helper (matching only [Invalid_argument
   _], no message check) because [canonical_encode : value -> string] doesn't fit
   [expect_invalid_argument]'s [unit -> Value.value] signature above. That was
   unnecessary - [Alcotest.check_raises] already fits any [unit -> unit] thunk directly -
   and weaker than the decode-side tests right below, which are message-exact. These two
   are now written the same way, matching that style. *)
let test_encode_rejects_an_in_memory_duplicate_key_record () =
  let v = Value.Record [ ("k", Value.Scalar (Value.Bool true)); ("k", Value.Scalar (Value.Bool false)) ] in
  Alcotest.check_raises "canonical_encode rejects an in-memory duplicate Record key"
    (Invalid_argument "canonical_encode: duplicate record field key")
    (fun () -> ignore (Value.canonical_encode v))

let test_encode_rejects_an_in_memory_duplicate_key_map () =
  let k = Value.Scalar (Value.String "k") in
  let v = Value.Map [ (k, Value.Scalar (Value.Int 1L)); (k, Value.Scalar (Value.Int 2L)) ] in
  Alcotest.check_raises "canonical_encode rejects an in-memory duplicate Map key"
    (Invalid_argument "canonical_encode: duplicate map key")
    (fun () -> ignore (Value.canonical_encode v))

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
    ( "decode rejects a non-canonically ordered record",
      `Quick,
      test_decode_rejects_a_non_canonically_ordered_record );
    ("decode rejects a duplicate key record", `Quick, test_decode_rejects_a_duplicate_key_record);
    ("decode rejects a non-canonically ordered map", `Quick, test_decode_rejects_a_non_canonically_ordered_map);
    ("decode rejects a duplicate key map", `Quick, test_decode_rejects_a_duplicate_key_map);
    ( "decode accepts a correctly-ordered multi-entry map",
      `Quick,
      test_decode_accepts_a_correctly_ordered_multi_entry_map );
    ("encode rejects an in-memory duplicate key record", `Quick, test_encode_rejects_an_in_memory_duplicate_key_record);
    ("encode rejects an in-memory duplicate key map", `Quick, test_encode_rejects_an_in_memory_duplicate_key_map);
    ("20k-deep nested map keys decode in linear time", `Quick, test_deeply_nested_map_keys_decode_in_linear_time);
    ("20k-deep nested map keys encode in linear time", `Quick, test_deeply_nested_map_keys_encode_in_linear_time);
    ( "2-entries-per-level 1000-deep map key encode/hash residual bounded",
      `Quick,
      test_two_entries_per_level_deep_map_encode_hash_residual_bounded );
    QCheck_alcotest.to_alcotest value_injective_prop;
    QCheck_alcotest.to_alcotest record_permutation_invariance_prop;
    QCheck_alcotest.to_alcotest map_permutation_invariance_prop;
    QCheck_alcotest.to_alcotest round_trip_prop
  ]
  @ malformed_input_tests
