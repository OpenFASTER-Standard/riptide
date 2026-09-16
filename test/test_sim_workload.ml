(* test/test_sim_workload.ml *)
open Riptide_sim

let test_same_seed_reproduces_identical_trace () =
  let faults =
    { Network.drop_probability = 0.1; duplicate_probability = 0.1; corrupt_probability = 0.3;
      min_delay = 0.0; max_delay = 1.0 }
  in
  let run () = Workload.run_toy_cluster ~seed:12345 ~peer_count:3 ~message_count:30 ~faults in
  let trace_a = run () in
  let trace_b = run () in
  Alcotest.(check bool) "identical seed produces byte-for-byte identical trace" true
    (trace_a = trace_b);
  (* corrupt_probability > 0.0 here specifically closes the review's H2 finding that "the headline
     reproducibility proof never corrupts anything at all" - this asserts corruption genuinely
     fired, not just that nothing crashed. drop/duplicate never invent new payload content (a
     duplicate is a second copy of the same bytes), so any received payload that doesn't match any
     sent payload can only be explained by corruption having mutated it in transit. *)
  let sent_payloads =
    List.filter_map
      (function Workload.Sent { payload; _ } -> Some payload | Workload.Received _ -> None)
      trace_a
    |> List.sort_uniq compare
  in
  Alcotest.(check bool)
    "byte-level corruption actually fired: at least one received payload matches no sent payload"
    true
    (List.exists
       (function
         | Workload.Received { payload; _ } -> not (List.mem payload sent_payloads)
         | Workload.Sent _ -> false)
       trace_a)

let test_random_byte_flip_mutates_exactly_one_byte () =
  let prng = Prng.create 5 in
  let original = "hello world" in
  let corrupted = Workload.random_byte_flip prng original in
  Alcotest.(check int) "same length" (String.length original) (String.length corrupted);
  let differing_positions =
    List.filter
      (fun i -> original.[i] <> corrupted.[i])
      (List.init (String.length original) Fun.id)
  in
  Alcotest.(check int) "exactly one byte differs" 1 (List.length differing_positions)

let test_random_byte_flip_is_deterministic () =
  let run () = Workload.random_byte_flip (Prng.create 5) "hello world" in
  Alcotest.(check string) "identical seed produces identical mutation" (run ()) (run ())

let test_random_byte_flip_empty_string_unchanged () =
  let prng = Prng.create 5 in
  Alcotest.(check string) "empty string returned unchanged" "" (Workload.random_byte_flip prng "")

let test_random_payload_is_deterministic () =
  let run () = Workload.random_payload (Prng.create 8) in
  Alcotest.(check string) "identical seed produces identical payload" (run ()) (run ())

let test_random_payload_varies_in_length_and_content () =
  (* One PRNG, many successive draws - if random_payload silently degenerated back to a fixed
     shape (e.g. always the same length, or the same bytes), this would catch it directly, unlike
     test_generator_covers_unstructured_workload which only observes it indirectly through a full
     run_toy_cluster call. *)
  let prng = Prng.create 9 in
  let payloads = List.init 30 (fun _ -> Workload.random_payload prng) in
  let lengths_seen = List.sort_uniq compare (List.map String.length payloads) in
  let payloads_seen = List.sort_uniq compare payloads in
  Alcotest.(check bool) "lengths vary across draws" true (List.length lengths_seen > 1);
  Alcotest.(check bool) "content varies across draws" true (List.length payloads_seen > 1)

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
     Run many seeds and confirm both the sender/receiver pairing *and* the payload shape/content
     vary - not just addressing. (Previously this only checked (sender, receiver) pairings, which
     is structurally incapable of catching a regression back to a fixed "msg-%d" payload; the
     payload-side assertions below close that gap.) *)
  let faults = Network.default_fault_config in
  let sent_events =
    List.init 40 (fun seed ->
      Workload.run_toy_cluster ~seed ~peer_count:4 ~message_count:5 ~faults
      |> List.filter_map (function
        | Workload.Sent { from_; to_; payload } -> Some (from_, to_, payload)
        | Workload.Received _ -> None))
    |> List.concat
  in
  let pairs_seen = List.sort_uniq compare (List.map (fun (f, t, _) -> (f, t)) sent_events) in
  let payloads_seen = List.sort_uniq compare (List.map (fun (_, _, p) -> p) sent_events) in
  let lengths_seen = List.sort_uniq compare (List.map String.length payloads_seen) in
  Alcotest.(check bool) "generator produces more than one distinct (sender, receiver) pairing across seeds"
    true (List.length pairs_seen > 1);
  Alcotest.(check bool) "generator produces more than one distinct payload across seeds"
    true (List.length payloads_seen > 1);
  Alcotest.(check bool) "generator produces more than one distinct payload length across seeds"
    true (List.length lengths_seen > 1)

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
      test_terminates_and_delivers_nothing_when_everything_is_dropped);
    ("random_byte_flip mutates exactly one byte", `Quick, test_random_byte_flip_mutates_exactly_one_byte);
    ("random_byte_flip is deterministic from seed", `Quick, test_random_byte_flip_is_deterministic);
    ("random_byte_flip leaves the empty string unchanged", `Quick,
      test_random_byte_flip_empty_string_unchanged);
    ("random_payload is deterministic from seed", `Quick, test_random_payload_is_deterministic);
    ("random_payload varies in length and content across draws", `Quick,
      test_random_payload_varies_in_length_and_content)
  ]
