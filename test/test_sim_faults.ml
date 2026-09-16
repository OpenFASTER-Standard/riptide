(* test/test_sim_faults.ml *)
open Riptide_sim

let test_zero_faults_behaves_like_task_2 () =
  Eio_main.run @@ fun _env ->
  let prng = Prng.create 1 in
  let net = Network.create prng () in
  Network.register net "a";
  Network.register net "b";
  Network.send Fun.id net ~from_:"a" ~to_:"b" "hello";
  Network.pump_all net;
  Alcotest.(check string) "delivered with default (zero) fault config" "hello"
    (Network.receive net "b")

let test_drop_probability_one_means_never_delivered () =
  Eio_main.run @@ fun _env ->
  let prng = Prng.create 2 in
  let net = Network.create ~faults:{ Network.default_fault_config with drop_probability = 1.0 } prng () in
  Network.register net "a";
  Network.register net "b";
  Network.send Fun.id net ~from_:"a" ~to_:"b" "hello";
  Network.pump_all net;
  Alcotest.(check bool) "message never arrives" true (Network.receive_nonblocking net "b" = None)

let test_duplicate_probability_one_means_delivered_twice () =
  Eio_main.run @@ fun _env ->
  let prng = Prng.create 3 in
  let net = Network.create ~faults:{ Network.default_fault_config with duplicate_probability = 1.0 } prng () in
  Network.register net "a";
  Network.register net "b";
  Network.send Fun.id net ~from_:"a" ~to_:"b" "hello";
  Network.pump_all net;
  let first = Network.receive net "b" in
  let second = Network.receive net "b" in
  Alcotest.(check (pair string string)) "delivered twice" ("hello", "hello") (first, second)

let test_corrupt_probability_one_always_applies_corruption_fn () =
  Eio_main.run @@ fun _env ->
  let prng = Prng.create 4 in
  let net = Network.create ~faults:{ Network.default_fault_config with corrupt_probability = 1.0 } prng () in
  Network.register net "a";
  Network.register net "b";
  Network.send String.uppercase_ascii net ~from_:"a" ~to_:"b" "hello";
  Network.pump_all net;
  Alcotest.(check string) "corruption function applied" "HELLO" (Network.receive net "b")

let test_corruption_applied_at_delivery_not_at_send () =
  Eio_main.run @@ fun _env ->
  let prng = Prng.create 6 in
  let net = Network.create ~faults:{ Network.default_fault_config with corrupt_probability = 1.0 } prng () in
  Network.register net "a";
  Network.register net "b";
  let applied = ref false in
  let corrupt msg = applied := true; msg in
  Network.send corrupt net ~from_:"a" ~to_:"b" "hello";
  Alcotest.(check bool) "corrupt fn not yet invoked right after send" false !applied;
  Network.pump_all net;
  Alcotest.(check bool) "corrupt fn invoked once pump_all delivers" true !applied

let test_same_seed_same_fault_decisions () =
  let run seed =
    Eio_main.run @@ fun _env ->
    let prng = Prng.create seed in
    let faults = { Network.default_fault_config with drop_probability = 0.5; duplicate_probability = 0.3 } in
    let net = Network.create ~faults prng () in
    Network.register net "a";
    Network.register net "b";
    for i = 1 to 50 do
      Network.send Fun.id net ~from_:"a" ~to_:"b" (string_of_int i)
    done;
    Network.pump_all net;
    let rec drain acc = match Network.receive_nonblocking net "b" with
      | Some m -> drain (m :: acc)
      | None -> List.rev acc
    in
    drain []
  in
  Alcotest.(check (list string)) "identical seed produces identical fault outcomes" (run 99) (run 99)

let tests =
  [ ("zero-fault config matches Task 2 behavior", `Quick, test_zero_faults_behaves_like_task_2);
    ("drop_probability=1.0 drops everything", `Quick, test_drop_probability_one_means_never_delivered);
    ("duplicate_probability=1.0 duplicates", `Quick, test_duplicate_probability_one_means_delivered_twice);
    ("corrupt_probability=1.0 applies corruption fn", `Quick, test_corrupt_probability_one_always_applies_corruption_fn);
    ("corruption fn is invoked at delivery (pump_all), not at send", `Quick,
      test_corruption_applied_at_delivery_not_at_send);
    ("same seed reproduces identical fault decisions", `Quick, test_same_seed_same_fault_decisions)
  ]
