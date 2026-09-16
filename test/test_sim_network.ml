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
    ("receive_nonblocking is empty with nothing sent", `Quick, test_receive_nonblocking_empty)
  ]
