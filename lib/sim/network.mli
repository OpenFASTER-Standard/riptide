(** An in-memory, peer-addressed network for deterministic simulation. Messages are delivered
    immediately in this task; {!module:Network} gains fault injection (delay, drop, reorder,
    duplication, corruption) in a later task without changing this signature. *)

type peer_id = string
type 'msg t

val create : unit -> 'msg t

val register : 'msg t -> peer_id -> unit
(** [register net id] gives [id] an inbox on [net]. Sending to or receiving from an
    unregistered [id] raises [Invalid_argument]. *)

val send : 'msg t -> from_:peer_id -> to_:peer_id -> 'msg -> unit
(** [send net ~from_ ~to_ msg] delivers [msg] to [to_]'s inbox. [from_] is currently unused by
    delivery itself but is required now so fault-injection logic added later (which may need to
    know the sender, e.g. to simulate a one-directional partition) doesn't change this
    signature. *)

val receive : 'msg t -> peer_id -> 'msg
(** [receive net id] blocks (cooperatively) until a message is available for [id]. *)

val receive_nonblocking : 'msg t -> peer_id -> 'msg option
