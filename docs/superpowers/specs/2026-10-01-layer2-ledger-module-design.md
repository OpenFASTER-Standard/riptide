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

This split is still deliberate, not redundant: "does this request make business sense" (can
evolve, can have bugs, lives in WASM) is a different concern from "is this one write, by itself,
well-formed" (must never break, lives at the authorization checkpoint) is a different concern again
from "are both legs of this transfer really a matched pair" (guaranteed by construction, verified
by fuzzing the construction code directly).

## Decision 2: schema and components

Hand-written `to_value`/`of_value` over `Riptide.Value.value`, per the resolved gap above:

- `transfer_request : { request_id : string; from_account : string; to_account : string; amount : int64 }`
  — proposed directly by a client (or this task's own test driver) at merge_key `"ledger.requests"`.
  `amount` is always a positive magnitude. Not itself balance-affecting; `authorize` allows it
  unconditionally.
- `transfer_leg : { transfer_id : string; role : [ `Debit | `Credit ]; this_account : string;
  other_account : string; amount : int64 }` — **self-certifying**: every field `authorize` needs to
  validate THIS leg alone is present in THIS leg's own payload (no need to see its sibling).
  `amount` is always positive; this leg's own signed balance delta is derived, not stored —
  `-amount` if `role = Debit`, `+amount` if `role = Credit`. `merge_key = "ledger.account." ^
  this_account`.

**Both legs of a transfer are always constructed together, from one request, by the same trusted
closure**: given an approved `transfer_request {transfer_id = request_id; from_account; to_account;
amount}`, the module's `~propose` closure always builds exactly
`[ { transfer_id; role = Debit; this_account = from_account; other_account = to_account; amount };
   { transfer_id; role = Credit; this_account = to_account; other_account = from_account; amount } ]`
and proposes them as one atomic `Batch_commit.propose` call — see Decision 1 for why this
construction-time guarantee, not `authorize`, is what makes the pair genuinely balanced.

**Account balances are materialized state, not a new lattice/CRDT type.** Each account's balance
is the Last-Write-Wins materialized value at `"ledger.account.<id>"`, maintained via the exact
read-materialized-then-propose-new-total pattern Task 7's own `counter.wat` already established
and proved correct end to end. An account implicitly exists (balance 0) the first time it's
referenced — no separate "open account" flow, consistent with the focused-core scope.

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

## Data flow (end to end)

```
Client proposes {request_id, from, to, amount}
  -> Batch_commit.propose (authorize: unconditional allow for "ledger.requests")
  -> materializes at "ledger.requests"
  -> Reactor dispatches the ledger module (fresh Loader.instantiate, Protocol check on "handle")
  -> module calls read_materialized("ledger.account.<from>") -> current balance
  -> module checks amount <= balance
       - insufficient: no propose_write call -- clean no-op, nothing committed
       - sufficient: module calls propose_write(encode(approved request))
            -> host ~propose closure ALWAYS constructs both legs together from the one
               request (Decision 2) -> [debit_leg; credit_leg]
            -> Batch_commit.propose (authorize: per-leg self-certifying well-formedness check)
                 - both legs individually well-formed: Allow
                      -> VSR commits both legs atomically
                      -> re-materializes "ledger.account.<from>" and "ledger.account.<to>"
                 - either leg malformed (amount<=0, same-account): Deny -> whole batch
                   refused, authorization_denials++
```

Every arrow is an existing, already-tested mechanism (materialize-then-dispatch,
read_materialized/propose_write, atomic multi-write commit, the authorization checkpoint) used
for the first time with a real domain and a real policy, instead of a toy counter.

## Error handling

- **Insufficient funds**: not an error — a legitimate business decision. The module simply never
  calls `propose_write`. Matches the "a module legitimately choosing not to act must be a clean
  no-op" convention already established and tested in the boundary work.
- **A single malformed or adversarial transfer leg** (non-positive amount, same account on both
  sides, a client attempting to propose a transfer leg directly without going through the module):
  caught by the self-certifying `authorize` check regardless of origin — `Deny`, whole batch
  refused, `authorization_denials` increments, nothing enters the log. Same "guard failure ⇒ total
  no-op" convention used throughout Layer 0. (A genuinely mismatched *pair* — two otherwise
  well-formed legs that don't actually belong together — cannot arise from this module's own
  `~propose` closure by construction, per Decision 1; it is out of `authorize`'s own reach.)
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
