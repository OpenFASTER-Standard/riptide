(** Real, TCP-backed implementation of {!Transport_intf.S}.

    {2 Authentication}

    Every connection in the mesh is {b mutually authenticated TLS}, unconditionally: there is no
    plaintext mode, no opt-in flag, and no way to construct a [t] without supplying the X.509
    material ({!Tls_identity.t}) to do it. Both ends verify the other -- the dialing side verifies
    the accepting side's certificate against the trust anchor it was given, and the accepting side
    verifies the dialing side's, against the same anchor. A peer holding no certificate, or one
    issued by any other authority, cannot establish a connection in either direction. See
    {!Tls_identity} for how the two configurations are built and what is checked at startup.

    Unconditional rather than optional is a deliberate call. This transport has exactly one
    production caller (a VSR replica's message path), it carries consensus traffic whose forgery
    would let an attacker rewrite replicated state, and its listening port is reachable by anyone
    who can route to it. An optional-security flag on a module like that has one realistic
    outcome: some deployment path silently not setting it. The cost of the choice is that every
    caller, including every test, must supply real certificates -- which is the intended cost.

    {b What mTLS here does and does not establish.} It establishes that the party on the other end
    holds a certificate this cluster's CA issued, and that every byte exchanged afterwards is
    confidential, integrity-protected, and not replayable onto the connection by anyone else. It
    does {e not} establish {e which} cluster member that party is: the peer id below is still the
    one the preamble claims, and nothing binds it to the certificate presented. So one holder of a
    cluster certificate can still claim another member's id. That is a real, remaining gap, and it
    is stated rather than closed here because closing it means deciding a naming convention
    between certificate subjects and peer ids -- policy this repo has no running code needing yet.
    The gap it {e does} close is the one that mattered most: an arbitrary party on the network can
    no longer inject, read, or tamper with cluster traffic at all.

    {2 Wire format}

    Everything described below happens {e inside} the TLS session, not before it: the first bytes
    on a new socket are always a TLS handshake, and the preamble and framing that follow are
    application data within that session, never plaintext on the wire.

    - {b Handshake preamble}: a plain [accept] does not tell you which peer just connected, so
      immediately after the TLS handshake completes, the {e connecting} side (the peer with
      the {e lower} id, per the connection-topology convention below) writes its own peer id as a
      raw, unframed 8-byte big-endian integer -- no length prefix, and before any framed message.
      The {e accepting} side (the peer with the {e higher} id) reads exactly these 8 bytes first,
      before doing anything else with the new connection, to learn which peer id the socket
      belongs to. The accepting side does {e not} send a reciprocal preamble back: only one
      direction needs it, since the connecting side already knows which peer it dialed.

      {b This preamble is authenticated as coming from some cluster member, but the id it claims
      is not verified} -- see the Authentication section above. A second connection claiming an id
      already present in this peer's connection table silently replaces the first one (an
      implementation detail of [Hashtbl.replace], not a validated "reconnect" feature).

      The accepting side's waits are bounded, at both layers and for the same reason: ~10s for the
      TLS handshake to complete, then ~10s for the preamble. A connection that is accepted but
      says nothing -- at either layer, and the TLS one needs no certificate to reach -- is dropped
      and its fd released, rather than parking a fiber and a file descriptor for the lifetime of
      the process. This matters because the listening port is reachable by anyone who can route to
      it, so an unbounded wait at either layer would be an unbounded resource leak.
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

    Each connection's reader and writer are coupled for as long as the connection lives: whichever
    one first discovers the connection is dead (peer disconnected, socket reset, or a malformed
    frame -- see {!max_message_size}) causes the other to be stopped too, before this module's own
    per-peer connection table is updated or the underlying flow is closed. This matters because
    the two directions of a single TCP connection do not fail independently and at the same
    moment in practice -- without this coupling, a reader that quietly notices a dead peer can
    otherwise leave a still-running writer holding (or, worse, attempting to write to) a flow the
    rest of this module has already treated as gone.

    Two consequences of this coupling, both intended, neither previously written down anywhere
    but the source: a peer that half-closes its side of the connection (shuts down its write
    direction but leaves its read direction open, a valid TCP operation this module does not
    otherwise distinguish from a full close) is treated as fully dead -- the reader's
    [End_of_file] stops the writer too, even though the peer might still have been able to
    receive. And any bytes already handed to {!send} but not yet flushed to the OS at the moment
    the reader side notices the connection is dead are discarded, not delivered -- consistent
    with {!Transport_intf.S.send}'s own "no delivery guarantee" documentation, but worth stating
    plainly here since this is the specific mechanism that can trigger it.

    {2 Delivery semantics this implementation provides}

    {!Transport_intf.S} deliberately promises none of the following (see its own doc comments) --
    they are what {e this} implementation happens to provide, on top of that contract, and a
    caller that wants to stay portable across implementations (notably the simulated-network
    adapter, which provides none of them) must not rely on them:

    - {b Per-peer FIFO ordering}: messages sent to one peer arrive in send order, because exactly
      one TCP connection, with exactly one {!Eio.Buf_write} in front of it, carries them all.
      Ordering {e across} different senders is not defined by anything here, and is not promised.
    - {b At-most-once delivery}: nothing in this module ever duplicates a message. Messages can
      still be lost (a connection that dies discards whatever it had buffered -- see above), so
      this is at-most-once, never at-least-once or exactly-once.
    - {b Payload integrity and confidentiality}: a delivered message is byte-identical to what was
      sent, and was sent by a party holding a certificate this cluster's CA issued. This is a
      cryptographic guarantee, not merely TCP's checksums: every byte travels inside the mutually
      authenticated TLS session described above, so an active attacker on the path can drop or
      delay a connection but cannot read, forge, or alter a message on it. ({!Transport_intf.S}
      itself still promises none of this -- {!Riptide_sim.Sim_transport} corrupts payloads
      deliberately, as fault injection -- so protocol code that must stay portable across
      implementations keeps its own end-to-end checks regardless.)

    {2 Listener error handling}

    A transient failure of [accept(2)] itself (fd exhaustion, a client that resets between SYN and
    accept, kernel buffer exhaustion) costs only the connection it was for: it is logged as a
    [Tcp: accept error], retried after a short pause, and every already-established connection
    keeps working. Only a listener that fails continuously for several seconds is treated as
    unrecoverable, at which point the failure is raised on [sw] rather than retried silently
    forever -- this module has no other channel to report it on.

    Because there is no cap on the number of concurrent accepted connections, any party able to
    reach this listener's port can drive it into fd exhaustion (and therefore the unrecoverable
    case above) simply by opening connections and stalling. Mutual TLS does not fix this: an
    attacker with no certificate at all still gets a socket, a fiber and an fd for as long as the
    handshake wait allows. What bounds it is that both waits are bounded (~10s for the handshake,
    ~10s for the preamble), so each such connection is a transient cost rather than a permanent
    one. Connection-count limiting and per-source rate limiting remain out of scope -- noted here
    because this is the specific mechanism by which reachability of the port stays a liveness
    concern even though it is no longer an authenticity one.

    A connection whose TLS handshake is {e refused} -- no certificate, or one from an authority
    this cluster does not trust -- is logged and dropped, and deliberately does {e not} count
    toward the consecutive-accept-error budget above. Otherwise an unauthenticated attacker could
    shut this listener down on demand simply by connecting repeatedly with a bad certificate.

    {2 Send failures}

    {!send} raises [Invalid_argument] (never any other exception type) in three cases:
    - the payload exceeds {!max_message_size};
    - [to_] is not present in the membership table {!create} was given;
    - this peer's connection to [to_] is known to be dead -- either it was never established, or
      it was established and has since been confirmed dead by that connection's reader or writer
      (see "Connection topology" above). A send that races the exact moment a connection dies may
      still appear to succeed once (the bytes are buffered, matching the "no delivery guarantee"
      documented on {!Transport_intf.S.send}) before this exception starts being raised on
      subsequent sends to the same peer.

    Nothing in {!Transport_intf.S} requires an implementation to behave this way -- a caller that
    wants to be portable across implementations (e.g. the simulated-network adapter, in a later
    task) should treat "the destination is known to be gone" as, at most, an opportunistic signal
    this implementation happens to offer, not a contract {!Transport_intf.S} itself promises.

    {2 Explicitly out of scope}

    No reconnection/retry once a connection has been established (only the initial "wait for the
    rest of the cluster to come up" retry during {!create} exists, bounded -- see {!create}); no
    binding of a peer's claimed id to the certificate it presented (see "Authentication" above);
    no certificate revocation, rotation or expiry handling of any kind -- {!create} takes the
    material it is given, and an expired certificate simply starts failing handshakes; no explicit
    shutdown/close (see the note at the end of this comment); no backpressure or flow control of
    any kind -- despite an earlier draft of this comment claiming {!Eio.Buf_write} provides some,
    it does not: both the per-connection write buffer and the receive-side inbox
    ([Eio.Stream.create max_int]) grow without bound in memory if a peer sends faster than the
    other side calls {!receive}. A caller that needs real backpressure today gets none from this
    module beyond whatever the OS TCP stack itself applies to the underlying socket buffers.

    Also out of scope, and worth naming here rather than only in the plan this module was built
    from: fault injection against {e real} sockets. This module has never been exercised under
    packet loss, reordering, duplication or corruption -- the simulated network fabric
    ([lib/sim/network.ml]) injects those faults at its own level, not at the byte level underneath
    a real {!Eio.Flow}. Building a fault-injecting flow wrapper to change that is a later,
    separate task.

    {2 No shutdown path}

    Neither this module nor {!Transport_intf.S} exposes a [close]/[shutdown] operation. A [t]'s
    background fibers (the listener's accept loop, and each connection's reader and writer) run
    for as long as the [sw] passed to {!create} is alive; the only way to stop them today is to
    let or force that switch to finish from the outside (e.g. [Eio.Switch.run]'s block returning,
    or an explicit {!Eio.Switch.fail}/cancellation). This is a real gap for anything that wants a
    [Tcp.t] to shut down cleanly and independently of its own switch -- e.g. the substitutability
    test, which needs to tear down a cluster between test cases, and works around the gap by
    failing the switch explicitly. Adding a [close] is a deliberate deferral, not an oversight: it
    belongs at the {!Transport_intf.S} level (so the simulated-network adapter can satisfy the
    same contract), not improvised per-implementation here, and is tracked as a follow-up in this
    module's own implementation plan. A concrete instance of the same gap: if {!create} itself
    fails (see its [@raise Failure] below), the listener and any connections already established
    before the failure stay attached to [sw] with no handle for {!create} to reach them and tear
    them down before raising -- deferred for the same reason. *)

type t

val max_message_size : int
(** The hard upper bound, in bytes, on any single message this module will send or accept.
    {!create} rejects nothing based on this at start time; it governs two independent runtime
    checks:
    - {!send} raises [Invalid_argument] immediately if [String.length bytes > max_message_size],
      rather than letting an oversized message appear to succeed and then fail later, silently,
      when the receiver rejects it.
    - On the receive side, a connection whose peer declares a frame longer than this (or a
      negative length, which a corrupt or hostile 8-byte prefix can produce via [Int64.to_int]
      truncation) is dropped rather than this process attempting to allocate an unbounded buffer
      for it -- logged as a [Tcp: connection error], not fatal. A message of exactly
      [max_message_size] bytes is accepted on both sides -- the send-side check and the
      receive-side check agree exactly, with no off-by-one gap where one side would accept
      something the other rejects. *)

val create :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  clock:_ Eio.Time.clock ->
  my_id:int ->
  peers:(int * string * int) list ->
  tls:Tls_identity.t ->
  t
(** [create ~sw ~net ~clock ~my_id ~peers ~tls] brings up this peer's side of the transport mesh:

    - Starts a listener on [my_id]'s own [(host, port)] entry in [peers].
    - Dials every peer in [peers] with an id greater than [my_id] (retrying with a short sleep,
      driven by [clock], for a bounded number of attempts, up to ~20s total -- this is only for
      the "wait for the rest of a small, fixed cluster to finish starting up" case, not general
      reconnection). The TLS handshake for a dialed peer happens {e during} [create], inline, so a
      refused one is reported by [create] itself rather than surfacing later as an unexplained
      missing peer. It is not retried: a rejected certificate is a settled disagreement, not a
      peer that has not started yet.
    - Accepts connections from every peer in [peers] with an id less than [my_id], completing the
      TLS handshake and then reading the handshake preamble documented above to learn which peer
      each accepted socket belongs to.

    - For each connection, runs a coupled reader/writer pair (see "Connection topology" above)
      matching this module's wire format, over the TLS flow -- never over the socket underneath
      it. A dialed connection's pair runs in one fiber forked onto [sw]; an accepted connection's
      pair runs directly inside the fiber {!Eio.Net.accept_fork} itself creates for that
      connection.

    [tls] is this replica's own X.509 identity -- the anchor it verifies peers against, plus the
    certificate and key it presents to them. It is a single required argument rather than three
    separate optional ones on purpose: the three values are only meaningful together (see
    {!Tls_identity.create}, which validates their mutual consistency once, up front), and there is
    no supported configuration of this transport that omits them.

    [peers] is the full membership table, including an entry for [my_id] itself. [create] blocks
    until this peer has an outbound path ready to {e each specific} other peer id in [peers] (not
    merely to that {e many} peers: the connection table is keyed by the id a handshake preamble
    claims, and that id is trusted rather than validated against [peers] -- see the preamble note
    above -- so a connection from an unexpected id must not, and does not, count toward readiness
    for an expected one). For a dialed connection, an outbound path is ready as soon as [connect]
    succeeds and the handshake preamble has been queued to send; for an accepted connection, it's
    once that connection's own incoming preamble has been read. (This is a slightly weaker
    guarantee than "handshaken in both directions simultaneously": it says nothing about whether
    the *other* end of a given connection has, at that exact moment, also finished its own half of
    the handshake -- only that queuing a message to it via {!send} is safe to do.) By the time
    [create] returns, {!send} to any other peer in [peers] is immediately deliverable.

    [sw] must outlive the returned [t]: the listener, and every connection's reader/writer fibers,
    are attached to it.

    @raise Invalid_argument if [my_id] is not present in [peers].
    @raise Failure if some peer in [peers] never showed up, or refused this peer's credentials.
      All three ways that can happen raise this one exception type, each with a message naming the
      peer(s) involved:
      - a higher-id peer never accepted this peer's dial (it never started, or is unreachable):
        raised once that peer's ~20s dial budget is spent, with the underlying [Eio.Io] error's
        own text appended;
      - a higher-id peer accepted the TCP connection but the mutual TLS handshake with it failed
        (its certificate did not chain to this peer's trust anchor, or it rejected this peer's):
        raised {e immediately}, not after any retry budget, with a message naming the TLS
        handshake specifically so it is not mistaken for unreachability, and carrying the
        underlying [tls] failure or alert;
      - a lower-id peer never dialed this peer, or dialed and failed the handshake (so no
        connection from it was ever accepted and handshaken): raised once the separate ~20s
        mesh-formation budget is spent, listing every still-missing peer id. A handshake this peer
        {e refused} is visible only in the log as a rejected connection, and is not distinguished
        from silence here -- from the accepting side the two are the same observation.

      Dialing is {e sequential}, one higher-id peer at a time -- but a peer's exhausted dial
      budget now raises {e immediately} for that peer, it does not wait for any remaining
      higher-id peers to also be dialed first. So the worst-case time before a dial-side failure
      is raised is bounded by (successful-connect time for whichever higher-id peers were dialed
      before the one that never showed up, typically fast) plus that one peer's own ~20s budget --
      not the peer count. [~20s * (number of higher-id peers) + ~20s] is only a real bound on the
      OTHER raise case (a lower-id peer that never dials in): that one waits out the full
      mesh-formation budget regardless of how the (already-successful) dial phase went, so ~20s
      dial time per successfully-dialed higher-id peer plus the ~20s mesh-formation wait is the
      right worst case there. For a two-peer cluster that is close to the ~40s the two budgets
      suggest either way; the two failure modes diverge more as peer count grows.

      A failed [create] does not clean up whatever it had already started (see "No shutdown path"
      above) -- a known, undone gap, not a claim that it does. *)

include Transport_intf.S with type t := t
