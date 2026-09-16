(** An in-memory, peer-addressed, fault-injecting network for deterministic simulation. All fault
    decisions are drawn from the single {!Prng.t} passed to {!create} — the same seed always
    produces the same sequence of drop/duplicate/corrupt decisions and delays, called in the same
    order. *)

type peer_id = string
type 'msg t

type fault_config = {
  drop_probability : float;  (** Probability a sent message is never delivered. *)
  duplicate_probability : float;  (** Probability a sent message is delivered twice. *)
  corrupt_probability : float;  (** Probability the corruption function is applied at delivery. *)
  min_delay : float;  (** Minimum simulated seconds before delivery. *)
  max_delay : float;  (** Maximum simulated seconds before delivery; must be >= [min_delay]. *)
}

val default_fault_config : fault_config
(** All probabilities [0.0], [min_delay = max_delay = 0.0] — i.e. immediate, reliable, single
    delivery, matching this module's Task 2 behavior exactly. *)

val create : ?faults:fault_config -> Prng.t -> unit -> 'msg t
(** [create ?faults prng ()] is a new network. [faults] defaults to {!default_fault_config}. *)

val register : 'msg t -> peer_id -> unit
(** [register net id] gives [id] an inbox on [net]. Sending to or receiving from an
    unregistered [id] raises [Invalid_argument]. *)

val send : ('msg -> 'msg) -> 'msg t -> from_:peer_id -> to_:peer_id -> 'msg -> unit
(** [send corrupt net ~from_ ~to_ msg] schedules [msg] for delivery to [to_], subject to this
    network's fault config: it may be dropped, duplicated, delayed, and/or transformed by
    [corrupt] before delivery. Scheduled deliveries are released by {!pump_one}/{!pump_all}, not
    delivered synchronously — call one of those (typically [pump_all]) after sending, or nothing
    will ever arrive. *)

val receive : 'msg t -> peer_id -> 'msg
(** [receive net id] blocks (cooperatively) until a message is available for [id]. *)

val receive_nonblocking : 'msg t -> peer_id -> 'msg option

val pump_one : 'msg t -> bool
(** [pump_one net] advances [net]'s virtual clock to the earliest still-pending scheduled
    delivery and delivers it. Returns [false] (a no-op) if nothing is pending. *)

val pump_all : 'msg t -> unit
(** [pump_all net] calls {!pump_one} until it returns [false]. *)
