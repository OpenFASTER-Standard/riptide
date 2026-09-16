(* test/test_sim_network.ml *)
open Riptide_sim

let test_send_and_receive () =
  Eio_mock.Backend.run @@ fun () ->
  let prng = Prng.create 1 in
  let net = Network.create prng () in
  Network.register net "a";
  Network.register net "b";
  Network.send Fun.id net ~from_:"a" ~to_:"b" "hello";
  Network.pump_all net;
  Alcotest.(check string) "b receives a's message" "hello" (Network.receive net "b")

let test_deterministic_two_fiber_exchange () =
  Eio_mock.Backend.run @@ fun () ->
  let prng = Prng.create 1 in
  let net = Network.create prng () in
  Network.register net "a";
  Network.register net "b";
  let trace = ref [] in
  Eio.Fiber.both
    (fun () ->
      Network.send Fun.id net ~from_:"a" ~to_:"b" "from a";
      Network.pump_all net;
      trace := "a sent" :: !trace;
      let msg = Network.receive net "a" in
      trace := Printf.sprintf "a received %s" msg :: !trace)
    (fun () ->
      let msg = Network.receive net "b" in
      trace := Printf.sprintf "b received %s" msg :: !trace;
      Network.send Fun.id net ~from_:"b" ~to_:"a" "from b";
      Network.pump_all net);
  Alcotest.(check (list string)) "deterministic interleaving, matching Fiber.both's f-before-g order"
    [ "a received from b"; "b received from a"; "a sent" ]
    !trace

let test_fiber_suspends_on_virtual_clock_and_wakes_via_pump () =
  (* Proves the virtual clock exposed by [Network.clock] is genuinely load-bearing: a fiber that
     calls [Eio.Time.sleep_until] on it actually suspends, and is woken only once a later
     [pump_one]/[pump_all]-driven [Eio_mock.Clock.set_time] call advances [net]'s own clock past
     the sleep target - not by any parallel counter, and not synchronously. If [Network.clock]
     ever stopped being the single source of truth [net] itself schedules against (e.g. reverted
     to a disconnected clock, or a plain float doing the real work again), this would either hang
     (and Eio_mock.Backend would raise Deadlock_detected instead of the assertion below ever
     running) or wake at the wrong point in the interleaving, breaking the exact order asserted
     here. *)
  Eio_mock.Backend.run @@ fun () ->
  let prng = Prng.create 1 in
  let net = Network.create prng () in
  Network.register net "a";
  Network.register net "b";
  let events = ref [] in
  let record ev = events := ev :: !events in
  Eio.Fiber.both
    (fun () ->
      Eio.Time.sleep_until (Network.clock net) 5.0;
      record "sleeper woken")
    (fun () ->
      record "driver: sending an immediate (zero-delay) message";
      Network.send Fun.id net ~from_:"a" ~to_:"b" "tick";
      Network.pump_all net;
      (* net's clock is now at 0.0 (the delivered message's time) - nowhere near the sleeper's
         5.0 target, so the sleeper must still be suspended at this point. *)
      record "driver: pumped the zero-delay send, sleeper must still be waiting";
      (* Directly advancing the clock past 5.0 stands in for a later scheduled delivery reaching
         that time; this is the same [Eio_mock.Clock.set_time] call [pump_one] itself makes. *)
      Eio_mock.Clock.set_time (Network.clock net) 5.0;
      record "driver: advanced the clock to 5.0");
  Alcotest.(check (list string))
    "sleeper only resumes after the clock reaches 5.0, and resumption is deferred (queued), not \
     synchronous with the set_time call"
    [ "driver: sending an immediate (zero-delay) message";
      "driver: pumped the zero-delay send, sleeper must still be waiting";
      "driver: advanced the clock to 5.0";
      "sleeper woken"
    ]
    (List.rev !events)

type event =
  | Sent of { to_ : string; payload : string }
  | Received of { by : string; payload : string }

let test_interleaving_with_active_fault_injection_is_deterministic () =
  (* The one composite property none of this PoC's other tests prove: fibers genuinely blocking
     on Network.receive (not receive_nonblocking), interleaved with an active, multi-axis fault
     config (nonzero duplicate/corrupt/delay - the exact fault types the real consensus protocol
     will depend on in every interaction), reproducing byte-identically from the same seed.
     Config mirrors the reviewer's own independently-verified scratch probe (duplicate 0.4,
     corrupt 0.3, delay 0.1-5.0), which produced a byte-identical 24-event trace across 3 runs
     with corruption and delay-reordering both visibly firing. *)
  let faults =
    { Network.default_fault_config with
      duplicate_probability = 0.4; corrupt_probability = 0.3; min_delay = 0.1; max_delay = 5.0 }
  in
  let peers = [ "p0"; "p1"; "p2" ] in
  let message_count = 9 in
  let guaranteed_per_peer = message_count / List.length peers in
  let run seed =
    Eio_mock.Backend.run @@ fun () ->
    let prng = Prng.create seed in
    let net = Network.create ~faults prng () in
    List.iter (Network.register net) peers;
    let events = ref [] in
    let record ev = events := ev :: !events in
    let receiver peer () =
      (* drop_probability is 0 here, so every raw send addressed to [peer] is guaranteed at
         least one delivery - these [guaranteed_per_peer] blocking receives are what proves
         genuine suspend/resume interleaving with the driver below, not just a scheduling
         artifact. *)
      for _ = 1 to guaranteed_per_peer do
        let payload = Network.receive net peer in
        record (Received { by = peer; payload })
      done
    in
    let driver () =
      for i = 1 to message_count do
        let to_ = List.nth peers ((i - 1) mod List.length peers) in
        let payload = Printf.sprintf "m%d" i in
        Network.send String.uppercase_ascii net ~from_:"driver" ~to_ payload;
        record (Sent { to_; payload });
        (* One message at a time, yielding between pumps, so receiver fibers genuinely interleave
           with in-flight delivery instead of the whole network resolving before any receiver
           gets a chance to run. *)
        ignore (Network.pump_one net);
        Eio.Fiber.yield ()
      done;
      (* Flush anything still pending (later-delayed deliveries, including duplicate extras). *)
      Network.pump_all net
    in
    Eio.Fiber.all (driver :: List.map receiver peers);
    (* By the time Fiber.all returns, every fiber above (including the driver's final pump_all)
       has completed, so the network is guaranteed fully flushed - drain any duplicate extras
       (stochastic, not required for the property under test, but makes the trace reflect
       duplication too) sequentially rather than risk a receiver racing the driver's last flush. *)
    List.iter
      (fun peer ->
        let rec drain_extras () =
          match Network.receive_nonblocking net peer with
          | Some payload ->
            record (Received { by = peer; payload });
            drain_extras ()
          | None -> ()
        in
        drain_extras ())
      peers;
    List.rev !events
  in
  let trace_a = run 2024 and trace_b = run 2024 in
  Alcotest.(check bool)
    "same seed, under active duplicate/corrupt/delay fault injection with genuine fiber/network \
     interleaving, produces a byte-identical trace across two separate runs"
    true (trace_a = trace_b);
  Alcotest.(check bool) "corruption actually fired at least once (an uppercased payload was received)"
    true
    (List.exists
       (function Received { payload; _ } -> String.uppercase_ascii payload = payload | Sent _ -> false)
       trace_a);
  Alcotest.(check bool) "duplication actually fired at least once (more than message_count receives)"
    true
    (List.length (List.filter (function Received _ -> true | Sent _ -> false) trace_a) > message_count)

let test_receive_nonblocking_empty () =
  Eio_mock.Backend.run @@ fun () ->
  let prng = Prng.create 1 in
  let net = Network.create prng () in
  Network.register net "a";
  Alcotest.(check bool) "no message yet" true (Network.receive_nonblocking net "a" = None)

let tests =
  [ ("send and receive", `Quick, test_send_and_receive);
    ("deterministic two-fiber exchange", `Quick, test_deterministic_two_fiber_exchange);
    ("fiber suspends on virtual clock and wakes via pump", `Quick,
      test_fiber_suspends_on_virtual_clock_and_wakes_via_pump);
    ("interleaving + active fault injection + determinism, combined", `Quick,
      test_interleaving_with_active_fault_injection_is_deterministic);
    ("receive_nonblocking is empty with nothing sent", `Quick, test_receive_nonblocking_empty)
  ]
