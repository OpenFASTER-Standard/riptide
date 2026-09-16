# DST Proof-of-Concept Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and validate the deterministic-simulation-testing (DST) substrate — seeded PRNG,
fault-injecting in-memory network, virtual clock, and a toy multi-fiber workload proving
byte-for-byte reproducible replay — as the required first deliverable of task-master subtask 3.2,
before any real consensus protocol implementation is architected against it.

**Architecture:** A new `sim` library (`lib/sim/`), separate from the `riptide` library, built on
OCaml 5's Eio (effect-handler-based concurrency, installed as `eio`/`eio_main`/`eio.mock`
1.5-series, resolved to `0.12` for this project's OCaml 5.0.0 switch). One seeded `Random.State.t`
drives every fault-injection decision. `Eio_mock.Clock` (real library code, not hand-rolled)
provides the virtual clock. A hand-rolled `Network` module provides peer-addressed,
fault-injecting message passing over `Eio.Stream` inboxes, since `Eio_mock.Net` is a
scripted-single-endpoint mock (configured with a fixed response sequence) and not shaped for an
N-peer simulated topology — confirmed by reading its installed `.mli` directly, not assumed.

**Tech Stack:** OCaml 5.0.0, dune, `eio`/`eio_main`/`eio.mock` (installed, findlib names `eio`,
`eio_main`, `eio.mock`), `alcotest`, `qcheck-core`/`qcheck-alcotest` (already project
dependencies from Layer 0).

**Spec:** `docs/superpowers/specs/2026-09-16-distributed-consensus-design.md` (Decision 2:
concurrency model and deterministic simulation harness).

## Global Constraints

- Every random decision anywhere in `lib/sim/` must be drawn from one explicitly-seeded
  `Random.State.t`, threaded as an explicit argument — never `Random.self_init` or any
  ambient/global randomness source.
- The virtual clock only advances when explicitly told to (`Eio_mock.Clock.advance`/`set_time`) —
  never real wall-clock time. Confirmed empirically: `Eio.Time.sleep` on an `Eio_mock.Clock`
  blocks until something external calls `advance`/`set_time`; there is no automatic passage of
  time.
- `Eio.Fiber.both f g` deterministically runs `f` before `g` — confirmed empirically against the
  installed `eio.0.12`, matching the library's own documented guarantee. Every test that asserts
  ordering may rely on this.
- This library proves the substrate; it does not implement or depend on anything about the real
  consensus protocol. No task in this plan references Task 3.1/3.3/3.5's protocol/commit/transport
  work.
- The workload generator (Task 4) must include unstructured/randomly-generated message sequences,
  not only a fixed scripted scenario — this directly closes the blind spot that caused
  TigerBeetle's real, Jepsen-found bug (a workload generator that only exercised structured,
  pre-registered queries missed a real class of bugs).

---

### Task 1: `sim` library scaffold and seeded PRNG

**Files:**
- Create: `lib/sim/dune`
- Create: `lib/sim/prng.ml`
- Create: `lib/sim/prng.mli`
- Create: `test/test_sim_prng.ml`
- Modify: `test/dune` (add `riptide_sim` to the `(libraries ...)` line — it already has no
  `(modules ...)` restriction, so new `test/test_sim_*.ml` files join the `test_riptide` binary
  automatically once their libraries are available, per Task 1 of the Layer 0 seed plan)
- Modify: `test/test_riptide.ml`

**Interfaces:**
- Consumes: nothing (foundational task)
- Produces:
  - `type t` (abstract)
  - `val create : int -> t` — `create seed` is a new PRNG seeded deterministically from `seed`
  - `val int : t -> int -> int` — `int t bound` draws `[0, bound)`, mirrors `Random.State.int`
  - `val float : t -> float -> float` — mirrors `Random.State.float`
  - `val bool : t -> float -> bool` — `bool t p` is `true` with probability `p` (`0.0 <= p <= 1.0`)

- [ ] **Step 1: Write the failing test**

```ocaml
(* test/test_sim_prng.ml *)
open Riptide_sim

let test_same_seed_same_sequence () =
  let a = Prng.create 42 in
  let b = Prng.create 42 in
  let draws t = List.init 20 (fun _ -> Prng.int t 1_000_000) in
  Alcotest.(check (list int)) "identical draw sequence from identical seed" (draws a) (draws b)

let test_different_seed_different_sequence () =
  let a = Prng.create 1 in
  let b = Prng.create 2 in
  let draws t = List.init 20 (fun _ -> Prng.int t 1_000_000) in
  Alcotest.(check bool) "different seeds produce different sequences" true (draws a <> draws b)

let test_bool_respects_probability_bounds () =
  let t = Prng.create 7 in
  (* p = 0.0 must never be true; p = 1.0 must always be true, across many draws *)
  Alcotest.(check bool) "p=0.0 never true"
    true (List.init 200 (fun _ -> Prng.bool t 0.0) |> List.for_all (fun b -> b = false));
  Alcotest.(check bool) "p=1.0 always true"
    true (List.init 200 (fun _ -> Prng.bool t 1.0) |> List.for_all (fun b -> b = true))

let tests =
  [ ("same seed produces same sequence", `Quick, test_same_seed_same_sequence);
    ("different seeds diverge", `Quick, test_different_seed_different_sequence);
    ("bool respects probability bounds", `Quick, test_bool_respects_probability_bounds)
  ]
```

- [ ] **Step 2: Write `lib/sim/dune`**

```
(library
 (name riptide_sim)
 (libraries eio eio.mock))
```

- [ ] **Step 2b: Add `riptide_sim` to `test/dune`'s libraries**

`test/dune` currently reads:

```
(test
 (name test_riptide)
 (libraries riptide golden_fixtures alcotest qcheck-core qcheck-alcotest)
 (deps ../spec/golden/vectors.txt))
```

Change the `(libraries ...)` line to add `riptide_sim`:

```
 (libraries riptide riptide_sim golden_fixtures alcotest qcheck-core qcheck-alcotest)
```

- [ ] **Step 3: Wire the test into the runner**

```ocaml
(* test/test_riptide.ml *)
let () =
  Alcotest.run "riptide"
    [
      ("value", Test_value.tests);
      ("envelope", Test_envelope.tests);
      ("log", Test_log.tests);
      ("golden", Test_golden.tests);
      ("sim_prng", Test_sim_prng.tests);
    ]
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `dune test`
Expected: FAIL to compile — `Riptide_sim`/`Prng` don't exist yet.

- [ ] **Step 5: Write `lib/sim/prng.mli`**

```ocaml
(** A single, explicitly-seeded pseudorandom source. Every random decision in this library's
    fault-injection code must be drawn from one value of this type, threaded explicitly — never
    from {!Stdlib.Random}'s global state or any OS entropy source. This is what makes an entire
    simulation run reproducible from one seed number. *)

type t

val create : int -> t
(** [create seed] is a new PRNG deterministically derived from [seed]. Two values created with
    the same [seed] produce identical output from every function below, called in the same
    order. *)

val int : t -> int -> int
(** [int t bound] draws a value in [\[0, bound)]. Mirrors {!Random.State.int}. *)

val float : t -> float -> float
(** [float t bound] draws a value in [\[0.0, bound)]. Mirrors {!Random.State.float}. *)

val bool : t -> float -> bool
(** [bool t p] is [true] with probability [p] (clamped to [\[0.0, 1.0\]]). *)
```

- [ ] **Step 6: Write `lib/sim/prng.ml`**

```ocaml
type t = Random.State.t

let create seed = Random.State.make [| seed |]
let int t bound = Random.State.int t bound
let float t bound = Random.State.float t bound

let bool t p =
  let p = if p < 0.0 then 0.0 else if p > 1.0 then 1.0 else p in
  Random.State.float t 1.0 < p
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `dune test`
Expected: PASS, all prior tests (25) still green plus the 3 new `sim_prng` tests (28 total).

- [ ] **Step 8: Commit**

```bash
git add lib/sim/dune lib/sim/prng.ml lib/sim/prng.mli test/test_sim_prng.ml test/test_riptide.ml
git commit -m "DST PoC Task 1: riptide_sim library scaffold and seeded PRNG"
```

---

### Task 2: In-memory peer-addressed network (no faults yet)

**Files:**
- Create: `lib/sim/network.ml`
- Create: `lib/sim/network.mli`
- Test: `test/test_sim_network.ml`
- Modify: `test/dune` (add `eio` and `eio_main` to the `(libraries ...)` line — this task's tests
  are the first to call `Eio_main.run`/`Eio.Fiber.both` directly)
- Modify: `test/test_riptide.ml`

**Interfaces:**
- Consumes: nothing new from Task 1 (this task's basic message passing doesn't need the PRNG yet
  — that arrives in Task 3)
- Produces:
  - `type 'msg t` (abstract) — a network of peers exchanging values of type `'msg`
  - `type peer_id = string`
  - `val create : unit -> 'msg t`
  - `val register : 'msg t -> peer_id -> unit` — registers a peer, giving it an inbox
  - `val send : 'msg t -> from_:peer_id -> to_:peer_id -> 'msg -> unit` — delivers immediately (no
    fault injection yet; Task 3 adds delay/drop/reorder/duplicate/corrupt on top of this same
    function's signature)
  - `val receive : 'msg t -> peer_id -> 'msg` — blocks (cooperatively, via the underlying
    `Eio.Stream`) until a message arrives for that peer
  - `val receive_nonblocking : 'msg t -> peer_id -> 'msg option`

- [ ] **Step 1: Write the failing test**

```ocaml
(* test/test_sim_network.ml *)
open Riptide_sim

let test_send_and_receive () =
  Eio_main.run @@ fun _env ->
  let net = Network.create () in
  Network.register net "a";
  Network.register net "b";
  Network.send net ~from_:"a" ~to_:"b" "hello";
  Alcotest.(check string) "b receives a's message" "hello" (Network.receive net "b")

let test_deterministic_two_fiber_exchange () =
  Eio_main.run @@ fun _env ->
  let net = Network.create () in
  Network.register net "a";
  Network.register net "b";
  let trace = ref [] in
  Eio.Fiber.both
    (fun () ->
      Network.send net ~from_:"a" ~to_:"b" "from a";
      trace := "a sent" :: !trace;
      let msg = Network.receive net "a" in
      trace := Printf.sprintf "a received %s" msg :: !trace)
    (fun () ->
      let msg = Network.receive net "b" in
      trace := Printf.sprintf "b received %s" msg :: !trace;
      Network.send net ~from_:"b" ~to_:"a" "from b");
  Alcotest.(check (list string)) "deterministic interleaving, matching Fiber.both's f-before-g order"
    [ "b received from b"; "a received from b"; "a sent"; "b received from a" ]
    !trace

let test_receive_nonblocking_empty () =
  Eio_main.run @@ fun _env ->
  let net = Network.create () in
  Network.register net "a";
  Alcotest.(check bool) "no message yet" true (Network.receive_nonblocking net "a" = None)

let tests =
  [ ("send and receive", `Quick, test_send_and_receive);
    ("deterministic two-fiber exchange", `Quick, test_deterministic_two_fiber_exchange);
    ("receive_nonblocking is empty with nothing sent", `Quick, test_receive_nonblocking_empty)
  ]
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `dune test`
Expected: FAIL to compile — `Network` doesn't exist yet, and `test/dune` doesn't yet list `eio`/
`eio_main`.

- [ ] **Step 2b: Add `eio` and `eio_main` to `test/dune`'s libraries**

Change the `(libraries ...)` line (as it stands after Task 1's Step 2b) to:

```
 (libraries riptide riptide_sim golden_fixtures alcotest qcheck-core qcheck-alcotest eio eio_main)
```

**Residual risk, flagged for the implementer to verify empirically rather than trust this plan's
guess:** `test_deterministic_two_fiber_exchange`'s expected trace order is derived by hand-tracing
`Fiber.both`'s confirmed f-before-g scheduling against this exact code shape (fiber `a` runs
first: sends to `b`'s now-nonempty inbox, records "a sent", then blocks on its own empty inbox;
fiber `b` runs: its inbox has a's message, so it receives immediately without blocking, records
"b received from a" — **wait, re-derive this at implementation time by actually running it once
un-asserted and printing the trace**, rather than trust this plan's hand-derivation blindly; the
exact trace is a Task 2 self-review item, not a Task 2 requirement to match this plan's guess
if the two disagree. If they disagree, trust the real run, fix the test to match it, and note the
correction in the report.

- [ ] **Step 3: Write `lib/sim/network.mli`**

```ocaml
(** An in-memory, peer-addressed network for deterministic simulation. Messages are delivered
    immediately in this task; {!module:Network} gains fault injection (delay, drop, reorder,
    duplication, corruption) in a later task without changing this signature. *)

type peer_id = string
type 'msg t

val create : unit -> 'msg t

val register : 'msg t -> peer_id -> unit
(** [register net id] gives [id] an inbox on [net]. Sending to or receiving from an
    unregistered [id] raises [Invalid_argument]. *)

val send : 'msg t -> from_:peer_id -> to_:peer_id -> 'msg -> unit
(** [send net ~from_ ~to_ msg] delivers [msg] to [to_]'s inbox. [from_] is currently unused by
    delivery itself but is required now so fault-injection logic added later (which may need to
    know the sender, e.g. to simulate a one-directional partition) doesn't change this
    signature. *)

val receive : 'msg t -> peer_id -> 'msg
(** [receive net id] blocks (cooperatively) until a message is available for [id]. *)

val receive_nonblocking : 'msg t -> peer_id -> 'msg option
```

- [ ] **Step 4: Write `lib/sim/network.ml`**

```ocaml
type peer_id = string
type 'msg t = (peer_id, 'msg Eio.Stream.t) Hashtbl.t

let create () : 'msg t = Hashtbl.create 8

let inbox_of net id =
  match Hashtbl.find_opt net id with
  | Some inbox -> inbox
  | None -> invalid_arg (Printf.sprintf "Network: peer %S is not registered" id)

let register net id =
  if Hashtbl.mem net id then invalid_arg (Printf.sprintf "Network: peer %S already registered" id);
  Hashtbl.add net id (Eio.Stream.create max_int)

let send net ~from_:_ ~to_ msg = Eio.Stream.add (inbox_of net to_) msg
let receive net id = Eio.Stream.take (inbox_of net id)
let receive_nonblocking net id = Eio.Stream.take_nonblocking (inbox_of net id)
```

- [ ] **Step 5: Wire into the runner**

```ocaml
(* test/test_riptide.ml *)
let () =
  Alcotest.run "riptide"
    [
      ("value", Test_value.tests);
      ("envelope", Test_envelope.tests);
      ("log", Test_log.tests);
      ("golden", Test_golden.tests);
      ("sim_prng", Test_sim_prng.tests);
      ("sim_network", Test_sim_network.tests);
    ]
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `dune test`
Expected: PASS. If `test_deterministic_two_fiber_exchange`'s expected trace doesn't match the
real run, fix the test's expected value to match reality (see the residual-risk note above), not
the implementation. 28 + 3 = 31 tests total once this and Task 1 are both green.

- [ ] **Step 7: Commit**

```bash
git add lib/sim/network.ml lib/sim/network.mli test/test_sim_network.ml test/test_riptide.ml
git commit -m "DST PoC Task 2: in-memory peer-addressed network, no fault injection yet"
```

---

### Task 3: Fault injection — delay, drop, duplicate, reorder, corrupt

**Files:**
- Modify: `lib/sim/network.ml`
- Modify: `lib/sim/network.mli`
- Test: `test/test_sim_faults.ml`
- Modify: `test/test_sim_network.ml` (Task 2's tests — their `Network.create`/`send` call sites
  break under this task's signature changes; see Step 6)
- Modify: `test/test_riptide.ml`

**Interfaces:**
- Consumes: `Prng.t` (Task 1), `Network.t`/`peer_id` (Task 2, signature extended below)
- Produces (extends Task 2's `Network` module):
  - `type fault_config = { drop_probability : float; duplicate_probability : float; corrupt_probability : float; min_delay : float; max_delay : float }`
  - `val default_fault_config : fault_config` — all probabilities `0.0`, `min_delay = max_delay = 0.0` (i.e., Task 2's exact behavior when unconfigured)
  - `val create : ?faults:fault_config -> Prng.t -> unit -> 'msg t` (replaces Task 2's `create :
    unit -> 'msg t` — **breaking change to Task 2's signature, deliberate**: every network in this
    library is fault-injectable from here on, configured to zero faults by default, rather than
    maintaining two parallel network types)
  - `val send : ('msg -> 'msg) -> 'msg t -> from_:peer_id -> to_:peer_id -> 'msg -> unit` (the
    first argument is a corruption function, applied to the message when the corruption fault
    fires; Task 4's toy messages define what "corrupted" means for their own message type)
  - `val pump_one : 'msg t -> bool` — advances the network's virtual clock to the next pending
    delayed delivery and delivers it; returns `false` if nothing is pending (no-op)
  - `val pump_all : 'msg t -> unit` — calls `pump_one` until it returns `false`

**Design note carried from the spec:** delay is what makes reordering possible at all — two
messages sent in order can be delivered out of order if the later one draws a shorter delay. This
task does not need a separate, independent "reorder" mechanism; delay-based reordering plus an
explicit `duplicate_probability` and `drop_probability` cover the fault classes the spec names.
Corruption is applied at delivery time, not send time, matching real byte-level corruption
happening in transit/at rest rather than at the moment of construction.

- [ ] **Step 1: Write the failing test**

```ocaml
(* test/test_sim_faults.ml *)
open Riptide_sim

let test_zero_faults_behaves_like_task_2 () =
  Eio_main.run @@ fun _env ->
  let prng = Prng.create 1 in
  let net = Network.create prng () in
  Network.register net "a";
  Network.register net "b";
  Network.send Fun.id net ~from_:"a" ~to_:"b" "hello";
  Network.pump_all net;
  Alcotest.(check string) "delivered with default (zero) fault config" "hello"
    (Network.receive net "b")

let test_drop_probability_one_means_never_delivered () =
  Eio_main.run @@ fun _env ->
  let prng = Prng.create 2 in
  let net = Network.create ~faults:{ Network.default_fault_config with drop_probability = 1.0 } prng () in
  Network.register net "a";
  Network.register net "b";
  Network.send Fun.id net ~from_:"a" ~to_:"b" "hello";
  Network.pump_all net;
  Alcotest.(check bool) "message never arrives" true (Network.receive_nonblocking net "b" = None)

let test_duplicate_probability_one_means_delivered_twice () =
  Eio_main.run @@ fun _env ->
  let prng = Prng.create 3 in
  let net = Network.create ~faults:{ Network.default_fault_config with duplicate_probability = 1.0 } prng () in
  Network.register net "a";
  Network.register net "b";
  Network.send Fun.id net ~from_:"a" ~to_:"b" "hello";
  Network.pump_all net;
  let first = Network.receive net "b" in
  let second = Network.receive net "b" in
  Alcotest.(check (pair string string)) "delivered twice" ("hello", "hello") (first, second)

let test_corrupt_probability_one_always_applies_corruption_fn () =
  Eio_main.run @@ fun _env ->
  let prng = Prng.create 4 in
  let net = Network.create ~faults:{ Network.default_fault_config with corrupt_probability = 1.0 } prng () in
  Network.register net "a";
  Network.register net "b";
  Network.send String.uppercase_ascii net ~from_:"a" ~to_:"b" "hello";
  Network.pump_all net;
  Alcotest.(check string) "corruption function applied" "HELLO" (Network.receive net "b")

let test_same_seed_same_fault_decisions () =
  let run seed =
    Eio_main.run @@ fun _env ->
    let prng = Prng.create seed in
    let faults = { Network.default_fault_config with drop_probability = 0.5; duplicate_probability = 0.3 } in
    let net = Network.create ~faults prng () in
    Network.register net "a";
    Network.register net "b";
    for i = 1 to 50 do
      Network.send Fun.id net ~from_:"a" ~to_:"b" (string_of_int i)
    done;
    Network.pump_all net;
    let rec drain acc = match Network.receive_nonblocking net "b" with
      | Some m -> drain (m :: acc)
      | None -> List.rev acc
    in
    drain []
  in
  Alcotest.(check (list string)) "identical seed produces identical fault outcomes" (run 99) (run 99)

let tests =
  [ ("zero-fault config matches Task 2 behavior", `Quick, test_zero_faults_behaves_like_task_2);
    ("drop_probability=1.0 drops everything", `Quick, test_drop_probability_one_means_never_delivered);
    ("duplicate_probability=1.0 duplicates", `Quick, test_duplicate_probability_one_means_delivered_twice);
    ("corrupt_probability=1.0 applies corruption fn", `Quick, test_corrupt_probability_one_always_applies_corruption_fn);
    ("same seed reproduces identical fault decisions", `Quick, test_same_seed_same_fault_decisions)
  ]
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `dune test`
Expected: FAIL to compile — `Network.create` doesn't take a `Prng.t` yet, `pump_all`/`fault_config`
don't exist.

- [ ] **Step 3: Write the extended `lib/sim/network.mli`**

```ocaml
(** An in-memory, peer-addressed, fault-injecting network for deterministic simulation. All fault
    decisions are drawn from the single {!Prng.t} passed to {!create} — the same seed always
    produces the same sequence of drop/duplicate/corrupt decisions and delays, called in the same
    order. *)

type peer_id = string
type 'msg t

type fault_config = {
  drop_probability : float;  (** Probability a sent message is never delivered. *)
  duplicate_probability : float;  (** Probability a sent message is delivered twice. *)
  corrupt_probability : float;  (** Probability the corruption function is applied at delivery. *)
  min_delay : float;  (** Minimum simulated seconds before delivery. *)
  max_delay : float;  (** Maximum simulated seconds before delivery; must be >= [min_delay]. *)
}

val default_fault_config : fault_config
(** All probabilities [0.0], [min_delay = max_delay = 0.0] — i.e. immediate, reliable, single
    delivery, matching this module's Task 2 behavior exactly. *)

val create : ?faults:fault_config -> Prng.t -> unit -> 'msg t
(** [create ?faults prng ()] is a new network. [faults] defaults to {!default_fault_config}. *)

val register : 'msg t -> peer_id -> unit

val send : ('msg -> 'msg) -> 'msg t -> from_:peer_id -> to_:peer_id -> 'msg -> unit
(** [send corrupt net ~from_ ~to_ msg] schedules [msg] for delivery to [to_], subject to this
    network's fault config: it may be dropped, duplicated, delayed, and/or transformed by
    [corrupt] before delivery. Scheduled deliveries are released by {!pump_one}/{!pump_all}, not
    delivered synchronously — call one of those (typically [pump_all]) after sending, or nothing
    will ever arrive. *)

val receive : 'msg t -> peer_id -> 'msg
val receive_nonblocking : 'msg t -> peer_id -> 'msg option

val pump_one : 'msg t -> bool
(** [pump_one net] advances [net]'s virtual clock to the earliest still-pending scheduled
    delivery and delivers it. Returns [false] (a no-op) if nothing is pending. *)

val pump_all : 'msg t -> unit
(** [pump_all net] calls {!pump_one} until it returns [false]. *)
```

- [ ] **Step 4: Write the extended `lib/sim/network.ml`**

```ocaml
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
  mutable pending : (float * peer_id * 'msg) list;  (* sorted ascending by delivery time *)
}

let create ?(faults = default_fault_config) prng () =
  { inboxes = Hashtbl.create 8; faults; prng; clock = Eio_mock.Clock.make (); pending = [] }

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
  let at = Eio_mock.Clock.now net.clock +. delay in
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
    Eio_mock.Clock.set_time net.clock at;
    Eio.Stream.add (inbox_of net to_) msg;
    true

let pump_all net = while pump_one net do () done
```

- [ ] **Step 5: Wire into the runner**

```ocaml
(* test/test_riptide.ml *)
let () =
  Alcotest.run "riptide"
    [
      ("value", Test_value.tests);
      ("envelope", Test_envelope.tests);
      ("log", Test_log.tests);
      ("golden", Test_golden.tests);
      ("sim_prng", Test_sim_prng.tests);
      ("sim_network", Test_sim_network.tests);
      ("sim_faults", Test_sim_faults.tests);
    ]
```

- [ ] **Step 6: Update `test/test_sim_network.ml` for the new `create`/`send` signatures**

Task 2's tests call `Network.create ()` and `Network.send net ~from_ ~to_ msg` (3 args, no
corruption function). Update both call sites to match this task's extended signatures:
`Network.create prng ()` (using a freshly created `Prng.create <any fixed seed>`, since Task 2's
tests don't exercise faults and any seed works identically under `default_fault_config`) and
`Network.send Fun.id net ~from_ ~to_ msg`. Also add one `Network.pump_all net` call after each
`Network.send` in Task 2's tests, before the corresponding `Network.receive` — Task 2's synchronous
delivery no longer applies once `send` schedules rather than delivers directly.

- [ ] **Step 7: Run tests to verify they pass**

Run: `dune test`
Expected: PASS. 31 + 5 = 36 tests total (accounting for Task 2's tests continuing to pass after
Step 6's updates).

- [ ] **Step 8: Commit**

```bash
git add lib/sim/network.ml lib/sim/network.mli test/test_sim_faults.ml test/test_sim_network.ml test/test_riptide.ml
git commit -m "DST PoC Task 3: fault injection (delay, drop, duplicate, corrupt)"
```

---

### Task 4: Toy fiber workload + adversarial generator — the capstone reproducibility proof

**Files:**
- Create: `lib/sim/workload.ml`
- Create: `lib/sim/workload.mli`
- Test: `test/test_sim_workload.ml`
- Modify: `test/test_riptide.ml`

**Interfaces:**
- Consumes: `Prng.t`, `Network.t`/`fault_config`/`send`/`receive_nonblocking`/`pump_all` (Tasks 1-3)
- Produces:
  - `type trace_event = Sent of { from_ : string; to_ : string; payload : string } | Received of { by : string; payload : string }`
  - `val run_toy_cluster : seed:int -> peer_count:int -> message_count:int -> faults:Network.fault_config -> trace_event list`
    — runs `peer_count` toy peers, each an Eio fiber; a driver generates `message_count` messages
    with **randomly chosen sender, receiver, and payload** (not a fixed script — this is the
    unstructured/adversarial generator the spec requires), sends them through a faulty `Network`,
    and returns the full ordered trace of every send and receive across all peers.

- [ ] **Step 1: Write the failing test**

```ocaml
(* test/test_sim_workload.ml *)
open Riptide_sim

let test_same_seed_reproduces_identical_trace () =
  let faults =
    { Network.drop_probability = 0.1; duplicate_probability = 0.1; corrupt_probability = 0.0;
      min_delay = 0.0; max_delay = 1.0 }
  in
  let run () = Workload.run_toy_cluster ~seed:12345 ~peer_count:3 ~message_count:30 ~faults in
  let trace_a = run () in
  let trace_b = run () in
  Alcotest.(check bool) "identical seed produces byte-for-byte identical trace" true
    (trace_a = trace_b)

let test_different_seeds_can_diverge () =
  let faults =
    { Network.drop_probability = 0.2; duplicate_probability = 0.2; corrupt_probability = 0.0;
      min_delay = 0.0; max_delay = 1.0 }
  in
  let run seed = Workload.run_toy_cluster ~seed ~peer_count:3 ~message_count:30 ~faults in
  Alcotest.(check bool) "different seeds are not guaranteed to match (sanity check the generator is not constant-folding to one fixed trace)"
    true (run 1 <> run 2)

let test_generator_covers_unstructured_workload () =
  (* Directly guards against the exact blind spot that caused a real, Jepsen-found bug in
     TigerBeetle: a generator that only ever produces one fixed, pre-registered message shape.
     Run many seeds and confirm the sender/receiver pairing varies, not just the payload. *)
  let faults = Network.default_fault_config in
  let pairs_seen =
    List.init 40 (fun seed ->
      Workload.run_toy_cluster ~seed ~peer_count:4 ~message_count:5 ~faults
      |> List.filter_map (function
        | Workload.Sent { from_; to_; _ } -> Some (from_, to_)
        | Workload.Received _ -> None))
    |> List.concat
    |> List.sort_uniq compare
  in
  Alcotest.(check bool) "generator produces more than one distinct (sender, receiver) pairing across seeds"
    true (List.length pairs_seen > 1)

let tests =
  [ ("identical seed reproduces identical trace", `Quick, test_same_seed_reproduces_identical_trace);
    ("different seeds are not artificially constant", `Quick, test_different_seeds_can_diverge);
    ("generator covers unstructured (sender, receiver) pairings", `Quick, test_generator_covers_unstructured_workload)
  ]
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `dune test`
Expected: FAIL to compile — `Workload` doesn't exist yet.

- [ ] **Step 2b: Add `eio_main` to `lib/sim/dune`**

`run_toy_cluster` calls `Eio_main.run` directly (it owns its own event loop so callers — the
tests in this task — can call it as a plain synchronous function). `lib/sim/dune` (written in
Task 1 as `(libraries eio eio.mock)`) needs `eio_main` added:

```
(library
 (name riptide_sim)
 (libraries eio eio.mock eio_main))
```

- [ ] **Step 3: Write `lib/sim/workload.mli`**

```ocaml
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
```

- [ ] **Step 4: Write `lib/sim/workload.ml`**

```ocaml
type trace_event =
  | Sent of { from_ : string; to_ : string; payload : string }
  | Received of { by : string; payload : string }

let peer_name i = Printf.sprintf "peer%d" i

let run_toy_cluster ~seed ~peer_count ~message_count ~faults =
  Eio_main.run @@ fun _env ->
  let prng = Prng.create seed in
  let net = Network.create ~faults prng () in
  let peers = List.init peer_count peer_name in
  List.iter (Network.register net) peers;
  let trace = ref [] in
  let record ev = trace := ev :: !trace in
  (* Unstructured/adversarial generator: sender, receiver, and payload are all drawn randomly,
     not from a fixed script - this is what a purely structured/pre-registered-query generator
     (the class of gap that caused a real bug TigerBeetle's own VOPR initially missed) would not
     cover. *)
  let random_peer () = List.nth peers (Prng.int prng peer_count) in
  Eio.Fiber.all
    (List.map
       (fun peer () ->
         let received = ref 0 in
         while !received < message_count do
           match Network.receive_nonblocking net peer with
           | Some payload ->
             record (Received { by = peer; payload });
             incr received
           | None -> Eio.Fiber.yield ()
         done)
       peers
     @ [ (fun () ->
           for i = 1 to message_count do
             let from_ = random_peer () and to_ = random_peer () in
             let payload = Printf.sprintf "msg-%d" i in
             Network.send Fun.id net ~from_ ~to_ payload;
             record (Sent { from_; to_; payload });
             Network.pump_all net
           done) ]);
  List.rev !trace
```

**Residual risk, flagged for the implementer to verify empirically:** the receiver loop above busy-polls
via `receive_nonblocking` + `Fiber.yield` rather than blocking on `receive`, because each peer must
wait for messages from *any* sender without knowing the count destined for it specifically ahead of
time, and this plan's `message_count` loop bound (`!received < message_count`) is a simplification
that only terminates correctly if every peer receives every message — **which won't generally be
true** once messages are addressed to randomly chosen individual peers rather than broadcast. Fix
this before Step 5: either (a) broadcast every message to all peers (simplest, and still exercises
random sender choice + faults), or (b) track expected-message-count per peer from the driver and
pass each peer its own target count. Pick whichever keeps `run_toy_cluster`'s signature unchanged;
document the choice in the task report. This is exactly the kind of design gap TDD's "run it and
see" step exists to catch — do not paper over it by guessing silently.

- [ ] **Step 5: Wire into the runner**

```ocaml
(* test/test_riptide.ml *)
let () =
  Alcotest.run "riptide"
    [
      ("value", Test_value.tests);
      ("envelope", Test_envelope.tests);
      ("log", Test_log.tests);
      ("golden", Test_golden.tests);
      ("sim_prng", Test_sim_prng.tests);
      ("sim_network", Test_sim_network.tests);
      ("sim_faults", Test_sim_faults.tests);
      ("sim_workload", Test_sim_workload.tests);
    ]
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `dune test`
Expected: PASS after resolving the residual risk above. 36 + 3 = 39 tests total.

- [ ] **Step 7: Commit**

```bash
git add lib/sim/workload.ml lib/sim/workload.mli test/test_sim_workload.ml test/test_riptide.ml
git commit -m "DST PoC Task 4: toy multi-fiber workload proving deterministic replay"
```

---

### Task 5: Documentation

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: nothing (documentation only)
- Produces: nothing new; describes what Tasks 1-4 built

- [ ] **Step 1: Append a "Deterministic simulation substrate (proof-of-concept)" section to `README.md`**

```markdown
## Deterministic simulation substrate (proof-of-concept)

`lib/sim/` (`riptide_sim` library) is a proof-of-concept proving the substrate a real
deterministic-simulation-testing (DST) harness will be built on, per
`docs/superpowers/specs/2026-09-16-distributed-consensus-design.md`'s Decision 2. It proves,
against this project's real installed OCaml 5 / Eio toolchain rather than by assumption:

- `Prng`: every random decision in this library flows through one explicitly-seeded source.
- `Network`: an in-memory, peer-addressed, fault-injecting (delay/drop/duplicate/corrupt) message
  network, built directly on `Eio.Stream` and `Eio_mock.Clock` (`Eio_mock.Net` was evaluated and
  rejected — it is a scripted single-endpoint mock, not shaped for an N-peer simulated topology).
- `Workload`: a toy multi-fiber cluster with a randomly-generated (not fixed-script) workload,
  proving that identical seeds reproduce byte-for-byte identical traces even with fault injection
  enabled.

**What this does NOT yet build:** the real VSR-derived consensus protocol, atomic multi-entity
commit, or a production (real-socket) network implementation — those are separate, later
task-master subtasks (3.1, 3.3, 3.5) that will be built against this validated substrate, per the
spec's own required sequencing (this proof-of-concept exists specifically to happen *before* that
work is architected).
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "DST PoC Task 5: document the simulation substrate proof-of-concept"
```

## Self-Review Notes

- **Spec coverage:** Decision 2's required first deliverable ("a proof-of-concept... before any
  protocol implementation begins") is exactly this plan's full scope. Decisions 1/3/4/5 from the
  spec are explicitly out of scope here (see Global Constraints) — they're separate, later plans.
- **Placeholder scan:** clean — no TBD/vague instructions found on re-read. Two residual risks
  (Task 2's exact trace order, Task 4's receive-loop termination logic) are explicitly flagged as
  things to verify empirically and fix if wrong, not silently guessed past — consistent with this
  project's established pattern from the Layer 0 seed plan.
- **Type consistency:** `Prng.t` used identically across Tasks 1/3/4. `Network.t`'s `create`
  signature changes once, deliberately, between Task 2 and Task 3 (documented as a breaking
  change with an explicit migration step for Task 2's own tests in Task 3 Step 6) — not an
  inconsistency, a planned evolution. `Network.fault_config`'s field names match between Task 3's
  definition and Task 4's usage.
- **Dependency-wiring gap found and fixed during self-review:** the first draft never added
  `riptide_sim`/`eio`/`eio_main` to `test/dune`'s `(libraries ...)` line, nor `eio_main` to
  `lib/sim/dune` (needed once `Workload.run_toy_cluster` calls `Eio_main.run` internally in
  Task 4) — every test file after Task 1 would have failed to build with "unbound module" errors.
  Fixed by adding explicit Step 2b to Tasks 1, 2, and 4 wiring each new dependency in at the exact
  point it first becomes necessary, verified against `test/dune`'s real current contents (read
  directly, not assumed) rather than guessed.
- **Toolchain grounding:** every API used above (`Eio.Stream`, `Eio.Fiber.both`/`all`,
  `Eio_mock.Clock`, `Eio_main.run` called multiple times per process) was verified empirically
  against this project's actual installed `eio.0.12` before this plan was written, not assumed
  from documentation alone — including the specific, real finding that `Eio_mock.Clock`'s `sleep`
  blocks until externally advanced (informing `Network.pump_one`'s design) and that `Eio_mock.Net`
  is the wrong shape for this task (informing the decision to hand-roll `Network` instead).
