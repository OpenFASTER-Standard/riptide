(** Real, TCP-backed implementation of {!Transport_intf.S}.

    {2 Wire format}

    - {b Handshake preamble}: a plain [accept] does not tell you which peer just connected, so
      immediately after a TCP connection is established, the {e connecting} side (the peer with
      the {e lower} id, per the connection-topology convention below) writes its own peer id as a
      raw, unframed 8-byte big-endian integer -- no length prefix, and before any framed message.
      The {e accepting} side (the peer with the {e higher} id) reads exactly these 8 bytes first,
      before doing anything else with the new connection, to learn which peer id the socket
      belongs to. The accepting side does {e not} send a reciprocal preamble back: only one
      direction needs it, since the connecting side already knows which peer it dialed.

      {b This preamble is trusted, not verified.} Nothing checks that the id an accepted socket
      claims is actually who it says it is, and a second connection claiming an id already present
      in this peer's connection table silently replaces the first one (an implementation detail of
      [Hashtbl.replace], not a validated "reconnect" feature). This is deliberate, not an
      oversight: real authentication is out of scope for this module, per Decision 1's
      single-operator-cluster framing in the design this implements. It is called out here so a
      future reader doesn't have to rediscover it by reading the source.
    - {b Message framing}: every message thereafter, in both directions, is wrapped as an 8-byte
      big-endian length prefix followed by exactly that many raw payload bytes -- the same
      convention as [Value.buf_add_len_prefixed] (see [lib/value.ml]), so that concatenating two
      messages' wire encodings can never be mistaken for a third. A declared length that is
      negative (possible via truncation of a hostile/corrupt prefix) or exceeds
      {!max_message_size} causes that connection to be dropped rather than accepted or crashing
      this process -- see {!max_message_size}.

    {2 Connection topology}

    Given the full membership table (including self) passed to {!create}, for every unordered
    pair of peers, the one with the {e lower} [int] id dials the one with the {e higher} id; the
    higher-id peer listens and accepts. Exactly one TCP connection is established per unordered
    pair, and it carries messages in both directions for the lifetime of the process -- it is
    never re-dialed per message.

    Peer hosts (the middle element of each [(int * string * int)] triple) must be IP literals
    (e.g. ["127.0.0.1"], ["::1"]) -- they are passed straight to {!Stdlib.Unix.inet_addr_of_string},
    which raises an opaque [Failure "inet_addr_of_string"] on a DNS name like ["localhost"] rather
    than resolving it. Resolving hostnames (e.g. via {!Eio.Net.getaddrinfo}) is not implemented.

    {2 Explicitly out of scope}

    No reconnection/retry once a connection has been established (only the initial "wait for the
    rest of the cluster to come up" retry during {!create} exists, bounded -- see {!create}); no
    TLS or authentication of any kind (see the handshake preamble note above); no explicit
    shutdown/close (see the note at the end of this comment); no backpressure or flow control of
    any kind -- despite an earlier draft of this comment claiming {!Eio.Buf_write} provides some,
    it does not: both the per-connection write buffer and the receive-side inbox
    ([Eio.Stream.create max_int]) grow without bound in memory if a peer sends faster than the
    other side calls {!receive}. A caller that needs real backpressure today gets none from this
    module beyond whatever the OS TCP stack itself applies to the underlying socket buffers.

    {2 No shutdown path}

    Neither this module nor {!Transport_intf.S} exposes a [close]/[shutdown] operation. A [t]'s
    background fibers (the listener's accept loop, and each connection's reader and writer) run
    for as long as the [sw] passed to {!create} is alive; the only way to stop them today is to
    let or force that switch to finish from the outside (e.g. [Eio.Switch.run]'s block returning,
    or an explicit {!Eio.Switch.fail}/cancellation). This is a real gap for anything that wants a
    [Tcp.t] to shut down cleanly and independently of its own switch -- e.g. Task 4's
    substitutability test, which needs to tear down a cluster between test cases -- but adding a
    [close] deliberately wasn't done as part of this fix round: it belongs at the
    {!Transport_intf.S} level (so the simulated-network adapter can satisfy the same contract),
    not improvised per-implementation here. *)

type t

val max_message_size : int
(** The hard upper bound, in bytes, on any single message this module will send or accept.
    {!create} rejects nothing based on this at start time; it governs two independent runtime
    checks:
    - {!send} raises [Invalid_argument] immediately if [String.length bytes > max_message_size],
      rather than letting an oversized message appear to succeed and then fail later, silently,
      when the receiver rejects it (which used to also crash the sender's own process before this
      fix round -- see the fix-round report's M1/H1).
    - On the receive side, a connection whose peer declares a frame longer than this (or a
      negative length, which a corrupt or hostile 8-byte prefix can produce via [Int64.to_int]
      truncation) is dropped rather than this process attempting to allocate an unbounded buffer
      for it -- logged as a [Tcp: connection error], not fatal (see the fix-round report's H2). *)

val create :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  clock:_ Eio.Time.clock ->
  my_id:int ->
  peers:(int * string * int) list ->
  t
(** [create ~sw ~net ~clock ~my_id ~peers] brings up this peer's side of the transport mesh:

    - Starts a listener on [my_id]'s own [(host, port)] entry in [peers].
    - Dials every peer in [peers] with an id greater than [my_id] (retrying with a short sleep,
      driven by [clock], for a bounded number of attempts -- this is only for the "wait for the
      rest of a small, fixed cluster to finish starting up" case, not general reconnection).
    - Accepts connections from every peer in [peers] with an id less than [my_id], reading the
      handshake preamble documented above to learn which peer each accepted socket belongs to.
    - Forks one background writer fiber and one background reader fiber (onto [sw]) per
      connection, matching this module's wire format above.

    [peers] is the full membership table, including an entry for [my_id] itself. [create] blocks
    until this peer has an outbound path ready to every other peer in [peers] (i.e.
    [List.length peers - 1] of them) -- for a dialed connection, that's as soon as [connect]
    succeeds and the handshake preamble has been queued to send; for an accepted connection, it's
    once that connection's own incoming preamble has been read. (This is a slightly weaker
    guarantee than "handshaken in both directions simultaneously": it says nothing about whether
    the *other* end of a given connection has, at that exact moment, also finished its own half of
    the handshake -- only that queuing a message to it via {!send} is safe to do.) By the time
    [create] returns, {!send} to any other peer in [peers] is immediately deliverable.

    [sw] must outlive the returned [t]: the listener, and every connection's reader/writer fibers,
    are attached to it.

    @raise Invalid_argument if [my_id] is not present in [peers].
    @raise Failure if the mesh has not finished forming within a bounded timeout (matching the
      dial loop's own ~20s retry budget) -- e.g. because some other peer in [peers] never started.
      The error message names which peer id(s) are still missing a connection. *)

include Transport_intf.S with type t := t
