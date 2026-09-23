(* See sim_transport.mli for the design rationale (why this exists, what it deliberately does not
   do) and the documentation for each value below. *)

type t = { net : string Network.t; me : int; corrupt : string -> string }

(* TASK 11. [corrupt] defaults to [Fun.id], which is what this adapter has always passed, and that
   default is deliberately kept -- but it is no longer the only option, because "always Fun.id"
   turned out to mean something stronger than intended: [Network.fault_config]'s own
   [corrupt_probability] is INERT for every consumer built on this adapter, including
   [Riptide_dst.Cluster] and therefore every VSR cluster test in this repo. A "corrupted" delivery
   was byte-identical to a clean one, so [Riptide_vsr.Replica.handle_message]'s whole battery of
   field-validation guards against forged/corrupted wire input (every range check its own doc
   comment describes) had never once been exercised against a real cluster, while the knob that
   looks like it would do that sat there being set. Passing an explicit [~corrupt] is how a caller
   opts into real byte corruption; the default keeps every existing caller's behaviour exactly as
   it was, so this adds a fault surface rather than changing one. *)
let create ?(corrupt = Fun.id) net me = { net; me; corrupt }

let create_cluster ?faults prng peer_count =
  let net = Network.create ?faults prng () in
  Array.init peer_count (fun i ->
      Network.register net (string_of_int i);
      create net i)

let pump_one t = Network.pump_one t.net
let pump_all t = Network.pump_all t.net

let send t ~to_ bytes =
  Network.send t.corrupt t.net ~from_:(string_of_int t.me) ~to_:(string_of_int to_) bytes

let receive t = Network.receive t.net (string_of_int t.me)
let receive_nonblocking t = Network.receive_nonblocking t.net (string_of_int t.me)
