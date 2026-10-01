# Layer 2 ledger module — design

Status: approved, written up for `writing-plans`.
Grounds task-master Task 6 ("Build one real, demanding Layer 2 module end to end"), subtasks 6.1-6.4.

## Context

Task 6's whole point, per its own description and this repo's `CLAUDE.md` ("Expect the first
extension mechanism to need real revision"): build ONE real, demanding Layer 2 module against the
boundary Tasks 1-5 shipped, and let it genuinely pressure-test that boundary — not several
imagined domains, not a toy. Task 6.1 is explicitly "a decision gate, not an implementation step,"
requiring a genuine, project-owner-chosen need rather than a domain picked for architectural
symmetry.

**Domain chosen: a double-entry ledger** (TigerBeetle-style), as riptide's own rigorous
proving-ground module — not wired to one external production consumer yet. This is a well-grounded
choice, not an arbitrary one: this project's entire Layer 0 architecture was already validated
against TigerBeetle's own real-world design choices before this task existed — VSR-derived
consensus was chosen specifically citing TigerBeetle's production use of it (
`2026-09-16-distributed-consensus-design.md`), the DST harness is explicitly modeled on
TigerBeetle's VOPR, and the storage layer's fault-tolerance work cites TigerBeetle's own FAST 2018
paper. A double-entry ledger is the domain this whole stack's own design decisions were already
reasoned about.

**Scope: a focused core, not the full TigerBeetle feature set.** Accounts, transfers, the
fundamental balance invariant, and real atomicity across the two accounts in a transfer. Richer
TigerBeetle features (two-phase/pending transfers, linked atomic transfer chains, multi-currency/
multi-ledger support) are explicit, named non-goals for this task — see Non-goals below. This
follows the same "build one real thing first, generalize later" sequencing already established
between this task and Task 10 (a second domain module, explicitly deferred).

### A real gap found and resolved during this brainstorm, not papered over

Task 6.3's own text asks to build this module's schema "using Task 2.1's functorial value
universe... via the schema-morphism machinery." Investigated directly: Task 2.1 (the
schema-morphism/schema-evolution mechanism itself) is still `pending` in `tasks.json` — it exists
only as prose in that task's own description, not as real code anywhere in `lib/`, `docs/`, or
`spec/`. Building a real schema-evolution/morphism mechanism now, before any module has ever
actually needed to evolve a schema, would be exactly the premature-generalization trap Task 6.2's
own TigerBeetle citation warns against ("the invariant is domain-specific by design... do not try
to make it generalize prematurely") — and genuinely Task 2.1's own scope, not something to absorb
into Task 6 unplanned.

**Resolution**: this module's schema uses the real, proven pattern every existing domain type in
this codebase already follows — hand-written `to_value`/`of_value` over `Riptide.Value.value`,
exactly like `Envelope.to_value` and `Batch_commit.write_to_value`/`write_of_value`. Task 2.1's
schema-morphism mechanism remains a separate, unbuilt prerequisite; this task does not build it,
and does not pretend to use it. Task 6.3's own wording should be read as aspirational/premature at
the time it was written, not as a literal requirement this task can actually satisfy as stated.

## Decision 1: two enforcement layers, not one — and a real constraint on what the second layer can actually check

The module's logic (WASM, admission-verified, Reactor-dispatched) decides WHETHER a transfer
should happen (a business rule — sufficient funds). A structural well-formedness check (is this
ONE write, by itself, a valid-looking ledger entry) is enforced separately, host-side, at the
`Batch_commit` authorization checkpoint Task 5.5 already built as "mechanism only, no policy" —
this is the first real policy that checkpoint ever carries.

**Why not enforce well-formedness only inside the WASM guest** (the simpler-looking alternative):
a guest-only check can't satisfy Task 6.2's own test requirement — "the invariant cannot be
violated by any sequence of valid-looking module operations" — because nothing stops a buggy or
compromised guest (or any other code that can reach `propose_write` with this module's merge_key
shape) from skipping the check. Putting the authoritative check at the one chokepoint every write
already passes through (independently audited and fuzz-tested by the final whole-branch review's
own `scripts/check-authorization-checkpoint` and `test_batch_commit_authorization_fuzz.ml`) makes
single-write well-formedness structurally unbypassable, not just conventionally respected.

**A real limit, found while writing the implementation plan, not assumed away**: `Batch_commit`'s
real, current signature is `val authorize : write -> decision` — it is evaluated **once per write,
in isolation**, with no visibility into the other writes in the same `propose` call. The original
version of this design (now corrected) assumed `authorize` could check "do the two legs of this
transfer, together, sum to zero" — genuinely impossible with this signature, since a single call
to `authorize` never sees both legs at once. Extending `Batch_commit`'s own authorize signature to
take the whole batch would be a Layer 0 change, which this repo's own governance model (small,
aligned group, everyone who approves has implemented against it) puts outside this task's scope to
decide unilaterally.

**Resolution, scoped to what the real mechanism can actually guarantee:**
- `authorize`, per write, checks exactly what a SINGLE write can self-certify: this leg's own
  `amount` is positive, its two named accounts are distinct, and its `merge_key` matches the
  account it claims to be about. This is real, structurally-enforced, un-bypassable protection
  against any malformed or self-inconsistent single write — including one constructed by a future
  caller that never goes through this module's own trusted code at all.
- The property `authorize` genuinely cannot check — that a transfer's two legs are truly a matched,
  balancing pair, both present in the same batch — is instead guaranteed **by construction**, in
  the one piece of trusted host code that ever builds a ledger transfer's write list: the
  `~propose` closure wired into this module's `Reactor.subscribe` call (Decision 2 below). WASM
  guest code can only reach `Batch_commit.propose` through that closure — never directly — so an
  adversarial or buggy guest can influence *which* accounts/amount a transfer names, but never
  *whether* the two legs it produces are a consistent pair, because the closure always derives both
  legs from the one `transfer_id`/`amount`/`from_account`/`to_account` tuple of a single decoded
  request.
- This is a real, disclosed difference in guarantee strength, not a hidden weakening: a
  single-write property (an individual leg's own well-formedness) gets the authorize checkpoint's
  full, structurally-unbypassable treatment; a cross-write property (two legs forming a true pair)
  gets construction-correctness instead, verified by direct fuzz-testing of the construction code
  itself (Testing strategy, below) rather than by the checkpoint. **This is exactly the kind of
  concrete boundary friction Task 6.4 exists to surface for Task 7** — record it there as a
  candidate for a future batch-aware `authorize` signature, not something to solve inside this task.

  > **CLOSED by Task 7** (`2026-10-01-layer2-boundary-revision-design.md`, Decision 4, and that
  > plan's Task 4). `Batch_commit.create` gained `?authorize_batch:(write list -> decision)`,
  > evaluated once per batch under the same guard as the per-write hook, and `Authorize.authorize_batch`
  > is this module's implementation of it: a batch carrying transfer legs must carry exactly two, same
  > `transfer_id`, same actor, opposite roles, equal amounts, each naming the other's account — and,
  > when the batch also carries this module's own committed decision record, legs that match exactly
  > the request that decision authorises. The cross-write property is therefore now checkpoint-enforced
  > rather than construction-guaranteed; construction in `Legs` still happens, so the module gets both.
  > The two consequences this paragraph and the Error-handling section below draw from the gap are
  > correspondingly obsolete: a well-formed single leg proposed directly is now DENIED, which is why
  > both test harnesses' seeding conventions became balanced mint pairs.

This split is still deliberate, not redundant: "does this request make business sense" (can
evolve, can have bugs, lives in WASM) is a different concern from "is this one write, by itself,
well-formed" (must never break, lives at the authorization checkpoint) is a different concern again
from "are both legs of this transfer really a matched pair" (guaranteed by construction, verified
by fuzzing the construction code directly).

## Decision 2: schema and components

Hand-written `to_value`/`of_value` over `Riptide.Value.value`, per the resolved gap above:

- `transfer_request : { request_id : int64; from_account : int64; to_account : int64; amount : int64 }`
  — proposed directly by a client (or this task's own test driver) at merge_key `"ledger.requests"`.
  `amount` is always a positive magnitude. Not itself balance-affecting; `authorize` allows it
  unconditionally. **Account identifiers are fixed-width `int64`, not free-form strings** — this
  is a deliberate schema choice, not an incidental one: it matches TigerBeetle's own real
  convention (128-bit integer account/transfer IDs, simplified here to OCaml's native `int64` for
  the focused-core scope), and it is what makes the wire encoding between host and guest tractable
  for a hand-written `.wat` fixture to parse (see Decision 3 below) — variable-length string
  parsing inside hand-written WebAssembly text is a real, separate complexity this task has no
  need to take on.
- `transfer_leg : { transfer_id : int64; role : [ `Debit | `Credit ]; actor : actor_id;
  this_account : int64; other_account : int64; amount : int64 }` — **self-certifying**: every field
  `authorize` needs to validate THIS leg alone is present in THIS leg's own payload (no need to see
  its sibling). `amount` is always positive; this leg's own signed balance delta is derived, not
  stored — `-amount` if `role = Debit`, `+amount` if `role = Credit`. `merge_key =
  "ledger.account." ^ Int64.to_string this_account`.

  `actor` records who authored the leg, and `authorize` **denies any leg whose payload `actor`
  disagrees with the `actor` of the write carrying it** — so for any leg that reaches the committed
  log the field is a structurally-guaranteed fact, not a claim. It is in the payload deliberately
  (final whole-branch review, finding I4): a `materialize_sink`'s own `write` callback receives only
  `~merge_key` and the payload, never the committing write's `actor`, so without this field the
  host-side accumulator downstream cannot tell a module-authored leg apart from one authored by any
  other path, and legs from the two can collide in its already-applied table. This is how that
  information reaches the sink without changing a Layer 0 signature.

**Account identifiers are constrained to be non-negative** (final whole-branch review, finding I2),
enforced by `authorize` on both write shapes. `Schema.account_merge_key` renders an id as *signed*
decimal while the guest's own hand-rolled routine renders it *unsigned*, so host and guest agree on
the key for a non-negative id and disagree for a negative one — which made a negatively-identified
account structurally unaddressable by the guest (it read balance 0 at a key nothing is ever written
to, and declined everything). Shrinking the valid domain to the range both sides already agree on
was chosen over hand-writing two's-complement decimal rendering in WebAssembly text.

**Both legs of a transfer are always constructed together, from one request, by the same trusted
closure**: given an approved `transfer_request {transfer_id = request_id; from_account; to_account;
amount}`, the module's `~propose` closure always builds exactly
`[ { transfer_id; role = Debit; this_account = from_account; other_account = to_account; amount };
   { transfer_id; role = Credit; this_account = to_account; other_account = from_account; amount } ]`
and proposes them as one atomic `Batch_commit.propose` call — see Decision 1 for why this
construction-time guarantee, not `authorize`, is what makes the pair genuinely balanced.

**Account balances are materialized state, not a new lattice/CRDT type.** Each account's balance
is the Last-Write-Wins materialized value at `"ledger.account.<id>"`. An account implicitly exists
(balance 0) the first time it's referenced — no separate "open account" flow, consistent with the
focused-core scope.

**Correction (final whole-branch review, finding I5): balances are maintained by host-side
accumulation over delta-carrying legs, not by the guest proposing a new absolute total.** This
paragraph previously described the balance mechanism as "the exact
read-materialized-then-propose-new-total pattern `counter.wat` already established" — that
mechanism was never built, and could not have been: what the guest's `propose_write` produces (via
the trusted `Legs` construction) is a `transfer_leg` *descriptor* carrying a role and a positive
magnitude, not an absolute balance, and a single transfer moves *two* accounts, so there is no one
total for a guest to propose. What actually ships, and is what this correction describes:

- A committed `transfer_leg` carries a signed *delta* by construction — `-amount` for `Debit`,
  `+amount` for `Credit` (`Accumulator.balance_delta`, the one place that derivation lives).
- `Accumulator.materialize_sink` — host-side, in `lib/ledger/`, wired as the `~materialize` sink —
  reads the account's current materialized balance, adds that delta, and writes the new absolute
  total back. It is `counter.wat`'s read-then-write-new-total *shape*, moved to the host where the
  information to do it actually exists.
- That accumulation is **not idempotent under replay**, unlike an ordinary lattice-join sink, so it
  carries an explicit already-applied guard. `Batch_commit.propose`'s materialize step re-runs on
  every call for a key, not only the one that committed, and re-hands the same committed leg
  payloads to the sink each time; without the guard a delta applies twice. See
  `accumulator.mli` for the guard's key and the two limits disclosed alongside it.

*(Cross-reference corrected in the same pass, finding M10: the `counter.wat` referred to here is
from plan-local **Task 7 of the Layer 0/Layer 2 boundary plan**
(`docs/superpowers/plans/2026-09-30-layer0-layer2-boundary.md`, commit `4227bae`) — **not**
task-master Task 7 ("Revise the Layer 0/Layer 2 boundary based on real usage"), which is still
pending and is where this module's own friction findings feed. The two numberings collide, and the
original wording did not say which was meant.)*

**Atomicity across the two legs of a transfer** comes for free from `Batch_commit`'s own existing
all-or-nothing multi-write commit (hardened since Task 3.3) — nothing new needed: if either leg's
own well-formedness check fails `authorize`, the WHOLE batch (both legs) is refused, never a
partial transfer.

**One `Batch_commit.t` handle for the whole module**, one `authorize` function branching on write
shape: a `"ledger.requests"` write is allowed unconditionally; a `"ledger.account.*"` write (a
transfer leg) gets the self-certifying per-write check described in Decision 1 — `amount > 0`,
`this_account <> other_account`, `this_account` matches the merge_key's own account suffix. A
`from_account = to_account` request therefore produces two same-account legs and is structurally
**Deny**'d here (via the `this_account <> other_account` check), not silently accepted as a no-op
net-zero transfer — the module itself has no special case for it either; it is the authorize
check's job to reject it.

**The ledger WASM module**: admission-verified (real `cosign`-signed artifact), declares a
`Protocol` permitting `handle` from `init` (same shape every existing module uses), subscribed via
`Reactor.subscribe` to `"ledger.requests"`.

## Decision 3: the guest reads its trigger via `read_materialized`, not `arg` — and why

`Reactor.wrap_materialize_sink` hard-wires `arg` to `Riptide.Value.canonical_encode` of the
triggering write's own payload — not something a subscribing module can override. Parsing that
real canonical encoding (sorted-key records, tagged sums, length-prefixed sequences) by hand inside
a `.wat` guest is real, separate complexity this task has no need to take on, and the established,
already-proven precedent in this codebase (`counter.wat`) avoids it entirely: it ignores `arg` and
instead calls `host.read_materialized` on its own subscribed key, using a **host-chosen, simple,
fixed-width byte convention** the host-side `~read` closure controls completely.

This module follows the same precedent: `handle` ignores `arg` and calls
`read_materialized("ledger.requests")` to learn the triggering request's own fields. This is sound
specifically because `wrap_materialize_sink` materializes a write BEFORE dispatching it (never
after, never batched with others) and dispatch is sequential, never concurrent (Decision 1's own
cited contract) — so during THIS dispatch, "the current materialized value of `ledger.requests`"
and "the request that triggered this dispatch" are always the same thing, even though
`"ledger.requests"` itself is an ordinary Last-Write-Wins key with no queue semantics of its own.

**Wire convention between host and guest** (this module's own private agreement between its
`~read`/`~propose` closures and `ledger.wat`, exactly as `counter.wat` and its own test already
established a private raw-little-endian-i32 convention for `"count"` — not part of the general
loader ABI): every `int64` field is 8 bytes, little-endian, fields in struct order, no
length-prefixing needed anywhere since every field is fixed-width.
- `read_materialized("ledger.requests")` returns exactly 32 bytes: `request_id ++ from_account ++
  to_account ++ amount` (4 × 8-byte LE `int64`).
- `read_materialized("ledger.account." ^ Int64.to_string account)` returns exactly 8 bytes: the
  account's current balance as one LE `int64` (absent/`None` from the host closure means balance
  0, matching `counter.wat`'s own "no value yet" convention). A separate call from the request
  read above, matching the two genuinely different concerns involved — "what was requested" versus
  "what is the current state of a different key."
- `propose_write` takes **33** bytes: a one-byte **decision tag** (`0` = declined, `1` = accepted)
  followed by the same 32 bytes as the `"ledger.requests"` read above (`request_id ++ from_account
  ++ to_account ++ amount`). The guest forwards the request bytes it already has resident and writes
  only the tag, so this stays self-contained and independent of any cross-call state-sharing between
  the `~read` and `~propose` closures. The `~propose` closure
  (`Accumulator.handle_guest_decision`) decodes these 33 bytes exactly once into the decision plus
  the one `transfer_request` it constructs both legs from (Decision 2). A tag byte that is neither
  `0` nor `1` is rejected outright rather than coerced — "nonzero means accepted" would silently
  turn a corrupt payload into an authorisation to move money.

  **Correction (final whole-branch review, finding C1): the tag, and the fact that the guest calls
  `propose_write` on BOTH outcomes, are a fix for a Critical defect, not a convenience.** Originally
  the guest called `propose_write` only on approval and simply returned otherwise, which left a
  decline with no trace anywhere. See Error handling below for the full mechanism.

  **Signedness is part of this convention** (finding I1): every field is a *signed* `int64`, and the
  balance encoding round-trips negative values faithfully, so a guest comparing them must use
  WebAssembly's signed comparisons (`i64.gt_s`, not `i64.gt_u`). Reading an overdrawn account's
  negative balance as unsigned yields roughly 1.8e19 and approves every further withdrawal from an
  account already in the red.

## Data flow (end to end)

```
Client proposes {request_id, from, to, amount}
  -> Batch_commit.propose (authorize: unconditional allow for "ledger.requests")
  -> materializes at "ledger.requests"
  -> Reactor dispatches the ledger module (fresh Loader.instantiate, Protocol check on "handle")
  -> module calls read_materialized("ledger.account.<from>") -> current balance
  -> module checks amount <= balance, SIGNED compare (finding I1)
  -> module ALWAYS calls propose_write(decision_tag ++ encode(request)), on both outcomes
       (finding C1 -- a decline that reports nothing is not durable)
  -> host ~propose closure = Accumulator.handle_guest_decision
       - request_id already decided? the FIRST decision stands, always:
            - previously DECLINED: nothing proposed, ever (this is C1's fix)
            - previously ACCEPTED: legs re-proposed from the RECORDED request, under the same
              idempotency key -- the recovery path for a legs batch a view change discarded
              before it committed; idempotent, and cannot alter amount or accounts
       - first decision for this request_id: recorded, then
            - declined: recorded and nothing proposed
            - accepted: ALWAYS constructs both legs together from the one request
              (Decision 2) -> [debit_leg; credit_leg]
                 -> Batch_commit.propose (authorize: per-leg self-certifying check)
                      - both legs individually well-formed: Allow
                           -> VSR commits both legs atomically
                           -> Accumulator.materialize_sink folds each leg's signed delta into
                              "ledger.account.<from>" and "ledger.account.<to>"
                      - either leg malformed (amount<=0, same-account, negative account,
                        merge_key/account mismatch, actor mismatch): Deny -> whole batch
                        refused, authorization_denials++
```

Every arrow is an existing, already-tested mechanism (materialize-then-dispatch,
read_materialized/propose_write, atomic multi-write commit, the authorization checkpoint) used
for the first time with a real domain and a real policy, instead of a toy counter.

## Error handling

- **Insufficient funds**: not an error — a legitimate business decision. **Corrected (final
  whole-branch review, finding C1): the module still reports the decline, explicitly, rather than
  "simply never calling `propose_write`" as this bullet originally said.** The original wording
  described a silent early return, which reads as the obvious implementation of "a module
  legitimately choosing not to act must be a clean no-op" and was a Critical defect. A decision
  nothing records is not durable, and this guest is re-dispatched whenever its triggering
  `"ledger.requests"` write is re-materialized — which happens for entirely routine reasons nobody
  has to ask for: `Batch_commit.propose` re-materializes unconditionally on every retry, and the
  empty-writes drain idiom and `materialize_up_to` both do it on demand. On such a re-dispatch the
  guest re-reads the *current* balance, which may have grown since, legitimately decides ACCEPT
  where it previously declined, and both legs commit — a transfer no client ever re-requested,
  moving real money. Live-reproduced, then fixed on both sides: the guest always calls
  `propose_write` with a decision tag (Decision 3), and `Accumulator.handle_guest_decision` makes
  the first decision recorded for a `request_id` final. The no-op convention is preserved where it
  genuinely applies — a declined request still commits nothing — it just is not implemented by
  staying silent. One place a silent return *is* still right: a dispatch that cannot read a
  well-formed request at all has no `request_id` to report a decision about.

  Scope of that guarantee, stated rather than implied: the decision table is in-memory, so a
  decision can never flip *within a process's lifetime*, which is what makes every idiom that
  actually triggered the bug unreachable. Making it durable across a restart means committing the
  decision to the replicated log as its own write shape — a real schema extension, and a question
  about what a module may durably record that belongs with the boundary revision (task-master Task
  7). Disclosed at `Accumulator.t`.

  **Correction (fix-wave round 2, item 1): the paragraph above understated the restart gap, and the
  real one is a great deal worse than "a decision could be re-decided".** `Accumulator.t` holds
  *two* in-memory tables, not one — the decision table, and `applied_legs`, the guard that stops a
  committed leg being folded into a balance twice. Both die with the process. So a restart followed
  by nothing more exotic than the documented `materialize_up_to` catch-up walk — which is exactly
  what a restarting node is expected to do, with no stale decline and no re-decided request needed
  anywhere — re-applies **every leg in the log** to balances that already contain them, silently
  **doubling every account's balance**. Live-reproduced: 1500 units across two accounts became
  3000. The committed log stays perfectly correct throughout; only the materialized balances
  diverge from it, which is the same silent shape as finding I4 and the reason "the log is fine" is
  never sufficient evidence for this module.

  This is disclosed, not fixed, and is deliberately pinned as current behaviour by
  `test_restart_without_durable_dedup_state_doubles_balances` in
  `test/test_ledger_end_to_end.ml` (a test that asserts the *bad* outcome on purpose, so a future
  incidental change here cannot alter the semantics unnoticed; read its own comment before
  touching it). Closing it needs both halves made durable: the decision committed to the log as
  its own write shape, and materialization given either a durable watermark or — the better
  framing — a `materialize_sink` that receives its write's own batch identity, so "already
  applied" is answerable from the log rather than from memory. That second half is already
  recorded as boundary friction (3) in task-master subtask 7.1, and this restart consequence is
  recorded there too; both are Task 7's, not this module's.

  > **CLOSED by Task 7** (the Layer 0/Layer 2 boundary revision — see
  > `2026-10-01-layer2-boundary-revision-design.md`, Decisions 1-3, and that plan's Task 4). Both
  > halves were made durable, exactly as sketched above and in that order: a decision is now
  > committed to the log as its own write shape (`Legs.decision_write`), and
  > `materialize_sink.write` now receives its write's own `(idempotency_key, position)` identity,
  > which is the injective key a durable per-write materialization watermark is kept under.
  > **That watermark is NOT something `Batch_commit` itself applies** (corrected by the final
  > whole-branch review, Minor — this sentence said "which `Batch_commit` itself uses", the exact
  > internal-gate framing that boundary revision's own Critical 1 removed, and this is the ledger
  > module's own authoritative spec). It lives in `Batch_commit.deduplicate`, a composable sink
  > wrapper the CALLER puts around this module's accumulating sink and *inside* any
  > `Reactor.wrap_materialize_sink`; `propose`/`materialize_up_to` deliberately have no watermark
  > parameter at all. Getting that composition backwards is a live-reproduced liveness bug, not a
  > style choice — see that spec's Decision 1 revision note and `accumulator.mli`'s own "THE ONE REAL
  > OBLIGATION" section, which is where this module states the obligation on its callers.
  > Both in-memory tables were deleted outright rather than persisted in parallel. The pin test named in
  > this paragraph no longer exists: the same slot in `test/test_ledger_end_to_end.ml` is now
  > `test_restart_with_durable_watermark_leaves_balances_correct`, which runs the identical
  > restart-plus-catch-up scenario and asserts the balances come out right.
- **A single malformed or adversarial transfer leg** (non-positive amount, same account on both
  sides, a negative account id, a merge_key naming a different account than the leg claims, a
  payload `actor` disagreeing with its write's): caught by the self-certifying `authorize` check
  regardless of origin — `Deny`, whole batch refused, `authorization_denials` increments, nothing
  enters the log. Same "guard failure ⇒ total no-op" convention used throughout Layer 0. (A
  genuinely mismatched *pair* — two otherwise well-formed legs that don't actually belong together —
  cannot arise from this module's own `~propose` closure by construction, per Decision 1; it is out
  of `authorize`'s own reach.)

  **Correction (final whole-branch review, finding I6): a well-formed transfer leg proposed
  DIRECTLY, by a client that never went through the module, is ALLOWED — by design.** This bullet
  originally listed "a client attempting to propose a transfer leg directly without going through
  the module" among the things `authorize` catches "regardless of origin". That is only true of a
  *malformed* direct leg. `authorize`'s argument is one write; it has no way to know whether a
  well-formed leg came from this module's trusted `Legs` construction or from anywhere else, and
  nothing about a single well-formed leg is self-evidently wrong. The permission is also
  load-bearing rather than incidental: it is exactly how both of this module's test harnesses seed
  an account's opening balance, there being no "mint"/account-opening flow in this focused-core
  scope (see Non-goals). What is structurally unbypassable is the *well-formedness* of every
  committed leg, on every axis listed above — not the provenance of one. Provenance would need a
  batch-aware `authorize` signature, which Decision 1 already records as boundary friction for
  task-master Task 7.

  > **CLOSED by Task 7** — see Decision 1's own closure note above. `Authorize.authorize_batch`,
  > wired as `Batch_commit.create`'s `?authorize_batch`, now refuses any batch carrying other than
  > exactly two matched, balancing legs, so a lone well-formed leg proposed directly is DENIED. Both
  > of this module's test harnesses consequently seed an opening balance as a BALANCED pair against a
  > mint account rather than as a single unpaired credit.
- **WASM trap or session-type violation** in the module: `Loader.invoke` returns `Error`, the
  reactor logs it (with merge_key/module-identity context) and continues — a trap on one request
  never blocks processing of the next, per the sibling-independence guarantee already proven.
- **Node failure mid-flight**: no special handling needed. VSR's existing quorum/replay guarantees
  mean a committed transfer is durable regardless of which node processes it next; `Batch_commit`'s
  existing idempotency-key mechanism means a retried `propose` for the same logical transfer never
  double-commits.

## Testing strategy

Maps directly onto subtasks 6.2 and 6.4:

- **Domain-invariant conformance suite (6.2, "mandatory-certification discipline from Task 5.5")**
  — two distinct properties, matching the two distinct guarantees Decision 1 actually provides:
  1. **Authorize-level fuzz test**: a QCheck property-fuzz test driving random `transfer_leg`
     writes — well-formed and deliberately malformed (non-positive amount, same-account,
     merge_key/account mismatch) — directly against the real `authorize` function and
     `Batch_commit.propose`, asserting no single malformed leg ever reaches `committed_envelopes`,
     regardless of how it's constructed (including constructed directly, bypassing the module
     entirely). Same pattern as the final whole-branch review's own
     `test_batch_commit_authorization_fuzz.ml`, applied to this module's real, narrower policy.
  2. **Construction-level fuzz test**: a QCheck property-fuzz test feeding arbitrary/adversarial
     bytes directly into the `~propose` closure's own request-decode-and-construct function,
     asserting the result is always either nothing (malformed input cleanly rejected) or exactly
     two well-paired, genuinely balancing legs — proving the pairing guarantee Decision 1 relies on
     construction (not `authorize`) for, empirically, not just by code inspection.
- **Schema round-trip tests**: `to_value`/`of_value` for both `transfer_request` and `transfer_leg`.
- **A real end-to-end module test** (same shape as `test_module_end_to_end.ml`): a real
  admission-verified ledger guest, a real solo replica, a sequence of requests exercising both the
  accept path (sufficient funds, balances update correctly) and the decline path (insufficient
  funds, no-op, balances unchanged).
- **Production-shaped load under DST with injected failures (6.4)**: many concurrent transfer
  requests (a realistic accept/decline mix, not hand-picked happy-path-only cases) driven through
  the existing DST harness (Task 3.4) with node failures injected mid-flight. Assertions: the
  structural invariant never breaks across any seed; every accepted transfer's materialized
  balance change is correct; no accepted transfer is ever lost or double-applied despite failures.
  Every friction point this surfaces against the Task 5 boundary gets written down, feeding
  directly into Task 7 per this repo's own established convention.

  **Corrected (final whole-branch review, finding I7): "the structural invariant never breaks
  across any seed" overstated what is actually verified, and what is currently verifiable at all.**
  As shipped this scenario ran one hardcoded seed (4242); it now runs a real five-seed sweep, each
  seed its own test case, asserting all four correctness properties. Five rather than the 100+ a
  dedicated sweep would run is a deliberate proportion call for this plan's scope. More
  importantly, the honest ceiling is not the sweep's width: of 16 arbitrary seeds surveyed, 6
  complete and 10 wedge in Layer 0's own consensus implementation — every replica live and agreeing
  on the view number, all stuck in `View_change`, so no replica is ever `Normal` *and* primary and
  every proposal becomes a silent no-op. That is the pre-existing VSR-subset view-change liveness
  gap Task 4's own review identified in `replica.ml` and this plan ruled out of scope; it is not a
  ledger defect, and it bounds what "any seed" can mean for any DST test on this stack until it is
  closed. The sweep's seeds are therefore seeds that genuinely complete, which is stated plainly in
  `test_ledger_dst_load.ml` rather than left to look like a universal claim.

## Non-goals (explicitly out of scope for this task)

- **Task 2.1's schema-morphism/schema-evolution mechanism.** Not built here; a separate, still-
  pending prerequisite task. This module's schema is fixed at design time, no evolution mechanism.
- **Two-phase / pending transfers.** TigerBeetle's own reserve-then-commit-or-void flow. Deferred;
  every transfer in this module is immediate (request → decision → commit, no reservation window).
- **Linked atomic transfer chains.** Multiple transfers succeeding or failing together as one
  unit, beyond the single transfer's own two legs. Deferred.
- **Multi-currency / multi-ledger support.** All accounts and amounts are in one implicit unit.
  Deferred.
- **Explicit account lifecycle** (opening, closing, freezing). Accounts implicitly exist on first
  reference; no account-level state beyond its balance.
- **A client-facing API layer.** That's Task 9's own job. This task's "client" is its own test
  driver proposing requests directly through `Batch_commit.propose`, the same way every existing
  test in this codebase already drives writes.

## Implementation notes

- **Two commit messages in the first whole-branch-review fix wave claimed a clean build that
  wasn't true at authoring time.** Commits `62c769a` and `3f8cb5d` each say "dune build @all
  clean" in their own commit message, but neither actually compiled in isolation when checked
  independently (confirmed twice): `62c769a` referenced a record field that didn't exist yet, and
  `3f8cb5d` called a function that had since been renamed. Both were fixed by later commits within
  that same fix wave, and the branch tip has always built clean — but the two commit messages
  themselves remain false as written, and `git log` doesn't let that be corrected after the fact.
  Recorded here (fix-wave round 3, item NF3) so the correction survives this plan's own SDD
  workspace being deleted, rather than leaving only the two inaccurate commit messages behind.
