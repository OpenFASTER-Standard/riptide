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

let tests = [ ("harness catches a real violation", `Quick, test_harness_catches_a_real_violation) ]

let tests =
  tests
  @ Lattice_conformance.tests (module Riptide_lattice.Last_write_wins) lww_arbitrary "last_write_wins"
