type trace_event =
  | Sent of { from_ : string; to_ : string; payload : string }
  | Received of { by : string; payload : string }

let peer_name i = Printf.sprintf "peer%d" i

(* --- Termination-logic design note (resolving the gap flagged in the Task 4 brief) ---

   The brief's reference sketch has each peer fiber busy-poll `receive_nonblocking` until its own
   `received` counter reaches `message_count`, interleaved with the driver sending one message at
   a time. That only terminates if every peer receives exactly `message_count` messages, which
   stops being true the moment messages are addressed to a randomly chosen individual peer instead
   of a fixed script.

   The brief names two fixes: (a) broadcast every message to all peers, or (b) give each peer its
   own expected-count target computed by the driver from the addressing it generated. (b) is the
   one that keeps the network's real point-to-point addressing (so `Sent.to_` is trivially the
   real recipient, with no reconciliation needed for the unstructured-pairing test) rather than
   changing what "sending a message" means - but a *literal* per-peer target computed from the
   driver's *intended* recipients is still wrong here: with `drop_probability > 0.0` (as in two of
   this task's own tests, 0.1 and 0.2), a message addressed to a peer can be dropped in transit, so
   that peer would then busy-poll forever waiting for a delivery that will never arrive.

   The fix actually implemented is a refinement of (b): the target each peer waits for is not the
   driver's *send intent* but the *actual* set of deliveries that end up scheduled for it, which is
   fully determined and fixed the moment the driver finishes sending and flushes the network. So
   the two phases are made explicit instead of interleaved:

     Phase 1 (driver, not itself a fiber - see below): generate and send all `message_count`
     messages with randomly chosen sender, receiver, and payload, recording a `Sent` trace event
     for each attempted send immediately (a `Sent` event means "the sender attempted this send",
     not "it was necessarily delivered" - matching how `Network.send` itself works, where drop is
     an internal, unobservable-to-the-caller decision). Then call `Network.pump_all` once, which
     resolves every drop/duplicate/delay/corrupt decision and leaves each peer's inbox holding
     exactly the messages it will ever receive for this run.

     Phase 2 (each peer, as its own Eio fiber, per the interface's requirement): drain its inbox
     exhaustively via `receive_nonblocking` until it returns `None`. Because Phase 1 already fully
     resolved and flushed all scheduled deliveries before Phase 2 starts, this is guaranteed to
     terminate no matter how addressing, drops, or duplicates skew the per-peer counts - no
     `Fiber.yield`-based busy-wait or fragile count bound is needed at all.

   This also means no reconciliation is needed for the unstructured-workload test: since delivery
   is still genuinely point-to-point (not broadcast), the `to_` recorded on each `Sent` event is
   already exactly the workload generator's randomly chosen intended target.

   --- Disclosure: what this design does NOT exercise ---

   A direct consequence of the phase split above: Phase 1 fully resolves and flushes the network
   (one `pump_all` call) *before* any Phase 2 peer fiber starts, and Phase 2's `drain` loop never
   calls `Network.receive` (blocking) or `Eio.Fiber.yield` - `receive_nonblocking` never suspends
   the fiber. So each peer fiber below runs to completion, start to finish, before
   `Eio.Fiber.all` moves on to the next one: there is zero real interleaving between peer fibers,
   or between a peer fiber and in-flight network activity, in this workload. That matters here
   specifically because this whole proof-of-concept exists to catch traps that, per this plan's
   own design spec (`docs/superpowers/specs/2026-09-16-distributed-consensus-design.md`,
   Decision 2 - "GC pauses interacting badly with virtual time, `Domain`-crossing nondeterminism,
   a transitive dependency that doesn't cooperate with Eio's effect handlers") "can only appear in
   code that never suspends" is exactly the wrong description of code like this: this workload's
   receiver loop *never suspends*, so it cannot surface those traps by construction. What this
   workload *does* prove is reproducibility (identical seed -> identical trace, including all
   fault decisions) under an adversarial, unstructured generator - a real and separate property
   from genuine concurrent fiber/network interleaving. That latter property - fibers genuinely
   blocking on `Network.receive` and actually interleaving with `pump_one`/`pump_all` mid-flight -
   is proven separately, by Task 2's `test/test_sim_network.ml` (see e.g. its "deterministic
   two-fiber exchange" test), which predates fault injection and does not go through this module
   at all. *)
let run_toy_cluster ~seed ~peer_count ~message_count ~faults =
  Eio_mock.Backend.run @@ fun () ->
  let prng = Prng.create seed in
  let net = Network.create ~faults prng () in
  let peers = List.init peer_count peer_name in
  List.iter (Network.register net) peers;
  let trace = ref [] in
  let record ev = trace := ev :: !trace in
  (* Unstructured/adversarial generator: sender, receiver, and payload are all drawn randomly, not
     from a fixed script - this is what a purely structured/pre-registered-query generator (the
     class of gap that caused a real bug TigerBeetle's own VOPR initially missed) would not
     cover. *)
  let random_peer () = List.nth peers (Prng.int prng peer_count) in
  (* Phase 1: driver sends everything and flushes the network. Deliberately a plain sequential
     loop, not a fiber - see the design note above for why every scheduled delivery must be fully
     resolved before any peer starts draining its inbox. *)
  for i = 1 to message_count do
    let from_ = random_peer () and to_ = random_peer () in
    let payload = Printf.sprintf "msg-%d" i in
    Network.send Fun.id net ~from_ ~to_ payload;
    record (Sent { from_; to_; payload })
  done;
  Network.pump_all net;
  (* Phase 2: each peer, as its own Eio fiber, drains exactly what ended up in its inbox. Never
     suspends (no blocking receive, no Fiber.yield), so peers run fully sequentially, one after
     another - no genuine fiber/network interleaving here; see the disclosure note above
     `run_toy_cluster` and Task 2's `test/test_sim_network.ml` for that property instead. *)
  Eio.Fiber.all
    (List.map
       (fun peer () ->
         let rec drain () =
           match Network.receive_nonblocking net peer with
           | Some payload ->
             record (Received { by = peer; payload });
             drain ()
           | None -> ()
         in
         drain ())
       peers);
  List.rev !trace
