(* See tcp.mli for the wire format (handshake preamble + length-prefixed framing) and connection
   topology (lower id dials higher id) this module implements. *)

(* How long to wait between connection attempts, and how many times to retry, when dialing a peer
   that hasn't started listening yet. This is bootstrap-only: it exists purely for "the rest of
   this small, fixed cluster is still starting up", not general reconnection (explicitly out of
   scope -- see tcp.mli). 100ms * 200 = up to 20s total, generous for a cluster starting on one
   machine or a handful of nearby ones. *)
let connect_retry_delay = 0.1
let connect_max_retries = 200

(* Backlog for the listening socket. This is a small, fixed cluster, so a generous constant is
   simpler than trying to size it from [peers]. *)
let listen_backlog = 64

(* Upper bound on a single message's size, used only to size Eio.Buf_read's internal buffer.
   Generous since [Transport.S] payloads are arbitrary caller-encoded bytes (e.g. whole VSR log
   entries) with no size negotiation at this layer. *)
let max_message_size = 64 * 1024 * 1024

type t = {
  my_id : int;
  inbox : string Eio.Stream.t;
  (* One entry per live outbound connection, keyed by the *remote* peer's id: the [Eio.Buf_write.t]
     to write framed messages to in order to reach that peer. Populated by both the dialing path
     (connect_to) and the accepting path (handle_accepted) as connections come up. *)
  writers : (int, Eio.Buf_write.t) Hashtbl.t;
  (* Broadcast every time an entry is added to [writers], so [create] can block until the whole
     mesh implied by [peers] is up without busy-polling [writers]'s length. *)
  writer_added : Eio.Condition.t;
}

let addr_of_host_port host port : Eio.Net.Sockaddr.stream =
  `Tcp (Eio_unix.Net.Ipaddr.of_unix (Unix.inet_addr_of_string host), port)

(* -- Framing -- *)

let write_frame w bytes =
  Eio.Buf_write.BE.uint64 w (Int64.of_int (String.length bytes));
  Eio.Buf_write.string w bytes

let read_frame r =
  let len = Eio.Buf_read.BE.uint64 r |> Int64.to_int in
  Eio.Buf_read.take len r

(* -- Handshake preamble (see tcp.mli) -- *)

let write_preamble w my_id = Eio.Buf_write.BE.uint64 w (Int64.of_int my_id)
let read_preamble r = Eio.Buf_read.BE.uint64 r |> Int64.to_int

let register_writer t peer_id w =
  Hashtbl.replace t.writers peer_id w;
  Eio.Condition.broadcast t.writer_added

(* Runs for the lifetime of the connection to [peer_id]: owns the Eio.Buf_write.t for that
   connection (registering it in [t.writers] as soon as it exists, so [send] can find it), sends
   the handshake preamble first if this is the dialing side, then just keeps the connection's
   write side alive until the enclosing switch tears it down. Meant to be run in its own forked
   fiber -- [Eio.Buf_write.with_flow]'s own background copy fiber is what actually performs the
   socket writes as data is buffered here. *)
let run_writer t ~is_dialer peer_id flow =
  Eio.Buf_write.with_flow flow (fun w ->
      if is_dialer then write_preamble w t.my_id;
      register_writer t peer_id w;
      Eio.Fiber.await_cancel ())

(* Runs for the lifetime of a connection's read side: loops decoding length-prefixed frames and
   pushing their payload bytes onto the shared inbox for this local peer. Ends quietly on
   End_of_file/connection reset -- once a connection is gone this module does not try to
   re-establish it (see tcp.mli), so there is nothing more for this fiber to do. *)
let run_reader t r =
  try
    while true do
      let payload = read_frame r in
      Eio.Stream.add t.inbox payload
    done
  with
  | End_of_file -> ()
  | Eio.Io _ -> ()

let handle_accepted t ~sw flow =
  let r = Eio.Buf_read.of_flow flow ~max_size:max_message_size in
  let peer_id = read_preamble r in
  Eio.Fiber.fork ~sw (fun () -> run_writer t ~is_dialer:false peer_id flow);
  run_reader t r

let connect_to t ~sw ~net ~clock ~host ~port peer_id =
  let addr = addr_of_host_port host port in
  let rec attempt n =
    match Eio.Net.connect ~sw net addr with
    | flow -> flow
    | exception exn ->
      if n <= 0 then raise exn
      else begin
        Eio.Time.sleep clock connect_retry_delay;
        attempt (n - 1)
      end
  in
  let flow = attempt connect_max_retries in
  Eio.Fiber.fork ~sw (fun () -> run_writer t ~is_dialer:true peer_id flow);
  Eio.Fiber.fork ~sw (fun () ->
      let r = Eio.Buf_read.of_flow flow ~max_size:max_message_size in
      run_reader t r)

let create ~sw ~net ~clock ~my_id ~peers =
  let my_host, my_port =
    match List.find_opt (fun (id, _, _) -> id = my_id) peers with
    | Some (_, host, port) -> (host, port)
    | None -> invalid_arg (Printf.sprintf "Tcp.create: my_id %d not present in peers" my_id)
  in
  let t =
    { my_id;
      inbox = Eio.Stream.create max_int;
      writers = Hashtbl.create (List.length peers);
      writer_added = Eio.Condition.create ();
    }
  in
  let listener =
    Eio.Net.listen ~reuse_addr:true ~backlog:listen_backlog ~sw net
      (addr_of_host_port my_host my_port)
  in
  Eio.Fiber.fork ~sw (fun () ->
      while true do
        Eio.Net.accept_fork ~sw listener
          ~on_error:(fun exn -> Eio.traceln "Tcp: accept/handshake error: %s" (Printexc.to_string exn))
          (fun flow _addr -> handle_accepted t ~sw flow)
      done);
  List.iter
    (fun (peer_id, host, port) ->
      if peer_id > my_id then connect_to t ~sw ~net ~clock ~host ~port peer_id)
    peers;
  let expected = List.length peers - 1 in
  if expected > 0 then
    Eio.Condition.loop_no_mutex t.writer_added (fun () ->
        if Hashtbl.length t.writers >= expected then Some () else None);
  t

let send t ~to_ bytes =
  match Hashtbl.find_opt t.writers to_ with
  | Some w -> write_frame w bytes
  | None -> invalid_arg (Printf.sprintf "Tcp.send: no connection to peer %d" to_)

let receive t = Eio.Stream.take t.inbox
let receive_nonblocking t = Eio.Stream.take_nonblocking t.inbox
