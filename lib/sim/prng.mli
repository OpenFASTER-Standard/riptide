(** A single, explicitly-seeded pseudorandom source. Every random decision in this library's
    fault-injection code must be drawn from one value of this type, threaded explicitly — never
    from {!Stdlib.Random}'s global state or any OS entropy source. This is what makes an entire
    simulation run reproducible from one seed number. *)

type t

val create : int -> t
(** [create seed] is a new PRNG deterministically derived from [seed]. Two values created with
    the same [seed] produce identical output from every function below, called in the same
    order. *)

val int : t -> int -> int
(** [int t bound] draws a value in [\[0, bound)]. Mirrors {!Random.State.int}. *)

val float : t -> float -> float
(** [float t bound] draws a value in [\[0.0, bound)]. Mirrors {!Random.State.float}. *)

val bool : t -> float -> bool
(** [bool t p] is [true] with probability [p] (clamped to [\[0.0, 1.0\]]). *)
