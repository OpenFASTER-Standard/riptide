open Riptide_lattice

(* A deliberately broken instance, used only to prove the harness is non-vacuous —
   NOT registered in test_riptide.ml, only invoked directly by the one test below.

   [a > b] (a strict inequality, as the task brief originally wrote it) does NOT actually break
   idempotency: [join a a] always takes the [else] branch (since [a > a] is false), so it returns
   [a] unchanged for every [a] - confirmed live, the meta-test below genuinely failed with "it
   passed" against that version. [a >= b] is the fix that matches the brief's own documented
   intent: now [join a a] takes the "wrong" branch and returns [a - 1 <> a], a real idempotency
   violation for every generated [a]. *)
module Broken_max : Lattice_intf.S with type t = int = struct
  type t = int
  let bottom = 0
  let join a b = if a >= b then a - 1 (* wrong: breaks idempotency *) else b
end

(* [Alcotest.check_raises] with an exact-equality expected exception was tried first (per the task
   brief's Step 2b) and confirmed live to be too brittle: [Test_fail]'s payload is the real list of
   counterexamples found during the run, never the literal [[]] a fixed expected value would need -
   so the exact-equality check failed even though the harness genuinely did catch the violation.
   This is the brief's own documented fallback: match on the exception shape only. *)
let test_harness_catches_a_real_violation () =
  let broken_tests = Lattice_conformance.tests (module Broken_max) QCheck.nat_small "broken" in
  let (_, _, run) =
    List.find (fun (name, _, _) -> name = "broken: join is idempotent") broken_tests
  in
  match run () with
  | () -> Alcotest.fail "expected the broken instance's idempotency check to fail, it passed"
  | exception QCheck.Test.Test_fail _ -> ()

let lww_arbitrary =
  QCheck.map
    (fun (s, ts) ->
      Riptide_lattice.Last_write_wins.{ value = Riptide.Value.Scalar (Riptide.Value.String s); timestamp = ts })
    (QCheck.pair QCheck.string_small QCheck.int64)

(* -- Final-review Finding 3: [bottom] must be the join identity for EVERY representable value,
   including one sitting at the most extreme representable timestamp.

   The bug this covers: [bottom] used to be an ordinary inhabitant of [t]
   ([{ value = Sequence []; timestamp = Int64.min_int }]) with no structural distinction from a
   real write, and [join] fell straight through to its content-hash tiebreak whenever two
   timestamps were equal. So for any real value [x] at [timestamp = Int64.min_int] whose
   [content_hash] happens to sort at-or-below [content_hash (Sequence [])], [join bottom x]
   returned [bottom] rather than [x] -- a real write silently swallowed, and (for the
   materializer) an accumulator stuck at [bottom] forever despite a committed write existing.

   Why [lww_arbitrary] above can never catch it: its timestamps come from [QCheck.int64], which is
   uniform over the whole 2^64 range, so the probability of a 200-case run ever drawing exactly
   [Int64.min_int] is ~200/2^64. The generic conformance harness was structurally blind to the one
   boundary where the law actually broke, which is why this is a targeted, deterministic test and
   not just another property run -- plus [lww_corner_arbitrary] below, which fixes the blindness
   itself rather than only this one instance of it. *)
let empty_sequence_hash = Riptide.Value.content_hash (Riptide.Value.Sequence [])

(* Real values, at the exact boundary timestamp, whose hash sorts at-or-below
   [content_hash (Sequence [])] -- i.e. precisely the inputs the old [join] returned [bottom] for.
   Drawn from a fixed, deterministic candidate set rather than randomly, so this test either finds
   the same witnesses on every run or fails the non-vacuity assertion below; it never flakes. *)
let hash_colliding_boundary_writes =
  List.filter_map
    (fun i ->
      let value = Riptide.Value.Scalar (Riptide.Value.String (Printf.sprintf "write-%d" i)) in
      if Riptide.Value.content_hash value <= empty_sequence_hash then
        Some Riptide_lattice.Last_write_wins.{ value; timestamp = Int64.min_int }
      else None)
    (List.init 200 (fun i -> i))

let test_bottom_is_identity_at_the_extreme_timestamp () =
  (* Non-vacuity first: if no candidate hashes below [Sequence []]'s, this test proves nothing,
     so say so loudly instead of passing green. *)
  Alcotest.(check bool)
    "candidate set genuinely contains hash-colliding boundary writes (test is non-vacuous)" true
    (hash_colliding_boundary_writes <> []);
  List.iter
    (fun x ->
      let module L = Riptide_lattice.Last_write_wins in
      let describe (w : L.t) =
        Printf.sprintf "{ value = %s; timestamp = %Ld }"
          (Riptide.Value.hash_to_hex (Riptide.Value.content_hash w.value))
          w.timestamp
      in
      Alcotest.(check bool)
        (Printf.sprintf "join bottom x = x for x = %s" (describe x))
        true
        (L.join L.bottom x = x);
      Alcotest.(check bool)
        (Printf.sprintf "join x bottom = x for x = %s" (describe x))
        true
        (L.join x L.bottom = x))
    hash_colliding_boundary_writes

(* The blindness fix, not just the bug fix: same shape as [lww_arbitrary], but its timestamps are
   drawn from a distribution that hits the representable extremes often rather than ~never, so the
   generic four-law harness itself would now catch a [bottom]-identity violation at a boundary
   timestamp. Stateless by construction ([oneof_weighted] over constant generators, deliberately
   not [QCheck.Gen.graft_corners], whose returned generator is documented as stateful and would
   hand its corner cases to whichever of the four law tests happened to run first, leaving the
   other three back to uniform sampling). *)
let lww_corner_arbitrary =
  let ts_gen =
    QCheck.Gen.oneof_weighted
      [
        (3, QCheck.Gen.return Int64.min_int);
        (2, QCheck.Gen.return Int64.max_int);
        (1, QCheck.Gen.return 0L);
        (1, QCheck.Gen.return (-1L));
        (1, QCheck.Gen.return 1L);
        (4, QCheck.Gen.int64);
      ]
  in
  (* Very few distinct payload strings on purpose: with timestamps repeatedly landing on the same
     extreme, the content-hash tiebreak -- and the [bottom] boundary -- is what gets exercised,
     which needs real hash collisions between generated pairs rather than a fresh unique string
     every draw. *)
  let value_gen =
    QCheck.Gen.map
      (fun i -> Riptide.Value.Scalar (Riptide.Value.String (Printf.sprintf "write-%d" i)))
      (QCheck.Gen.int_range 0 7)
  in
  QCheck.make
    (QCheck.Gen.map
       (fun (value, timestamp) -> Riptide_lattice.Last_write_wins.{ value; timestamp })
       (QCheck.Gen.pair value_gen ts_gen))

let tests =
  [
    ("harness catches a real violation", `Quick, test_harness_catches_a_real_violation);
    ( "bottom is the join identity at the extreme timestamp", `Quick,
      test_bottom_is_identity_at_the_extreme_timestamp );
  ]

let tests =
  tests
  @ Lattice_conformance.tests (module Riptide_lattice.Last_write_wins) lww_arbitrary "last_write_wins"
  @ Lattice_conformance.tests
      (module Riptide_lattice.Last_write_wins)
      lww_corner_arbitrary "last_write_wins (corner timestamps)"
