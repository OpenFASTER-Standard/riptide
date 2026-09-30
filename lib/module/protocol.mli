type state = string
type transition = { from_state : state; on_call : string; to_state : state }
type t

val create : states:state list -> initial:state -> transitions:transition list -> t
(** @raise Invalid_argument if [initial] is not in [states], if any transition's [from_state] or
    [to_state] is not in [states], or if two transitions share the same [(from_state, on_call)]
    pair (a nondeterministic protocol). *)

type checker

val start : t -> checker
val step : checker -> call:string -> (checker, string) result
val current_state : checker -> state
