(* The abstract, byte-oriented, peer-addressed network interface that both the real TCP
   implementation ({!Tcp}) and (in a later task) an adapter over the existing simulated network
   conform to. Deliberately has no dependency on anything beyond stdlib: no [Value.t],
   [Envelope.t], or any other VSR/protocol-level type, so that application/protocol code written
   against this signature never needs to change when the underlying transport is swapped between
   "real sockets" and "simulated fabric".

   Per this repo's own convention that [.mli]/interface-defining files are the spec of record,
   this [module type S] (not any prose elsewhere) is the authoritative definition of the
   transport-carrier contract. *)

(* What this contract does NOT promise, stated once here because it is what actually differs
   between the two conforming implementations that exist today, and protocol code written against
   this signature (rather than against whichever implementation it was developed on) has no other
   way to find out:

   - NO ordering of any kind, not even between two messages sent by the same sender to the same
     destination. [Tcp] does in fact deliver those in send order -- one TCP connection per peer
     pair, one write buffer in front of it -- and has a test asserting exactly that, but that is
     [Tcp]'s own property, not this contract's. [Sim_transport] draws an independent random delay
     per message and can therefore deliver two messages from one sender out of order under any
     non-degenerate fault configuration.
   - NO at-most-once delivery: a conforming implementation may deliver the same message more than
     once ([Sim_transport] does, under [duplicate_probability]).
   - NO delivery at all for any particular message: it may be dropped silently
     ([Sim_transport]'s [drop_probability]; also [Tcp], whenever a connection dies holding
     buffered bytes).
   - NO payload integrity: received bytes may differ from sent bytes ([Sim_transport] corrupts
     them deliberately, as fault injection).

   None of these are defects in [Sim_transport]: injecting exactly these faults is its purpose,
   and it is a legitimate conforming implementation precisely because this contract does not
   outlaw them. A caller that needs ordering, deduplication, retransmission or integrity must
   build them on top -- e.g. by encoding sequencing in the message itself, as VSR's own message
   records already do with view/op numbers.

   Each implementation's [.mli] documents what it actually provides on top of this floor; see
   [tcp.mli]'s "Delivery semantics this implementation provides" and [sim_transport.mli]. *)

module type S = sig
  type t
  (** One local peer's live handle onto the transport. Already knows which peer it is -- callers
      never pass their own identity, only the identity of who they're sending to. *)

  val send : t -> to_:int -> string -> unit
  (** [send t ~to_ bytes] sends already-encoded message bytes to peer [to_]. Returns once the
      bytes are handed to the transport (queued for a real send, or scheduled for simulated
      delivery) -- NOT once the peer has received them. Delivery order is NOT guaranteed: not
      across different senders, and not even between two [send] calls made by the same sender to
      the same destination (see this file's own top-level comment for why -- {!Tcp} happens to
      provide same-sender FIFO, the simulated-network adapter deliberately does not). Callers
      needing ordering must encode it in the message itself, which VSR's own message records
      already do (view/op numbers).

      This signature alone does not say what happens when [to_] is unreachable (never known, or
      known but since gone): a conforming implementation MAY raise to signal this synchronously on
      a later call (e.g. {!Tcp.send} raises [Invalid_argument] once it has confirmed a peer's
      connection is dead -- see [tcp.mli]'s "Send failures" section for the exact cases), or it MAY
      just keep silently dropping the message, matching the "no delivery guarantee" above. Callers
      that want to be portable across implementations should not rely on [send] either always or
      never raising for a gone peer -- only on the fact that it never blocks waiting for
      delivery. *)

  val receive : t -> string
  (** [receive t] blocks (cooperatively) until the next message addressed to this handle's own
      peer is available, then returns its raw bytes.

      {b An implementation may require delivery to be driven externally, so a [receive] loop must
      not assume it is the only thing that needs to run.} This signature says when [receive]
      returns, not what causes a message to become available: an implementation MAY deliver on its
      own in the background (as {!Tcp} does, via per-connection reader fibers), or it MAY deliver
      only when some {e other} code explicitly advances it (as the simulated-network adapter does
      -- nothing is delivered there until a [pump_one]/[pump_all] call, which is deliberately not
      part of this signature because it is meaningless for a real socket). Against the latter, the
      obvious single-fiber loop [let msg = receive t in handle msg] never returns: it blocks
      forever without ever yielding to whatever would have pumped. Portable code must therefore
      either run its receive loop in a fiber alongside whatever drives delivery, or take the
      driving step as a parameter -- see [test/test_transport_shared.ml], whose shared body does
      exactly the latter.

      Nor is there any guarantee [receive] ever returns even on an implementation that does
      deliver on its own: if every peer is gone, it simply blocks. This contract exposes no
      liveness or peer-state signal, and no timeout -- a caller that needs one must impose it
      itself (e.g. {!Eio.Time.with_timeout}). *)

  val receive_nonblocking : t -> string option
  (** [receive_nonblocking t] is like {!receive}, but returns [None] immediately instead of
      blocking if no message is currently available for this handle's own peer. *)
end
