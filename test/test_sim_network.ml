(* test/test_sim_network.ml *)
open Riptide_sim

let test_send_and_receive () =
  Eio_main.run @@ fun _env ->
  let net = Network.create () in
  Network.register net "a";
  Network.register net "b";
  Network.send net ~from_:"a" ~to_:"b" "hello";
  Alcotest.(check string) "b receives a's message" "hello" (Network.receive net "b")

let test_deterministic_two_fiber_exchange () =
  Eio_main.run @@ fun _env ->
  let net = Network.create () in
  Network.register net "a";
  Network.register net "b";
  let trace = ref [] in
  Eio.Fiber.both
    (fun () ->
      Network.send net ~from_:"a" ~to_:"b" "from a";
      trace := "a sent" :: !trace;
      let msg = Network.receive net "a" in
      trace := Printf.sprintf "a received %s" msg :: !trace)
    (fun () ->
      let msg = Network.receive net "b" in
      trace := Printf.sprintf "b received %s" msg :: !trace;
      Network.send net ~from_:"b" ~to_:"a" "from b");
  Alcotest.(check (list string)) "deterministic interleaving, matching Fiber.both's f-before-g order"
    [ "a received from b"; "b received from a"; "a sent" ]
    !trace

let test_receive_nonblocking_empty () =
  Eio_main.run @@ fun _env ->
  let net = Network.create () in
  Network.register net "a";
  Alcotest.(check bool) "no message yet" true (Network.receive_nonblocking net "a" = None)

let tests =
  [ ("send and receive", `Quick, test_send_and_receive);
    ("deterministic two-fiber exchange", `Quick, test_deterministic_two_fiber_exchange);
    ("receive_nonblocking is empty with nothing sent", `Quick, test_receive_nonblocking_empty)
  ]
