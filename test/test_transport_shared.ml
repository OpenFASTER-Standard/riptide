(* test/test_transport_shared.ml

   The actual proof of subtask 3.5's own stated test: "swapping the transport carrier
   implementation must not require touching the application-level protocol code." Everything
   below [Make_transport_tests] is implementation-agnostic by construction (a functor over
   [Transport_intf.S], referencing only [T.t]/[T.send]/[T.receive]/[T.receive_nonblocking]); the
   two instantiations below it ([Sim_tests], [Tcp_tests]) are exercised through the exact same
   [test_echo_between_peers] function body, textually -- the only implementation-specific code in
   this file is each instantiation's own "glue" (building a cluster of [T.t] handles and, where
   the underlying implementation needs it, driving delivery).

   [Sim_transport] and [Tcp] differ in one behavioral respect [Transport_intf.S] deliberately
   leaves unspecified: whether a sent message is available to the recipient's [receive] the
   instant [send] returns, or only after something later drives delivery (see
   [transport_intf.ml]'s own doc comment on [send] -- "queued for a real send, or scheduled for
   simulated delivery"). [Sim_transport] needs an explicit [pump_all] call (see
   [sim_transport.mli] -- deliberately NOT hidden inside [send], so pumping stays a visible,
   explicit step); [Tcp] delivers on its own via background reader/writer fibers once bytes reach
   the OS. [~run] is the one hook the shared body needs to stay portable across that difference:
   each glue module supplies a [unit -> unit] callback that the shared body calls after every
   round of sends and before asserting on [receive] -- [Sim_tests]'s glue implements it as
   [pump_all], [Tcp_tests]'s glue implements it as a no-op. This is not a workaround or a hidden
   per-implementation branch in the assertions themselves: it is exactly the "when do I check for
   new messages" seam [Transport_intf.S] itself leaves open, made explicit rather than papered
   over. *)

open Riptide_transport

module Make_transport_tests (T : Transport_intf.S) = struct
  (* Application-level test logic only: given a cluster of [T.t] handles (indexed by peer id,
     i.e. [cluster.(i)] is peer [i]'s own handle) and a [run] hook to call after sending to let
     delivery happen, send a handful of messages in a few directions and assert every one arrives
     at the right peer with the right bytes -- entirely through [T.send]/[T.receive]. This
     function never references [Sim_transport], [Tcp], [Network], or anything implementation
     specific. *)
  let test_echo_between_peers ~run (make_cluster : unit -> T.t array) =
    let cluster = make_cluster () in
    let n = Array.length cluster in
    Alcotest.(check bool) "cluster has at least 3 peers, to exercise more than one direction" true
      (n >= 3);
    let get id = cluster.(id) in
    let last = n - 1 in
    let rounds =
      [
        (0, 1, "hello-from-0-to-1");
        (1, 0, "hello-from-1-to-0");
        (0, last, "hello-from-0-to-last");
        (last, 0, "hello-from-last-to-0");
        (1, last, "hello-from-1-to-last");
      ]
    in
    List.iter
      (fun (from_, to_, msg) ->
        T.send (get from_) ~to_ msg;
        run ();
        Alcotest.(check string)
          (Printf.sprintf "peer %d receives peer %d's message, verbatim" to_ from_)
          msg (T.receive (get to_)))
      rounds;
    (* Confirm no stray/duplicated messages are left sitting anywhere once every expected message
       has been drained -- exercised through [T.receive_nonblocking], the third and last
       [Transport_intf.S] operation, so all three are covered by this one shared body. *)
    List.iter
      (fun id ->
        Alcotest.(check bool)
          (Printf.sprintf "peer %d has no leftover undelivered messages" id)
          true
          (T.receive_nonblocking (get id) = None))
      (List.init n (fun i -> i))
end

module Sim_tests = Make_transport_tests (Riptide_sim.Sim_transport)
module Tcp_tests = Make_transport_tests (Tcp)

(* -- Sim_transport glue: the ONLY implementation-specific code for this instantiation -- *)

let test_sim_echo_between_peers () =
  Eio_mock.Backend.run @@ fun () ->
  (* [make_cluster] both builds the cluster AND stashes it in [cluster_ref], so [run] (defined
     alongside it, before the shared body ever calls [make_cluster]) can reach the same
     underlying [Network.t] to pump once the shared body has actually created the cluster. This
     indirection lives entirely in this glue -- the shared [test_echo_between_peers] above only
     ever sees a plain [unit -> unit] [run] and a plain [unit -> T.t array] [make_cluster]. *)
  let cluster_ref = ref [||] in
  let make_cluster () =
    let prng = Riptide_sim.Prng.create 1 in
    let cluster = Riptide_sim.Sim_transport.create_cluster prng 3 in
    cluster_ref := cluster;
    cluster
  in
  let run () = Riptide_sim.Sim_transport.pump_all (!cluster_ref).(0) in
  Sim_tests.test_echo_between_peers ~run make_cluster

(* -- Tcp glue: the ONLY implementation-specific code for this instantiation --

   [Tcp.t] has no close/shutdown operation (see tcp.mli's "No shutdown path" section), so this
   mirrors test_transport_tcp.ml's own [with_mesh] pattern: force the switch to finish via
   [Eio.Switch.fail] once the shared test body returns, rather than let [Eio.Switch.run] block
   forever waiting for the never-ending listener/reader/writer fibers [Tcp.create] forks onto it.
   Distinct ports (19401-19403) from every range test_transport_tcp.ml already uses, so the two
   files' tests can never collide even if run back-to-back.

   [Tcp] is unconditionally mutually-authenticated, so this glue also has to mint a real X.509
   identity per peer (one shared CA, one leaf each -- see test_transport_tcp.ml's own material for
   the same pattern). That is genuinely implementation-specific setup and belongs here rather than
   in the shared body: [Transport_intf.S] says nothing about transport security, and
   [Sim_transport] has no equivalent notion. *)
exception Shared_tcp_mesh_torn_down

let () = Mirage_crypto_rng_unix.use_default ()

let shared_tcp_ca = Riptide_pki.Ca.generate_root ~common_name:"riptide-shared-transport-test-root"

let shared_tcp_identity id =
  let cert, priv_key =
    Riptide_pki.Ca.sign_leaf shared_tcp_ca
      ~common_name:(Printf.sprintf "shared-peer-%d.riptide.test" id)
      ~valid_days:1
  in
  Tls_identity.create ~trust_anchor:shared_tcp_ca.Riptide_pki.Ca.cert ~cert ~priv_key

let test_tcp_echo_between_peers () =
  let peer_specs = [ (0, "127.0.0.1", 19401); (1, "127.0.0.1", 19402); (2, "127.0.0.1", 19403) ] in
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  try
    Eio.Switch.run (fun sw ->
        let make_cluster () =
          let handles = Hashtbl.create (List.length peer_specs) in
          Eio.Fiber.all
            (List.map
               (fun (my_id, _, _) ->
                 fun () ->
                   let t =
                     Tcp.create ~sw ~net ~clock ~my_id ~peers:peer_specs
                       ~tls:(shared_tcp_identity my_id)
                   in
                   Hashtbl.replace handles my_id t)
               peer_specs);
          Array.init (List.length peer_specs) (fun i -> Hashtbl.find handles i)
        in
        (* Real sockets deliver on their own once bytes reach the OS -- no explicit pump exists
           or is needed for [Tcp], so this glue's [run] hook is a genuine no-op. *)
        let run () = () in
        Tcp_tests.test_echo_between_peers ~run make_cluster;
        Eio.Switch.fail sw Shared_tcp_mesh_torn_down)
  with Shared_tcp_mesh_torn_down -> ()

let sim_tests = [ ("sim_transport: shared echo-between-peers body", `Quick, test_sim_echo_between_peers) ]

let tcp_tests = [ ("tcp: shared echo-between-peers body", `Quick, test_tcp_echo_between_peers) ]
