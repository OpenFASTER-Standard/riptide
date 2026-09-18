(* test/test_transport_tcp.ml

   Permanent regression coverage for [Riptide_transport.Tcp], the real-socket implementation of
   [Transport_intf.S]. These tests exercise real loopback TCP via [Eio_main.run] (NOT
   [Eio_mock.Backend] -- there is no mock socket layer to substitute here; the whole point is to
   prove the real wire behavior).

   This module does not re-derive the crash-bug hunt that produced the current, fixed
   [tcp.ml]/[tcp.mli] (send-to-dead-peer, corrupt/oversized-frame, and accept-vs-dial connection
   lifecycle bugs -- see task-3-brief.md and tcp.ml's own doc comments on [run_connection] for that
   history). It locks in, permanently, the three properties that history's throwaway repro scripts
   proved and that would otherwise have no lasting test:
   - a real multi-peer mesh actually delivers messages correctly, in both directions, on every
     pairwise connection;
   - length-prefixed framing is byte-exact even when payload content itself contains bytes that
     look like framing metadata -- two back-to-back sends over one connection arrive as two
     distinct, unmodified messages, never merged or split;
   - each peer's [receive] only ever surfaces messages actually sent [~to_] it, with no
     cross-peer misattribution, even under concurrent multi-connection traffic.

   Port choice: distinct, non-overlapping port ranges per test (19301-19303, 19311-19312,
   19321-19323) so a re-run or a future added test in this file can't collide even if an earlier
   test's sockets are still winding down -- [Tcp.create] itself passes [~reuse_addr:true] to
   [Eio.Net.listen], but distinct ports sidestep the question entirely rather than relying on
   that. [Tcp.create] does not expose its internal listening socket, so there is no way to ask it
   for an OS-assigned ephemeral (port 0) address from outside; fixed, spread-out ports are the
   only option here. *)

open Riptide_transport

(* [Tcp.t] has no close/shutdown operation (see tcp.mli's "No shutdown path" section): its
   listener's accept loop and every connection's reader/writer fibers are forked onto the [sw]
   passed to [Tcp.create] and run for as long as that switch is alive. [Eio.Switch.run]'s own
   contract ([switch.mli]: "waits for all fibers registered with the switch to finish, and then
   releases all attached resources") means simply falling off the end of a test body inside a bare
   [Eio.Switch.run] would block [Switch.run] forever waiting for that never-ending accept loop --
   confirmed live while developing this file (the very first draft hung every test until the
   suite's own 5s SIGALRM watchdog fired). [Test_mesh_torn_down] is this file's use of the
   "explicit [Eio.Switch.fail]/cancellation" escape hatch tcp.mli's own doc names as the only way
   to force such a switch to finish from the outside. *)
exception Test_mesh_torn_down

(* Brings up one [Tcp.t] per entry in [peer_specs], all concurrently (every entry's dial loop
   needs the others' listeners to already be up, or coming up within its own retry budget -- see
   [Tcp.create]'s docs), runs [body] against the resulting handles (keyed by peer id), then force-
   tears the mesh down so this function returns instead of hanging -- see [Test_mesh_torn_down]
   above for why that's necessary. *)
let with_mesh peer_specs body =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  try
    Eio.Switch.run (fun sw ->
        let handles = Hashtbl.create (List.length peer_specs) in
        Eio.Fiber.all
          (List.map
             (fun (my_id, _, _) ->
               fun () ->
                 let t = Tcp.create ~sw ~net ~clock ~my_id ~peers:peer_specs in
                 Hashtbl.replace handles my_id t)
             peer_specs);
        body handles;
        Eio.Switch.fail sw Test_mesh_torn_down)
  with Test_mesh_torn_down -> ()

(* -- Area 1: real-loopback, multi-peer delivery -- *)

let test_three_peer_mesh_bidirectional_delivery () =
  let peer_specs = [ (1, "127.0.0.1", 19301); (2, "127.0.0.1", 19302); (3, "127.0.0.1", 19303) ] in
  with_mesh peer_specs (fun handles ->
      let get id = Hashtbl.find handles id in
      (* Every unordered pair gets exercised in both directions, covering all three physical
         connections this mesh forms (1-2, 1-3, 2-3, per the lower-dials-higher topology documented
         in tcp.mli) without any way for this test to observe connection identity directly -- the
         observable property is "every pairwise send/receive round-trips correctly, in order,
         verbatim", which is what actually matters at this module's public interface. *)
      let pairs = [ (1, 2); (2, 1); (1, 3); (3, 1); (2, 3); (3, 2) ] in
      List.iter
        (fun (from_, to_) ->
          let msgs = List.init 3 (fun i -> Printf.sprintf "peer%d->peer%d#%d" from_ to_ i) in
          List.iter (fun m -> Tcp.send (get from_) ~to_ m) msgs;
          List.iter
            (fun expected ->
              Alcotest.(check string)
                (Printf.sprintf "peer %d receives peer %d's message, verbatim and in order" to_
                   from_)
                expected (Tcp.receive (get to_)))
            msgs)
        pairs)

(* -- Area 2: framing-boundary correctness -- *)

let test_framing_boundary_back_to_back_messages_stay_distinct () =
  let peer_specs = [ (1, "127.0.0.1", 19311); (2, "127.0.0.1", 19312) ] in
  with_mesh peer_specs (fun handles ->
      let a = Hashtbl.find handles 1 and b = Hashtbl.find handles 2 in
      (* Both payloads deliberately embed bytes that look exactly like this module's own 8-byte
         big-endian length-prefix framing (see tcp.ml's [write_frame]/[read_frame]) followed by
         content that would, if a receiver ever mistakenly scanned payload bytes for a nested
         prefix/delimiter instead of trusting only the real out-of-band prefix that precedes each
         frame, look like a second, smaller message hiding inside the first. A byte-exact,
         length-prefix-only reader treats all of this as fully opaque payload content. *)
      let msg1 = "\x00\x00\x00\x00\x00\x00\x00\x05hello-this-is-actually-all-of-msg1-not-just-hello" in
      let msg2 = "\x00\x00\x00\x00\x00\x00\x00\x04ABCD-and-this-is-all-of-msg2-too" in
      Tcp.send a ~to_:2 msg1;
      Tcp.send a ~to_:2 msg2;
      let r1 = Tcp.receive b in
      let r2 = Tcp.receive b in
      Alcotest.(check string)
        "first back-to-back send is received whole and unmodified, not merged with the second" msg1
        r1;
      Alcotest.(check string)
        "second back-to-back send is received whole and unmodified, not merged with or split off \
         the first"
        msg2 r2;
      Alcotest.(check bool) "no leftover/duplicated bytes beyond the two expected messages" true
        (Tcp.receive_nonblocking b = None))

(* -- Area 3: handshake / peer-attribution correctness under concurrent traffic -- *)

let test_no_cross_peer_misattribution_under_concurrent_traffic () =
  let peer_specs = [ (1, "127.0.0.1", 19321); (2, "127.0.0.1", 19322); (3, "127.0.0.1", 19323) ] in
  with_mesh peer_specs (fun handles ->
      let ids = [ 1; 2; 3 ] in
      let seqs = [ 0; 1; 2 ] in
      let tag from_ to_ seq = Printf.sprintf "msg-from%d-to%d-seq%d" from_ to_ seq in
      let pairs =
        List.concat_map
          (fun from_ -> List.filter_map (fun to_ -> if from_ = to_ then None else Some (from_, to_)) ids)
          ids
      in
      (* [receive]'s own signature carries no sender identity (see transport_intf.ml) -- the only
         way this layer can prove "peer A only ever sees messages actually sent [~to_:A]" is by
         round-tripping identity through payload content itself, the same way a real caller's
         envelope would. *)
      let expected_for p =
        List.concat_map (fun (from_, to_) -> if to_ = p then List.map (tag from_ to_) seqs else []) pairs
        |> List.sort compare
      in
      let received = Hashtbl.create (List.length ids) in
      (* Fire every sender for every pair, and every receiver's full expected drain, all as fibers
         running concurrently against the same live mesh -- this is what actually stresses
         misattribution: without this, a bug that routed a send meant for peer 3 onto peer 2's
         connection instead could still pass a test that only ever has one connection active at a
         time. *)
      Eio.Fiber.all
        (List.concat_map
           (fun (from_, to_) ->
             List.map (fun seq () -> Tcp.send (Hashtbl.find handles from_) ~to_ (tag from_ to_ seq)) seqs)
           pairs
        @ List.map
            (fun p () ->
              let expected_count = List.length (expected_for p) in
              let msgs = List.init expected_count (fun _ -> Tcp.receive (Hashtbl.find handles p)) in
              Hashtbl.replace received p (List.sort compare msgs))
            ids);
      List.iter
        (fun p ->
          Alcotest.(check (list string))
            (Printf.sprintf
               "peer %d's receive() surfaces exactly the messages sent ~to_ it (and only those), \
                even under concurrent multi-connection traffic"
               p)
            (expected_for p) (Hashtbl.find received p))
        ids)

let tests =
  [ ("three-peer mesh: bidirectional delivery on every pairwise connection", `Quick,
      test_three_peer_mesh_bidirectional_delivery);
    ("framing boundary: back-to-back sends stay distinct, byte-exact", `Quick,
      test_framing_boundary_back_to_back_messages_stay_distinct);
    ("no cross-peer misattribution under concurrent traffic", `Quick,
      test_no_cross_peer_misattribution_under_concurrent_traffic)
  ]
