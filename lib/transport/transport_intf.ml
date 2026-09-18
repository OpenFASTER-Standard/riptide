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
      own message records already do (view/op numbers). *)

  val receive : t -> string
  (** [receive t] blocks (cooperatively) until the next message addressed to this handle's own
      peer is available, then returns its raw bytes. *)

  val receive_nonblocking : t -> string option
  (** [receive_nonblocking t] is like {!receive}, but returns [None] immediately instead of
      blocking if no message is currently available for this handle's own peer. *)
end
