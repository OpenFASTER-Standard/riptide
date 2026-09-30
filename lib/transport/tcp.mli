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
    also establishes {e which} cluster member that party is, for {!receive}'s purposes: {!receive}
    reports a [sender] decoded from the SubjectAltName of the certificate {e actually presented and
    verified} on the connection a message arrived on (see the module-level implementation, in
    particular [authenticated_peer_id]), never from the handshake preamble below. So one holder of
    a cluster certificate can no longer make a message it sends appear, to a {!receive} caller, to
    come from another member -- the naming convention this used to need deciding (mapping
    certificate SAN to peer id) is now decided: the peer's numeric id is the trailing run of
    decimal digits in the SAN hostname's leftmost DNS label (e.g. ["peer-3.riptide.test"] and
    bare ["3"] both decode to [3]).

    {b What is still not bound to the certificate.} This module's own OUTBOUND routing table (keyed
    by peer id, used by {!send} to find which live connection to write to) is still populated from
    the handshake preamble's claim, unverified against the certificate on that same connection --
    see the {!create} implementation's [writers] field for the precise, current boundary. So a
    cluster member can still cause its {e own} outbound traffic to be routed onto a connection an
    attacker holds (a routing-table poisoning, not a message-attribution forgery). A second
    connection claiming an id already routed to a still-LIVE connection is now {b rejected} rather
    than silently replacing the first: the new connection's writer fiber exits with a logged
    "connection error" and the first connection's entry in the routing table remains untouched. A
    second connection claiming an id whose routed entry is already dead is still let through (the
    same as always), so a legitimate reconnect from the same peer is never wrongly refused. The gap
    {!receive}'s fix closes is the one that mattered most for message provenance: an arbitrary
    party on the network can no longer inject, read, tamper with, or (as of this fix) falsely
    attribute cluster traffic. What
    remains is narrower, and is a separate, later fix.

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
      is not verified against the certificate on the same connection} -- see the Authentication
      section above for the precise, now-narrower boundary: this preamble still decides this
      connection's entry in the OUTBOUND routing table ({!send}'s target lookup), but no longer
      decides what {!receive} reports a delivered message's sender as -- that is decoded
      independently, straight from the certificate. A second connection claiming an id already
      present and LIVE in this peer's connection table is rejected rather than replacing the
      first one -- see the "Authentication" section above. One claiming an id whose table entry
      is already dead (the prior connection gone, but not yet cleaned up) is let through, the same
      as it always was, so a legitimate reconnect is never wrongly refused.

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

    {b [EMFILE] is the one exception to "several seconds", by design.} Even with the
    [max_connections] cap below in place, [EMFILE] (this process's own fd table full) remains
    reachable in practice -- the cap only bounds fds held by connections THIS listener has
    accepted, not fds this process holds for any other reason (outbound connections to other
    cluster members, open storage files, etc.), and a caller can configure [max_connections] above
    what the process's real OS fd ulimit can actually support. When [EMFILE] specifically is what
    [accept(2)] fails with, this listener retries indefinitely rather than ever treating it as the
    unrecoverable case above -- see [tcp.ml]'s [accept_max_consecutive_errors] comment for why
    (this process's own fd churn, not giving up, is what plausibly relieves a per-process limit
    like this one) and for the disclosed cost of that choice (a listener stuck in sustained
    [EMFILE] retries forever with no alarm this module can raise on its own).
    [ENFILE] (system-wide, not per-process, fd exhaustion) is deliberately NOT given this
    treatment and remains part of the ordinary several-seconds-then-unrecoverable path above --
    see the same comment for why the two are not interchangeable.

    {!create}'s [max_connections] bounds the number of concurrently accepted connections this
    listener will ever be handling at once (mid-handshake or fully connected), which closes the
    fd-exhaustion route this paragraph used to describe as open: without it, any party able to
    reach this listener's port could drive it into fd exhaustion (and therefore the unrecoverable
    case above) simply by opening connections and stalling -- mutual TLS alone does not fix this,
    since an attacker with no certificate at all still gets a socket, a fiber and an fd for as long
    as the handshake wait allows. Both handshake-layer waits (~10s for the TLS handshake, ~10s for
    the preamble) remain in place regardless, so even a connection admitted under the cap is only
    ever a transient cost, never a permanent one. Per-source rate limiting (as opposed to a single
    process-wide count) remains out of scope.

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
    rest of the cluster to come up" retry during {!create} exists, bounded -- see {!create}). {b This
    is what makes [read_idle_timeout] (see {!create}) a permanent, not a recoverable, closure:} once
    a connection is dropped for going quiet longer than [read_idle_timeout], nothing anywhere in this
    module (or, as of this task, anywhere else in this codebase's real VSR implementation -- there is
    no heartbeat mechanism either; see [default_read_idle_timeout]'s own comment for how this was
    confirmed) will ever re-establish it. If that silence was a genuinely healthy quiet period (no
    client write traffic for a while, not a dead or wedged peer), the two peers on that connection are
    now permanently partitioned from each other for the rest of the process's life, indistinguishable
    from here on out from any other reason {!send} might report "no connection to peer". This task
    deliberately biases [read_idle_timeout]'s default heavily toward avoiding that outcome (30
    minutes, not seconds -- see [default_read_idle_timeout]), but a large timeout only lowers the
    odds of hitting this, it cannot eliminate them: this transport-layer module cannot, on its own,
    tell "the peer went quiet because nothing needed saying" apart from "the peer is gone and never
    coming back" for any finite timeout value. Fully closing that ambiguity needs either a heartbeat
    at a higher (VSR/cluster) layer or a reconnection mechanism here -- both explicitly out of scope
    for this task and this module, so [read_idle_timeout] closes the "an attacker (or a wedged peer)
    can hold a connection open, idle, for the lifetime of the process" finding only at the cost of
    this disclosed, real, un-eliminated risk in the other direction, not for free.

    No binding of a peer's PREAMBLE-claimed id (used for {!send}'s outbound routing table) to the
    certificate it presented on that connection -- {!receive}'s reported sender {e is} now bound to
    the certificate; the routing table is the narrower, still-open part (see "Authentication"
    above); no certificate revocation, rotation or expiry handling of any kind -- {!create} takes the
    material it is given, and an expired certificate simply starts failing handshakes; no explicit
    shutdown/close (see the note at the end of this comment).

    {b Backpressure and flow control:} the receive side now has real, if narrow, backpressure --
    {!create}'s [inbox_capacity] bounds the shared inbox every connection's reader delivers into
    (see {!create}), and a reader fiber blocks, rather than growing this process's memory without
    bound, once it is full; that block is what naturally propagates into TCP-level flow control
    against whichever peer is sending too fast, an inherent property of a blocking, cooperative
    reader loop over a real socket rather than a mechanism this module implements on top of it. What
    remains genuinely out of scope is the OTHER side of the same problem: the per-connection
    OUTGOING write buffer ({!Eio.Buf_write}, one per connection, fed by {!send}) still grows without
    bound in memory if a local caller calls {!send} faster than the OS can actually drain it onto the
    wire -- despite an earlier draft of this comment claiming {!Eio.Buf_write} bounds that too, it
    does not. A caller that needs real send-side backpressure today gets none from this module beyond
    whatever the OS TCP stack itself applies to the underlying socket buffers.

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
  ?max_connections:int ->
  ?inbox_capacity:int ->
  ?read_idle_timeout:float ->
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  clock:_ Eio.Time.clock ->
  my_id:int ->
  peers:(int * string * int) list ->
  tls:Tls_identity.t ->
  unit ->
  t
(** [create ~sw ~net ~clock ~my_id ~peers ~tls ()] brings up this peer's side of the transport
    mesh. The trailing [unit] is only there so that [?max_connections]/[?inbox_capacity]/
    [?read_idle_timeout] can be optional at all -- every other argument is a required label, and
    OCaml needs a final non-labeled argument to know where the optional-argument list ends (the
    same pattern {!Riptide_vsr.Replica.create}'s own [?on_commit_advanced] uses in this codebase)
    -- it carries no meaning of its own:

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

    [max_connections] caps how many connections this peer's listener will ever have
    simultaneously accepted (mid-handshake or fully connected) -- see the implementation's
    [run_accept_loop] for the mechanism, and its [default_max_connections] for the default
    ([max 16 (4 * List.length peers)]) and the concurrency model that default is sized against.
    This closes an audit finding: without it, any party able to reach this listener's port could
    exhaust this process's file descriptors, and therefore kill the listener, simply by opening
    connections and never completing them (reproduced at 315 concurrent connections). A connection
    attempted beyond the cap is never handed to [accept(2)] at all -- it sits in the kernel's own
    listen backlog ([listen_backlog]) until a slot frees, rather than being individually accepted
    and then closed by this module.

    [inbox_capacity] caps how many not-yet-{!receive}d [(payload, sender)] pairs the shared inbox
    every connection's reader delivers into will hold before the reader fiber that produced the
    next one blocks trying to add it -- see the implementation's [default_inbox_capacity] for the
    default ([max 16 (4 * List.length peers)]) and the consumption model it is sized against. This
    closes an audit finding: without it ([Eio.Stream.create max_int], this module's previous
    behavior), a peer that sends faster than the local caller drains {!receive} grows this
    process's memory without limit (reproduced at 20,000 x 64KiB). Once the inbox is full, the
    blocked reader fiber simply stops pulling more bytes off its own connection's socket -- which
    is real backpressure against whichever peer is sending too fast, an inherent property of a
    blocking, cooperative reader loop over a real socket, not a mechanism this module has to
    implement on top. This is the "no backpressure ... the receive-side inbox grows without bound"
    half of the "Explicitly out of scope" section above being closed; the OTHER half named there
    (the per-connection outgoing write buffer) remains open, unaffected by this parameter.

    [read_idle_timeout] bounds how long an ESTABLISHED connection (past both handshake-layer waits
    above) may go without a complete frame arriving before it is dropped -- see the
    implementation's [reader_body] for the mechanism and [default_read_idle_timeout] for the
    default (30 minutes) and, importantly, the reasoning behind picking a number this large: this
    module's only production caller has no heartbeat or other synthetic non-silence mechanism today
    (see that comment for how this was confirmed, not assumed), so a long stretch of zero traffic on
    one specific connection can be entirely legitimate, and {e this parameter's closure of the
    "Explicitly out of scope" no-reconnection gap above is PERMANENT} if it fires during such a
    period. Applies only to the wait for the NEXT frame -- never to time already spent blocked on
    [inbox_capacity]'s own backpressure above, which is the connection actively delivering data, not
    idleness.

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
      - a higher-id peer accepted the TCP connection but the mutual TLS handshake with it did not
        succeed: raised without waiting on the dial retry budget above, with a message naming the
        TLS handshake specifically so it is not mistaken for unreachability. Two distinct causes
        share this path: a refused handshake (its certificate did not chain to this peer's trust
        anchor, or it rejected this peer's) is raised {e immediately}, carrying the underlying
        [tls] failure or alert; a handshake that is accepted but never completes at all -- the
        peer took the TCP connection and then never spoke TLS back, whether wedged, mid-restart,
        or behind a path that silently drops packets after [connect] -- is raised once
        [tls_handshake_timeout] (~10s) is spent, carrying a message naming that timeout, rather
        than leaving [create] hanging with no diagnostic;
      - a lower-id peer never dialed this peer, or dialed and failed the handshake (so no
        connection from it was ever accepted and handshaken): raised once the separate ~20s
        mesh-formation budget is spent, listing every still-missing peer id. A handshake this peer
        {e refused} is visible only in the log as a rejected connection, and is not distinguished
        from silence here -- from the accepting side the two are the same observation.

      Dialing is {e sequential}, one higher-id peer at a time -- but a peer's exhausted dial
      budget now raises {e immediately} for that peer, it does not wait for any remaining
      higher-id peers to also be dialed first. So the worst-case time before a dial-side failure
      is raised is bounded by (successful-connect-and-handshake time for whichever higher-id peers
      were dialed before the one that failed, typically fast) plus that one peer's own budget --
      ~20s if it never showed up at the TCP layer at all, or the shorter [tls_handshake_timeout]
      (~10s) if it accepted the TCP connection but then stalled inside the TLS handshake, since in
      that case the (already-spent) connect time isn't part of the remaining wait -- not the peer
      count. [~20s * (number of higher-id peers) + ~20s] is only a real bound on the
      OTHER raise case (a lower-id peer that never dials in): that one waits out the full
      mesh-formation budget regardless of how the (already-successful) dial phase went, so ~20s
      dial time per successfully-dialed higher-id peer plus the ~20s mesh-formation wait is the
      right worst case there. For a two-peer cluster that is close to the ~40s the two budgets
      suggest either way; the two failure modes diverge more as peer count grows.

      A failed [create] does not clean up whatever it had already started (see "No shutdown path"
      above) -- a known, undone gap, not a claim that it does. *)

include Transport_intf.S with type t := t
