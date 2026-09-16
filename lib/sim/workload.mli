(** A toy multi-peer workload over {!Network}, used to prove end-to-end deterministic replay:
    the same seed must always produce the exact same trace of sends and receives, even with
    fault injection enabled. *)

type trace_event =
  | Sent of { from_ : string; to_ : string; payload : string }
  | Received of { by : string; payload : string }

val run_toy_cluster :
  seed:int -> peer_count:int -> message_count:int -> faults:Network.fault_config -> trace_event list
(** [run_toy_cluster ~seed ~peer_count ~message_count ~faults] runs [peer_count] peers (named
    ["peer0"], ["peer1"], ...) as concurrent fibers over a faulty {!Network} seeded from [seed].
    A driver generates [message_count] messages with randomly chosen sender, receiver, and
    payload (drawn from the same seeded source), sends them, pumps the network to completion, and
    returns the full trace in the order events actually occurred. Two calls with identical
    arguments always return identical results. *)
