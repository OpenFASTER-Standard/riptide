(* test/test_sim_faults.ml *)
open Riptide_sim

let test_zero_faults_behaves_like_task_2 () =
  Eio_mock.Backend.run @@ fun () ->
  let net = Network.create ~seed:1 () in
  Network.register net "a";
  Network.register net "b";
  Network.send Fun.id net ~from_:"a" ~to_:"b" "hello";
  Network.pump_all net;
  Alcotest.(check string) "delivered with default (zero) fault config" "hello"
    (Network.receive net "b")

let test_drop_probability_one_means_never_delivered () =
  Eio_mock.Backend.run @@ fun () ->
  let net = Network.create ~faults:{ Network.default_fault_config with drop_probability = 1.0 } ~seed:2 () in
  Network.register net "a";
  Network.register net "b";
  Network.send Fun.id net ~from_:"a" ~to_:"b" "hello";
  Network.pump_all net;
  Alcotest.(check bool) "message never arrives" true (Network.receive_nonblocking net "b" = None)

let test_duplicate_probability_one_means_delivered_twice () =
  Eio_mock.Backend.run @@ fun () ->
  let net = Network.create ~faults:{ Network.default_fault_config with duplicate_probability = 1.0 } ~seed:3 () in
  Network.register net "a";
  Network.register net "b";
  Network.send Fun.id net ~from_:"a" ~to_:"b" "hello";
  Network.pump_all net;
  let first = Network.receive net "b" in
  let second = Network.receive net "b" in
  Alcotest.(check (pair string string)) "delivered twice" ("hello", "hello") (first, second)

let test_corrupt_probability_one_always_applies_corruption_fn () =
  Eio_mock.Backend.run @@ fun () ->
  let net = Network.create ~faults:{ Network.default_fault_config with corrupt_probability = 1.0 } ~seed:4 () in
  Network.register net "a";
  Network.register net "b";
  Network.send String.uppercase_ascii net ~from_:"a" ~to_:"b" "hello";
  Network.pump_all net;
  Alcotest.(check string) "corruption function applied" "HELLO" (Network.receive net "b")

let test_corruption_applied_at_delivery_not_at_send () =
  Eio_mock.Backend.run @@ fun () ->
  let net = Network.create ~faults:{ Network.default_fault_config with corrupt_probability = 1.0 } ~seed:6 () in
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
    Eio_mock.Backend.run @@ fun () ->
    let faults = { Network.default_fault_config with drop_probability = 0.5; duplicate_probability = 0.3 } in
    let net = Network.create ~faults ~seed () in
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

let test_delay_based_reordering () =
  (* The plan argues no separate reorder fault is needed because delay jitter alone can reorder
     messages sent in order (a later send can draw a shorter delay than an earlier one). That
     argument had no test anywhere in this PoC. Send several messages in order under a nonzero
     [max_delay] (drop/duplicate/corrupt all off, so the only thing that can change is order, not
     which/how-many payloads arrive) and confirm delivery order actually differs from send order -
     not just that everything arrived. *)
  let payloads = List.init 10 string_of_int in
  let faults = { Network.default_fault_config with min_delay = 0.0; max_delay = 10.0 } in
  let run seed =
    Eio_mock.Backend.run @@ fun () ->
    let net = Network.create ~faults ~seed () in
    Network.register net "a";
    Network.register net "b";
    List.iter (fun payload -> Network.send Fun.id net ~from_:"a" ~to_:"b" payload) payloads;
    Network.pump_all net;
    let rec drain acc =
      match Network.receive_nonblocking net "b" with
      | Some m -> drain (m :: acc)
      | None -> List.rev acc
    in
    drain []
  in
  let seeds = List.init 10 (fun i -> i + 1) in
  let results = List.map run seeds in
  (* Sanity: reordering must never drop or invent payloads - every run is a permutation of what
     was sent, just possibly in a different order. *)
  List.iter
    (fun delivered ->
      Alcotest.(check (list string)) "delivery is always a permutation of the sent payloads (sorted)"
        (List.sort compare payloads) (List.sort compare delivered))
    results;
  Alcotest.(check bool)
    "delay-based reordering actually changes delivery order from send order, for at least one of \
     several seeds (not just that all messages arrived)"
    true
    (List.exists (fun delivered -> delivered <> payloads) results)

let tests =
  [ ("zero-fault config matches Task 2 behavior", `Quick, test_zero_faults_behaves_like_task_2);
    ("drop_probability=1.0 drops everything", `Quick, test_drop_probability_one_means_never_delivered);
    ("duplicate_probability=1.0 duplicates", `Quick, test_duplicate_probability_one_means_delivered_twice);
    ("corrupt_probability=1.0 applies corruption fn", `Quick, test_corrupt_probability_one_always_applies_corruption_fn);
    ("corruption fn is invoked at delivery (pump_all), not at send", `Quick,
      test_corruption_applied_at_delivery_not_at_send);
    ("same seed reproduces identical fault decisions", `Quick, test_same_seed_same_fault_decisions);
    ("delay-based reordering actually reorders delivery", `Quick, test_delay_based_reordering)
  ]
