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
    - {b Message framing}: every message thereafter, in both directions, is wrapped as an 8-byte
      big-endian length prefix followed by exactly that many raw payload bytes -- the same
      convention as [Value.buf_add_len_prefixed] (see [lib/value.ml]), so that concatenating two
      messages' wire encodings can never be mistaken for a third.

    {2 Connection topology}

    Given the full membership table (including self) passed to {!create}, for every unordered
    pair of peers, the one with the {e lower} [int] id dials the one with the {e higher} id; the
    higher-id peer listens and accepts. Exactly one TCP connection is established per unordered
    pair, and it carries messages in both directions for the lifetime of the process -- it is
    never re-dialed per message.

    {2 Explicitly out of scope}

    No reconnection/retry once a connection has been established (only the initial "wait for the
    rest of the cluster to come up" retry during {!create} exists); no TLS or authentication of
    any kind; no backpressure or flow control beyond whatever the OS TCP stack and {!Eio.Buf_write}
    already provide. *)

type t

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
    until every connection implied by [peers] (i.e. [List.length peers - 1] of them) is
    established and handshaken in both directions, so that by the time it returns, {!send} to any
    other peer in [peers] is immediately deliverable. [sw] must outlive the returned [t]: the
    listener, and every connection's reader/writer fibers, are attached to it.

    @raise Invalid_argument if [my_id] is not present in [peers]. *)

include Transport_intf.S with type t := t
