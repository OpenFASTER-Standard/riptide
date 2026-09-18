(* See tcp.mli for the wire format (handshake preamble + length-prefixed framing) and connection
   topology (lower id dials higher id) this module implements. *)

(* How long to wait between connection attempts, and how many times to retry, when dialing a peer
   that hasn't started listening yet. This is bootstrap-only: it exists purely for "the rest of
   this small, fixed cluster is still starting up", not general reconnection (explicitly out of
   scope -- see tcp.mli). 100ms * 200 = up to 20s total, generous for a cluster starting on one
   machine or a handful of nearby ones. *)
let connect_retry_delay = 0.1
let connect_max_retries = 200

(* Bound on how long [create] will wait for the rest of the mesh implied by [peers] to finish
   connecting+handshaking, once dialing itself has either succeeded or exhausted its own retries
   above. Reuses the dial loop's own total budget (also ~20s): if every dial that was going to
   succeed has already done so well within that window, waiting much longer for the *accepting*
   side to complete isn't buying anything -- it just turns a misconfigured/late cluster into an
   unexplained hang instead of a clear error (see [Mesh_formation_timeout] below). *)
let mesh_formation_timeout = connect_retry_delay *. float_of_int connect_max_retries

(* Backlog for the listening socket. This is a small, fixed cluster, so a generous constant is
   simpler than trying to size it from [peers]. *)
let listen_backlog = 64

(* Hard upper bound on a single message's size: [Buf_read.of_flow]'s [~max_size] (so a peer that
   claims a frame longer than this gets rejected via [Frame_too_large] below, rather than this
   process trying to allocate an unbounded buffer for it), and [send]'s own cap on outgoing
   messages so the two sides agree on the limit instead of a sender being able to "successfully"
   queue something the receiver is guaranteed to reject (see M1 in the fix-round report). Generous
   since [Transport.S] payloads are arbitrary caller-encoded bytes (e.g. whole VSR log entries)
   with no size negotiation at this layer. *)
let max_message_size = 64 * 1024 * 1024

(* Raised by [read_frame] when a peer's declared frame length is negative (possible via
   [Int64.to_int] truncation of a hostile or corrupt 8-byte length prefix) or exceeds
   [max_message_size]. Caught by [run_reader] right next to it, so this never needs to escape this
   module -- it exists as a named exception (rather than e.g. reusing [End_of_file]) purely so a
   [Tcp: connection error] log line can say *why* a connection was dropped instead of looking
   identical to an ordinary disconnect. *)
exception Frame_too_large of int

type t = {
  my_id : int;
  inbox : string Eio.Stream.t;
  (* One entry per live outbound connection, keyed by the *remote* peer's id: the [Eio.Buf_write.t]
     to write framed messages to in order to reach that peer. Populated by both the dialing path
     (connect_to) and the accepting path (handle_accepted) as connections come up, and removed by
     [run_writer] once it detects that connection is dead (see the fix-round report's H1/M3
     discussion for why cleanup lives there and not in [run_reader]). *)
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
  (* Bounds-check before ever calling [take]: a raw 8-byte prefix of e.g. all-1-bits truncates via
     [Int64.to_int] to a negative OCaml [int], which [Buf_read.take] itself would reject with
     [Invalid_argument "take: -1 is negative!"] -- and a merely very large (but non-negative)
     length would otherwise reach the [~max_size] limit inside [take]/[ensure] and raise
     [Buf_read.Buffer_limit_exceeded] there instead. Checking here catches both cases in one place,
     with one clear, dedicated exception, rather than relying on whatever stdlib/Eio exception two
     different downstream failure paths happen to raise. *)
  if len < 0 || len > max_message_size then raise (Frame_too_large len);
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
   write side alive until either the enclosing switch tears it down or the connection dies.

   [Eio.Buf_write.with_flow]'s own background copy fiber is what actually performs the socket
   writes as data is buffered here -- and critically, if *that* fiber's write fails (e.g. the peer
   crashed: [Eio.Io Net Connection_reset], "broken pipe"), the exception propagates out of
   [with_flow] itself, not just out of some inner callback. Before this fix-round, that exception
   propagated all the way out of the bare [Eio.Fiber.fork] this runs in and failed the *caller's*
   switch -- i.e. one crashed peer's write failure killed this entire process, and every other
   still-healthy connection with it (H1 in the fix-round report). [End_of_file]/[Eio.Io] are
   caught here for exactly that reason, mirroring [run_reader]'s existing handling of the same
   fault class. [Eio.Cancel.Cancelled] is deliberately NOT caught: that means the enclosing switch
   itself is shutting down, which must be allowed to propagate normally rather than being
   swallowed.

   Once the connection is confirmed dead (by either exception, not by a graceful [with_flow]
   return, since this fiber's body -- [Eio.Fiber.await_cancel ()] -- never returns normally), the
   stale [t.writers] entry is removed so a subsequent [send] to this peer gets the existing,
   synchronous, catchable "no connection to peer N" [Invalid_argument] (tcp.ml, [send], below)
   instead of silently buffering into a writer that will never reach the peer again (M3 in the
   fix-round report). Meant to be run in its own forked fiber. *)
let run_writer t ~is_dialer peer_id flow =
  (try
     Eio.Buf_write.with_flow flow (fun w ->
         if is_dialer then write_preamble w t.my_id;
         register_writer t peer_id w;
         Eio.Fiber.await_cancel ())
   with
   | End_of_file -> ()
   | Eio.Io _ -> ());
  Hashtbl.remove t.writers peer_id

(* Runs for the lifetime of a connection's read side: loops decoding length-prefixed frames and
   pushing their payload bytes onto the shared inbox for this local peer. Ends quietly (this
   module does not try to re-establish a dead connection -- see tcp.mli) on:
   - [End_of_file]/[Eio.Io _]: the connection closed or reset;
   - [Frame_too_large]: the peer's declared frame length was negative or over [max_message_size];
   - [Buf_read.Buffer_limit_exceeded]/[Invalid_argument]: defense in depth for the same class of
     malformed-length input as [Frame_too_large], in case some other path into this loop ever
     produces it directly instead of going through [read_frame]'s own check.

   This same function is used for both accepted and dialed connections' read sides. Before this
   fix-round only the accepted side was effectively protected against non-[End_of_file]/[Eio.Io]
   failures -- not by anything in this function, but incidentally, because [accept_fork]'s
   [~on_error] wraps the whole connection handler. The dialed side's reader is a bare
   [Eio.Fiber.fork] with no equivalent wrapper, so the same malformed input that an accepted
   connection survived was fatal on a dialed one (H2 in the fix-round report). Catching the full
   set here, in the shared function, fixes both call sites at once and makes them symmetric by
   construction rather than by relying on which side happens to have an outer guard. *)
let run_reader t r =
  try
    while true do
      let payload = read_frame r in
      Eio.Stream.add t.inbox payload
    done
  with
  | End_of_file -> ()
  | Eio.Io _ -> ()
  | Frame_too_large len ->
    Eio.traceln "Tcp: connection error: peer declared a frame of %d bytes (max %d); dropping connection"
      len max_message_size
  | Eio.Buf_read.Buffer_limit_exceeded | Invalid_argument _ as exn ->
    Eio.traceln "Tcp: connection error: %s; dropping connection" (Printexc.to_string exn)

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
          ~on_error:(fun exn -> Eio.traceln "Tcp: connection error: %s" (Printexc.to_string exn))
          (fun flow _addr -> handle_accepted t ~sw flow)
      done);
  List.iter
    (fun (peer_id, host, port) ->
      if peer_id > my_id then connect_to t ~sw ~net ~clock ~host ~port peer_id)
    peers;
  let expected = List.length peers - 1 in
  if expected > 0 then begin
    match
      Eio.Time.with_timeout clock mesh_formation_timeout (fun () ->
          Eio.Condition.loop_no_mutex t.writer_added (fun () ->
              if Hashtbl.length t.writers >= expected then Some () else None);
          Ok ())
    with
    | Ok () -> ()
    | Error `Timeout ->
      let missing =
        List.filter_map
          (fun (id, _, _) -> if id <> my_id && not (Hashtbl.mem t.writers id) then Some id else None)
          peers
      in
      failwith
        (Printf.sprintf
           "Tcp.create: timed out after %.1fs waiting for the mesh to form; still missing connection(s) to peer(s) [%s]"
           mesh_formation_timeout
           (String.concat "; " (List.map string_of_int missing)))
  end;
  t

let send t ~to_ bytes =
  if String.length bytes > max_message_size then
    invalid_arg
      (Printf.sprintf "Tcp.send: message of %d bytes exceeds max_message_size (%d bytes)"
         (String.length bytes) max_message_size)
  else
    match Hashtbl.find_opt t.writers to_ with
    | Some w -> write_frame w bytes
    | None -> invalid_arg (Printf.sprintf "Tcp.send: no connection to peer %d" to_)

let receive t = Eio.Stream.take t.inbox
let receive_nonblocking t = Eio.Stream.take_nonblocking t.inbox
