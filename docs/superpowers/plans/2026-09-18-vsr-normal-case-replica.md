# Implementation plan: VSR normal-case replica implementation

Second of several plans implementing the remainder of task-master subtask 3.2. The first plan
(`2026-09-18-vsr-wire-and-log.md`, merged) built prerequisite data structures (`Value.canonical_decode`,
`lib/vsr/message.ml`, `lib/vsr/replica_log.ml`). This plan builds the first real slice of protocol
logic: a running OCaml replica that implements `spec/tla/VSR.tla`'s **normal-case actions only**
(`ReceiveClientRequest`, `ReceivePrepareMsg`, `ReceivePrepareOkMsg`, `PrimaryExecuteOp`) with a
FIXED primary — deliberately mirroring how `VSR.tla` itself was built incrementally (its own
Task 2 was normal-case-only with a fixed `Primary(0)`; view-change came later, in its own Task 3).
View-change (`TimerSendSVC` through `ReceiveSV`) is explicitly out of scope for this plan — a
following plan adds it once this slice is proven correct in isolation, exactly the same
incremental structure the TLA+ spec itself used and that this project's own `CLAUDE.md` argues for
("expect the first extension mechanism to need real revision... get a real module built... fast").

Per this repo's own "no spec without running code" rule (`CLAUDE.md`): this plan does not stop at
implementing the four actions — it ends with a real, multi-replica test using `Sim_transport` that
proves a client value submitted at the primary is actually replicated and committed by running
OCaml code exchanging real wire-encoded messages, not by re-checking the already-proven TLA+ model.

## Research grounding (verified directly against this repo, not assumed)

**Every normal-case action, transcribed exactly from `spec/tla/VSR.tla`** (re-verify against the
actual file before implementing — this plan quotes it for convenience, the file is the source of
truth):

- `ReceiveClientRequest(v)` (VSR.tla:91-102): guarded on being the (fixed, for this plan) primary,
  and `v` not already present anywhere in the log (a real dedup check — VSR.tla does this by
  content equality, not an idempotency key; Decision 3's own text already flags a real idempotency
  key as separate future work, out of scope here). Appends `v` at `op_number = rep_op_number+1`,
  broadcasts `Prepare{view, n, v, k=rep_commit_number}` to every other replica.
- `ReceivePrepareMsg` (VSR.tla:110-123): guarded on being a normal backup, `m.view = View(r)`
  (trivial for this plan — view is always 0), and **strict op-number order**:
  `rep_op_number[r] + 1 = m.n`. Appends `m.v`, sets `rep_op_number = m.n`, advances
  `rep_commit_number` to `m.k` if higher (monotonic only — never regress), unicasts
  `PrepareOk{view, n=m.n, i=r}` back to the primary. **A `Prepare` that arrives out of order is
  simply not matched by this action in the TLA+ model — there is no buffering, reordering, or
  retry logic anywhere in this spec's scope** (state-transfer/GETSTATE-NEWSTATE, the mechanism
  that would let a lagging backup catch up, is explicitly out of scope per the design spec's
  Decision 1 and `spec/tla/README.md`'s own "Explicitly out of scope" list). This plan's
  implementation must replicate that same behavior — silently ignore an out-of-order `Prepare`
  rather than buffer or retry it — and must disclose this as a real, known liveness gap (see
  Global Constraints), not silently paper over it with ad hoc buffering that the TLA+ model was
  never checked against.
- `ReceivePrepareOkMsg` (VSR.tla:126-136): guarded on being the primary, `m.view = View(r)`.
  Updates the peer's own tracked op-number high-water-mark (`rep_peer_op_number[r][m.i]`) to
  `m.n`, but only if higher — cumulative, not per-op.
- `IsCommitted`/`PrimaryExecuteOp` (VSR.tla:139-155): a primary advances its commit-number by
  exactly one, from `rep_commit_number` to `rep_commit_number+1`, only once at least `f` OTHER
  replicas have acked that op-number or higher (`f = (ReplicaCount-1) \div 2`, giving `f+1`
  including the primary itself — majority for `2f+1` replicas). Never skips ahead even if a
  higher op is already quorum-acked; advances one at a time.

**Building blocks already merged and tested, to reuse — not to reimplement**:
- `Riptide_vsr.Message.t`/`.encode`/`.decode` (this plan's own predecessor) — the five VSR wire
  message types. This plan's normal-case slice uses only `Prepare` and `Prepare_ok`.
- `Riptide_vsr.Replica_log.t` — `create`/`append`/`get`/`replace_with`/`length`/`to_list`.
  `append` already raises `Out_of_order_append` on a mismatched position — this plan's
  `ReceivePrepareMsg` handler must catch/check for this and treat it as "action not enabled, drop
  the message," per the research grounding above, not let it propagate as an unhandled crash.
- `Transport_intf.S` (`send`/`receive`/`receive_nonblocking`, byte-oriented, `int` peer ids) — the
  real substrate this replica sends/receives over. **Its own doc comments are directly load-bearing
  for this plan's Architecture, re-read them before writing the replica's main loop**: no delivery
  ordering guarantee (not even same-sender FIFO against a conforming implementation, though `Tcp`
  happens to provide it); an implementation may require delivery to be driven externally (true of
  `Sim_transport`, via `pump_one`/`pump_all`) — a naive `let msg = receive t in handle msg` loop
  deadlocks against it. This plan's replica loop must work identically against both `Tcp` and
  `Sim_transport`, matching subtask 3.2's own stated test ("the exact same code path must run
  identically against a real network and a simulated one").

## Architecture

**A replica's mutable state, and a `handle_message` dispatch function that decodes one already-received
message and mutates that state — kept separate from any particular main-loop/driving strategy.**
This separation is what makes the replica portable across `Tcp` (self-driving) and `Sim_transport`
(externally pumped): the replica itself never calls `receive`/`pump` directly inside its own logic,
only `send`; a thin, separate driving loop (provided by this plan's Task 2 test harness, and later
by a real binary) is what actually calls `receive` and feeds bytes into `handle_message`.

```ocaml
(* lib/vsr/replica.ml, sketch -- not binding, your judgment on exact field/function names, but
   the SHAPE (state separate from message handling separate from any particular driving loop)
   is the binding architectural decision this plan makes. *)

type t = {
  my_id : int;
  replica_count : int;
  primary_id : int;               (* FIXED for this plan -- no view-change yet *)
  log : Replica_log.t;
  mutable op_number : int;
  mutable commit_number : int;
  peer_op_number : (int, int) Hashtbl.t;  (* primary-only bookkeeping; harmless if unused on a backup *)
  send : to_:int -> string -> unit;       (* a closure over some Transport.S.t's own send, so this
                                              module has zero direct dependency on Transport_intf
                                              itself -- keeps lib/vsr/ decoupled from lib/transport/,
                                              matching lib/transport/'s own "no dependency on
                                              VSR/protocol types" decoupling in the other direction *)
}

val create : my_id:int -> replica_count:int -> primary_id:int -> send:(to_:int -> string -> unit) -> t
val propose : t -> Riptide.Value.value -> unit  (* ReceiveClientRequest -- the primary-side entry
                                                    point a caller uses to submit a new value; a
                                                    no-op (or an explicit rejection -- your call,
                                                    document whichever) if [t] is not the primary *)
val handle_message : t -> string -> unit        (* decode + dispatch ONE already-received message;
                                                    this is what ReceivePrepareMsg/ReceivePrepareOkMsg
                                                    become *)
val is_committed : t -> Riptide.Value.value -> bool  (* or similar -- a read-only way for a test/
                                                         caller to observe whether a given value has
                                                         been committed on this replica, needed for
                                                         Task 2's own assertions; your judgment on
                                                         the exact query shape *)
```

`send`/`to_`/`from_` are deliberately NOT `Transport.S.t` directly — `lib/vsr/` should depend on
`Transport_intf.S`'s SHAPE (a `send : to_:int -> string -> unit` function), not on
`lib/transport/` as a library dependency, so this module stays usable by any future transport
without a build-time coupling. A caller constructs `t` by passing `(Tcp_instance.send tcp_handle)`
or `(fun ~to_ bytes -> Sim_transport.send sim_handle ~to_ bytes)` as the `send` closure. (If you
find a cleaner idiomatic OCaml way to express "depends on the shape of `Transport.S.send`, not on
`Transport.S` itself" — e.g. a first-class module parameter, a functor — you may use it instead of
a bare closure; the binding requirement is no `lib/transport` dependency in `lib/vsr/dune`, not
the specific mechanism.)

**`PrimaryExecuteOp` is not itself a discrete external event** (no incoming message triggers it in
the TLA+ spec — it's an always-enabled action whenever its guard holds) — call the quorum-check +
commit-advance logic from wherever it can actually become newly enabled: after `handle_message`
processes a `Prepare_ok` (the only action that can advance `peer_op_number` and thus make
`IsCommitted` newly true). Do not build a separate polling loop for this; drive it directly from
`ReceivePrepareOkMsg`'s own handler, matching how the TLA+ spec makes both actions available in the
same `Next` disjunction without implying one must poll for the other's enablement.

## Global Constraints

- **No view-change logic of any kind in this plan** — `primary_id` is fixed at `create` time and
  never changes; `view` is implicitly always `0` (or omit tracking it at all for this plan, since
  every message's `view` field will be `0` — your judgment, but document whichever choice clearly).
  A following plan adds view-change; do not anticipate its shape here beyond what's already fixed
  by `lib/vsr/message.ml`'s existing wire format (already merged, not this plan's to change).
- **`lib/vsr/dune` must not depend on `lib/transport`** — see Architecture above. `lib/transport/dune`
  already correctly has no dependency on `lib/vsr`; this plan must not introduce a dependency in
  the other direction either, keeping both libraries independently testable and matching the
  layering `Transport_intf.S`'s own header comment already documents (transport knows nothing
  about VSR; this plan's addition is that VSR-level code doesn't need to link the transport
  library either, only close over its `send` shape).
- **An out-of-order `Prepare` is silently dropped, not buffered, not retried, not treated as an
  error** — per the Research Grounding above, this exactly matches `spec/tla/VSR.tla`'s own
  behavior (the action simply isn't enabled for a mismatched `n`). **This is a real, disclosed
  liveness gap, not a defect to silently fix**: a backup that misses one `Prepare` (e.g. to
  `Sim_transport`'s own drop/reorder fault injection) has no way to catch up in this plan's scope
  — no COMMIT-message resend, no state-transfer, no retry. Document this explicitly in
  `replica.mli` and in this plan's own Task 2 test harness (which must therefore use RELIABLE,
  ORDERED delivery for its correctness assertions — i.e. `Sim_transport`'s DEFAULT fault config,
  all-zero probabilities, per `lib/sim/network.mli`'s own `default_fault_config` — proving the
  happy path works over real running code; testing the fault-injected/lossy path against this
  known gap is explicitly future work, likely subtask 3.4's territory once state-transfer or a
  retry mechanism exists to test against).
- **The replica's dedup check for `ReceiveClientRequest`** (VSR.tla: `v \notin { rep_log[r][i] :
  i \in DOMAIN rep_log[r] }`) must be implemented via `Replica_log.to_list` plus a real equality
  check on `Value.value` — use `Value.canonical_encode` equality (or `Value.content_hash`
  equality) for this, not OCaml's structural `=` on `Value.value` directly (the `Float` case's own
  documented bit-pattern semantics, `lib/value.mli`, mean structural `=` and canonical-encoding
  equality can diverge for NaN/`-0.0` — stay consistent with `Value`'s own established identity
  notion rather than introducing a second one).

## Task 1: The `Riptide_vsr.Replica` module — normal-case state and the four actions

**Files:**
- Create: `lib/vsr/replica.ml`, `lib/vsr/replica.mli`
- Modify: `lib/vsr/dune` (no new external dependency — only `riptide` (for `Value`) and this
  library's own existing `message.ml`/`replica_log.ml`; confirm `lib/transport` is NOT added)
- Create: `test/test_vsr_replica.ml` (single-replica-in-isolation tests only — Task 2 covers real
  multi-replica message exchange)

**Steps:**

1. Implement the `t` type and `create`/`propose`/`handle_message` roughly per the Architecture
   sketch above (your judgment on exact field names/shapes, the sketch is illustrative not
   binding). `handle_message` decodes via `Riptide_vsr.Message.decode`, dispatches on the
   constructor (`Prepare` → the backup-side handler; `Prepare_ok` → the primary-side handler;
   anything else — `Start_view_change`/`Do_view_change`/`Start_view` — is out of this plan's
   scope and should be silently ignored for now, NOT raise, since a real message stream will
   eventually carry them once a later plan adds view-change and this replica must not crash on a
   message type it doesn't yet handle). `Message.decode`'s own `Malformed_message` exception
   (already handled defensively by that module, per the prior plan's review) should also be
   caught here and treated as "drop this message" — a real network can deliver garbage
   (`Transport_intf.S`'s own documented "no payload integrity" guarantee), and a replica must not
   crash on it.
2. Implement `ReceiveClientRequest` (as `propose`), `ReceivePrepareMsg`, `ReceivePrepareOkMsg`,
   and the `PrimaryExecuteOp` quorum-check-and-advance logic (called from inside
   `ReceivePrepareOkMsg`'s handler, per Architecture above) — transcribe each guard and effect
   precisely from the Research Grounding section's own citations, not from paraphrase.
3. Write `lib/vsr/replica.mli` to a documentation standard matching `replica_log.mli`/`message.mli`
   (cite the exact VSR.tla line/action each function implements, state the out-of-order-drop
   behavior explicitly per Global Constraints, document `propose`'s behavior on a non-primary
   replica clearly).
4. Single-replica-in-isolation tests in `test/test_vsr_replica.ml` (no real transport, no second
   replica — just calling `handle_message` directly with hand-constructed encoded messages and
   inspecting the resulting state via whatever read-only accessors you exposed): a primary
   receiving `propose` broadcasts the right `Prepare` (assert on the closure's captured sends); a
   backup receiving an in-order `Prepare` appends and replies with the right `PrepareOk`; a backup
   receiving an out-of-order `Prepare` is silently dropped (log unchanged, no reply sent); a
   primary receiving enough `Prepare_ok`s to reach quorum advances its commit-number by exactly
   one, not skipping ahead even if a higher op is already quorum-acked (construct a scenario where
   op 2 becomes quorum-acked before op 1 does, and confirm commit-number does NOT jump to 2 while
   op 1 is still uncommitted); a duplicate client value submitted twice via `propose` is rejected
   the second time (the dedup check).
5. `dune build`/`dune test`, confirm clean.
6. Commit.

## Task 2: Real multi-replica proof — running code, not the TLA+ model

**Files:**
- Create: `test/test_vsr_replica_cluster.ml`
- Modify: `test/dune`, `test/test_riptide.ml`

This is the actual point of this plan, per `CLAUDE.md`'s "no spec without running code": prove
that real, running OCaml replicas — not the already-proven TLA+ model — actually replicate and
commit a value when driven over a real (simulated, for determinism) transport.

**Steps:**

1. Using `lib/sim/sim_transport.ml` (already merged) at `Network.default_fault_config` (reliable,
   ordered-in-the-sense-of-no-corruption delivery — per this plan's own Global Constraints, this
   plan's replica has a known gap against reordering/loss, so this test must not exercise that
   gap yet), build a small cluster: 3 `Riptide_vsr.Replica.t` instances (matching
   `spec/tla/VSR.cfg`'s own `ReplicaCount = 3` bound), each wired to its own `Sim_transport.t`
   handle sharing one underlying `Network.t`, with a fixed primary (replica 1, matching
   `Primary(0) = 1` per `VSR.tla`'s own `Primary` formula).
2. Run each replica's receive-and-dispatch loop as its own Eio fiber (`let rec loop () = let msg =
   Sim_transport.receive handle in Replica.handle_message replica msg; loop ()`), all under one
   `Eio_mock.Backend.run`, alongside explicit `Network.pump_all` calls driving delivery — matching
   the pump-agnostic pattern `test/test_transport_shared.ml` already established for exactly this
   "replica code portable across self-driving and externally-pumped transports" concern.
3. Call `Replica.propose` on the primary's replica with a real `Value.value` (not a placeholder —
   use a nontrivial shape, e.g. a `Record` or `Sequence`, matching how Task 2 of the prior plan
   tested `Message` round-trips with non-trivial payloads rather than bare scalars).
4. Pump until quiescent, then assert: every replica's log (via whatever read accessor you exposed)
   contains the proposed value at op-number 1; the primary's commit-number has advanced to 1;
   the backups' commit-numbers have ALSO advanced to 1 (this only happens because a SUBSEQUENT
   `Prepare` carries the primary's `k` field — if this test only ever proposes ONE value, verify
   whether backup commit-number advancement genuinely needs a second `Prepare` to piggyback on,
   per `ReceivePrepareMsg`'s own `k`-field-driven advancement logic, and if so, either propose a
   second value to trigger it, or explicitly test-and-document that a backup's commit-number
   legitimately lags by design until further traffic arrives — don't let the test silently pass
   by asserting something weaker than what you intended to prove).
5. A second test: propose multiple values in sequence from the primary, confirm all replicas
   converge to the same log content and the same (or correctly-lagging, per Step 4's own finding)
   commit-number.
6. `dune build`/`dune test`, confirm clean, run several times to check for flakiness (real fiber
   interleaving, even under `Eio_mock.Backend`'s determinism, is worth stress-testing a few times
   given this is new, non-trivial concurrent code).
7. Commit.

## Self-Review Notes

- **Spec coverage**: implements exactly `spec/tla/VSR.tla`'s four normal-case actions, with a
  fixed primary — deliberately, not view-change, matching how the spec itself was built
  incrementally. This is a real, disclosed scope boundary (see Global Constraints' own
  out-of-order-drop discussion), not an oversight.
- **Blast radius check**: only `lib/vsr/` (new files) and `test/` are touched; `lib/transport/`,
  `lib/sim/network.ml`, `lib/log.ml`, `lib/value.ml`, `lib/envelope.ml` are all untouched — this
  plan builds strictly on top of already-merged, already-reviewed primitives.
- **The single highest-risk judgment call in this plan**: whether `PrimaryExecuteOp`'s logic
  (driven from inside `ReceivePrepareOkMsg`'s own handler, per Architecture) correctly reproduces
  the TLA+ spec's own "advance by exactly one, never skip" semantics under real concurrent
  message arrival order (e.g. `Prepare_ok`s for op 3 arriving before op 2's quorum is reached) —
  Task 1's own test suite (Step 4) is specifically designed to catch a regression here; whoever
  reviews this plan's Task 1 should treat this as the single most important thing to verify
  independently, not just re-read the implementer's own tests.
- **What the NEXT plan (view-change) will need from this one**: `Replica.t`'s `primary_id` being
  fixed at `create` time will need to become mutable (or the type will need restructuring) once
  view-change can actually change who the primary is — noted here so that plan's own author isn't
  surprised by needing to touch this plan's own `replica.ml` again. This is expected, healthy
  incremental-extension cost, not a design mistake in this plan (per `CLAUDE.md`'s own "expect the
  first extension mechanism to need real revision" principle).
