# Implementation plan: transport carrier (subtask 3.5)

Implements Decision 4 of `docs/superpowers/specs/2026-09-16-distributed-consensus-design.md`:
plain TCP with custom framing, behind a message-oriented abstract network interface — not the
task tracker's original placeholder "QUIC recommended" (already corrected by that design doc;
research found no real precedent for QUIC on this kind of workload).

Task-master's own stated test for subtask 3.5: **"swapping the transport carrier implementation
must not require touching the application-level protocol code."** This plan is built directly
around proving that property, not just asserting it — Task 4 below is a single, shared test body
run unmodified against both implementations via an OCaml functor, which is the only way this
property is actually checked rather than merely believed.

## Research grounding (verified directly against this repo and this box's installed toolchain,
not assumed)

- `lib/sim/network.ml`/`.mli` (merged, Task 2 of the DST PoC plan) already has an in-memory,
  peer-addressed, fault-injecting network, but it is **PoC-scoped in a load-bearing way, not a
  generalizable interface today**: `type peer_id = string`; `send` takes an explicit `~from_`
  (because one `Network.t` models the whole cluster's fabric from a god's-eye view, which only
  makes sense for a simulation harness — a real process has no such view of the whole cluster);
  delivery only progresses via explicit `pump_one`/`pump_all` calls; the message type `'msg` is a
  free type parameter carrying arbitrary in-memory OCaml values, with no byte encoding anywhere.
  None of this is a defect in that module — it's exactly right for what Task 2 of that plan
  needed — but it cannot be swapped for a real TCP implementation as-is.
- **No wire framing exists anywhere in this repo.** `Value.canonical_encode : Value.value ->
  string` (`lib/value.mli`) is a real, exported, deterministic byte encoder (already used for
  `content_hash`), but it encodes one value's bytes with no message-boundary framing on top —
  reusable as a payload encoding, not a substitute for length-prefixed message framing over a
  stream socket.
- **No peer-identity type exists outside `lib/sim/network.ml`'s own `string`.** `spec/tla/VSR.tla`
  (merged) uses `replicas == 1..ReplicaCount` — plain positive integers — as the identity domain
  for every protocol-level function (`Primary(v)`, `rep_log[r]`, etc.). This plan makes peer
  identity `int`, matching VSR directly, so the eventual protocol implementation (subtask 3.2)
  never needs an identity-translation layer between "which replica" and "which transport peer."
- **Eio's real TCP API** (confirmed installed: `eio 0.12` at this box's durable opam switch,
  `/work/toolchain/opam-root/5.0.0/lib/eio/net.mli`): `Eio.Net.listen`, `Eio.Net.accept_fork`,
  `Eio.Net.connect`/`with_tcp_connect`, `Sockaddr.stream = [ \`Unix of string | \`Tcp of
  Ipaddr.v4v6 * int ]`. `Eio.Buf_read`/`Eio.Buf_write` (same package) are the natural building
  blocks for length-prefixed framing over a `stream_socket`.
- Test convention confirmed from this repo's existing suites: `dune test` runs one Alcotest binary
  (`test/test_riptide.ml`) aggregating named suites; per-module test files live at
  `test/test_sim_<module>.ml` or similarly named; a fiber test needing an Eio loop wraps in
  `Eio_mock.Backend.run` for simulated tests. **Real-socket tests in this plan need a REAL event
  loop, not `Eio_mock.Backend`** — use `Eio_main.run` for those specifically (confirm this
  dependency is added to `test/dune`, it currently is not). The existing suite-wide `SIGALRM`
  watchdog (`test/test_riptide.ml`, documented there) exists because `Eio_mock.Backend`'s deadlock
  detector can't catch a busy-poll loop — the same trap applies to real-socket code, so don't
  write a nonblocking-poll retry loop anywhere in this plan; block properly instead
  (`Eio.Stream`/condition variables/`Buf_read` blocking reads).

## Architecture

**A new library, `lib/transport/`, defines the abstract interface. Two independent
implementations conform to it: an adapter over the existing (unmodified) `lib/sim/network.ml`,
and a new real TCP implementation.** Neither implementation depends on the other; both depend only
on `lib/transport`'s signature. This mirrors TigerBeetle's own `IO` type-parameter design (cited
in the spec): application/protocol code is written against the abstract signature only, and a
harness (test, or eventually the real binary) chooses which concrete implementation to link.

```
module type S = sig
  type t
  (** One local peer's live handle onto the transport. Already knows which peer it is --
      callers never pass their own identity, only the identity of who they're sending to. *)

  val send : t -> to_:int -> string -> unit
  (** [send t ~to_ bytes] sends already-encoded message bytes to peer [to_]. Returns once the
      bytes are handed to the transport (queued for a real send, or scheduled for simulated
      delivery) -- NOT once the peer has received them. Delivery order across different senders
      is NOT guaranteed (neither real TCP-across-multiple-connections nor the simulated fabric
      promises it) -- callers needing ordering must encode it in the message itself, which VSR's
      own message records already do (view/op numbers). *)

  val receive : t -> string
  (** [receive t] blocks (cooperatively) until the next message addressed to this handle's own
      peer is available, then returns its raw bytes. *)

  val receive_nonblocking : t -> string option
end
```

Deliberately **not** a callback-registration ("`on_receive`") shape, despite Decision 4's own
prose using that phrase: this repo's whole architecture is single-domain cooperative fibers with
an explicit receive-loop already the natural place per-peer work happens (see `lib/sim/network.ml`
itself, and the existing test suites' own style) — `let msg = receive t in handle msg` in a loop
is behaviorally equivalent to a per-message callback firing, just structured as a loop instead of
an inverted callback, and it is the shape both `Eio.Stream`-backed simulation and a real blocking
socket read naturally produce. **Ruling, recorded here rather than silently deviating**: this plan
treats "message-oriented, peer-addressed, not stream/connection-shaped" (Decision 4's actual
architectural point — the fault-injection/routing boundary is at whole-message send/receive, not
inside a connection's byte stream) as the binding requirement, and treats the specific
callback-vs-blocking-loop phrasing as an implementation-plan-level detail Decision 5's own text
elsewhere says such details are ("implementation-plan-level detail, not a design-level one").

## Global Constraints

- `Transport.S` is byte-oriented (`string` in, `string` out) — it knows nothing about `Value.t`,
  `Envelope.t`, or VSR message shapes. Encoding a protocol message to bytes (e.g. via
  `Value.canonical_encode`) and decoding it back is the caller's job, not this layer's — this
  keeps the transport genuinely swappable independent of whatever message format subtask 3.2
  eventually settles on.
- `lib/sim/network.ml`/`.mli` are **not modified** by this plan. It already has two tested
  consumers (`test/test_sim_network.ml`, `test/test_sim_faults.ml`) plus `workload.ml`; this plan
  adapts it from the outside (a new module wrapping its existing public interface), at zero risk
  to that already-reviewed code.
- Peer identity is `int` everywhere in `Transport.S` and both implementations' public interfaces.
- No new opam dependency beyond what's already installed (`eio`, `eio_main`, `eio_posix` are all
  already present in this box's durable switch per the research above; `test/dune` needs
  `eio_main`/`eio_posix` added if not already listed — check first, don't assume).
- Framing: every message is wrapped as an 8-byte big-endian length prefix (matching
  `Value.canonical_encode`'s own existing length-prefix convention, `lib/value.ml`'s
  `buf_add_len_prefixed`, for consistency across the codebase — do not invent a different prefix
  width) followed by that many raw bytes. No message-type discriminator at this layer (that's the
  caller's concern, inside the bytes it hands to `send`).
- Connection topology for the real transport: given a small, fixed, known peer set (a static
  membership table passed at creation, `(int * string * int) list` — peer id, host, port), exactly
  one TCP connection per unordered pair, established by convention (lower id dials higher id;
  higher id listens and accepts). Both directions of an established connection carry messages —
  it is not re-dialed per message.

## Task 1: Define `Transport.S` and the real TCP implementation

**Files:**
- Create: `lib/transport/dune`, `lib/transport/transport_intf.ml` (the `module type S` above,
  plus a short doc comment on each function — treat this `.ml`'s top-level module type as the
  authoritative spec per this repo's own convention that `.mli`/interface-defining files are the
  spec of record)
- Create: `lib/transport/tcp.ml`, `lib/transport/tcp.mli`

**Steps:**

1. `lib/transport/transport_intf.ml`: define `module type S` exactly as sketched in Architecture
   above. This file has no dependencies beyond stdlib.

2. `lib/transport/tcp.ml`/`.mli`: implement `Tcp : Transport.S` (as a functor or a plain module
   with a `create` returning `t` — your call, but `t`'s creation needs `sw:Eio.Switch.t`,
   `net:_ Eio.Net.t` (or the equivalent capability type this Eio version uses — check the actual
   installed `.mli`, don't guess), `my_id:int`, and `peers:(int * string * int) list` (the full
   membership table including self)).

   Connection-establishment algorithm (implement exactly this, it's deliberately simple given a
   small fixed cluster — do not build anything more general like retry-with-backoff reconnection
   logic; that's explicitly out of scope for this plan, note it as a follow-up if you think it's
   needed):
   - Start a listener on this peer's own `(host, port)` from the membership table
     (`Eio.Net.listen`).
   - For every peer with a **higher** id in the membership table: `Eio.Net.connect` to it
     (blocking until connected — since this is a small fixed cluster starting up together, a
     bounded retry loop with a short sleep between attempts is fine here, this is genuinely a
     "wait for the rest of the cluster to come up" case, not the general-reconnection case just
     ruled out above).
   - For every peer with a **lower** id: accept its incoming connection (`Eio.Net.accept_fork`,
     matching each accepted socket to the peer id it claims — see the handshake note below).
   - **Minimal handshake, needed because a plain `accept` doesn't tell you who just connected**:
     immediately after either side establishes a connection, the connecting side sends its own
     peer id as a fixed-width (8-byte big-endian, matching the framing convention) preamble before
     any framed messages; the accepting side reads that preamble first to learn which peer id this
     socket belongs to. Document this preamble explicitly in `tcp.mli` since it's a real,
     easy-to-forget wire-format detail future readers need to know about.
   - Once a connection is established+identified in either direction, spawn one background reader
     fiber per connection (`Eio.Fiber.fork`, using the `sw` passed to `create`) that loops reading
     length-prefixed frames (`Eio.Buf_read`) and pushes each decoded message's bytes onto a shared
     `Eio.Stream.t` inbox for this peer (mirroring `lib/sim/network.ml`'s own inbox pattern — read
     that module for the idiom even though you're not modifying or depending on it).
   - `send t ~to_ bytes`: look up the connection to `to_` in a table built during setup, write the
     length prefix then the bytes (`Eio.Buf_write`).
   - `receive`/`receive_nonblocking`: read from this peer's own inbox stream (`Eio.Stream.take`/
     `Eio.Stream.take_nonblocking` or equivalent — check actual `Eio.Stream` API).

3. Update `lib/dune` files as needed (new `lib/transport/dune` stanza: `(library (name
   riptide_transport) (libraries eio))`).

4. Run `dune build` to confirm this compiles before moving to Task 2 (no real test yet — Task 4
   covers testing both implementations together).

## Task 2: Adapt `lib/sim/network.ml` into a `Transport.S` implementation, without modifying it

**Files:**
- Create: `lib/sim/sim_transport.ml`, `lib/sim/sim_transport.mli`
- Modify: `lib/sim/dune` (add the new module + a dependency on `riptide_transport` for the shared
  signature)

**Steps:**

1. `lib/sim/sim_transport.ml`/`.mli`: implement `Sim_transport : Transport.S`, as a thin adapter:
   - `type t = { net : string Riptide_sim.Network.t; me : int }` (the underlying `Network.t` is
     instantiated with `'msg = string`, matching `Transport.S`'s byte-oriented contract — this is
     a NEW instantiation choice made only inside this adapter, not a change to `Network.ml`
     itself, which stays fully polymorphic and untouched for its existing consumers).
   - `send t ~to_ bytes = Network.send Fun.id t.net ~from_:(string_of_int t.me)
     ~to_:(string_of_int to_) bytes` — `Fun.id` as the corruption function, since real byte-level
     corruption for THIS adapter's purposes is out of scope (that's `lib/sim/network.ml`'s own
     PoC concern via its `fault_config`, already tested elsewhere; this adapter exists to prove
     interface substitutability, not to re-test fault injection).
   - `receive`/`receive_nonblocking`: delegate directly to `Network.receive`/
     `Network.receive_nonblocking`, translating `int` to `string` peer ids the same way.
   - Expose whatever setup helper Task 4's shared test needs to construct N `Sim_transport.t`
     handles sharing one underlying `Network.t` and to drive delivery (a thin wrapper around
     `Network.create`/`Network.register`/`Network.pump_all` — your judgment on the exact shape,
     but keep pump-driving explicit and visible to the test, not hidden inside `send`, since
     that's the real, correct behavior of the underlying simulated network and hiding it would
     make this adapter lie about being non-blocking-until-pumped).

2. `dune build` to confirm this compiles.

## Task 3: Wire framing correctness tests for the TCP implementation, in isolation

**Files:**
- Create: `test/test_transport_tcp.ml`
- Modify: `test/dune` (add the new suite, add `eio_main`/`eio_posix` to the library list if not
  already present — check first)

**Steps:**

1. A real-loopback test (using `Eio_main.run`, not `Eio_mock.Backend` — this needs real sockets):
   start 2-3 `Tcp` transports on `127.0.0.1` with distinct ports, send several messages in both
   directions, assert they arrive with correct content and at the correct peer's `receive`.
2. A framing-boundary test: send a message containing bytes that could be mistaken for a length
   prefix or contain the byte sequence of another message's framing, if framing were done wrong —
   confirm two back-to-back `send` calls on the same connection are received as two distinct
   messages via two `receive` calls, not concatenated or split.
3. A handshake test: confirm each side of a connection resolves the correct peer id for the other
   side (send a message immediately after connection setup completes and confirm it's attributed
   to the right sender-side inbox — i.e. that `receive` on peer A's handle only ever returns
   messages actually sent `~to_:A`, never a message meant for peer B, even though both connections
   might be active concurrently).

## Task 4: The substitutability proof — one shared test body, run against both implementations

**Files:**
- Create: `test/test_transport_shared.ml`
- Modify: `test/dune`

This is the actual proof of subtask 3.5's own stated test ("swapping the transport carrier
implementation must not require touching the application-level protocol code"), not a restatement
of it in prose. Write ONE functor:

```ocaml
module Make_transport_tests (T : Riptide_transport.Transport_intf.S) = struct
  let test_echo_between_peers ~run (make_cluster : unit -> T.t array) = ...
  (* application-level test logic: given an array of T.t handles (one per peer, indices matching
     peer ids), send a handful of messages in a few directions and assert every one arrives at
     the right peer with the right bytes, entirely through T.send / T.receive -- this function
     must not reference Sim_transport, Tcp, Network, or anything implementation-specific *)
end

module Sim_tests = Make_transport_tests(Sim_transport)
module Tcp_tests = Make_transport_tests(Tcp)
```

Each concrete module (`Sim_tests`, `Tcp_tests`) supplies its own `make_cluster`/`run` glue (e.g.
`Sim_tests`'s glue creates a `Network.t`, registers peers, and drives `pump_all` after each round;
`Tcp_tests`'s glue picks free loopback ports and calls `Eio_main.run`/`Eio.Switch.run`) — that glue
is the ONLY implementation-specific code in this file. The shared `test_echo_between_peers` body
itself must be identical for both, textually — if you find yourself writing two different
versions of the actual assertions, something about `Transport.S` doesn't actually abstract the two
implementations and needs to be fixed in Task 1/2, not worked around here.

Register both suites in `test/test_riptide.ml`.

## Self-Review Notes

- **Spec coverage:** Decision 4's core requirements — plain TCP, custom (not QUIC) framing,
  message-oriented peer-addressed abstraction, not a stream/connection abstraction — are all
  directly implemented. The callback-vs-blocking-receive deviation from Decision 4's literal
  prose is called out explicitly above as a ruling, not silently substituted.
- **Blast radius check:** `lib/sim/network.ml`/`.mli` untouched (Global Constraint, verified by
  this plan's own Task 2 design choice to wrap rather than modify). `lib/value.ml`/`lib/envelope.ml`
  untouched (this plan predates any message-format decision — that's subtask 3.2's job).
- **What this plan deliberately does NOT do**, to keep it bounded — flag these as open follow-ups
  for subtask 3.2 or later, not gaps in this plan: no reconnection/retry-after-established logic
  beyond initial cluster startup; no TLS/authentication (single-operator cluster, per Decision 1's
  own fault-model framing — not a stated requirement anywhere in the design spec); no
  backpressure/flow-control beyond whatever the OS TCP stack and `Eio.Buf_write` already provide;
  no integration with `lib/sim/network.ml`'s own fault-injection for the TCP implementation (a
  DST harness that wants to fault-inject *real* socket behavior, e.g. via a wrapping `Eio.Flow`
  that drops/delays at the byte level, is subtask 3.4's concern, building on top of this plan's
  `Transport.S` boundary — genuinely a different, later task, not silently owed by this one).
- **Toolchain grounding:** every Eio API cited above (`Eio.Net.listen`/`connect`/`accept_fork`,
  `Buf_read`/`Buf_write`, `eio 0.12`) was confirmed installed and read directly from this box's
  own opam switch before writing this plan, not assumed from training data — see the Research
  Grounding section. The implementer should still re-verify exact function signatures against the
  installed `.mli` files before use (`/work/toolchain/opam-root/5.0.0/lib/eio/*.mli`), since minor
  signature details (label names, capability type shape) matter and this plan's sketches are not
  guaranteed byte-exact.
