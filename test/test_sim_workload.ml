(* test/test_sim_workload.ml *)
open Riptide_sim

let test_same_seed_reproduces_identical_trace () =
  let faults =
    { Network.drop_probability = 0.1; duplicate_probability = 0.1; corrupt_probability = 0.0;
      min_delay = 0.0; max_delay = 1.0 }
  in
  let run () = Workload.run_toy_cluster ~seed:12345 ~peer_count:3 ~message_count:30 ~faults in
  let trace_a = run () in
  let trace_b = run () in
  Alcotest.(check bool) "identical seed produces byte-for-byte identical trace" true
    (trace_a = trace_b)

let test_different_seeds_can_diverge () =
  let faults =
    { Network.drop_probability = 0.2; duplicate_probability = 0.2; corrupt_probability = 0.0;
      min_delay = 0.0; max_delay = 1.0 }
  in
  let run seed = Workload.run_toy_cluster ~seed ~peer_count:3 ~message_count:30 ~faults in
  Alcotest.(check bool) "different seeds are not guaranteed to match (sanity check the generator is not constant-folding to one fixed trace)"
    true (run 1 <> run 2)

let test_generator_covers_unstructured_workload () =
  (* Directly guards against the exact blind spot that caused a real, Jepsen-found bug in
     TigerBeetle: a generator that only ever produces one fixed, pre-registered message shape.
     Run many seeds and confirm the sender/receiver pairing varies, not just the payload. *)
  let faults = Network.default_fault_config in
  let pairs_seen =
    List.init 40 (fun seed ->
      Workload.run_toy_cluster ~seed ~peer_count:4 ~message_count:5 ~faults
      |> List.filter_map (function
        | Workload.Sent { from_; to_; _ } -> Some (from_, to_)
        | Workload.Received _ -> None))
    |> List.concat
    |> List.sort_uniq compare
  in
  Alcotest.(check bool) "generator produces more than one distinct (sender, receiver) pairing across seeds"
    true (List.length pairs_seen > 1)

let test_terminates_and_delivers_nothing_when_everything_is_dropped () =
  (* Regression test for the termination-logic fix (see workload.ml's design note): under a
     literal reading of "give each peer its own expected-count target from the driver's intended
     addressing" (the brief's option (b) as originally worded), a peer whose only intended
     message is dropped would busy-poll forever waiting for a delivery that will never arrive.
     drop_probability = 1.0 is the sharpest case of that: every single message is dropped, so no
     peer should ever receive anything - and the call must still terminate (this test itself
     would hang, rather than fail an assertion, if the old bug were reintroduced). *)
  let faults = { Network.default_fault_config with drop_probability = 1.0 } in
  let trace = Workload.run_toy_cluster ~seed:7 ~peer_count:5 ~message_count:50 ~faults in
  let sent, received =
    List.partition (function Workload.Sent _ -> true | Workload.Received _ -> false) trace
  in
  Alcotest.(check int) "all 50 sends are still recorded (send is attempted regardless of drop)" 50
    (List.length sent);
  Alcotest.(check int) "nothing was ever received" 0 (List.length received)

let tests =
  [ ("identical seed reproduces identical trace", `Quick, test_same_seed_reproduces_identical_trace);
    ("different seeds are not artificially constant", `Quick, test_different_seeds_can_diverge);
    ("generator covers unstructured (sender, receiver) pairings", `Quick, test_generator_covers_unstructured_workload);
    ("terminates and delivers nothing when drop_probability = 1.0", `Quick,
      test_terminates_and_delivers_nothing_when_everything_is_dropped)
  ]
