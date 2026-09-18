(* See sim_transport.mli for the design rationale (why this exists, what it deliberately does not
   do) and the documentation for each value below. *)

type t = { net : string Network.t; me : int }

let create net me = { net; me }

let create_cluster ?faults prng peer_count =
  let net = Network.create ?faults prng () in
  Array.init peer_count (fun i ->
      Network.register net (string_of_int i);
      create net i)

let pump_one t = Network.pump_one t.net
let pump_all t = Network.pump_all t.net

let send t ~to_ bytes =
  Network.send Fun.id t.net ~from_:(string_of_int t.me) ~to_:(string_of_int to_) bytes

let receive t = Network.receive t.net (string_of_int t.me)
let receive_nonblocking t = Network.receive_nonblocking t.net (string_of_int t.me)
