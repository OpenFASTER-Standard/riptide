(* test/test_transport_tcp.ml

   Permanent regression coverage for [Riptide_transport.Tcp], the real-socket implementation of
   [Transport_intf.S]. These tests exercise real loopback TCP via [Eio_main.run] (NOT
   [Eio_mock.Backend] -- there is no mock socket layer to substitute here; the whole point is to
   prove the real wire behavior).

   {b What these tests do not cover, permanently.} An earlier round of work on [tcp.ml] fixed a
   family of crash bugs -- a write to a peer that had already died, and a corrupt/oversized frame,
   each behaving differently depending on whether the connection had been dialed or accepted --
   whose defining symptom was that they killed the whole OS process, not just one connection (see
   [tcp.ml]'s doc comment on [run_connection] for the mechanism and the fix). Nothing below
   regression-tests that class of bug, and nothing in this file structurally can: observing
   "process A survived process B's death" requires two real OS processes, and this suite runs a
   whole mesh inside one. A failure of that kind would take the test runner itself down rather
   than fail an assertion. So treat a green run here as evidence about the framing, routing and
   delivery properties listed below, and {b not} as evidence that the process-crash-on-dead-peer
   scenarios are still fixed -- those were verified with throwaway multi-process harnesses at the
   time, and re-verifying them needs the same kind of harness again. Closing this gap properly
   would mean a multi-process integration-test mechanism this repo does not yet have.

   What this file does lock in, permanently, is the three properties that would otherwise have no
   lasting test:
   - a real multi-peer mesh actually delivers messages correctly, in both directions, on every
     pairwise connection;
   - length-prefixed framing is byte-exact even when payload content itself contains bytes that
     look like framing metadata -- two back-to-back sends over one connection arrive as two
     distinct, unmodified messages, never merged or split;
   - each peer's [receive] only ever surfaces messages actually sent [~to_] it, with no
     cross-peer misattribution, even under concurrent multi-connection traffic;
   - [Tcp.create] does not return until every SPECIFIC expected peer id is connected, rather than
     merely that many connections existing (see that test's own comment);
   - [receive]'s reported sender is decoded from the certificate actually verified during the TLS
     handshake, never from the handshake preamble's own claim, even when a connection is
     constructed (by hand, bypassing [connect_to]) so the two genuinely disagree (see
     [test_receive_follows_the_certificate_not_the_preamble_claim] below);
   - the dial side's own TLS handshake (inside [connect_to]) is bounded by
     [tls_handshake_timeout], the same as the accept side's, rather than able to hang [Tcp.create]
     forever against a peer that accepts the TCP connection and then never speaks TLS back (see
     [test_dial_side_tls_handshake_has_a_bounded_timeout] below for how this is timed without
     actually waiting out the real ~10s).

   One further failure path was long believed uncoverable here, for reasons of mechanism rather
   than oversight, and was instead verified with a throwaway harness: the listener surviving a
   transient [accept(2)] error needs the process's file-descriptor budget deliberately exhausted,
   which would break the test runner itself long before it reached an assertion -- true of {e
   this} process (the one running the whole [test_riptide] binary), but not of a second, disposable
   OS process forked and exec'd specifically to be sacrificed this way. [Test 29] revisits that:
   [test_emfile_on_accept_does_not_kill_the_listener] below forks+execs [tcp_emfile_probe.exe]
   under a real, shell-level [ulimit -n] (the same technique, and the same reasoning, as
   [test_file_storage.ml]'s own [ulimit -f]-based real EFBIG reproduction for Task 19), so the real
   OS-level fd exhaustion happens entirely inside that disposable child, never inside this suite's
   own process. The {e accept} side's own bounded waits (the TLS handshake and the
   handshake-preamble read, both ~10s) remain uncovered on a real clock, for the reason above --
   ~10s eats most of this suite's own 15s-per-test watchdog budget. The {e dial} side's equivalent
   new timeout, added in this file alongside the fix, sidesteps that by racing the real handshake
   against a virtual [Eio_mock.Clock] instead of the real one, so it does not have this problem and
   is covered.

   Port choice: distinct, non-overlapping port ranges per test (19301-19303, 19311-19312,
   19321-19323, 19331-19333, 19341-19342, 19351, 19352, 19353, 19361-19362, 19371-19372, 19391,
   19410, 19401-19402, 19421-19422) so a re-run or a future added test in this file can't collide
   even if an earlier test's sockets are still winding down -- [Tcp.create] itself passes
   [~reuse_addr:true] to [Eio.Net.listen], but distinct ports sidestep the question entirely rather
   than relying on that. [Tcp.create] does not expose its internal listening socket, so there is no
   way to ask it for an OS-assigned ephemeral (port 0) address from outside; fixed, spread-out ports
   are the only option here. Note [19410] is dialed directly with raw sockets, never through
   [Tcp.create] or [with_mesh] -- it belongs to a probe process forked from this file, not a peer in
   this file's own [Eio_main.run]. [19422] (Task 30's read-idle-timeout test) is likewise a raw
   listener standing in for peer 2, not a real [Tcp.create] peer. *)

open Riptide_transport

(* -- Mutual-TLS test material --------------------------------------------------------------

   [Tcp] is unconditionally mutually-authenticated: every test in this file therefore has to hand
   [Tcp.create] a real X.509 identity, and every one of them is consequently also an end-to-end
   proof that the mTLS handshake succeeded -- a mesh that failed to handshake delivers no bytes at
   all, so the delivery/framing/attribution assertions below cannot pass without it.

   Two entirely unrelated certificate authorities exist here, both generated by Task 7's own
   [Riptide_pki.Ca] (no PEM round-trip, no fixture files):
   - [cluster_ca] issues every legitimate peer's leaf, and is the trust anchor every legitimate
     peer is configured with;
   - [foreign_ca] issues nothing any legitimate peer trusts. It exists solely so the negative
     cases below can present a certificate that is perfectly well-formed and validly signed --
     just not by an authority this cluster has any reason to accept. That is the distinction the
     negative tests are actually about: rejection must come from the trust decision, not from
     handing the peer garbage bytes it would have rejected for some unrelated parsing reason. *)

let () = Mirage_crypto_rng_unix.use_default ()

let cluster_ca = Riptide_pki.Ca.generate_root ~common_name:"riptide-tcp-test-cluster-root"
let foreign_ca = Riptide_pki.Ca.generate_root ~common_name:"riptide-tcp-test-foreign-root"

let leaf_of (ca : Riptide_pki.Ca.t) name = Riptide_pki.Ca.sign_leaf ca ~common_name:name ~valid_days:1

(* A fully self-consistent identity: a leaf signed by [ca], trusting [ca]. *)
let identity_of (ca : Riptide_pki.Ca.t) name =
  let cert, priv_key = leaf_of ca name in
  Tls_identity.create ~trust_anchor:ca.Riptide_pki.Ca.cert ~cert ~priv_key

let peer_identity id = identity_of cluster_ca (Printf.sprintf "peer-%d.riptide.test" id)

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
                 let t =
                   Tcp.create ~sw ~net ~clock ~my_id ~peers:peer_specs ~tls:(peer_identity my_id) ()
                 in
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
              let payload, sender = Tcp.receive (get to_) in
              Alcotest.(check string)
                (Printf.sprintf "peer %d receives peer %d's message, verbatim and in order" to_
                   from_)
                expected payload;
              Alcotest.(check int)
                (Printf.sprintf "peer %d's receive attributes it to the real sender, peer %d" to_
                   from_)
                from_ sender)
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
      let r1, sender1 = Tcp.receive b in
      let r2, sender2 = Tcp.receive b in
      Alcotest.(check string)
        "first back-to-back send is received whole and unmodified, not merged with the second" msg1
        r1;
      Alcotest.(check string)
        "second back-to-back send is received whole and unmodified, not merged with or split off \
         the first"
        msg2 r2;
      Alcotest.(check int) "first message is attributed to the real sender, peer 1" 1 sender1;
      Alcotest.(check int) "second message is attributed to the real sender, peer 1" 1 sender2;
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
      (* Two independent proofs of attribution, checked together: the payload content itself
         (round-tripping [from_] through the message the way a real caller's envelope would,
         which is the only proof available before Task 1) AND, now, [receive]'s own [sender]
         (transport_intf.ml) -- authenticated straight off the TLS certificate actually presented
         on the connection each message arrived on, per peer's own certificate identity (see
         [leaf_of]/[peer_identity] above), not derived from payload content at all. The two must
         agree for every message: a bug that routed a send meant for peer 3 onto peer 2's
         connection instead would now be caught either way -- by the payload landing in the wrong
         receiver's expected set (as before), or by that receiver's reported [sender] disagreeing
         with what the payload itself claims (new). *)
      let expected_for p =
        List.concat_map
          (fun (from_, to_) -> if to_ = p then List.map (fun seq -> (tag from_ to_ seq, from_)) seqs else [])
          pairs
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
          Alcotest.(check (list (pair string int)))
            (Printf.sprintf
               "peer %d's receive() surfaces exactly the (payload, authenticated sender) pairs \
                sent ~to_ it (and only those), even under concurrent multi-connection traffic"
               p)
            (expected_for p) (Hashtbl.find received p))
        ids)

(* -- Area 4: [create]'s mesh-readiness predicate -- *)

exception Stray_mesh_torn_down

let be8 n =
  let b = Bytes.create 8 in
  Bytes.set_int64_be b 0 (Int64.of_int n);
  Bytes.to_string b

(* [Tcp.create] must not return until it has an outbound path to each SPECIFIC other peer id in
   the membership table -- not merely to that MANY peers. The distinction is observable because
   the per-peer connection table is keyed by the id a handshake preamble claims, and that id is
   trusted rather than checked against the membership table (see tcp.mli's preamble note): any
   accepted connection lands in it, including one claiming an id the cluster has never heard of.

   This test makes the difference decide the outcome. Two stray sockets connect to peer 3's
   listener and claim ids 98 and 99 -- neither in [peer_specs] -- before peers 1 and 2 have even
   started. That is exactly as many connections as peer 3 is waiting for, so a readiness check
   that counted entries would declare the mesh formed and let [create] return with no path to
   either real peer. Peer 3's fiber therefore sends to both real peers the instant its own
   [create] returns, while peers 1 and 2 may still be starting: against a count-based check those
   sends raise [Invalid_argument "no connection to peer 1"], and against a per-id check they
   cannot, because [create] cannot have returned yet. The receives are asserted afterwards, once
   every peer is up, so the assertion proves the messages were also really delivered.

   The strays speak real mTLS, presenting their own leaf certificates issued by the same
   [cluster_ca] every legitimate peer trusts, and write their claimed preamble id {e inside} the
   resulting TLS flow. That is deliberate and load-bearing, not incidental: a stray that failed
   the handshake would never reach peer 3's connection table at all, which would make this test
   quietly vacuous (a count-based readiness check and a per-id one would then agree, and the test
   would pass against both). It is also the honest threat model now that {!Tcp} is mutually
   authenticated -- mTLS proves an incoming connection holds a certificate this cluster's CA
   issued, and nothing more; the preamble id it then claims is still not bound to that
   certificate, exactly as tcp.mli says. These two strays are that residual gap, made
   observable. *)
let test_create_waits_for_the_specific_expected_peers () =
  let peer_specs = [ (1, "127.0.0.1", 19331); (2, "127.0.0.1", 19332); (3, "127.0.0.1", 19333) ] in
  let stray_addr : Eio.Net.Sockaddr.stream = `Tcp (Eio.Net.Ipaddr.V4.loopback, 19333) in
  let msg = "sent-the-instant-create-returned" in
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  try
    Eio.Switch.run (fun sw ->
        let handles = Hashtbl.create (List.length peer_specs) in
        Eio.Fiber.all
          ((fun () ->
             (* Let peer 3's listener bind first (it starts without any delay, below), then park
                two connections on it claiming ids outside the membership table entirely. *)
             Eio.Time.sleep clock 0.1;
             List.iter
               (fun claimed_id ->
                 let flow = Eio.Net.connect ~sw net stray_addr in
                 let tls =
                   Tls_eio.client_of_flow
                     (Tls_identity.client_config
                        (identity_of cluster_ca
                           (Printf.sprintf "stray-%d.riptide.test" claimed_id)))
                     flow
                 in
                 Eio.Flow.copy_string (be8 claimed_id) tls)
               [ 98; 99 ])
          :: List.map
               (fun (my_id, _, _) () ->
                 (* Peers 1 and 2 start late deliberately, so that the strays are the only thing
                    in peer 3's connection table when a count-based check would have fired. *)
                 if my_id <> 3 then Eio.Time.sleep clock 0.5;
                 let t =
                   Tcp.create ~sw ~net ~clock ~my_id ~peers:peer_specs ~tls:(peer_identity my_id) ()
                 in
                 Hashtbl.replace handles my_id t;
                 if my_id = 3 then List.iter (fun to_ -> Tcp.send t ~to_ msg) [ 1; 2 ])
               peer_specs);
        List.iter
          (fun id ->
            let payload, sender = Tcp.receive (Hashtbl.find handles id) in
            Alcotest.(check string)
              (Printf.sprintf
                 "peer %d receives what peer 3 sent the instant peer 3's own create returned" id)
              msg payload;
            Alcotest.(check int)
              (Printf.sprintf "peer %d attributes it to the real sender, peer 3 (not a stray)" id)
              3 sender)
          [ 1; 2 ];
        Eio.Switch.fail sw Stray_mesh_torn_down)
  with Stray_mesh_torn_down -> ()

(* -- Area 4b: [receive]'s reported sender follows the certificate, never the preamble --------

   The property [authenticated_peer_id] (tcp.ml) exists to guarantee -- that {!Tcp.receive}'s
   reported sender is decoded from the certificate {e actually verified} during the mutual TLS
   handshake, never from the handshake preamble's own in-band claim -- has no test anywhere in
   this suite, old or new, that ever makes the two diverge: every mesh built above (including
   [test_create_waits_for_the_specific_expected_peers]'s strays) hands every connection a
   certificate whose SAN-encoded id and preamble claim are the same value. A regression that
   silently reverted [reader_body] to trusting the preamble instead of re-deriving from
   [Tls_eio.epoch] would pass every one of those tests unchanged.

   This test forces the divergence directly, the same way the stray-connection test above
   bypasses [Tcp.connect_to] (which always ties the preamble it writes to the same identity as
   the certificate it dials with, so it structurally cannot produce this case): dial the
   receiving peer's real listener with a raw socket, complete a real mTLS handshake presenting a
   certificate that encodes id [claimed_cert_id], then write a handshake preamble claiming a
   DIFFERENT id [claimed_preamble_id], then a real length-prefixed frame. [receive] on the other
   end must report the certificate's id -- never the preamble's. *)
exception Preamble_cert_divergence_test_done

let test_receive_follows_the_certificate_not_the_preamble_claim () =
  let receiver_id = 2 in
  let peer_specs = [ (receiver_id, "127.0.0.1", 19381) ] in
  let claimed_cert_id = 42 and claimed_preamble_id = 7 in
  let frame payload = be8 (String.length payload) ^ payload in
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  try
    Eio.Switch.run (fun sw ->
        (* A single-member "mesh": [receiver] has no other peer to dial or wait on, so [create]
           starts its listener and returns immediately -- the stray connection below is dialed
           entirely by hand, exactly like the strays in the readiness test above. *)
        let receiver =
          Tcp.create ~sw ~net ~clock ~my_id:receiver_id ~peers:peer_specs
            ~tls:(peer_identity receiver_id) ()
        in
        let addr : Eio.Net.Sockaddr.stream = `Tcp (Eio.Net.Ipaddr.V4.loopback, 19381) in
        let flow = Eio.Net.connect ~sw net addr in
        let tls =
          Tls_eio.client_of_flow
            (Tls_identity.client_config
               (identity_of cluster_ca (Printf.sprintf "peer-%d.riptide.test" claimed_cert_id)))
            flow
        in
        let msg = "divergent-preamble-vs-cert" in
        Eio.Flow.copy_string (be8 claimed_preamble_id ^ frame msg) tls;
        let payload, sender = Tcp.receive receiver in
        Alcotest.(check bool)
          "test setup: the preamble's claim genuinely differs from the certificate's id" true
          (claimed_preamble_id <> claimed_cert_id);
        Alcotest.(check string) "message content arrives unmodified" msg payload;
        Alcotest.(check int)
          "receive attributes the message to the certificate's id, not the differing preamble claim"
          claimed_cert_id sender;
        Eio.Switch.fail sw Preamble_cert_divergence_test_done)
  with Preamble_cert_divergence_test_done -> ()

(* -- Area 4c: second connection claiming an already-connected id is refused --------

   When a connection is established with a peer id (determined by the handshake preamble),
   that id's entry in [t.writers] is populated. If a second connection then claims the same id
   while the first is still LIVE, the second connection must be refused and the first
   connection's entry must remain untouched -- proven here the same way delivery is proven
   elsewhere in this file: by actually driving [Tcp.send] through the receiver and reading the
   real bytes off the raw client socket, both before and after the rejected duplicate attempt.
   The previous behavior silently replaced the first connection's entry via [Hashtbl.replace],
   which would have re-routed the receiver's later sends onto the second (attacker- or
   reconnect-controlled) connection instead -- exactly the regression this test exists to catch.

   The rejection itself is observed by reading from the SECOND connection's own raw socket: a
   refused connection's writer fiber exits without registering (see [register_writer] /
   [writer_body] in tcp.ml), which ends that connection's [run_connection] and lets
   [Eio.Net.accept_fork] close the accepted flow -- so a read on the client side of the rejected
   connection must observe that closure (some exception, since neither side ever sends a TLS
   close_notify -- see tcp.ml's [run_connection] doc comment) rather than ever seeing a frame
   delivered to it. *)
exception Duplicate_id_test_done

let test_second_connection_claiming_already_connected_id_is_refused () =
  let receiver_id = 2 in
  let duplicate_id = 1 in
  let peer_specs = [ (duplicate_id, "127.0.0.1", 19381); (receiver_id, "127.0.0.1", 19382) ] in
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  (* Bounded so a real regression (a hang instead of a clean rejection, or a frame that never
     arrives because routing silently moved to the wrong connection) fails this test with a clear
     mismatch well inside the suite's own 15s-per-test watchdog, instead of hanging it. *)
  let read_frame_with_timeout r =
    match
      Eio.Time.with_timeout clock 3.0 (fun () ->
          let len = Eio.Buf_read.BE.uint64 r |> Int64.to_int in
          Ok (Eio.Buf_read.take len r))
    with
    | Ok s -> s
    | Error `Timeout -> "<test bug or regression: timed out waiting for a frame>"
  in
  try
    Eio.Switch.run (fun sw ->
        let receiver = ref None in
        Eio.Fiber.both
          (fun () ->
            (* Create the receiver, which will wait for peer 1's connection *)
            receiver := Some (Tcp.create ~sw ~net ~clock ~my_id:receiver_id ~peers:peer_specs
              ~tls:(peer_identity receiver_id) ()))
          (fun () ->
            (* Meanwhile, manually create the connections from peer 1 *)
            let addr : Eio.Net.Sockaddr.stream = `Tcp (Eio.Net.Ipaddr.V4.loopback, 19382) in
            let dial_as_duplicate_id () =
              let flow = Eio.Net.connect ~sw net addr in
              let tls =
                Tls_eio.client_of_flow
                  (Tls_identity.client_config
                     (identity_of cluster_ca (Printf.sprintf "peer-%d.riptide.test" duplicate_id)))
                  flow
              in
              Eio.Flow.copy_string (be8 duplicate_id) tls;
              (tls, Eio.Buf_read.of_flow tls ~max_size:4096)
            in

            (* Add a small delay to ensure the receiver's listener is up before we try to connect *)
            Eio.Time.sleep clock 0.1;

            (* Connection 1 claims id 1 and completes its handshake + preamble. *)
            let _tls1, r1 = dial_as_duplicate_id () in

            (* Now wait for the receiver to be created *)
            let deadline = Eio.Time.now clock +. 5.0 in
            let rec wait_for_receiver () =
              match !receiver with
              | Some r -> r
              | None ->
                if Eio.Time.now clock > deadline then
                  Alcotest.fail "Receiver creation took too long"
                else begin
                  Eio.Time.sleep clock 0.01;
                  wait_for_receiver ()
                end
            in
            let rcv = wait_for_receiver () in

            (* Prove connection 1 is really the live, routed entry for id 1 *before* the duplicate
               attempt exists at all: send a real message from the receiver to id 1 and read it back
               off connection 1's own raw socket. *)
            let deadline = Eio.Time.now clock +. 3.0 in
            let rec send_once_registered msg =
              match Tcp.send rcv ~to_:duplicate_id msg with
              | () -> ()
              | exception Invalid_argument _ ->
                if Eio.Time.now clock > deadline then
                  Alcotest.fail "Tcp.send: peer never registered a writer within the retry budget"
                else begin
                  Eio.Time.sleep clock 0.02;
                  send_once_registered msg
                end
            in
            send_once_registered "before";
            Alcotest.(check string)
              "a message sent to id 1 before the duplicate attempt arrives on connection 1" "before"
              (read_frame_with_timeout r1);

            (* Connection 2 also claims id 1 while connection 1 is still live -- this must be refused,
               not silently swapped in for connection 1. *)
            let _tls2, r2 = dial_as_duplicate_id () in
            let connection_2_was_refused =
              match Eio.Time.with_timeout clock 3.0 (fun () -> Ok (Eio.Buf_read.take 1 r2)) with
              | Ok _got_a_byte -> false
              | Error `Timeout -> false
              | exception (End_of_file | Eio.Io _ | Tls_eio.Tls_alert _ | Tls_eio.Tls_failure _) -> true
            in
            Alcotest.(check bool)
              "a second connection claiming the same, still-live id is refused (its socket is closed \
               rather than ever receiving a frame)"
              true connection_2_was_refused;

            (* The rejected duplicate must not have touched connection 1's table entry: the receiver
               can still reach id 1, and still reaches it via connection 1 specifically. *)
            send_once_registered "after";
            Alcotest.(check string)
              "the first connection can still send/receive normally after the rejected duplicate \
               attempt -- its table entry was never touched"
              "after" (read_frame_with_timeout r1));

        Eio.Switch.fail sw Duplicate_id_test_done)
  with Duplicate_id_test_done -> ()

(* -- Area 5: mutual TLS ---------------------------------------------------------------------

   Two different levels of evidence are needed here, and neither substitutes for the other.

   (a) {b At the wire.} That the mTLS handshake happens {e at all} and that nothing this module
       sends afterwards bypasses it. Proved by [test_first_bytes_on_the_wire_are_a_tls_handshake]
       below, which sniffs the raw socket directly: the very first bytes a dialing peer puts on
       it must be a TLS record, never this module's own plaintext 8-byte handshake preamble.

   (b) {b At the trust decision.} That {e both} ends actually verify the other's certificate. The
       client half is visible end-to-end through [Tcp.create] itself (a dialer refuses to finish
       connecting to a server whose certificate it cannot chain to its own CA). The server half
       -- the one that is silently absent if [Tls.Config.server]'s own optional [?authenticator]
       is left unset, in which case the server happily accepts any client certificate, or none --
       is not observable through [Tcp]'s public surface on any useful timescale: a rejected client
       simply never appears in the server's connection table, and the only externally visible
       consequence is that [Tcp.create]'s ~20s mesh-formation budget eventually expires, which is
       both far too slow for this suite and far too weak an assertion (it would pass just as
       happily if the client had never dialed at all). So those cases drive [Tls_eio] directly,
       through the {e same} [Tls_identity.server_config] value [Tcp] itself uses -- the production
       server configuration is the actual subject under test, and the client is the adversary.

   The adversary's own [Tls.Config.client] values are built by hand here rather than through
   [Tls_identity], on purpose: an attacker does not use our helper, and hand-building is also the
   only way to express the two configurations that matter (a client that trusts our CA while
   presenting a certificate from another one, and a client presenting no certificate at all). *)

let tls_authenticator_for (ca : Riptide_pki.Ca.t) =
  X509.Authenticator.chain_of_trust
    ~time:(fun () -> Some (Ptime_clock.now ()))
    [ ca.Riptide_pki.Ca.cert ]

let adversary_client_config ?certificates () =
  match
    Tls.Config.client ~authenticator:(tls_authenticator_for cluster_ca)
      ?certificates
      ~version:(`TLS_1_3, `TLS_1_3) ()
  with
  | Ok c -> c
  | Error (`Msg m) -> Alcotest.failf "test setup: could not build adversary client config: %s" m

(* Runs exactly one TLS handshake over one real loopback TCP connection. The server side always
   uses [Tls_identity.server_config server_identity] -- byte for byte the configuration
   [Tcp.create] installs for its own listener -- and then reads four bytes of application data
   through the resulting TLS flow. The client side is whatever [client_config] the caller passes.

   Returns the {e server's} view, classified: this is the side whose trust decision is under test,
   and reading its outcome directly is what stops these tests from degenerating into "some branch
   of some code ran". Because the only thing that differs between the positive control and each
   negative case below is the client's certificate, "accepted" vs "rejected-by-tls" is a
   difference the certificate alone produced. *)
let server_side_of_one_handshake ~port ~server_identity ~client_config =
  let outcome = ref (Error End_of_file) in
  let addr : Eio.Net.Sockaddr.stream = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
  Eio_main.run (fun env ->
      let net = Eio.Stdenv.net env in
      Eio.Switch.run (fun sw ->
          let listener = Eio.Net.listen ~reuse_addr:true ~backlog:1 ~sw net addr in
          Eio.Fiber.both
            (fun () ->
              let flow, _addr = Eio.Net.accept ~sw listener in
              match Tls_eio.server_of_flow (Tls_identity.server_config server_identity) flow with
              | exception exn -> outcome := Error exn
              | tls -> (
                let r = Eio.Buf_read.of_flow tls ~max_size:4096 in
                match Eio.Buf_read.take 4 r with
                | exception exn -> outcome := Error exn
                | got -> outcome := Ok (got, Tls_eio.epoch tls)))
            (fun () ->
              let flow = Eio.Net.connect ~sw net addr in
              (* Every failure the adversary side can hit is expected and irrelevant to the
                 assertion: if the client is the one that rejects, or if it is cut off mid-write by
                 the server's alert, that is fine -- what is being asserted is the server's
                 outcome, recorded above. [Eio.Cancel.Cancelled] is deliberately not caught. *)
              match Tls_eio.client_of_flow client_config flow with
              | exception (Tls_eio.Tls_alert _ | Tls_eio.Tls_failure _ | End_of_file | Eio.Io _) ->
                ()
              | tls -> (
                match Eio.Flow.copy_string "ping" tls with
                | () -> ()
                | exception
                    (Tls_eio.Tls_alert _ | Tls_eio.Tls_failure _ | End_of_file | Eio.Io _) ->
                  ()))));
  !outcome

let classify_server_outcome = function
  | Ok _ -> "accepted"
  | Error (Tls_eio.Tls_failure _) -> "rejected-by-tls"
  | Error (Tls_eio.Tls_alert _) -> "rejected-by-tls"
  | Error exn -> "other-failure: " ^ Printexc.to_string exn

(* The positive control for the two negative cases below, and the explicit end-to-end proof that a
   real mutual handshake between two Task-7-CA-signed identities succeeds and carries application
   bytes. The two epoch assertions are what make it a proof of {e mutual} authentication rather
   than of server-only TLS: the server having a [peer_certificate] at all means the client really
   did present one and it really was verified against the trust anchor. *)
let test_mutual_handshake_between_two_ca_signed_peers_succeeds () =
  let outcome =
    server_side_of_one_handshake ~port:19351 ~server_identity:(peer_identity 1)
      ~client_config:(Tls_identity.client_config (peer_identity 2))
  in
  Alcotest.(check string)
    "a client holding a leaf issued by the cluster CA completes the mutual handshake" "accepted"
    (classify_server_outcome outcome);
  match outcome with
  | Error _ -> Alcotest.fail "unreachable: outcome was classified as accepted"
  | Ok (payload, epoch) ->
    Alcotest.(check string) "application bytes cross the TLS-wrapped flow verbatim" "ping" payload;
    let epoch = match epoch with Ok e -> e | Error () -> Alcotest.fail "no TLS epoch available" in
    Alcotest.(check bool)
      "the server holds the client's verified certificate, i.e. the handshake was MUTUAL" true
      (epoch.Tls.Core.peer_certificate <> None);
    Alcotest.(check bool)
      "the server resolved the client's chain to a trust anchor" true
      (epoch.Tls.Core.trust_anchor <> None);
    (* The version pin is real, not just written down: both ends are configured TLS 1.3-only, so
       a future edit that widened the range to admit older versions (and with them
       downgrade negotiation) would have to change this assertion too. *)
    Alcotest.(check string) "the session negotiated the pinned protocol version"
      (Fmt.to_to_string Tls.Core.pp_tls_version (snd Tls_identity.protocol_version))
      (Fmt.to_to_string Tls.Core.pp_tls_version epoch.Tls.Core.protocol_version)

(* {b Negative case 1, the Review Focus case.} A client that trusts this cluster's CA (so it has
   no objection of its own to raise, and the handshake really does get as far as the server's
   trust decision) but presents a leaf issued by an entirely unrelated CA. The server must reject
   it. If [Tls.Config.server]'s own [?authenticator] were left unset -- the single easiest thing
   to miss when wiring mTLS, since the client side's [authenticator] is mandatory and the server
   side's is not -- this test would classify as "accepted", because the server would take the
   foreign certificate without looking at it. *)
let test_server_rejects_a_client_certificate_from_an_unrelated_ca () =
  let rogue_cert, rogue_key = leaf_of foreign_ca "rogue.riptide.test" in
  let outcome =
    server_side_of_one_handshake ~port:19352 ~server_identity:(peer_identity 1)
      ~client_config:(adversary_client_config ~certificates:(`Single ([ rogue_cert ], rogue_key)) ())
  in
  Alcotest.(check string)
    "a client whose leaf is signed by an unrelated CA is rejected at the handshake"
    "rejected-by-tls" (classify_server_outcome outcome)

(* {b Negative case 2.} The same server, same port topology, same everything -- except the client
   presents no certificate at all. A server whose [?authenticator] is unset does not even ask for
   one, and this connection would be established as ordinary one-way TLS. It must be rejected. *)
let test_server_rejects_a_client_presenting_no_certificate () =
  let outcome =
    server_side_of_one_handshake ~port:19353 ~server_identity:(peer_identity 1)
      ~client_config:(adversary_client_config ())
  in
  Alcotest.(check string) "a client presenting no certificate is rejected at the handshake"
    "rejected-by-tls" (classify_server_outcome outcome)

(* The other half of mutual authentication, asserted end-to-end through [Tcp.create]'s own real
   dialing path rather than against [Tls_eio] directly: peer 1 trusts [cluster_ca], peer 2 is a
   complete, internally-consistent replica of some {e other} cluster (its own CA, its own leaf).
   Peer 1 must refuse to complete the connection, and must say why -- [Tcp.create] surfacing this
   as a bare dial timeout, or (worse) proceeding, would both be failures here. *)
let test_dialer_rejects_a_server_certificate_from_an_unrelated_ca () =
  let peer_specs = [ (1, "127.0.0.1", 19361); (2, "127.0.0.1", 19362) ] in
  let identity_for id = if id = 1 then peer_identity 1 else identity_of foreign_ca "impostor.riptide.test" in
  let failure = ref None in
  (try
     Eio_main.run (fun env ->
         let net = Eio.Stdenv.net env in
         let clock = Eio.Stdenv.clock env in
         Eio.Switch.run (fun sw ->
             Eio.Fiber.all
               (List.map
                  (fun (my_id, _, _) () ->
                    ignore
                      (Tcp.create ~sw ~net ~clock ~my_id ~peers:peer_specs
                         ~tls:(identity_for my_id) ()))
                  peer_specs)))
   with Failure msg -> failure := Some msg);
  let msg =
    match !failure with
    | Some msg -> msg
    | None ->
      Alcotest.fail
        "Tcp.create completed against a peer presenting a certificate from an unrelated CA -- the \
         dialing side's authenticator did not reject it"
  in
  let contains needle haystack =
    let nl = String.length needle and hl = String.length haystack in
    let rec go i = i + nl <= hl && (String.sub haystack i nl = needle || go (i + 1)) in
    go 0
  in
  Alcotest.(check bool)
    (Printf.sprintf
       "the failure names the TLS handshake with peer 2 as the cause, not a generic dial timeout \
        (got: %s)"
       msg)
    true
    (contains "TLS handshake" msg && contains "peer 2" msg)

(* [Tls_identity.create]'s own two startup checks. Both exist to turn a silent misconfiguration
   into a loud one at boot instead of an opaque handshake failure later, so both need a test that
   proves the check fires -- otherwise the checks are exactly the kind of prose-shaped claim that
   no code exercises. *)

let expect_tls_config_error what f =
  match f () with
  | (_ : Tls_identity.t) -> Alcotest.failf "Tls_identity.create accepted %s" what
  | exception Tls_identity.Tls_config_error _ -> ()

let test_identity_rejects_a_key_that_does_not_match_its_certificate () =
  let cert, _ = leaf_of cluster_ca "matched.riptide.test" in
  let _, other_key = leaf_of cluster_ca "unrelated.riptide.test" in
  expect_tls_config_error "a certificate paired with an unrelated private key" (fun () ->
      Tls_identity.create ~trust_anchor:cluster_ca.Riptide_pki.Ca.cert ~cert ~priv_key:other_key)

let test_identity_rejects_a_certificate_its_trust_anchor_did_not_issue () =
  let cert, priv_key = leaf_of foreign_ca "elsewhere.riptide.test" in
  expect_tls_config_error "its own certificate not chaining to its own trust anchor" (fun () ->
      Tls_identity.create ~trust_anchor:cluster_ca.Riptide_pki.Ca.cert ~cert ~priv_key)

(* Nothing this module puts on the wire may bypass the TLS flow. That is a property no
   application-level round-trip test can distinguish from "TLS was negotiated and then ignored",
   so it is asserted where it is actually observable: on the raw socket.
   A plain TCP listener stands in for peer 2 and reads the first bytes peer 1's dialing path
   writes. Those bytes must be a TLS handshake record, and must specifically {e not} be this
   module's own 8-byte plaintext handshake preamble -- which is exactly what a wiring that
   TLS-wrapped nothing, or that wrapped the flow but kept writing the preamble to the raw socket
   underneath it, would produce. *)
exception Wire_probe_done

let test_first_bytes_on_the_wire_are_a_tls_handshake () =
  let peer_specs = [ (1, "127.0.0.1", 19341); (2, "127.0.0.1", 19342) ] in
  let first_bytes = ref "" in
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  (try
     Eio.Switch.run (fun sw ->
         let listener =
           Eio.Net.listen ~reuse_addr:true ~backlog:1 ~sw net
             (`Tcp (Eio.Net.Ipaddr.V4.loopback, 19342))
         in
         Eio.Fiber.both
           (fun () ->
             let flow, _addr = Eio.Net.accept ~sw listener in
             let r = Eio.Buf_read.of_flow flow ~max_size:4096 in
             first_bytes := Eio.Buf_read.take 8 r;
             (* Peer 1 is now blocked waiting for a ServerHello that is never coming; tearing the
                switch down is how this test ends rather than sitting out peer 1's dial budget. *)
             Eio.Switch.fail sw Wire_probe_done)
           (fun () ->
             ignore (Tcp.create ~sw ~net ~clock ~my_id:1 ~peers:peer_specs ~tls:(peer_identity 1) ())))
   with Wire_probe_done -> ());
  let observed = !first_bytes in
  Alcotest.(check int) "the probe actually captured the dialer's first bytes" 8
    (String.length observed);
  Alcotest.(check bool)
    (Printf.sprintf
       "the dialer's first wire bytes are a TLS handshake record (0x16), not plaintext (got %S)"
       observed)
    true
    (String.length observed > 0 && observed.[0] = '\x16');
  Alcotest.(check bool)
    "...and specifically not this module's own 8-byte plaintext handshake preamble" false
    (observed = be8 1)

(* -- Area 6: dial-side TLS handshake timeout -----------------------------------------------

   Regression test for the finding fixed in this round: [connect_to]'s call to
   [Tls_eio.client_of_flow] used to have no timeout at all, unlike [handle_accepted]'s equivalent
   [server_of_flow] call. A peer that accepts the TCP connection and then never speaks TLS back --
   wedged, mid-restart, or behind a path that silently drops packets after [connect] -- used to
   park [Tcp.create] inside the handshake forever, with no diagnostic, *before*
   [mesh_formation_timeout] ever got a chance to apply. The fix wraps the dial-side handshake in
   the same [Eio.Time.with_timeout clock tls_handshake_timeout] the accept side already used.

   A raw TCP listener again stands in for peer 2 (as in
   [test_first_bytes_on_the_wire_are_a_tls_handshake] above), except this one accepts the
   connection and then holds it open without ever writing a byte, instead of being torn down
   immediately -- exactly the hang scenario the finding describes.

   Waiting out the real [tls_handshake_timeout] (~10s) here, on the suite's real wall clock, would
   eat most of this suite's own 15s-per-test watchdog budget (see this file's header comment) --
   uncomfortably close for a suite that otherwise runs in a couple of seconds. [Tcp.create]'s
   [~clock] argument is a plain [_ Eio.Time.clock], though, so this test hands it an
   [Eio_mock.Clock] instead of the real one -- the same virtual-time mechanism
   [lib/sim/network.ml] already uses to drive [Riptide_sim]'s simulated network deterministically.
   The raw TCP connect and the handshake's own blocked read are still real OS I/O via
   [Eio_main.run]; only the timeout race's notion of elapsed time is virtual, which is what lets
   this test fire the timeout near-instantly and deterministically instead of either sleeping for
   real or racing the assertion against wall-clock flakiness. *)
exception Handshake_timeout_probe_done

let test_dial_side_tls_handshake_has_a_bounded_timeout () =
  let peer_specs = [ (1, "127.0.0.1", 19371); (2, "127.0.0.1", 19372) ] in
  let result = ref None in
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let real_clock = Eio.Stdenv.clock env in
  let mock_clock = Eio_mock.Clock.make () in
  let clock_for_tcp : float Eio.Time.clock_ty Eio.Std.r =
    (mock_clock :> float Eio.Time.clock_ty Eio.Std.r)
  in
  (try
     Eio.Switch.run (fun sw ->
         let listener =
           Eio.Net.listen ~reuse_addr:true ~backlog:1 ~sw net
             (`Tcp (Eio.Net.Ipaddr.V4.loopback, 19372))
         in
         Eio.Fiber.both
           (fun () ->
             (* Accept the raw connection -- proving the finding's premise, that the raw TCP
                connect succeeds -- then hold [flow] open and silent. [sw] keeps the fd alive after
                this fiber moves on, so peer 1's dialer genuinely blocks inside
                [Tls_eio.client_of_flow] waiting for a ServerHello that is never coming. Once that
                wait has registered its timeout job on the mock clock, push virtual time past it to
                fire the timeout deterministically rather than waiting out the real ~10s. *)
             let flow, _addr = Eio.Net.accept ~sw listener in
             ignore flow;
             let rec wait_for_timeout_job () =
               match Eio_mock.Clock.advance mock_clock with
               | () -> ()
               | exception Invalid_argument _ ->
                 Eio.Time.sleep real_clock 0.02;
                 wait_for_timeout_job ()
             in
             wait_for_timeout_job ())
           (fun () ->
             (match
                Tcp.create ~sw ~net ~clock:clock_for_tcp ~my_id:1 ~peers:peer_specs
                  ~tls:(peer_identity 1) ()
              with
             | (_ : Tcp.t) ->
               Alcotest.fail
                 "Tcp.create succeeded despite peer 2 never completing its TLS handshake"
             | exception Failure msg -> result := Some msg);
             Eio.Switch.fail sw Handshake_timeout_probe_done))
   with Handshake_timeout_probe_done -> ());
  let msg =
    match !result with
    | Some msg -> msg
    | None ->
      Alcotest.fail
        "Tcp.create never raised -- the dial-side TLS handshake timeout did not fire"
  in
  let contains needle haystack =
    let nl = String.length needle and hl = String.length haystack in
    let rec go i = i + nl <= hl && (String.sub haystack i nl = needle || go (i + 1)) in
    go 0
  in
  Alcotest.(check bool)
    (Printf.sprintf
       "the failure names the TLS handshake and peer 2 specifically, not a generic dial timeout \
        (got: %s)"
       msg)
    true
    (contains "TLS handshake" msg && contains "peer 2" msg)

let test_send_refuses_an_id_outside_the_configured_membership () =
  let peer_specs = [ (0, "127.0.0.1", 19381) ] in
  with_mesh peer_specs (fun handles ->
      let t = Hashtbl.find handles 0 in
      Alcotest.check_raises "send to a non-member id is refused"
        (Invalid_argument "Tcp.send: no connection to peer 99")
        (fun () -> Tcp.send t ~to_:99 "x"))

(* -- Area 7: a configurable cap on concurrent accepted connections -------------------------

   Regression test for Task 28's audit finding: [run_accept_loop] used to fork a new fiber for
   every accepted connection unconditionally, with no bound -- an attacker (or a misbehaving
   client) opening many TCP connections and never completing anything can exhaust this process's
   file descriptors and kill the listener (reproduced at 315 concurrent connections; see this
   module's own "Listener error handling" doc section before this fix). The fix wraps
   [run_accept_loop]'s existing [accept_fork] call in an [Eio.Semaphore.t] sized to
   [?max_connections] -- see [tcp.ml]'s own comment on [run_accept_loop] for why this, rather
   than "accept then immediately close", is the chosen mechanism.

   {b What this test actually observes.} With the semaphore wrapped around [accept_fork] itself
   (not around [handle_accepted]), a connection beyond the cap is never even handed to
   [Eio.Net.accept]'s underlying [accept(2)] call -- it simply sits, already TCP-established, in
   the kernel's own listen backlog (a real, observable TCP property: the kernel completes the
   3-way handshake and queues the connection the instant the backlog has room, entirely
   independently of whether the application has called [accept(2)] yet). That means a client
   cannot tell "still queued in the kernel" apart from "not yet connected" merely by observing
   that [connect] returned -- but it CAN tell the two apart by whether the server ever responds to
   real TLS bytes it sends: the server's [handle_accepted] doesn't start [Tls_eio.server_of_flow]
   (and therefore never produces a ServerHello) until [Eio.Net.accept_fork] actually dequeues the
   connection, which only happens once a semaphore slot is free. So "this client's real mTLS
   handshake completed" is a faithful, wire-level proxy for "this connection is currently past
   [accept(2)] and being handled by this listener" -- exactly the property [max_connections] is
   supposed to bound.

   Each client that completes its handshake holds the connection open (without ever sending this
   module's own post-handshake preamble) for [hold_time], long enough to force real overlap among
   concurrently-active clients to be observable, then explicitly closes it -- which the server
   observes as an early EOF on its own bounded preamble read (see [handle_accepted]), causing that
   connection's [handle_accepted] call to return and its semaphore permit to be released for the
   next waiting client. A client that is still waiting for a permit doesn't hang forever either
   way: bounded by its own [Eio.Time.with_timeout] below, generous relative to
   [hold_time] * [num_clients] / [max_connections] (the real worst-case queue-drain time). *)
exception Concurrency_cap_test_done

let test_accept_loop_caps_concurrent_connections () =
  let my_id = 1 in
  let port = 19391 in
  let max_connections = 2 in
  let num_clients = 6 in
  let hold_time = 0.3 in
  let peer_specs = [ (my_id, "127.0.0.1", port) ] in
  let max_active_observed = ref 0 in
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  (try
     Eio.Switch.run (fun sw ->
         let (_ : Tcp.t) =
           Tcp.create ~sw ~net ~clock ~my_id ~peers:peer_specs ~tls:(peer_identity my_id)
             ~max_connections ()
         in
         let addr : Eio.Net.Sockaddr.stream = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
         (* Only ever touched from Eio fibers running cooperatively on this one domain -- no
            genuine data race, so a plain [ref] (not an [Eio.Mutex]-guarded value or an [Atomic])
            is enough, the same reasoning [file_storage.ml]'s single-fiber-per-replica model
            relies on elsewhere in this codebase. *)
         let active = ref 0 in
         (* Task 28 review, Minor finding: the peak-count assertion below alone doesn't prove every
            client eventually got through -- only that whichever ones did never exceeded the cap.
            A connection genuinely stuck in the kernel backlog receives zero bytes and can only
            ever hit the [Error `Timeout] branch (never a TLS exception -- there is nothing to send
            a TLS alert about), so the [Tls_alert]/[Tls_failure]/[End_of_file]/[Eio.Io] branch below
            is not expected to fire in this test at all; a [succeeded] counter makes that
            expectation an explicit, checked assertion instead of an implicit one, and is robust
            against a future refactor that changed the queuing mechanism in a way that silently
            dropped connections instead of queuing them. *)
         let succeeded = ref 0 in
         let client_body i () =
           let flow = Eio.Net.connect ~sw net addr in
           match
             Eio.Time.with_timeout clock 10.0 (fun () ->
                 Ok
                   (Tls_eio.client_of_flow
                      (Tls_identity.client_config
                         (identity_of cluster_ca (Printf.sprintf "client-%d.riptide.test" i)))
                      flow))
           with
           | exception (Tls_eio.Tls_alert _ | Tls_eio.Tls_failure _ | End_of_file | Eio.Io _) -> ()
           | Error `Timeout ->
             Alcotest.failf
               "client %d: the server never dequeued this connection within the test's own \
                generous timeout -- either the cap never releases queued connections, or it is \
                stuck at 0 permits"
               i
           | Ok tls ->
             incr active;
             if !active > !max_active_observed then max_active_observed := !active;
             Eio.Time.sleep clock hold_time;
             decr active;
             incr succeeded;
             (try Eio.Flow.close tls with End_of_file | Eio.Io _ -> ())
         in
         Eio.Fiber.all (List.init num_clients (fun i () -> client_body i ()));
         Alcotest.(check int)
           "every client's handshake eventually completed -- none was silently dropped instead of \
            queued"
           num_clients !succeeded;
         Eio.Switch.fail sw Concurrency_cap_test_done)
   with Concurrency_cap_test_done -> ());
  Alcotest.(check bool)
    (Printf.sprintf
       "at most %d connections were ever simultaneously past accept(2) and being handled by this \
        listener (observed a peak of %d, out of %d clients)"
       max_connections !max_active_observed num_clients)
    true
    (!max_active_observed <= max_connections)

(* -- Area 9: EMFILE on accept must not kill the listener (Task 29) -- *)

(* [tcp_emfile_probe.ml] (its own top comment has the full design) is a standalone process, built
   as a separate dune executable, whose entire job is to bring up one real
   [Riptide_transport.Tcp.t] and then run forever. It is forked+exec'd here under a real,
   shell-level [ulimit -n] -- lowering THIS suite's own process's fd budget would break every
   other test sharing it (see this file's own top comment); a disposable child process pays that
   cost instead, and only it. This is the same fork+exec-under-a-lowering-[ulimit] technique
   [test_file_storage.ml]'s own [run_o_direct_probe] uses for a real, non-EINVAL EFBIG (Task 19),
   substituting [-n] (RLIMIT_NOFILE, what actually governs EMFILE) for [-f] (RLIMIT_FSIZE).

   Unlike that probe, this one is long-lived by design (it blocks forever until killed, or until
   it dies on its own past the fatal threshold this test exists to exercise) -- so its stdout and
   stderr are redirected to a plain file, not a pipe drained to EOF: a pipe would risk blocking the
   child on a full buffer while this test is still busy flooding connections and has not read
   anything yet, and [Eio.traceln] (see [Eio.Debug], confirmed live by reading
   [core/debug.ml]'s own [default_traceln]) already flushes stderr after every message, so a plain
   file gives byte-exact, immediately-visible output without needing a background reader. *)
let tcp_emfile_probe_path = "./tcp_emfile_probe.exe"

let start_emfile_probe ~ulimit_n ~port ~log_path =
  let log_fd = Unix.openfile log_path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600 in
  match Unix.fork () with
  | 0 ->
    (try
       Unix.dup2 log_fd Unix.stdout;
       Unix.dup2 log_fd Unix.stderr;
       Unix.close log_fd;
       Unix.execv "/bin/sh"
         [| "/bin/sh"; "-c";
            Printf.sprintf "ulimit -n %d && exec %s %d" ulimit_n
              (Filename.quote tcp_emfile_probe_path) port
         |]
     with _ -> Unix._exit 127)
  | child_pid ->
    Unix.close log_fd;
    child_pid

(* [Unix.WNOHANG] so this never blocks: [(0, _)] means the child has not changed state (i.e. is
   still running), any other result means it has exited (or, in principle, been stopped/signalled
   -- [run_accept_loop]'s own fatal path re-raises, which surfaces as a plain uncaught-exception
   exit, not a signal, so [WEXITED]/[WSIGNALED] are not distinguished here). *)
let emfile_probe_alive pid =
  match Unix.waitpid [ Unix.WNOHANG ] pid with
  | 0, _ -> true
  | _, _ -> false
  | exception Unix.Unix_error (Unix.ECHILD, _, _) -> false

let read_whole_file path =
  let ic = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in ic) (fun () -> really_input_string ic (in_channel_length ic))

let contains_substring ~needle haystack =
  let nl = String.length needle and hl = String.length haystack in
  let rec go i = (i + nl <= hl) && (String.sub haystack i nl = needle || go (i + 1)) in
  nl = 0 || go 0

(* Calibrated by a live run against today's (pre-fix) code, recorded in this task's own report:
   with [ulimit_n = 30] and 6 fds already spent by the probe's own startup (the listening socket,
   the RNG source, a couple of dynamic-linker/runtime fds), 50 concurrently-held raw connections
   (comfortably above the ~24 remaining) reliably drive real, sustained [EMFILE] on the probe's own
   [accept(2)] -- confirmed starting within the first ~15 consecutive failures and continuing
   uninterrupted. [num_flood_connections] is deliberately kept at or below [listen_backlog] (64,
   see that constant above): the kernel completes the TCP handshake for anything within the
   backlog whether or not the server's [accept(2)] ever successfully dequeues it, so every flood
   connection's own [Eio.Net.connect] returns promptly instead of one beyond the backlog blocking
   this test's own controller fiber on kernel-level SYN retries for far longer than intended (up to
   real [tcp_syn_retries] backoff, which can run well past this suite's 15s watchdog). 9s of
   sustained pressure is comfortably past [accept_max_consecutive_errors *. accept_error_backoff]
   (~6.4s, the OLD code's own fatal threshold) while still safely under the 15s watchdog once
   probe startup and the final recovery check are added in. *)
let test_emfile_on_accept_does_not_kill_the_listener () =
  let port = 19410 in
  let ulimit_n = 30 in
  let num_flood_connections = 50 in
  let pressure_duration = 9.0 in
  let log_path = Filename.temp_file "tcp_emfile_probe" ".log" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove log_path with Sys_error _ -> ())
    (fun () ->
      let child_pid = start_emfile_probe ~ulimit_n ~port ~log_path in
      Fun.protect
        ~finally:(fun () ->
          (* Best-effort teardown: this test never asks the probe to shut down gracefully (there
             is nothing graceful to ask for -- see [tcp_emfile_probe.ml]'s own comment), so a plain
             SIGKILL plus a reaping [waitpid] is enough to avoid leaking either the process or a
             zombie entry, whether the probe is still alive at this point or already exited on its
             own. *)
          (try Unix.kill child_pid Sys.sigkill with Unix.Unix_error _ -> ());
          let rec reap () =
            match Unix.waitpid [] child_pid with
            | _ -> ()
            | exception Unix.Unix_error (Unix.EINTR, _, _) -> reap ()
            | exception Unix.Unix_error (Unix.ECHILD, _, _) -> ()
          in
          reap ())
        (fun () ->
          Eio_main.run @@ fun env ->
          let net = Eio.Stdenv.net env in
          let clock = Eio.Stdenv.clock env in
          let addr : Eio.Net.Sockaddr.stream = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
          Eio.Switch.run (fun sw ->
              (* Bounded poll-connect: the same "not listening yet" idiom [Tcp.connect_to]'s own
                 dial loop uses, needed here because this probe's readiness has no other signal
                 this test synchronizes on. *)
              let rec wait_for_listener n =
                if n <= 0 then
                  Alcotest.failf
                    "tcp_emfile_probe never started listening on port %d within budget -- see %s \
                     for its own stdout/stderr"
                    port log_path
                else
                  match Eio.Net.connect ~sw net addr with
                  | flow -> (try Eio.Flow.close flow with End_of_file | Eio.Io _ -> ())
                  | exception Eio.Io _ ->
                    Eio.Time.sleep clock 0.05;
                    wait_for_listener (n - 1)
              in
              wait_for_listener 100;
              (* The flood: raw sockets, no TLS -- the point is a bare accepted fd held open on
                 the SERVER side, not a completed handshake. Every successful connect is held open
                 (read/written to not at all) for [pressure_duration] by its own fiber, which
                 closes it once that fiber's own sleep elapses; [Eio.Fiber.all] therefore does not
                 return until the full pressure window has elapsed AND every connection has been
                 released. *)
              let held = ref 0 in
              Eio.Fiber.all
                (List.init num_flood_connections (fun _ () ->
                     match Eio.Net.connect ~sw net addr with
                     | flow ->
                       incr held;
                       Eio.Time.sleep clock pressure_duration;
                       (try Eio.Flow.close flow with End_of_file | Eio.Io _ -> ())
                     | exception (Eio.Io _ | End_of_file) -> ()));
              Alcotest.(check bool)
                (Printf.sprintf
                   "the fd-exhaustion flood actually got through at the TCP level -- at least half \
                    of %d attempted connections were accepted by the kernel (got %d); otherwise \
                    this test is not exercising real EMFILE pressure at all"
                   num_flood_connections !held)
                true
                (!held >= num_flood_connections / 2);
              Alcotest.(check bool)
                (Printf.sprintf
                   "the probe (a real OS process under a real ulimit -n %d) is still alive after \
                    %.1fs of sustained accept-time fd exhaustion -- the pre-fix code re-raises and \
                    kills the listener once consecutive EMFILE failures cross \
                    accept_max_consecutive_errors (~6.4s); see %s for the probe's own log"
                   ulimit_n pressure_duration log_path)
                true
                (emfile_probe_alive child_pid);
              (* Recovery: with the flood released, a brand-new connection must still be
                 acceptABLE -- proof the *listener*, not merely the OS process, is still doing its
                 job, rather than e.g. wedged with every fd still consumed. *)
              (match Eio.Net.connect ~sw net addr with
              | flow -> (try Eio.Flow.close flow with End_of_file | Eio.Io _ -> ())
              | exception exn ->
                Alcotest.failf
                  "listener did not accept a fresh connection after the flood was released: %s (see \
                   %s for the probe's own log)"
                  (Printexc.to_string exn) log_path);
              let log = read_whole_file log_path in
              Alcotest.(check bool)
                "the probe's own log shows it actually hit a real EMFILE (Too many open files), not \
                 some other failure mode"
                true
                (contains_substring ~needle:"Too many open files" log))))

(* -- Area 10: a configurable, finite cap on the shared inbox (Task 30, Fix 1) --------------

   Regression test for the audit finding that [Eio.Stream.create max_int] (this module's shared
   receive-side inbox, fed by every connection's own reader fiber and drained by {!receive}/
   {!receive_nonblocking}) let a fast-sending peer grow this process's memory without bound if the
   local caller doesn't keep up -- reproduced by the audit at 20,000 x 64KiB. The fix makes the
   inbox's capacity finite and caller-configurable ([?inbox_capacity] on [Tcp.create]): once it is
   full, [reader_body]'s own call to [Eio.Stream.add] blocks the READER fiber itself, rather than
   accepting an unbounded backlog of not-yet-consumed messages.

   {b How this is observed without measuring real process RSS.} [receive_nonblocking] is a thin
   wrapper over [Eio.Stream.take_nonblocking], and this suite's own pinned Eio (0.12,
   [lib/eio/stream.ml]) documents and implements a specific, deterministic hand-off: draining one
   item from a FULL bounded stream immediately (synchronously, within the very same
   [take_nonblocking] call, before the blocked writer's own fiber ever gets a scheduler tick) moves
   the single writer that was blocked trying to add the next item into the queue -- see that
   module's own [add]/[take] comments ("This is called directly from [wake_one] ... We get here
   immediately when called by [take], after removing an item, so there is space"). [reader_body]'s
   loop only ever has ONE [Eio.Stream.add] call in flight at a time (it reads one frame, then tries
   to add it, in strict sequence) -- so at most one write can ever be sitting blocked waiting for
   room. Combining the two facts: draining this test's peer's inbox in a tight loop (no sleep or
   other yield point between iterations, so the reader fiber's OWN continuation never actually gets
   to run and attempt a THIRD item) surfaces exactly [inbox_capacity] items already queued plus the
   one single item the blocked reader hands off on the very first drain call -- [inbox_capacity + 1]
   total -- never more, and, crucially, never anywhere close to the far larger number of messages
   actually sent, which is exactly the bound this fix exists to prove. *)
let test_inbox_capacity_is_bounded_not_unbounded () =
  let peer_specs = [ (1, "127.0.0.1", 19401); (2, "127.0.0.1", 19402) ] in
  let inbox_capacity = 5 in
  let total_sent = 200 in
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  try
    Eio.Switch.run (fun sw ->
        let handles = Hashtbl.create 2 in
        Eio.Fiber.all
          (List.map
             (fun (my_id, _, _) ->
               fun () ->
                 let t =
                   Tcp.create ~sw ~net ~clock ~my_id ~peers:peer_specs ~tls:(peer_identity my_id)
                     ~inbox_capacity ()
                 in
                 Hashtbl.replace handles my_id t)
             peer_specs);
        let a = Hashtbl.find handles 1 and b = Hashtbl.find handles 2 in
        (* Peer 2 never calls [receive]/[receive_nonblocking] until the drain below -- exactly the
           "local caller doesn't keep up" scenario the audit's own finding describes. *)
        for i = 1 to total_sent do
          Tcp.send a ~to_:2 (Printf.sprintf "msg-%d" i)
        done;
        (* Real wall-clock time for peer 2's reader fiber to actually run: read every frame already
           sitting in the (tiny, real-loopback) socket buffer and push as many as it can into its
           now-bounded inbox before blocking trying to push the next one. Generous relative to real
           loopback IPC of a few hundred tiny messages. *)
        Eio.Time.sleep clock 0.3;
        let drained = ref 0 in
        let rec drain () =
          match Tcp.receive_nonblocking b with
          | Some _ ->
            incr drained;
            drain ()
          | None -> ()
        in
        drain ();
        Alcotest.(check int)
          (Printf.sprintf
             "peer 2's inbox holds exactly its configured capacity plus the one item its reader was \
              blocked trying to add (%d), not anywhere near all %d messages peer 1 actually sent"
             (inbox_capacity + 1) total_sent)
          (inbox_capacity + 1) !drained;
        Eio.Switch.fail sw Test_mesh_torn_down)
  with Test_mesh_torn_down -> ()

(* -- Area 11: a read-idle timeout closes an established connection that goes silent (Task 30,
   Fix 2) ---------------------------------------------------------------------------------------

   Regression test for the audit finding that an established connection (past both existing
   handshake-layer bounded waits) could be held open, completely silent, forever -- there was no
   timeout anywhere in [reader_body]'s post-handshake frame-read loop. The fix wraps ONLY the wait
   for the next frame in [Eio.Time.with_timeout clock t.read_idle_timeout], the same mechanism
   [tls_handshake_timeout]/[preamble_read_timeout] already use one layer earlier -- see
   [default_read_idle_timeout]'s own comment in [tcp.ml] for why its production default (30 minutes)
   is nowhere near [tls_handshake_timeout]/[preamble_read_timeout]'s ~10s, and for the disclosed,
   real residual risk (a sufficiently long but genuinely healthy quiet period is indistinguishable
   from a dead connection at this layer, and tcp.mli's own "no reconnection once established"
   limitation makes this timeout's closure of the former PERMANENT).

   This test passes a SHORT, test-only [~read_idle_timeout] explicitly -- never the real ~30-minute
   default, which would make this test take real minutes even on a real clock, and would still be
   the wrong thing to assert against even on a mock one (this test is about proving the mechanism
   the parameter wires up, not re-deriving the production default's own justification). Like
   [test_dial_side_tls_handshake_has_a_bounded_timeout] above, it uses an [Eio_mock.Clock] (the same
   virtual-time mechanism [lib/sim/network.ml] already uses for [Riptide_sim]) so the timeout fires
   near-instantly and deterministically regardless of the configured value, instead of either
   sleeping for real or racing the assertion against wall-clock flakiness.

   A raw TCP listener again stands in for peer 2 (as in that same earlier test), except this one
   DOES complete a real mutual-TLS handshake -- proving the connection genuinely reaches
   "established", past both existing bounded waits -- and then goes completely silent forever,
   never writing a single byte back (correct behavior for peer 2's role here regardless: only the
   DIALER writes a handshake preamble; the accepting side never sends one back -- see tcp.mli's wire
   format section). That silence is exactly the "genuinely established, then nothing, ever" shape
   [read_idle_timeout] exists to bound. *)
exception Read_idle_timeout_probe_done

let test_established_connection_is_closed_after_read_idle_timeout () =
  let peer_specs = [ (1, "127.0.0.1", 19421); (2, "127.0.0.1", 19422) ] in
  let read_idle_timeout = 5.0 (* short, test-only value; see this test's own comment above for why
                                  the real ~30-minute default is deliberately not used here *) in
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let real_clock = Eio.Stdenv.clock env in
  let mock_clock = Eio_mock.Clock.make () in
  let clock_for_tcp : float Eio.Time.clock_ty Eio.Std.r =
    (mock_clock :> float Eio.Time.clock_ty Eio.Std.r)
  in
  let t1 = ref None in
  (try
     Eio.Switch.run (fun sw ->
         let listener =
           Eio.Net.listen ~reuse_addr:true ~backlog:1 ~sw net
             (`Tcp (Eio.Net.Ipaddr.V4.loopback, 19422))
         in
         Eio.Fiber.both
           (fun () ->
             (* Stand in for peer 2: accept the TCP connection and complete a real mutual-TLS
                handshake, so the connection genuinely reaches "established" -- then go completely
                silent forever. [sw] keeps the fd alive after this fiber moves on. *)
             let flow, _addr = Eio.Net.accept ~sw listener in
             let tls_flow =
               Tls_eio.server_of_flow (Tls_identity.server_config (peer_identity 2)) flow
             in
             ignore tls_flow)
           (fun () ->
             let t =
               Tcp.create ~sw ~net ~clock:clock_for_tcp ~my_id:1 ~peers:peer_specs
                 ~tls:(peer_identity 1) ~read_idle_timeout ()
             in
             t1 := Some t);
         (* Both branches above have completed: peer 1's [Tcp.create] has returned (a dialed
            connection's outbound path is ready as soon as the handshake completes -- see tcp.mli's
            own [create] doc -- it does not wait on the reader loop this timeout lives in), and peer
            2's stand-in has finished its own handshake and gone silent. The read-idle timeout wait
            registered by peer 1's background reader fiber may not have been scheduled to actually
            run yet at this exact point, so poll (on the REAL clock) until advancing the mock clock
            succeeds -- the same robust idiom
            [test_dial_side_tls_handshake_has_a_bounded_timeout] above uses, for the same reason. *)
         let rec wait_for_timeout_job () =
           match Eio_mock.Clock.advance mock_clock with
           | () -> ()
           | exception Invalid_argument _ ->
             Eio.Time.sleep real_clock 0.02;
             wait_for_timeout_job ()
         in
         wait_for_timeout_job ();
         (* Give the now-unblocked reader fiber a moment on the real clock to actually run its
            timeout-handling code path (log, end the loop, let [Eio.Fiber.first] cancel the writer,
            remove the [t.writers] entry) before this test inspects the result. *)
         Eio.Time.sleep real_clock 0.05;
         Eio.Switch.fail sw Read_idle_timeout_probe_done)
   with Read_idle_timeout_probe_done -> ());
  let t1 = match !t1 with Some t -> t | None -> Alcotest.fail "peer 1's Tcp.create never returned" in
  (* The connection is now closed from peer 1's own perspective: [run_connection] has removed its
     [writers] entry for peer 2 once both the (timed-out) reader and the (cancelled) writer
     confirmed the connection dead, so a subsequent [send] is refused exactly the way tcp.mli's
     "Send failures" section documents for a connection "established and has since been confirmed
     dead" -- not held open silently forever. *)
  Alcotest.check_raises
    "peer 1's connection to peer 2 is closed after the read-idle timeout elapses with no frame \
     received, not held open forever"
    (Invalid_argument "Tcp.send: no connection to peer 2")
    (fun () -> Tcp.send t1 ~to_:2 "x")

let tests =
  [ ("three-peer mesh: bidirectional delivery on every pairwise connection", `Quick,
      test_three_peer_mesh_bidirectional_delivery);
    ("framing boundary: back-to-back sends stay distinct, byte-exact", `Quick,
      test_framing_boundary_back_to_back_messages_stay_distinct);
    ("no cross-peer misattribution under concurrent traffic", `Quick,
      test_no_cross_peer_misattribution_under_concurrent_traffic);
    ("create waits for the specific expected peers, not merely that many connections", `Quick,
      test_create_waits_for_the_specific_expected_peers);
    ("receive attributes a message to the certificate's id, not a differing preamble claim",
      `Quick, test_receive_follows_the_certificate_not_the_preamble_claim);
    ("second connection claiming an already-connected id is refused", `Quick,
      test_second_connection_claiming_already_connected_id_is_refused);
    ("mTLS: a mutual handshake between two CA-signed peers succeeds and carries bytes", `Quick,
      test_mutual_handshake_between_two_ca_signed_peers_succeeds);
    ("mTLS: the server rejects a client certificate signed by an unrelated CA", `Quick,
      test_server_rejects_a_client_certificate_from_an_unrelated_ca);
    ("mTLS: the server rejects a client presenting no certificate at all", `Quick,
      test_server_rejects_a_client_presenting_no_certificate);
    ("mTLS: the dialer rejects a server certificate signed by an unrelated CA", `Quick,
      test_dialer_rejects_a_server_certificate_from_an_unrelated_ca);
    ("mTLS: the dialer's first bytes on the raw wire are a TLS handshake, not the preamble",
      `Quick, test_first_bytes_on_the_wire_are_a_tls_handshake);
    ("mTLS identity: a private key not matching its certificate is rejected at construction",
      `Quick, test_identity_rejects_a_key_that_does_not_match_its_certificate);
    ("mTLS identity: a certificate the trust anchor did not issue is rejected at construction",
      `Quick, test_identity_rejects_a_certificate_its_trust_anchor_did_not_issue);
    ("mTLS: the dial-side TLS handshake has a bounded timeout, not an unbounded hang", `Quick,
      test_dial_side_tls_handshake_has_a_bounded_timeout);
    ("send refuses an id outside the configured membership", `Quick,
      test_send_refuses_an_id_outside_the_configured_membership);
    ("accept loop caps the number of concurrently accepted connections", `Quick,
      test_accept_loop_caps_concurrent_connections);
    ("EMFILE on accept does not kill the listener", `Quick,
      test_emfile_on_accept_does_not_kill_the_listener);
    ("the shared inbox has a finite, configurable capacity, not an unbounded one", `Quick,
      test_inbox_capacity_is_bounded_not_unbounded);
    ("an established connection that goes silent is closed after its read-idle timeout", `Quick,
      test_established_connection_is_closed_after_read_idle_timeout)
  ]
