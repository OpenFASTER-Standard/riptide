(** A hand-rolled session-type protocol finite-state-machine validator. Validates
    protocol definitions at creation time (rejecting unknown states and nondeterministic
    transitions) and provides a runtime {!checker} to step through a protocol's state
    machine, advancing on valid calls and rejecting invalid ones.

    This module is consumed by Task 4 (loader enforcement) to validate that incoming
    messages follow a declared protocol's allowed state transitions. *)

(** A protocol state name. Concrete (not abstract), since protocols are defined by the
    caller — the protocol FSM itself has no built-in knowledge of domain-specific state
    names. *)
type state = string

(** A single state transition, from one state to another on a given call. *)
type transition = { from_state : state; on_call : string; to_state : state }

(** A validated protocol: a set of states, an initial state, and a set of transitions
    defining which calls are allowed from which states. *)
type t

val create :
  states:state list ->
  initial:state ->
  transitions:transition list ->
  t
(** Validates a protocol definition and returns an opaque, validated [t].

    Raises [Invalid_argument] if:
    - [initial] is not in [states]
    - any transition's [from_state] or [to_state] is not in [states]
    - two transitions share the same [(from_state, on_call)] pair
      (nondeterministic protocol; the FSM must have exactly one next state
      for any given (state, call) pair, never zero or multiple). *)

(** An in-progress run through the protocol, tracking the current state. *)
type checker

val start : t -> checker
(** Initialize a checker at the protocol's initial state. *)

val step : checker -> call:string -> (checker, string) result
(** Attempt to advance the checker through a transition on [call].

    Returns [Ok c] where [c] is the new checker (updated to the next state)
    if a transition exists from the current state on [call].

    Returns [Error msg] if no such transition exists. The error message names
    both the illegal call and the current state for debugging. *)

val current_state : checker -> state
(** Query the checker's current state. *)
