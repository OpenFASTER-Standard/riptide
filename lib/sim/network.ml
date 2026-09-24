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

(* A single scheduled delivery. [should_corrupt] is decided (via Prng.bool) at send time, same as
   drop/duplicate, so fault *decisions* stay seeded/reproducible from send order. The corruption
   function itself is carried through uninvoked and only ever applied in [pump_one], at the moment
   of delivery — matching real byte-level corruption happening in transit/at rest, not at the
   moment of construction (see the design note in network.mli). *)
type 'msg pending_delivery = {
  at : float;
  to_ : peer_id;
  msg : 'msg;
  should_corrupt : bool;
  corrupt : 'msg -> 'msg;
}

(* Pending deliveries, kept as a plain list sorted by delivery time. A PoC-scale choice: O(n)
   insert/pop is fine for the handful of in-flight messages this proof-of-concept exercises. A
   real, larger-scale simulation harness would want a proper priority queue here — deliberately
   not built now, since this module's whole purpose is to prove the substrate, not to be the
   production implementation the real protocol work depends on unchanged. *)
type 'msg t = {
  inboxes : (peer_id, 'msg Eio.Stream.t) Hashtbl.t;
  faults : fault_config;
  prng : Prng.t;
  (* [base_seed] and [send_counts] are what fault DECISIONS (drop/duplicate/corrupt) are now
     derived from -- never from further draws against [prng] above. [prng] remains the source for
     delivery-delay jitter only (see [schedule]), which is not what made the ring-capacity-boundary
     DST scenario flaky: that flakiness came from [prng] being one shared stream consumed in
     whatever order real [send] calls actually happened, which varies run-to-run against real
     [File_storage] I/O completion timing (see [fault_prng_for] below and this module's own top
     comment). *)
  base_seed : int;
  send_counts : (peer_id, int) Hashtbl.t;
  clock : Eio_mock.Clock.t;
  (* Virtual clock time lives solely in [clock] (read via [Eio.Time.now], advanced only by
     [pump_one] via [Eio_mock.Clock.set_time]) - deliberately not duplicated in a parallel plain
     field, so that a fiber sleeping on [clock] (e.g. via [Eio.Time.sleep_until]) is genuinely
     woken by delivery, not just by a bookkeeping side effect. *)
  mutable pending : 'msg pending_delivery list;  (* sorted ascending by delivery time *)
}

let create ?(faults = default_fault_config) ~seed () =
  { inboxes = Hashtbl.create 8; faults; prng = Prng.create seed; base_seed = seed;
    send_counts = Hashtbl.create 16; clock = Eio_mock.Clock.make (); pending = [] }

(* Returns a fresh [Prng.t], seeded from this network's own [base_seed] plus [from_]'s own send
   count SO FAR (incremented here as a side effect, before the caller draws anything from the
   result) -- i.e. keyed by "the Nth message this sender has sent", not by "the Nth fault decision
   made by anyone, in whatever order those decisions happen to occur". A replica's own sequence of
   sends is fully determined by the protocol's logic given a fixed seed; only the INTERLEAVING of
   sends *across* replicas depends on real I/O completion order, and that interleaving is exactly
   what this keying removes from the fault-decision inputs. [Hashtbl.hash] is a pure, deterministic
   function (not affected by [Hashtbl.randomize], never called on this table), so the same
   [(base_seed, from_, count)] triple always derives the same sub-seed. *)
let fault_prng_for net ~from_ =
  let count = Option.value (Hashtbl.find_opt net.send_counts from_) ~default:0 in
  Hashtbl.replace net.send_counts from_ (count + 1);
  Prng.create (Hashtbl.hash (net.base_seed, from_, count))

let clock net : float Eio.Time.clock_ty Eio.Std.r = (net.clock :> float Eio.Time.clock_ty Eio.Std.r)

let inbox_of net id =
  match Hashtbl.find_opt net.inboxes id with
  | Some inbox -> inbox
  | None -> invalid_arg (Printf.sprintf "Network: peer %S is not registered" id)

let register net id =
  if Hashtbl.mem net.inboxes id then
    invalid_arg (Printf.sprintf "Network: peer %S already registered" id);
  Hashtbl.add net.inboxes id (Eio.Stream.create max_int)

let schedule net ~to_ ~corrupt ~should_corrupt msg =
  let delay =
    if net.faults.max_delay <= net.faults.min_delay then net.faults.min_delay
    else net.faults.min_delay +. Prng.float net.prng (net.faults.max_delay -. net.faults.min_delay)
  in
  let at = Eio.Time.now net.clock +. delay in
  let entry = { at; to_; msg; should_corrupt; corrupt } in
  net.pending <- List.merge (fun a b -> compare a.at b.at) net.pending [ entry ]

let send corrupt net ~from_ ~to_ msg =
  (* One [fault_prng_for] call per [send] invocation, i.e. once per message this sender decides to
     send -- all three fault decisions below (and one sub-draw per duplicate copy) come from this
     one per-message PRNG, keyed by [from_]'s own send count, not from [net.prng]. See
     [fault_prng_for]'s own doc comment for why this removes the cross-replica interleaving
     dependence that made this flaky. *)
  let fault_prng = fault_prng_for net ~from_ in
  if Prng.bool fault_prng net.faults.drop_probability then ()
  else begin
    let copies = if Prng.bool fault_prng net.faults.duplicate_probability then 2 else 1 in
    for _ = 1 to copies do
      (* The decision to corrupt is made here, at send time, so it stays seeded/reproducible from
         this sender's own send count — but [corrupt] itself is not invoked here; it's carried
         through [schedule] and only applied in [pump_one], at delivery. *)
      let should_corrupt = Prng.bool fault_prng net.faults.corrupt_probability in
      schedule net ~to_ ~corrupt ~should_corrupt msg
    done
  end

let receive net id = Eio.Stream.take (inbox_of net id)
let receive_nonblocking net id = Eio.Stream.take_nonblocking (inbox_of net id)

let pump_one net =
  match net.pending with
  | [] -> false
  | { at; to_; msg; should_corrupt; corrupt } :: rest ->
    net.pending <- rest;
    (* Advancing the virtual clock is what wakes any fiber blocked in Eio.Time.sleep_until on this
       clock for a time <= [at] - this is the mechanism, not a bookkeeping side effect. *)
    Eio_mock.Clock.set_time net.clock at;
    let msg = if should_corrupt then corrupt msg else msg in
    Eio.Stream.add (inbox_of net to_) msg;
    true

let pump_all net = while pump_one net do () done
