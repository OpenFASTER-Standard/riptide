(* The abstract, byte-oriented, peer-addressed network interface that both the real TCP
   implementation ({!Tcp}) and (in a later task) an adapter over the existing simulated network
   conform to. Deliberately has no dependency on anything beyond stdlib: no [Value.t],
   [Envelope.t], or any other VSR/protocol-level type, so that application/protocol code written
   against this signature never needs to change when the underlying transport is swapped between
   "real sockets" and "simulated fabric".

   Per this repo's own convention that [.mli]/interface-defining files are the spec of record,
   this [module type S] (not any prose elsewhere) is the authoritative definition of the
   transport-carrier contract. *)

module type S = sig
  type t
  (** One local peer's live handle onto the transport. Already knows which peer it is -- callers
      never pass their own identity, only the identity of who they're sending to. *)

  val send : t -> to_:int -> string -> unit
  (** [send t ~to_ bytes] sends already-encoded message bytes to peer [to_]. Returns once the
      bytes are handed to the transport (queued for a real send, or scheduled for simulated
      delivery) -- NOT once the peer has received them. Delivery order across different senders is
      NOT guaranteed (neither real TCP-across-multiple-connections nor the simulated fabric
      promises it) -- callers needing ordering must encode it in the message itself, which VSR's
      own message records already do (view/op numbers).

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
      peer is available, then returns its raw bytes. *)

  val receive_nonblocking : t -> string option
  (** [receive_nonblocking t] is like {!receive}, but returns [None] immediately instead of
      blocking if no message is currently available for this handle's own peer. *)
end
