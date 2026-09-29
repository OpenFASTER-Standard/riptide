(* See tcp.mli for the wire format (handshake preamble + length-prefixed framing) and connection
   topology (lower id dials higher id) this module implements. *)

(* How long to wait between connection attempts, and how many times to retry, when dialing a peer
   that hasn't started listening yet. This is bootstrap-only: it exists purely for "the rest of
   this small, fixed cluster is still starting up", not general reconnection (explicitly out of
   scope -- see tcp.mli). 100ms * 200 = up to 20s total, generous for a cluster starting on one
   machine or a handful of nearby ones. *)
let connect_retry_delay = 0.1
let connect_max_retries = 200
let dial_timeout = connect_retry_delay *. float_of_int connect_max_retries

(* Bound on how long [create] will wait, after dialing itself has either succeeded or exhausted
   its own retries above, for the rest of the mesh implied by [peers] to finish
   connecting+handshaking. Reuses the dial loop's own total budget (also ~20s): if every dial that
   was going to succeed has already done so well within that window, waiting much longer for the
   *accepting* side to complete isn't buying anything -- it just turns a misconfigured/late
   cluster into an unexplained hang instead of a clear error. Note this is a SECOND, independent
   ~20s budget stacked after the dial loop's own, and the dial loop runs SEQUENTIALLY over every
   higher-id peer: [create]'s real worst-case wall-clock time is
   [dial_timeout *. (number of higher-id peers) +. mesh_formation_timeout], not just this constant
   on its own -- see the [@raise Failure] note on [create] in tcp.mli. *)
let mesh_formation_timeout = dial_timeout

(* Bound on how long an ACCEPTED connection is given to send its 8-byte handshake preamble (see
   tcp.mli) before it is dropped. Without a bound, any party that can reach the listening port can
   open a connection, send nothing, and park a fiber plus an fd here for the lifetime of the
   process -- and accumulating stuck fds is precisely what walks this process toward the [EMFILE]
   the accept loop below has to survive. Generous relative to the real case (the dialing side
   writes its preamble immediately after [connect] returns, before anything else), so this only
   ever fires for a peer that is not speaking this protocol at all, or is wedged. *)
let preamble_read_timeout = 10.0

(* The same bound, for the same reason, one layer earlier: how long an ACCEPTED connection is
   given to complete its TLS handshake before it is dropped. This one is load-bearing in exactly
   the way [preamble_read_timeout] is, and would be easy to lose by accident: with mutual TLS in
   front of it, the preamble timeout above no longer protects the listener on its own, because a
   connection that opens and then says nothing at all now parks inside [Tls_eio.server_of_flow]
   and never reaches the preamble read. Anyone who can route to this port can still do that
   without holding any certificate, so this is the bound that keeps "open a socket and go quiet"
   from costing an fd and a fiber for the lifetime of the process. *)
let tls_handshake_timeout = 10.0

(* Error handling for the listener's accept loop. [Eio.Net.accept_fork]'s [~on_error] covers only
   the per-connection handler fiber, NOT the [accept(2)] call itself, so a transient OS-level
   accept failure ([EMFILE]/[ENFILE] fd exhaustion, [ECONNABORTED] from a client that resets
   between SYN and accept, [ENOBUFS]) would otherwise escape the loop, fail the whole transport's
   switch, and take every already-established connection -- and typically the process -- with it.
   A single failed accept must cost at most the one connection it was for.

   The loop therefore logs and retries, pausing [accept_error_backoff] first so a listener that is
   failing continuously degrades into a slow log rather than a busy loop (a busy loop is invisible
   to Eio's own deadlock detection and to the test suite's watchdog). But retrying forever would
   turn a PERMANENT failure -- the listening socket itself closed, say -- into a silent,
   unbounded log spin with no way for the caller to ever learn about it, and this module exposes
   no error channel other than raising. So consecutive failures are counted (the count resets on
   every successful accept, so unrelated transient blips never accumulate into a shutdown) and
   once the budget is spent the last exception is re-raised, surfacing on [sw] the way an
   unrecoverable listener failure should. 64 * 0.1s means roughly 6s of uninterrupted failure
   before that happens -- far longer than any transient condition here plausibly lasts, far
   shorter than "never". *)
let accept_error_backoff = 0.1
let accept_max_consecutive_errors = 64

(* Backlog for the listening socket. This is a small, fixed cluster, so a generous constant is
   simpler than trying to size it from [peers]. *)
let listen_backlog = 64

(* Hard upper bound on a single message's size: [Buf_read.of_flow]'s [~max_size] (so a peer that
   claims a frame longer than this gets rejected via [Frame_too_large] below, rather than this
   process trying to allocate an unbounded buffer for it), and [send]'s own cap on outgoing
   messages so the two sides agree on the limit instead of a sender being able to "successfully"
   queue something the receiver is guaranteed to reject. Generous since [Transport.S] payloads are
   arbitrary caller-encoded bytes (e.g. whole VSR log entries) with no size negotiation at this
   layer. *)
let max_message_size = 64 * 1024 * 1024

(* Raised by [read_frame] when a peer's declared frame length is negative (possible via
   [Int64.to_int] truncation of a hostile or corrupt 8-byte length prefix) or exceeds
   [max_message_size]. Caught by [reader_body] right next to it, so this never needs to escape
   this module -- it exists as a named exception (rather than e.g. reusing [End_of_file]) purely
   so a [Tcp: connection error] log line can say *why* a connection was dropped instead of looking
   identical to an ordinary disconnect. *)
exception Frame_too_large of int

(* Raised by [connect_to] when the TLS handshake with a dialed peer fails, so that [create] can
   report it as the distinct, named cause it is rather than folding it into the "gave up dialing"
   message that a peer which never accepted a TCP connection at all produces. The two are very
   different operational problems -- a certificate/trust misconfiguration versus an unreachable or
   not-yet-started peer -- and a single message covering both would send an operator looking in
   the wrong place. Never escapes this module: [create] converts it to the documented [Failure]. *)
exception Tls_handshake_failed of exn

(* Raised by [register_writer] when a connection attempts to claim a peer id whose entry in the
   writers table is still LIVE -- see [register_writer] below. A dead entry (its [Eio.Buf_write.t]
   already closed, the same liveness check [send] itself uses) does not raise this: the table only
   ever drops an entry once both the reader and writer fibers of the connection that installed it
   have confirmed it is done (see the [writers] field's own doc comment on [t] above), so a real
   reconnect from the same peer can otherwise still find a stale, not-yet-cleaned-up entry here and
   must be let through rather than wrongly rejected as a duplicate. Never escapes this module:
   [writer_body] catches it and closes the connection, so this exists as a named exception purely
   so a [Tcp: connection error] log line can say *why* a connection was dropped rather than looking
   identical to an ordinary disconnect, the same discipline as [Frame_too_large] and
   [Unauthenticated_peer] above. *)
exception Duplicate_connection_id of int

(* [Printexc.to_string] renders [Tls_eio]'s two exceptions as bare constructor names with no
   payload ("Tls_eio.Tls_failure(_)"), which is useless in a log line or an error message when the
   whole question is *why* a handshake was refused. Both carry a printable payload; this uses it.
   Everything else falls through to [Printexc]. *)
let describe_exn = function
  | Tls_eio.Tls_failure f -> "TLS failure: " ^ Fmt.to_to_string Tls.Engine.pp_failure f
  | Tls_eio.Tls_alert a -> "TLS alert from peer: " ^ Tls.Packet.alert_type_to_string a
  | Duplicate_connection_id peer_id ->
    Printf.sprintf "a second connection claiming peer id %d (already connected)" peer_id
  | exn -> Printexc.to_string exn

type t = {
  my_id : int;
  (* The two TLS configurations this peer uses, derived once (in [Tls_identity.create], before
     [create] is even called) from this replica's CA/certificate/key: [tls_client] for every
     connection this peer dials, [tls_server] for every connection it accepts. Both carry an
     authenticator built from the same trust anchor, which is what makes every connection in the
     mesh mutually authenticated in both directions -- see tls_identity.mli. *)
  tls : Tls_identity.t;
  (* Each element is [(payload, sender)], where [sender] is the id [authenticated_peer_id] (see
     below) decoded from the certificate actually presented on the connection the message arrived
     on -- never the handshake preamble's claim. [reader_body] is the only producer. *)
  inbox : (string * int) Eio.Stream.t;
  (* One entry per live connection, keyed by the *remote* peer's id: the [Eio.Buf_write.t] to
     write framed messages to in order to reach that peer. Populated by both the dialing path
     (connect_to) and the accepting path (handle_accepted) as connections come up, via
     [register_writer]. Every connection that gets this far has completed mutual TLS, so an entry
     here always belongs to a holder of a certificate this cluster's CA issued -- but the *key*
     under which it is stored is still the one the handshake preamble claimed, and nothing yet
     binds that key to the certificate that was actually presented on the connection it names.

     This is narrower than it used to be, not the same residual gap restated: {!receive} (via
     [reader_body]/[authenticated_peer_id]) now reports a real, certificate-bound sender for every
     delivered message, so a peer can no longer make itself appear, to the code actually consuming
     messages, as a cluster member it is not. What remains open is [send]-side routing: this table
     decides which live connection a given outbound peer id resolves to, and that decision is
     still keyed by the preamble, so a cluster member can still cause a peer's OWN outbound
     messages to route to a connection the attacker holds (rather than forging what the receiving
     side believes about a message it receives). A second connection claiming an id whose entry
     here is still LIVE is refused rather than replacing it (see [register_writer] and
     [Duplicate_connection_id]); one claiming an id whose entry is already dead (the old holder's
     [Eio.Buf_write.t] closed, but not yet removed -- see below) is let through, the same as the
     old plain-[Hashtbl.replace] behavior, so a legitimate reconnect is never wrongly rejected. See
     tcp.mli's "Authentication" section for the precise boundary. An entry is removed by
     [run_connection] once that connection's reader and writer fibers have BOTH confirmed the
     connection is dead -- see [run_connection] for why cleanup only happens there, coupled,
     rather than independently in whichever of the reader/writer notices death first. *)
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

(* -- Deriving the authenticated sender from the peer's actual TLS certificate -- *)

(* Raised by [authenticated_peer_id] when the certificate [Tls_eio.epoch] reports as verified on a
   connection does not encode a usable replica id -- no certificate at all (unreachable once a
   mutual-TLS handshake has actually completed, since both [Tls_identity.client_config] and
   [Tls_identity.server_config] set a required/optional [authenticator] that only ever accepts a
   chain rooted at [trust_anchor], but checked here rather than assumed, since this function must
   never crash the process over a peer whose certificate is merely unusual), no SubjectAltName DNS
   entry, more than one, or a SAN whose leftmost DNS label carries no trailing decimal digits.
   Caught by [reader_body] right next to where it matters, exactly like [Frame_too_large] above --
   this exists as a named exception, rather than reusing [Failure]/[Invalid_argument], purely so a
   [Tcp: connection error] log line can say *why* a connection was dropped. *)
exception Unauthenticated_peer of string

(* The authenticated sender id for [flow]: decoded from the SubjectAltName of the certificate
   [Tls_eio.epoch] reports as the one actually verified on this connection during the mutual TLS
   handshake -- NEVER from the handshake preamble above, which a hostile peer fully controls (see
   the [writers] field's own doc comment on [t] above for why the preamble alone is not a binding
   of claimed id to presented certificate).

   [lib/pki/ca.ml]'s [sign_leaf] mints exactly one DNS SAN entry per leaf
   ([X509.General_name.singleton DNS [ common_name ]]), so exactly one [X509.Host.Set.t] element is
   expected here too -- zero or more than one is treated as a malformed/unusable certificate rather
   than arbitrarily picking one.

   {b The id-encoding convention.} The replica's numeric id is the trailing run of ASCII decimal
   digits in that hostname's LEFTMOST label, e.g. ["peer-3.riptide.test"], ["replica-3.example"],
   and bare ["3"] all decode to [3] -- deciding this is genuinely new policy this module did not
   need before (see tcp.mli's "Authentication" section: closing this gap was explicitly deferred
   pending exactly this decision), not a convention [ca.ml] already established, since [sign_leaf]
   accepts an arbitrary caller-chosen hostname and enforces nothing about its shape beyond being a
   valid DNS name. Anchoring on a trailing digit run in the first label, rather than requiring the
   whole label (or the whole hostname) to be numeric, is what lets every existing test fixture's
   ["<name>-<id>.<domain>"]-shaped common name keep working unchanged, while still letting a real
   deployment use bare numeric hostnames or any domain suffix it likes. *)
let authenticated_peer_id flow =
  match Tls_eio.epoch flow with
  | Error () -> raise (Unauthenticated_peer "no TLS epoch available (handshake not complete?)")
  | Ok epoch -> (
    match epoch.Tls.Core.peer_certificate with
    | None ->
      raise
        (Unauthenticated_peer
           "peer presented no certificate (unreachable under mutual TLS once the handshake has \
            completed)")
    | Some cert -> (
      match X509.Host.Set.elements (X509.Certificate.hostnames cert) with
      | [] -> raise (Unauthenticated_peer "certificate has no SubjectAltName DNS entry")
      | _ :: _ :: _ ->
        raise (Unauthenticated_peer "certificate has more than one SubjectAltName DNS entry")
      | [ (_, host) ] -> (
        let name = Domain_name.to_string host in
        let label = match String.index_opt name '.' with Some i -> String.sub name 0 i | None -> name in
        let len = String.length label in
        let is_digit c = c >= '0' && c <= '9' in
        let rec digits_start i =
          if i <= 0 then 0 else if is_digit label.[i - 1] then digits_start (i - 1) else i
        in
        let start = digits_start len in
        if start = len then
          raise
            (Unauthenticated_peer
               (Printf.sprintf
                  "certificate SAN %S has no trailing replica id in its leftmost label" name))
        else
          match int_of_string_opt (String.sub label start (len - start)) with
          | Some id -> id
          | None ->
            raise
              (Unauthenticated_peer
                 (Printf.sprintf "certificate SAN %S: replica id does not fit an OCaml int" name)))))

let register_writer t peer_id w =
  match Hashtbl.find_opt t.writers peer_id with
  | Some existing when not (Eio.Buf_write.is_closed existing) -> raise (Duplicate_connection_id peer_id)
  | Some _ | None ->
    Hashtbl.replace t.writers peer_id w;
    Eio.Condition.broadcast t.writer_added

(* The write side of one connection's lifetime. Always returns [unit] -- every fault this function
   knows how to handle is caught internally, never re-raised -- so that it composes correctly with
   [Eio.Fiber.first] in [run_connection]: returning (for any reason) means "this side is done",
   which is exactly the signal [run_connection] needs to also stop the reader side and clean up.
   [Eio.Cancel.Cancelled] is deliberately NOT caught: that's [run_connection] itself cancelling
   this fiber because the READER side finished first, and must be allowed to propagate so
   [Eio.Fiber.first] can tell the two cases apart.

   [w] is exposed via [writer_cell] as soon as it exists (before this function can block), so
   [run_connection] can find and remove this connection's own [t.writers] entry once both sides
   are confirmed done -- see [run_connection] for why "this connection's own" matters (evicting a
   different, newer connection's entry for the same peer id would be a real bug, not a cosmetic
   one).

   Catches:
   - [End_of_file]/[Eio.Io _]: the peer died or the connection reset. [Eio.Buf_write.with_flow]'s
     own background copy fiber is what actually performs the socket writes as data is buffered
     here, and if THAT fiber's write fails, the exception propagates out of [with_flow] itself,
     not out of some inner callback -- this is what makes catching it here, rather than deeper
     inside, both necessary and sufficient.
   - [Failure _]: specifically [Eio.Buf_write]'s own "cannot write to closed writer", reachable if
     [w] gets closed (by [with_flow]'s own unwind, once this function's [fn] argument is
     cancelled) in the narrow window before a concurrent [send] call on it completes -- see
     [send]'s own [Eio.Buf_write.is_closed] guard below, which is the caller-facing half of
     closing this same race.
   - [Tls_eio.Tls_alert]/[Tls_eio.Tls_failure]: the TLS session itself died mid-connection (the
     peer sent a fatal alert, or a record failed to decrypt/authenticate). These are new failure
     modes that did not exist before this flow was TLS-wrapped, and they are exactly as fatal to
     one connection -- and exactly as harmless to the rest of the process -- as an ordinary reset.
     Leaving them uncaught would make a single peer's TLS-level failure propagate out onto the
     whole transport's switch, which is the same process-wide blast radius [run_connection]'s
     reader/writer coupling exists to prevent. *)
let writer_body t ~is_dialer peer_id flow writer_cell =
  try
    Eio.Buf_write.with_flow flow (fun w ->
        writer_cell := Some w;
        if is_dialer then write_preamble w t.my_id;
        register_writer t peer_id w;
        Eio.Fiber.await_cancel ())
  with
  | End_of_file -> ()
  | Eio.Io _ -> ()
  | Failure _ -> ()
  | Duplicate_connection_id _ as exn ->
    Eio.traceln "Tcp: connection error: %s; dropping connection" (describe_exn exn)
  | Tls_eio.Tls_alert _ | Tls_eio.Tls_failure _ -> ()

(* The read side of one connection's lifetime: decodes the connection's own authenticated sender
   id ONCE from [flow] (see [authenticated_peer_id] above), then loops decoding length-prefixed
   frames and pushing [(payload, sender)] onto the shared inbox for this local peer. Decoding once
   up front rather than per message is correct, not just an optimization: a single TLS connection
   has exactly one peer certificate for its whole lifetime (renegotiation is never used here), so
   the sender cannot change between messages on the same connection. Like [writer_body], always
   returns [unit] (never re-raises a fault it catches) so it composes with [Eio.Fiber.first] the
   same way; [Eio.Cancel.Cancelled] is likewise left uncaught, for the same reason.

   Ends on:
   - [Unauthenticated_peer]: the certificate actually presented on this connection does not encode
     a usable replica id -- see [authenticated_peer_id] for the exact cases. Checked before the
     read loop even starts: a connection this module cannot attribute a sender to is as useless as
     one that never completed its handshake, and must not deliver a single message while
     unattributed.
   - [End_of_file]/[Eio.Io _]: the connection closed or reset;
   - [Tls_eio.Tls_alert]/[Tls_eio.Tls_failure]: the TLS session died -- see [writer_body] above
     for why these are treated as ordinary connection death rather than allowed to escape;
   - [Frame_too_large]: the peer's declared frame length was negative or over [max_message_size];
   - [Buf_read.Buffer_limit_exceeded]/[Invalid_argument]: defense in depth for the same class of
     malformed-length input as [Frame_too_large], in case some other path into this loop ever
     produces it directly instead of going through [read_frame]'s own check.

   This same function is used for both accepted and dialed connections' read sides -- both go
   through [run_connection], so both get identical fault handling and identical connection
   teardown by construction, not by accident of which side happens to have an outer guard. This
   also makes [authenticated_peer_id]'s use of [Tls_eio.epoch flow] correct on both sides
   symmetrically: for an accepted connection [flow]'s [peer_certificate] is the dialer's (client)
   certificate, and for a dialed connection it is the accepted peer's (server) certificate -- mutual
   TLS means both sides always have one to report once the handshake has completed at all. *)
let reader_body t flow r =
  try
    let sender = authenticated_peer_id flow in
    while true do
      let payload = read_frame r in
      Eio.Stream.add t.inbox (payload, sender)
    done
  with
  | End_of_file -> ()
  | Eio.Io _ -> ()
  | (Tls_eio.Tls_alert _ | Tls_eio.Tls_failure _) as exn ->
    Eio.traceln "Tcp: connection error: %s; dropping connection" (describe_exn exn)
  | Unauthenticated_peer msg ->
    Eio.traceln
      "Tcp: connection error: peer's certificate does not authenticate a usable replica id: %s; \
       dropping connection"
      msg
  | Frame_too_large len ->
    Eio.traceln "Tcp: connection error: peer declared a frame of %d bytes (max %d); dropping connection"
      len max_message_size
  | Eio.Buf_read.Buffer_limit_exceeded | Invalid_argument _ as exn ->
    Eio.traceln "Tcp: connection error: %s; dropping connection" (Printexc.to_string exn)

(* Runs one connection's whole lifetime, coupling its reader and writer fibers so that neither can
   outlive the other's knowledge that the connection is dead.

   This coupling is load-bearing, not tidiness. The uncoupled arrangement -- writer forked bare
   onto the OUTER, whole-process switch, reader running inline inside whatever called this
   connection's handler (for an accepted connection, that's [Eio.Net.accept_fork]'s own
   per-connection handler) -- leaves whichever side notices death first unable to tell the other.
   On a dialed connection that "only" leaks an open, unused flow forever (the flow is owned by the
   outer switch, and nothing else ever closes it). On an ACCEPTED connection it is far worse,
   because [accept_fork] closes the flow itself, exactly once, the moment its handler returns
   (`Flow.close flow` right after `handle flow addr` completes): a reader that returns quietly on
   EOF lets [accept_fork] close the fd out from under a writer that is still alive on the outer
   switch, and that writer's next write raises
   [Invalid_argument "writev: file descriptor used after calling close!"] -- a shape the
   [End_of_file]/[Eio.Io] guards in [writer_body] do not catch, i.e. a real process crash, on
   every peer holding an ACCEPTED connection to a peer that just died. Given this module's own
   "lower id dials, higher id accepts" topology, that is every surviving peer with a higher id
   than the one that died: one peer's death would kill the rest of the cluster.

   [Eio.Fiber.first] is what actually couples the two fibers: it runs [writer_body flow] and
   [reader_body flow r] concurrently in a private cancellation sub-context, and as soon as EITHER one
   finishes (both are written to always return normally rather than raise, for exactly this
   reason), the other is cancelled and [first] returns. Only once both sides have therefore
   actually stopped does this function proceed to:
   - remove this connection's [t.writers] entry, but only if the table's current entry for
     [peer_id] is still the exact writer THIS connection itself installed (via [writer_cell]) --
     otherwise a slow-to-notice OLDER connection's cleanup could evict a NEWER connection's live
     entry for the same id, which is reachable in principle because [register_writer] still lets a
     second connection claim an already-known id once the OLD entry is dead (a legitimate
     reconnect -- see the [writers] field's own doc comment above and [register_writer]'s own
     liveness check), so an old connection's belated cleanup racing a new, already-registered
     replacement for the same id is a real case, not a hypothetical one;
   - close the flow ITSELF, but only if [owns_flow] -- true for a dialed connection (whose flow is
     owned by the long-lived outer [sw] and would otherwise never be closed at all), false for an
     accepted connection (whose flow [accept_fork] itself closes exactly once, automatically, the
     moment the function calling [run_connection] -- [handle_accepted] -- returns; closing it a
     second time here would race that automatic close instead of cooperating with it).

   [flow] is always the TLS flow, never the socket underneath it, on both paths. That does not
   change the [owns_flow] reasoning above, because [Tls_eio]'s own [close] is defined as closing
   the underlying flow: closing the TLS wrapper of an accepted connection would be closing exactly
   the fd [accept_fork] is about to close, i.e. the same double close, not a different one. (It
   does mean neither path sends a TLS close_notify -- that is [Tls_eio.shutdown], not [close].
   Nothing here relies on a peer being able to distinguish an orderly TLS shutdown from a dropped
   connection: this module treats every way a connection can end identically, and has no
   truncation-sensitive stream semantics for close_notify to protect.) *)
let run_connection t ~is_dialer ~owns_flow peer_id flow r =
  let writer_cell = ref None in
  Eio.Fiber.first
    (fun () -> writer_body t ~is_dialer peer_id flow writer_cell)
    (fun () -> reader_body t flow r);
  (match !writer_cell, Hashtbl.find_opt t.writers peer_id with
   | Some w, Some w' when w == w' -> Hashtbl.remove t.writers peer_id
   | _ -> ());
  if owns_flow then (
    try Eio.Flow.close flow with
    | End_of_file | Eio.Io _ -> ()
    (* [Eio.Cancel.Cancelled] is deliberately NOT caught here either, for the same reason
       [writer_body]/[reader_body] leave it uncaught above: if this cleanup itself is running
       inside an outer cancellation (e.g. the whole transport's [sw] tearing down), swallowing
       that signal here would stop it from propagating to whatever is waiting on it. *))

(* Handles one accepted connection for its whole lifetime: TLS handshake first, then this
   module's own handshake preamble, then the connection proper.

   [tls_flow] is the ONLY flow anything below this line ever touches. [raw_flow] -- the socket
   [Eio.Net.accept_fork] handed us -- is passed to [Tls_eio.server_of_flow] and then deliberately
   never mentioned again: no [Buf_read] over it, no [Buf_write] over it, no close of it (see
   [~owns_flow:false] below). That is what makes "every byte after the handshake is encrypted and
   authenticated" a property of the code's shape rather than of remembering to use the right
   variable, and it is why the raw flow is shadowed out of scope the moment the wrapper exists.

   Both waits are bounded, for the same reason and against the same party -- anyone who can route
   to this port, certificate or not: [tls_handshake_timeout] for the handshake,
   [preamble_read_timeout] for the preamble. On either timeout, or on a refused handshake, this
   function simply returns without ever running the connection, which is enough to release the fd,
   since [Eio.Net.accept_fork] closes the flow itself as soon as this handler returns.

   A refused handshake is logged and swallowed rather than raised. It is not an error of this
   listener's: rejecting a peer whose certificate does not chain to this cluster's CA (or that
   presented none) is this module working exactly as intended, and letting it propagate would put
   an attacker in control of how many consecutive "accept errors" the loop above counts.

   The preamble read below still exists, and [peer_id] read from it is still passed to
   [run_connection] unchanged -- it is what [t.writers] gets keyed by for THIS connection (see the
   [writers] field's own doc comment on [t] for why that is still merely claimed, not verified).
   What no longer flows from the preamble is the sender attribution {!receive} reports:
   [run_connection] independently decodes that straight from [tls_flow]'s own verified certificate
   (via [reader_body]/[authenticated_peer_id]), so a connection's preamble claim and its
   certificate-authenticated identity can now diverge -- [t.writers] would (still) be keyed by the
   former, every message delivered over it attributed to the latter. *)
let handle_accepted t ~clock raw_flow =
  match
    Eio.Time.with_timeout clock tls_handshake_timeout (fun () ->
        Ok (Tls_eio.server_of_flow (Tls_identity.server_config t.tls) raw_flow))
  with
  | exception ((Tls_eio.Tls_alert _ | Tls_eio.Tls_failure _ | End_of_file) as exn) ->
    (* [Eio.Cancel.Cancelled] is deliberately not matched here: it is this fiber's own switch
       tearing down, and must propagate. *)
    Eio.traceln "Tcp: rejected an accepted connection: TLS handshake failed: %s" (describe_exn exn)
  | Error `Timeout ->
    Eio.traceln
      "Tcp: connection error: accepted connection did not complete its TLS handshake within \
       %.1fs; dropping connection"
      tls_handshake_timeout
  | Ok tls_flow -> (
    let r = Eio.Buf_read.of_flow tls_flow ~max_size:max_message_size in
    match Eio.Time.with_timeout clock preamble_read_timeout (fun () -> Ok (read_preamble r)) with
    | Ok peer_id -> run_connection t ~is_dialer:false ~owns_flow:false peer_id tls_flow r
    | Error `Timeout ->
      Eio.traceln
        "Tcp: connection error: accepted connection sent no handshake preamble within %.1fs; \
         dropping connection"
        preamble_read_timeout)

(* The listener's whole lifetime: accept connections until cancelled, surviving transient
   accept-time errors -- see [accept_max_consecutive_errors] above for the full reasoning behind
   this loop's error policy, including why it eventually gives up rather than retrying forever. *)
let run_accept_loop t ~sw ~clock listener =
  let consecutive_errors = ref 0 in
  while true do
    match
      Eio.Net.accept_fork ~sw listener
        ~on_error:(fun exn -> Eio.traceln "Tcp: connection error: %s" (Printexc.to_string exn))
        (fun flow _addr -> handle_accepted t ~clock flow)
    with
    | () -> consecutive_errors := 0
    (* [Eio.Cancel.Cancelled] is deliberately NOT caught: it is this fiber's own switch tearing
       down, not a listener fault, and must propagate for that teardown to complete. *)
    | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
    | exception ((Eio.Io _ | End_of_file) as exn) ->
      incr consecutive_errors;
      if !consecutive_errors >= accept_max_consecutive_errors then begin
        Eio.traceln
          "Tcp: accept failed %d times consecutively over ~%.0fs; giving up on the listener: %s"
          !consecutive_errors
          (float_of_int !consecutive_errors *. accept_error_backoff)
          (Printexc.to_string exn);
        raise exn
      end;
      Eio.traceln "Tcp: accept error (%d consecutive), retrying in %.1fs: %s" !consecutive_errors
        accept_error_backoff (Printexc.to_string exn);
      Eio.Time.sleep clock accept_error_backoff
  done

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
  let raw_flow = attempt connect_max_retries in
  (* The TLS handshake runs HERE, inline, before the connection's fibers are forked -- not inside
     the forked fiber. That is deliberate: [create] calls this function and treats its return as
     "this peer is dialed", so a handshake that is going to be refused must be refused while
     [create] is still on the stack and can report it. Done inside the fork instead, a certificate
     rejection would be invisible to [create], which would then sit out its full ~20s
     mesh-formation budget and report a generic "peer never showed up" -- the single most
     misleading possible message for a trust misconfiguration.

     It is deliberately OUTSIDE the [attempt] retry loop above, too. That loop exists for one
     thing: a peer whose listener has not started yet. A refused handshake is not that -- it is a
     settled disagreement about certificates that retrying 200 times cannot resolve, and burning
     20s on it before reporting would only delay the truth.

     As in [handle_accepted], [raw_flow] is never touched again once wrapped.

     This wait is bounded by [tls_handshake_timeout], the same constant and for the same reason
     [handle_accepted] bounds its own [Tls_eio.server_of_flow] call: the peer we just dialed is,
     from this point on, an unauthenticated party that has only proven it can accept a TCP
     connection, not that it will ever speak TLS back to us. Without this, a peer whose process is
     wedged, mid-restart, or behind a path that silently drops packets after [connect] succeeds
     would park this fiber inside [Tls_eio.client_of_flow]'s [drain_handshake] forever -- and
     because that wait happens before [mesh_formation_timeout] even starts (see below), no
     existing timeout would ever catch it; [create] would simply hang at startup with no
     diagnostic. *)
  match
    Eio.Time.with_timeout clock tls_handshake_timeout (fun () ->
        Ok (Tls_eio.client_of_flow (Tls_identity.client_config t.tls) raw_flow))
  with
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn ->
    (* [Eio.Net.connect ~sw] attached [raw_flow] to the long-lived outer switch, and nothing else
       will ever close it: without this, every rejected dial leaks an fd until the whole transport
       shuts down. *)
    (try Eio.Flow.close raw_flow with End_of_file | Eio.Io _ -> ());
    raise (Tls_handshake_failed exn)
  | Error `Timeout ->
    (try Eio.Flow.close raw_flow with End_of_file | Eio.Io _ -> ());
    raise
      (Tls_handshake_failed
         (Failure
            (Printf.sprintf "TLS handshake with dialed peer did not complete within %.1fs"
               tls_handshake_timeout)))
  | Ok tls_flow ->
    Eio.Fiber.fork ~sw (fun () ->
        let r = Eio.Buf_read.of_flow tls_flow ~max_size:max_message_size in
        run_connection t ~is_dialer:true ~owns_flow:true peer_id tls_flow r)

(* Which peers in [peers] this handle does not yet have an outbound path to. The empty list is
   exactly the "mesh is formed" condition [create] waits for, and the same list names the peers in
   [create]'s own timeout error -- deliberately one function used for both, because a readiness
   check that is not literally the negation of the diagnostic ("are there ENOUGH connections?" vs
   "are the RIGHT ones present?") can and did disagree with it: [t.writers] is keyed by whatever
   peer id a handshake preamble claims (trusted, not validated -- see the [writers] field above),
   so any accepted connection, including one claiming an id not in [peers] at all, counts toward a
   count-based check while leaving a genuinely expected peer missing. *)
let missing_peers t peers =
  List.filter_map
    (fun (id, _, _) -> if id <> t.my_id && not (Hashtbl.mem t.writers id) then Some id else None)
    peers

let create ~sw ~net ~clock ~my_id ~peers ~tls =
  let my_host, my_port =
    match List.find_opt (fun (id, _, _) -> id = my_id) peers with
    | Some (_, host, port) -> (host, port)
    | None -> invalid_arg (Printf.sprintf "Tcp.create: my_id %d not present in peers" my_id)
  in
  let t =
    { my_id;
      tls;
      inbox = Eio.Stream.create max_int;
      writers = Hashtbl.create (List.length peers);
      writer_added = Eio.Condition.create ();
    }
  in
  let listener =
    Eio.Net.listen ~reuse_addr:true ~backlog:listen_backlog ~sw net
      (addr_of_host_port my_host my_port)
  in
  Eio.Fiber.fork ~sw (fun () -> run_accept_loop t ~sw ~clock listener);
  (* Known gap (documented, not fixed here): from this point on, if this function raises, the
     listener and any connections already established stay attached to [sw] with no handle for
     this function to reach them and tear them down -- see tcp.mli's "No shutdown path" section,
     which this is one more concrete instance of. *)
  List.iter
    (fun (peer_id, host, port) ->
      if peer_id > my_id then
        match connect_to t ~sw ~net ~clock ~host ~port peer_id with
        | () -> ()
        | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
        | exception Tls_handshake_failed exn ->
          (* Reported separately from the dial failure below, and worded so that it cannot be
             mistaken for one: the TCP connection succeeded and the peer is plainly running -- it
             is the mutual authentication that failed, which is a certificate/trust-anchor
             problem, not a reachability one. *)
          failwith
            (Printf.sprintf "Tcp.create: TLS handshake with peer %d at %s:%d failed: %s" peer_id
               host port (describe_exn exn))
        | exception exn ->
          (* [connect_to] re-raises whatever [Eio.Net.connect] last failed with once its retry
             budget is spent -- most often an [Eio.Io] "connection refused" from a peer that never
             started. Re-raise it as the same [Failure] the mesh-formation timeout below produces,
             so that BOTH ways a peer can fail to show up (it never accepted our dial; it never
             dialed us) reach the caller as one documented exception type carrying the peer id,
             rather than the caller having to also know Eio's own exception vocabulary to catch
             the more likely of the two. The original exception's text is preserved verbatim. *)
          failwith
            (Printf.sprintf "Tcp.create: gave up dialing peer %d at %s:%d after ~%.1fs: %s" peer_id
               host port dial_timeout (Printexc.to_string exn)))
    peers;
  if missing_peers t peers <> [] then begin
    match
      Eio.Time.with_timeout clock mesh_formation_timeout (fun () ->
          Eio.Condition.loop_no_mutex t.writer_added (fun () ->
              if missing_peers t peers = [] then Some () else None);
          Ok ())
    with
    | Ok () -> ()
    | Error `Timeout ->
      failwith
        (Printf.sprintf
           "Tcp.create: timed out after %.1fs waiting for the mesh to form; still missing connection(s) to peer(s) [%s]"
           mesh_formation_timeout
           (String.concat "; " (List.map string_of_int (missing_peers t peers))))
  end;
  t

let send t ~to_ bytes =
  if String.length bytes > max_message_size then
    invalid_arg
      (Printf.sprintf "Tcp.send: message of %d bytes exceeds max_message_size (%d bytes)"
         (String.length bytes) max_message_size)
  else
    match Hashtbl.find_opt t.writers to_ with
    | Some w when not (Eio.Buf_write.is_closed w) -> write_frame w bytes
    | Some _ | None -> invalid_arg (Printf.sprintf "Tcp.send: no connection to peer %d" to_)

let receive t = Eio.Stream.take t.inbox
let receive_nonblocking t = Eio.Stream.take_nonblocking t.inbox
