(** A toy multi-peer workload over {!Network}, used to prove end-to-end deterministic replay:
    the same seed must always produce the exact same trace of sends and receives, even with
    fault injection enabled. *)

type trace_event =
  | Sent of { from_ : string; to_ : string; payload : string }
  | Received of { by : string; payload : string }

val random_byte_flip : Prng.t -> string -> string
(** [random_byte_flip prng s] is a copy of [s] with exactly one byte - chosen via [prng] - mutated
    to a different byte value (also chosen via [prng]); the empty string is returned unchanged.
    Genuine byte-level (not just whole-message) corruption, per the design spec's explicit "not
    just whole-message" requirement - unlike a whole-message transform such as
    [String.uppercase_ascii], this can corrupt part of a payload while leaving the rest intact. *)

val run_toy_cluster :
  seed:int -> peer_count:int -> message_count:int -> faults:Network.fault_config -> trace_event list
(** [run_toy_cluster ~seed ~peer_count ~message_count ~faults] runs [peer_count] peers (named
    ["peer0"], ["peer1"], ...) as Eio fibers over a faulty {!Network} seeded from [seed]. A
    driver generates [message_count] messages with randomly chosen sender, receiver, and payload
    (drawn from the same seeded source), sends them - using {!random_byte_flip} (seeded from the
    same source) as the corruption function, so a nonzero [faults.corrupt_probability] genuinely
    exercises byte-level corruption, not a no-op - and pumps the network to completion; each
    peer fiber then drains whatever ended up in its own inbox. [Sent] events appear in the trace
    in actual send order. [Received] events appear grouped per peer, in each peer's own drain
    order - not interleaved by actual delivery time across peers - because the network is fully
    resolved and flushed before any peer starts draining (see the implementation's disclosure
    note in [workload.ml] for why this workload does not exercise genuine concurrent
    fiber/network interleaving; [test/test_sim_network.ml]'s "interleaving + active fault
    injection + determinism, combined" test covers that property, together with active fault
    injection, instead). Two
    calls with identical arguments always return identical results, including identical
    [Received] grouping and order. *)
