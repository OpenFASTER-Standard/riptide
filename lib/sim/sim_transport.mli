(** Adapter that implements {!Riptide_transport.Transport_intf.S} on top of the existing,
    unmodified {!Network} simulated fabric.

    {2 Relationship to {!Network}}

    {!Network.t} is polymorphic in its message type and its peer ids are plain [string]s, because
    it was built (in an earlier plan) as a god's-eye-view simulation harness: one [Network.t]
    models an entire cluster's fabric, and [Network.send] takes an explicit [~from_] because
    nothing about [Network.t] itself assumes a caller only ever acts as one fixed peer.
    {!Riptide_transport.Transport_intf.S}, by contrast, models what a single real process actually has: one handle
    that already knows its own identity ([int], matching this repo's VSR replica-id domain) and
    never has to say who a message is from, only where it's going.

    This module bridges the two by (a) fixing [Network.t]'s message type to [string] -- a NEW
    choice made only here, not a change to {!Network} itself, which stays fully polymorphic for
    its other, pre-existing consumers ([workload.ml], [test/test_sim_network.ml],
    [test/test_sim_faults.ml]) -- and (b) pairing a shared [string Network.t] with one fixed [int]
    peer id per {!t}, so every {!Riptide_transport.Transport_intf.S} operation on a given {!t} implicitly supplies
    that id as [Network]'s [~from_]/[peer_id] argument.

    Peer ids are encoded to {!Network}'s [string] peer ids via [string_of_int]/back via nothing
    (the translation is one-directional at this boundary: callers only ever supply an [int], and
    this module is the only place that ever turns one into the [string] {!Network} expects).

    {2 What this adapter does NOT do}

    It does not re-implement or re-test fault injection: {!send} always uses [Fun.id] as
    {!Network.send}'s corruption function, so any drop/duplicate/corrupt/delay behavior comes
    entirely from whatever {!Network.fault_config} the underlying {!Network.t} was created with --
    already covered by {!Network}'s own existing tests. This module's whole purpose is to prove
    that {!Network} and a real transport are genuinely swappable behind {!Riptide_transport.Transport_intf.S}, not
    to add a second, redundant fault-injection surface.

    It does not drive delivery on its own: {!Network}'s sends are only scheduled, not delivered,
    until something calls {!Network.pump_one}/{!Network.pump_all} -- see [network.mli]. {!send}
    here is a thin pass-through to [Network.send] and inherits that exact behavior, deliberately:
    hiding the need to pump inside {!send} would make this adapter lie about being
    non-blocking-until-pumped, which is real, correct behavior of the underlying simulated
    network, not an adapter-specific quirk to paper over. {!pump_one}/{!pump_all} below are
    exposed on {!t} precisely so a caller (e.g. a test) can drive delivery explicitly, the same
    way it would have to against {!Network} directly. *)

type t

val create : string Network.t -> int -> t
(** [create net me] is a handle onto [net], acting as peer [me]. [me] must already be registered
    on [net] (i.e. [Network.register net (string_of_int me)] must have already been called) --
    {!receive}/{!receive_nonblocking} below raise [Invalid_argument] (via {!Network}'s own check)
    if it isn't. {!send} does NOT validate [me]'s own registration this way: [Network.send]
    ignores its [~from_] argument entirely, so an unregistered sender is not rejected at {!send}
    time -- a send to an unregistered {e destination} is also not rejected at {!send} time, only
    deferred until a later {!pump_one}/{!pump_all} attempts delivery, where it can surface far
    from the original {!send} call. This is real, pre-existing {!Network} behavior this adapter
    faithfully passes through, not something introduced here. Multiple {!t}s may be created over
    the same [net] -- e.g. one per peer of a simulated cluster -- and freely interleave
    sends/receives/pumps against it, matching {!Network.t} itself being a single shared
    god's-eye-view fabric. *)

val create_cluster : ?faults:Network.fault_config -> Prng.t -> int -> t array
(** [create_cluster ?faults prng peer_count] is a convenience wrapper around {!Network.create} +
    {!Network.register} + {!create}: a fresh [string Network.t] (seeded from [prng], with fault
    behavior [faults], defaulting to {!Network.default_fault_config} same as {!Network.create}
    itself), with peer ids [0, 1, ..., peer_count - 1] registered on it, returning one {!t} per
    peer id, indexed so the array's [i]-th element is the handle for peer [i]. All returned
    handles share the one underlying [Network.t] -- {!pump_one}/{!pump_all} called on any one of
    them drives delivery for all of them identically, since it's the same [net] underneath. *)

val pump_one : t -> bool
(** [pump_one t] is {!Network.pump_one} applied to [t]'s underlying [net] -- delivers at most the
    single earliest still-pending scheduled message (across the WHOLE shared [net], not just
    messages addressed to [t]'s own peer), returning [false] if nothing was pending. Exposed here,
    rather than left implicit inside {!send}, so delivery-driving stays a visible, explicit step
    for callers -- see this file's top-level doc comment. *)

val pump_all : t -> unit
(** [pump_all t] is {!Network.pump_all} applied to [t]'s underlying [net]: calls {!pump_one} until
    it returns [false], i.e. delivers everything currently scheduled across the whole shared
    [net]. *)

include Riptide_transport.Transport_intf.S with type t := t
