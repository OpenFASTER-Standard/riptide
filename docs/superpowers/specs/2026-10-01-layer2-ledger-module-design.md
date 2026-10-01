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

## Decision 1: two enforcement layers, not one

The module's logic (WASM, admission-verified, Reactor-dispatched) decides WHETHER a transfer
should happen (a business rule — sufficient funds). The actual safety invariant (debits=credits,
real atomicity) is enforced separately, host-side, at the `Batch_commit` authorization checkpoint
Task 5.5 already built as "mechanism only, no policy" — this is the first real policy that
checkpoint ever carries.

**Why not enforce the invariant only inside the WASM guest** (the simpler-looking alternative):
a guest-only check can't satisfy Task 6.2's own test requirement — "the invariant cannot be
violated by any sequence of valid-looking module operations" — because nothing stops a buggy or
compromised guest (or any other code that can reach `propose_write` with this module's merge_key
shape) from skipping the check. Putting the authoritative check at the one chokepoint every write
already passes through (independently audited and fuzz-tested by the final whole-branch review's
own `scripts/check-authorization-checkpoint` and `test_batch_commit_authorization_fuzz.ml`) makes
the invariant structurally unbypassable, not just conventionally respected.

This split is deliberate, not redundant: "does this request make business sense" (can evolve, can
have bugs, lives in WASM) is a different concern from "is this batch actually a valid double-entry
transfer" (must never break, lives at the authorization checkpoint).

## Decision 2: schema and components

Hand-written `to_value`/`of_value` over `Riptide.Value.value`, per the resolved gap above:

- `transfer_request : { request_id : string; from_account : string; to_account : string; amount : int64 }`
  — proposed directly by a client (or this task's own test driver) at merge_key `"ledger.requests"`.
  `amount` is always a positive magnitude. Not itself balance-affecting; `authorize` allows it
  unconditionally.
- `transfer_leg : { transfer_id : string; account : string; delta : int64 }` — exactly two of
  these, derived by the module from one approved request as `{account = from_account; delta =
  -amount}` and `{account = to_account; delta = +amount}`, sharing one `transfer_id`, proposed
  together as a single atomic `Batch_commit.propose` call at merge_key
  `"ledger.account.<account-id>"`.

**Account balances are materialized state, not a new lattice/CRDT type.** Each account's balance
is the Last-Write-Wins materialized value at `"ledger.account.<id>"`, maintained via the exact
read-materialized-then-propose-new-total pattern Task 7's own `counter.wat` already established
and proved correct end to end. An account implicitly exists (balance 0) the first time it's
referenced — no separate "open account" flow, consistent with the focused-core scope.

**Atomicity across the two legs of a transfer** comes for free from `Batch_commit`'s own existing
all-or-nothing multi-write commit (hardened since Task 3.3) — nothing new needed.

**One `Batch_commit.t` handle for the whole module**, one `authorize` function branching on write
shape: a `"ledger.requests"` write is allowed unconditionally; a `"ledger.account.*"` write (a
transfer leg) is checked structurally — exactly two legs share a `transfer_id` within the batch,
their deltas sum to exactly zero, the two accounts are distinct (a `from_account = to_account`
request therefore produces two same-account legs and is structurally **Deny**'d here, not silently
accepted as a no-op net-zero transfer — the module itself has no special case for it either; it is
the authorize check's job to reject it, consistent with "the invariant cannot be violated by any
sequence of valid-looking module operations" covering this case too).

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
       - sufficient: module calls propose_write(encode(debit_leg, credit_leg))
            -> host ~propose closure decodes into [debit_leg; credit_leg]
            -> Batch_commit.propose (authorize: structural debits=credits check)
                 - balanced, same transfer_id, distinct accounts: Allow
                      -> VSR commits both legs atomically
                      -> re-materializes "ledger.account.<from>" and "ledger.account.<to>"
                 - malformed/unbalanced: Deny -> whole batch refused, authorization_denials++
```

Every arrow is an existing, already-tested mechanism (materialize-then-dispatch,
read_materialized/propose_write, atomic multi-write commit, the authorization checkpoint) used
for the first time with a real domain and a real policy, instead of a toy counter.

## Error handling

- **Insufficient funds**: not an error — a legitimate business decision. The module simply never
  calls `propose_write`. Matches the "a module legitimately choosing not to act must be a clean
  no-op" convention already established and tested in the boundary work.
- **Malformed or adversarial transfer legs** (wrong account, mismatched `transfer_id`,
  non-balancing deltas, a client attempting to propose a transfer leg directly without going
  through the module): caught by the structural `authorize` check regardless of origin — `Deny`,
  whole batch refused, `authorization_denials` increments, nothing enters the log. Same
  "guard failure ⇒ total no-op" convention used throughout Layer 0.
- **WASM trap or session-type violation** in the module: `Loader.invoke` returns `Error`, the
  reactor logs it (with merge_key/module-identity context) and continues — a trap on one request
  never blocks processing of the next, per the sibling-independence guarantee already proven.
- **Node failure mid-flight**: no special handling needed. VSR's existing quorum/replay guarantees
  mean a committed transfer is durable regardless of which node processes it next; `Batch_commit`'s
  existing idempotency-key mechanism means a retried `propose` for the same logical transfer never
  double-commits.

## Testing strategy

Maps directly onto subtasks 6.2 and 6.4:

- **Domain-invariant conformance suite (6.2, "mandatory-certification discipline from Task 5.5")**:
  a QCheck property-fuzz test driving random batches of transfer-leg writes — balanced and
  deliberately malformed (mismatched deltas, wrong `transfer_id` pairing, self-transfers,
  single-leg batches) — directly against the real `authorize` function and `Batch_commit.propose`,
  asserting no unbalanced write ever reaches `committed_envelopes`, regardless of how it's
  constructed. Same pattern as the final whole-branch review's own
  `test_batch_commit_authorization_fuzz.ml`, applied to this module's real policy.
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
