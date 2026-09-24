# Lattice merge-law contract, incremental materialization, redaction, and encryption

Design spec for task-master Task 4 ("Lattice merge-law contract and incremental materialized
state"), covering all four of its subtasks (4.1-4.4) as one design, per this project's own
established precedent of treating a task-master task's own subtask grouping as one coherent unit
of work rather than four independent projects. This document is the argument; the implementation
plan and running code that follow it are the authority, per `CLAUDE.md`'s "no spec without running
code" rule.

## Context

Task 3 (VSR consensus, storage-fault-tolerant recovery) is functionally complete and merged. Its
own final review surfaced a real, disclosed gap: `File_storage`'s fixed-size ring WAL silently
destroys committed data once a log exceeds `ring_capacity`, because nothing in the system ever
checkpoints — every entry stays live forever with no way to safely evict it. That gap is tracked
as task-master subtask 3.7, explicitly deferred to Task 4 ("the real fix is almost certainly Task
4's own scope"). This spec's Decision 3 is that fix, not a separate mechanism bolted on afterward.

The four subtasks, restated in the order this spec builds them:

- **4.1**: the join-semilattice law contract — the RULE any type claiming to be mergeable must
  satisfy (commutative, associative, idempotent join). Layer 0 mechanism; which concrete lattice a
  domain module uses is Layer 2 policy, per `CLAUDE.md`'s existing boundary rule.
- **4.2**: the incremental-projection mechanism — reads hit a materialized, incrementally-updated
  accumulator, never a full log replay.
- **4.3**: redaction-with-preserved-hash — erase a payload's content while the envelope's own
  hash-chain integrity stays intact.
- **4.4**: encryption at rest and mTLS in transit, non-optional.

The user directed real research (matching this project's own precedent from the storage-fault-
tolerance work) into 4.3/4.4's cryptographic design specifically, given the explicit "professional,
top-notch, serious" bar — that research is cited throughout Decisions 4-6 below, not asserted from
memory.

## Decision 1: The lattice law contract — a signature plus a reusable conformance harness

```ocaml
module type S = sig
  type t
  val bottom : t
  val join : t -> t -> t
end
```

Enforcement is a **reusable property-test harness** — given `(module Lattice.S with type t = 'a)`
and a `QCheck.arbitrary` generator for `'a`, it produces the standard property tests (commutativity,
associativity, idempotency, and `join bottom x = x`) any concrete instance can run against itself.
This mirrors `test_transport_shared.ml`/`test_storage_shared.ml`'s existing pattern — a shared
conformance suite instantiated per implementation is already this codebase's established way of
proving a structural contract, not a new idea introduced here. `qcheck-core`/`qcheck-alcotest` are
already project dependencies (Task 2's golden-vector work).

Layer 0 may also ship one or two genuinely domain-agnostic concrete instances (e.g. a grow-only
set, a last-write-wins register) as reusable utility modules — these don't violate the Layer 0/
Layer 2 boundary any more than `Value.value`'s own scalar/record/sequence types do, since they
carry no domain semantics of their own.

## Decision 2: Merge-key scheme — caller-supplied, opaque, never Layer 0's business

Writes destined for materialization carry an opaque, caller-supplied `merge_key : string` — the
same shape as `batch_commit`'s own `idempotency_key`, never inspected or interpreted by Layer 0.
This is the same resolution the atomic-multi-envelope-commit work already reached for "entity":
Layer 0 has no entity/subject concept, so grouping-for-merge has to be an opaque token the caller
picks, not something Layer 0 derives from payload structure or existing envelope fields (`correlation`
already means something specific — causal link — and overloading it as "merge grouping" would
conflate two different concepts to avoid adding one new field).

## Decision 3: Incremental projection — the generic engine, and how far it closes subtask 3.7

A **materializer** is built by supplying a concrete `Lattice.S` module (satisfying Decision 1's
contract) plus a codec (`Value.value <-> 'a`). As each write for a given `merge_key` commits, the
materializer folds it into that key's running accumulator (`join old new`) and persists the
*accumulated* value — not the raw history. A read for key `K` fetches the current accumulator
directly. Layer 0's own code is generic over any conforming `Lattice.S` instance; it never hardcodes
domain semantics. This resolves the apparent tension in Decision 1's own framing ("the law is Layer
0 mechanism, the concrete lattice is Layer 2 policy"): Layer 0 ships the generic engine and the
conformance harness; a concrete lattice module is supplied by whoever sets up a materializer,
Layer 2 or otherwise.

**This is subtask 3.7's fix for merge-keyed writes, within the scope stated below — not a general
closure of 3.7.** Once a write is folded into its key's accumulator, the raw WAL entry behind it is
safe to evict: its content survives, compacted, in the materialized state.

> **Amended 2026-09-23, after the final whole-branch review, to say what was actually built.**
> This section originally specified a *watermark/eviction interlock*: the materializer would track
> the highest op-number it had folded, and `File_storage`'s ring would only be permitted to evict an
> entry once the watermark had passed that op-number. **That interlock was never implemented.**
> `lib/storage/file_storage.ml` is not touched anywhere in this work, and no watermark exists in
> the shipped code. The original wording is preserved here only as the record of what was
> envisioned; everything below describes the delivered mechanism and its real limits. Leaving the
> unbuilt design in place as if it were the shipped one would be exactly the "spec ahead of running
> code" failure this repo's own `CLAUDE.md` forbids, and would make a `done` status unprovable.

**What was actually delivered.** Materialization is **synchronous with commit, at the point of the
`Batch_commit.propose` call that observes the batch as committed**. A write carrying a `merge_key`
is folded into its accumulator inside that same call, strictly before any later call on that replica
could evict the WAL slot it occupies. There is no runtime watermark check, and no background
process: *some* `propose` call supplied with `?materialize` has to actually run, at or after the
moment the commit lands, for anything to be materialized at all.

**The scope that makes ring eviction genuinely safe by construction is therefore narrower than
"always", and is exactly this:**

- **`replica_count = 1` (`f = 0`)**: `Riptide_vsr.Replica.propose` commits synchronously, so the
  very first `propose` call for a batch both commits it and materializes it. Safe by construction,
  with no further action by anyone.
- **A caller explicitly driving materialization on a replica that has since learned of the
  commit**: e.g. an operator or client re-proposing under the same `idempotency_key`, or calling
  `propose ~materialize:sink []` (the empty-writes idiom) against a replica that is merely behind.
  Also safe — but it depends on that call actually being made.

**What is *not* covered, stated as a real limitation rather than an implementation detail:** in a
normal `replica_count >= 3` cluster, `propose` never commits synchronously — the primary learns of
its own commit later, asynchronously, via `handle_message` processing a quorum of replies. Nothing
in the shipped code triggers materialization off that asynchronous commit. A follower that never has
`propose ~materialize` called on it never materializes anything, and its ring can evict entries
whose content was never absorbed into any accumulator. Closing that case is what the original
watermark/eviction interlock above was for, and it remains open.

**Tracked as future work**, deliberately not smuggled into this plan: a general
watermark/eviction interlock — the materializer publishing a durable watermark, and `File_storage`
(or a caller-side guard analogous to the existing `wal_truncate_after`-below-`commit_number` guard)
refusing to evict past it — belongs in its own task-master subtask, because it is real new
production scope in `lib/storage/file_storage.ml`, a file this entire plan otherwise never touches.

Writes with no `merge_key` are unaffected by any of this: they remain exactly as subject to ring
eviction as before, a disclosed scope boundary that Decision 2's opt-in framing already implies.
`lib/batch_commit/batch_commit.mli`'s own `{b Scope, ...}` paragraph is the authoritative,
code-adjacent statement of all of the above, and this section is written to agree with it rather
than to overstate it.

## Decision 4: Redaction — real envelope encryption, not a derived key

Every payload gets a **fresh, independently-generated Data Encryption Key (DEK)** — never derived
from the Key Encryption Key (KEK) via HKDF or similar. This is deliberate and load-bearing: Kubernetes'
own KMS v2 derives a per-object key from a shared seed via HKDF for performance, and explicitly does
**not** support per-object redaction as a result — the only thing actually deletable is the shared
seed, which would erase everything derived from it, not one record. The real crypto-shredding
precedent (AWS/GCP envelope encryption; the EventStoreDB/Verraes "Throw Away the Key" pattern) uses
a genuinely separate, independently-stored DEK per redaction unit, specifically because that's what
makes "delete one key, lose one record" possible at all.

- **Cipher**: AES-256-GCM, with a **deterministic, counter-based nonce per DEK** (a fixed
  per-process-or-key prefix plus a monotonic counter), not a randomly-generated nonce — per NIST SP
  800-38D §8.2.1's own permitted construction, and matching Kubernetes KMS v2's real, shipped
  approach. This sidesteps the real 2^32-random-nonce collision cap GCM (and IETF ChaCha20-Poly1305)
  carry under purely random nonces, without needing XChaCha20-Poly1305 (libsodium's own recommended
  answer to that same problem) — which isn't available in `mirage-crypto` without hand-rolling
  HChaCha20, a real extra audit-risk cost this spec explicitly declines to pay.
- **Granularity**: per-record (per-envelope), not per-subject/per-stream — matching the task's own
  literal wording, and the more general primitive: a caller can always redact every record sharing
  a `merge_key` to get subject-level erasure; the reverse isn't possible.
- **Storage**: the wrapped DEK lives in a **new, separate keystore, indexed by `event_id`** —
  structurally outside whatever the envelope's own `content_hash` covers. The envelope's
  `content_hash` is computed over ciphertext only. Redaction is exactly one operation: delete the
  keystore entry for an `event_id`. The hash chain never changes, never even sees the deletion.
  (The keystore needs genuine per-key deletion, which `Storage.S`'s own WAL-shaped abstraction
  doesn't naturally provide — this is a new, small, separate storage primitive, not a reuse of
  `Storage.S` itself; exact shape is an implementation-plan decision.)
- **Library**: `mirage-crypto` (AES-GCM) + `mirage-crypto-rng` (Fortuna CSPRNG, for real DEK
  generation) — confirmed actively maintained (releases through August 2026, including real
  security-advisory fixes), the direct, author-sanctioned successor to the old `nocrypto`. No
  envelope-encryption/KMS-client abstraction exists anywhere in the OCaml ecosystem; the wrap/unwrap
  logic is composed directly from these primitives, which is normal — even Tink, the one ecosystem
  with a dedicated library for this, doesn't target OCaml.

## Decision 5: KEK sourcing

The KEK is supplied externally at process startup — a file (permissions-restricted), generated
outside Riptide (e.g. via `openssl rand` or equivalent) — **never generated or persisted by
Riptide itself**. This matches real, credible non-hyperscaler precedent: `restic`'s own master-key
handling, `age`+`sops`'s file/env-var KEK pattern (explicitly self-contained, "no cloud account, no
API calls" as its own real first implementation, with KMS integration as a later optional upgrade),
and Kubernetes' own non-KMS encryption-provider baseline (a KEK embedded in a config file). File is
preferred over an environment variable, per OWASP's Cryptographic Storage Cheat Sheet's own explicit
caution against env-var key storage (process-listing/crash-dump/log leakage) — a file with
restrictive permissions is the safer of the two options real precedent actually uses. External KMS/
Vault integration is a legitimate later upgrade (the same swap `sops` itself supports), not a
blocker for a correct first implementation.

## Decision 6: mTLS — a minimal, self-managed PKI now, SPIFFE/SPIRE deferred to Task 8

A self-signed root CA, generated and used to sign per-replica leaf certificates, entirely in-repo
via `x509` + `mirage-crypto-pk` (+ `mirage-crypto-rng`) — the same `create`/`sign` pattern the real
`certify` reference tool (same maintainer ecosystem as `mirage-crypto`/`tls`) already uses as its
own idiomatic implementation. `Riptide_transport.Tcp` is upgraded to use **`tls-eio`** (this
project's own concurrency substrate is Eio, not Lwt/Async/Mirage — the scheduler choice must match)
with the root CA as trust anchor and mutual certificate verification on both sides, reversing the
transport's existing disclosed non-goal ("TLS/authentication... single-operator-cluster fault
model"). `tls` is confirmed actively maintained (v2.1.3 released within this same month, including
real CVE fixes), with TLS 1.3 support since 2020 and native mutual-TLS support via
`Tls.Config.server`'s `~authenticator` parameter.

Certs are static and long-lived (matching etcd's and CockroachDB's own real, documented,
production-used baselines — etcd's own `--peer-auto-tls` defaults to 1 year; CockroachDB's
`cockroach cert` defaults to 10 years) with manual rotation as an operational runbook item, not
automated issuance. This is confirmed to be the real, current baseline every mainstream consensus/
database system in this space (etcd, CockroachDB, TiKV) actually ships as its first implementation —
dynamic short-lived issuance (Consul's built-in-CA auto-rotation; SPIRE-style attestation) is a real,
legitimate *upgrade path*, not table stakes for a correct first implementation anywhere in this
survey.

**SPIFFE/SPIRE is explicitly out of scope here, deferred to task-master Task 8** (which already
plans it, gated behind a later multi-tier/heterogeneous-hardware node model that doesn't exist yet).
SPIRE's own documentation frames its value proposition around workload identity across
"multiple networks... deployed by different teams" and dynamic runtime attestation — real adoption
write-ups describe it as "a multi-year engineering project" most teams underestimate, and explicitly
recommend it only once genuine multi-tenancy/heterogeneous-compute exists. Riptide today is one
homogeneous cluster with statically-known replica identities — exactly the case real precedent says
doesn't yet justify SPIRE's operational cost. Building a lightweight version of SPIRE's own rotation
machinery now, only to have Task 8 replace it later, would mean building two generations of the same
mechanism; deferring avoids that.

## Testing

- **Decision 1**: the conformance harness itself gets tested against at least one real instance
  (e.g. whichever concrete lattice Decision 1's own utility modules ship), proving it actually
  catches a law violation (a deliberately-broken `join` should fail the harness — mutation-style
  proof, matching this project's established non-vacuity discipline).
- **Decision 3**: a materializer under real concurrent/interleaved commits converges to the same
  accumulator regardless of delivery order (this is what the lattice laws are *for* — prove it, not
  just assert it). The materialization/eviction interaction gets a real test mirroring subtask 3.7's
  own reproduction: propose enough writes to exceed `ring_capacity` with materialization keeping
  pace, confirm no data loss, then (as a negative control) confirm the old, pre-Decision-3 failure
  mode still reproduces if materialization is disabled/starved. **Amended 2026-09-23 (final
  review):** "watermark/eviction interaction" here originally named a mechanism that was never
  built — see Decision 3's own amendment box. What is testable, and what this bullet now means, is
  the *synchronous-with-commit* interaction, in the narrow scope Decision 3 now states: a
  `replica_count = 1` cluster, or a caller explicitly driving `propose ~materialize`. There is no
  watermark to test, and the general `replica_count >= 3` follower case is open, not covered by any
  test, because the mechanism that would make it hold does not exist yet.
- **Decision 4**: a redacted record's hash-chain integrity is unaffected (`Log.verify_chain_list`
  still passes) and the payload is genuinely unrecoverable after its keystore entry is deleted —
  proven by attempting decryption post-redaction and confirming failure, not merely that the
  function returns without the key.
- **Decision 6**: a real mTLS handshake between two replicas over `tls-eio`, using the in-repo CA,
  succeeds; a connection attempt presenting no cert or a cert signed by a different CA is rejected —
  proven against a real socket pair, not mocked.

## Non-goals, explicitly out of scope

- **SPIFFE/SPIRE, dynamic attestation, automated cert rotation** — Decision 6; deferred to Task 8.
- **Redaction at coarser-than-per-record granularity as a Layer 0 primitive** — Decision 4; a
  caller can build subject-level redaction by redacting every record under a shared `merge_key`,
  but Layer 0 itself only ever redacts one record.
- **External KMS/Vault/HSM integration for the KEK** — Decision 5; a legitimate later upgrade, not
  this spec's own deliverable.
- **Which concrete lattice a real domain module uses** — Decision 1; Layer 2 policy, decided when
  task-master Task 6 picks its first real use case.
- **XChaCha20-Poly1305 or any hand-rolled extended-nonce construction** — Decision 4; not available
  in `mirage-crypto`, and the deterministic-nonce AES-GCM construction already closes the gap it
  would have solved.
