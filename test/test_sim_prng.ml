open Riptide_sim

let test_same_seed_same_sequence () =
  let a = Prng.create 42 in
  let b = Prng.create 42 in
  let draws t = List.init 20 (fun _ -> Prng.int t 1_000_000) in
  Alcotest.(check (list int)) "identical draw sequence from identical seed" (draws a) (draws b)

let test_different_seed_different_sequence () =
  let a = Prng.create 1 in
  let b = Prng.create 2 in
  let draws t = List.init 20 (fun _ -> Prng.int t 1_000_000) in
  Alcotest.(check bool) "different seeds produce different sequences" true (draws a <> draws b)

let test_bool_respects_probability_bounds () =
  let t = Prng.create 7 in
  (* p = 0.0 must never be true; p = 1.0 must always be true, across many draws *)
  Alcotest.(check bool) "p=0.0 never true"
    true (List.init 200 (fun _ -> Prng.bool t 0.0) |> List.for_all (fun b -> b = false));
  Alcotest.(check bool) "p=1.0 always true"
    true (List.init 200 (fun _ -> Prng.bool t 1.0) |> List.for_all (fun b -> b = true))

let tests =
  [ ("same seed produces same sequence", `Quick, test_same_seed_same_sequence);
    ("different seeds diverge", `Quick, test_different_seed_different_sequence);
    ("bool respects probability bounds", `Quick, test_bool_respects_probability_bounds)
  ]
