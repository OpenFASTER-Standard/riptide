type peer_id = string

type fault_config = {
  drop_probability : float;
  duplicate_probability : float;
  corrupt_probability : float;
  min_delay : float;
  max_delay : float;
}

let default_fault_config =
  { drop_probability = 0.0; duplicate_probability = 0.0; corrupt_probability = 0.0;
    min_delay = 0.0; max_delay = 0.0 }

(* Pending deliveries, kept as a plain association list sorted by delivery time. A PoC-scale
   choice: O(n) insert/pop is fine for the handful of in-flight messages this proof-of-concept
   exercises. A real, larger-scale simulation harness would want a proper priority queue here —
   deliberately not built now, since this module's whole purpose is to prove the substrate, not
   to be the production implementation the real protocol work depends on unchanged. *)
type 'msg t = {
  inboxes : (peer_id, 'msg Eio.Stream.t) Hashtbl.t;
  faults : fault_config;
  prng : Prng.t;
  clock : Eio_mock.Clock.t;
  mutable now : float;  (* virtual clock time, advanced only by pump_one *)
  mutable pending : (float * peer_id * 'msg) list;  (* sorted ascending by delivery time *)
}

let create ?(faults = default_fault_config) prng () =
  { inboxes = Hashtbl.create 8; faults; prng; clock = Eio_mock.Clock.make (); now = 0.0;
    pending = [] }

let inbox_of net id =
  match Hashtbl.find_opt net.inboxes id with
  | Some inbox -> inbox
  | None -> invalid_arg (Printf.sprintf "Network: peer %S is not registered" id)

let register net id =
  if Hashtbl.mem net.inboxes id then
    invalid_arg (Printf.sprintf "Network: peer %S already registered" id);
  Hashtbl.add net.inboxes id (Eio.Stream.create max_int)

let schedule net ~to_ msg =
  let delay =
    if net.faults.max_delay <= net.faults.min_delay then net.faults.min_delay
    else net.faults.min_delay +. Prng.float net.prng (net.faults.max_delay -. net.faults.min_delay)
  in
  let at = net.now +. delay in
  net.pending <- List.merge (fun (a, _, _) (b, _, _) -> compare a b) net.pending [ (at, to_, msg) ]

let send corrupt net ~from_:_ ~to_ msg =
  if Prng.bool net.prng net.faults.drop_probability then ()
  else begin
    let copies = if Prng.bool net.prng net.faults.duplicate_probability then 2 else 1 in
    for _ = 1 to copies do
      let msg = if Prng.bool net.prng net.faults.corrupt_probability then corrupt msg else msg in
      schedule net ~to_ msg
    done
  end

let receive net id = Eio.Stream.take (inbox_of net id)
let receive_nonblocking net id = Eio.Stream.take_nonblocking (inbox_of net id)

let pump_one net =
  match net.pending with
  | [] -> false
  | (at, to_, msg) :: rest ->
    net.pending <- rest;
    net.now <- at;
    Eio_mock.Clock.set_time net.clock at;
    Eio.Stream.add (inbox_of net to_) msg;
    true

let pump_all net = while pump_one net do () done
