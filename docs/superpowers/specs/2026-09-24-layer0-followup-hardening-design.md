# Layer 0 follow-up hardening: wire integrity, general ring-eviction watermark,
# encryption-required policy, keystore/materializer namespacing, a DST flake, PKI persistence

Design spec for six real, disclosed gaps found by this session's own adversarial reviews across
two just-merged plans (VSR consensus/storage-fault-tolerant-recovery, and lattice/materialization/
redaction/encryption/PKI/mTLS), tracked as task-master subtasks 3.6, 3.7, 3.8, 4.5, 4.6, and 4.7.
Brainstormed and specified together per this project's own established precedent of treating a
related cluster of gaps as one coherent design rather than six independent specs, per user
direction. This document is the argument; the implementation plan and running code that follow it
are the authority, per `CLAUDE.md`'s "no spec without running code" rule.

## Context

All six items sit in the same layer of the system — the Layer 0 write/storage/transport path —
and were found by this session's own final whole-branch reviews, not invented speculatively. Two
(3.6, 3.7) touch Layer 0 architecture directly (the consensus/replication protocol and the event
envelope's own storage guarantees) and fall under `CLAUDE.md`'s "small, aligned governance for
Layer 0" rule; this document names that explicitly rather than deciding those items' shape
unilaterally.

Effort across the six is uneven. 3.7 is a real, multi-mechanism change touching both `Riptide_vsr`
and `Riptide_storage`. The other five are each a small, well-bounded addition to one existing
module.

## Decision 1 (subtask 3.6): VSR wire integrity via a plain checksum, not a MAC

**Why a checksum, not a cryptographic MAC:** VSR is a crash-fault-tolerant protocol, not a
Byzantine one — a compromised replica already holds a valid TLS identity and could simply lie
about a message's content, which no message-level authentication code defends against. The actual,
demonstrated failure mode this closes is *accidental* corruption from something other than the
network: a local encoding bug, or a WAL-read that was corrupted before being retransmitted. The
network-corruption case this subtask originally found is **already closed for every real
deployment** as a side effect of the just-merged Task 8 mTLS work — `Riptide_transport.Tcp` is the
only transport any production code path uses (confirmed via `grep`: only `lib/dst/cluster.ml`,
`lib/pki/ca.mli`, `lib/sim/sim_transport.mli`, and `lib/transport/tcp.mli` reference either
transport module in `lib/`), and `Sim_transport`'s `corrupt_probability` is documented as real only
for that harness's own fault-injection testing. AES-GCM's authenticated encryption means a
corrupted wire byte already fails TLS's own record authentication and kills the connection before
VSR ever sees it.

**Mechanism:** `lib/vsr/message.ml`'s `encode`/`decode` (names to be confirmed against the real,
current file before implementation) gain a trailing checksum:

```
encode msg =
  let body = Value.canonical_encode (to_value msg) in
  body ^ checksum body

checksum s = (* first 8 bytes of SHA-256 s -- accidental-corruption detection, not a
                security boundary; 64 bits of collision resistance is far more than
                needed for this threat model *)
```

`decode` splits the trailing 8 bytes off, recomputes the checksum over the remaining prefix, and
raises the existing `Malformed_message` exception (already defined in `message.ml`) on mismatch —
reusing VSR's own established malformed-message signal rather than inventing a new one.

**Real implementation question the plan must verify against current code, not assume:** does
`Riptide_vsr.Replica.handle_message` already catch a `Malformed_message` raised from decode and
drop the offending message, or would this newly-reachable exception path crash the replica instead
of degrading gracefully? If the latter, making `handle_message`'s malformed-message handling
correct is the actual work here, not the checksum arithmetic itself.

**Testing:** a corruption-fault test proving `decode` now rejects a tampered byte stream (via
`Sim_transport`'s existing `corrupt_probability` under DST, and — if feasible without excessive
harness cost — a focused test proving the same rejection over a real `Tcp` round-trip, independent
of TLS). The existing DST corruption test's own meaning shifts from "network corruption is caught"
(no longer the interesting case, closed by mTLS) to "VSR's own defense-in-depth catches
non-network corruption" — the test should be re-labeled/re-commented to say this honestly, not
left implying it's still testing a network-layer threat.

## Decision 2 (subtask 3.7): General multi-replica ring-eviction watermark

**This is the one item requiring explicit sign-off as the Layer-0 architectural change it is**, per
`CLAUDE.md`'s governance rule — presented here as the argued design, not a unilateral decision.

**The gap, restated precisely:** the just-merged materialization work makes ring eviction safe by
construction *only* when the same `propose` call that materializes a write also observes its
commit — true for a solo (`replica_count = 1`) replica, or a replica an operator explicitly drives
via `propose ~materialize:sink []` after the fact. A real `replica_count >= 3` follower never
automatically materializes anything off an asynchronous commit; nothing currently drives that.
Writes with no `merge_key` remain exactly as vulnerable to eviction as before this whole
materialization effort — an existing, disclosed, unchanged boundary, not something this decision
touches.

**Two cooperating mechanisms, decided together because neither is safe alone:**

**(a) Trigger side — a generic "commit advanced" hook on `Replica`, not a materialization-aware
hook baked into VSR.** `Riptide_vsr.Replica.create` gains:

```ocaml
?on_commit_advanced:(old_commit:int -> new_commit:int -> unit)
```

invoked synchronously wherever `commit_number` updates — both the primary's own commit path
(inside `primary_execute_op`) and a follower's commit advancing via `handle_message` processing a
`Prepare` that piggybacks new commit information. `Replica` stays domain-agnostic (the hook takes
only integers, knows nothing about materialization, redaction, or `Value.value`), preserving the
existing, deliberate architectural boundary documented in `batch_commit.mli`'s own top-of-file
comment ("Deliberately does NOT touch `Riptide_vsr.Replica`'s message-handling side"). `Batch_commit`
wires this hook, when the caller supplies a materialize sink, to a new range-based drain:

```ocaml
val materialize_up_to :
  Riptide_vsr.Replica.t -> materialize:materialize_sink -> through_commit_number:int -> unit
```

generalizing the existing per-idempotency-key `committed_writes_for` (added by the just-merged
plan's Task 9 fix) into one that walks every committed batch since the last-observed watermark and
materializes each write carrying a `merge_key`, in commit order.

**(b) Gate side — a bounded soft gate on `File_storage`, not a hard refuse-to-evict.** A hard "never
evict below the watermark" repeats the exact liveness-wedge failure mode this project's own
governance already explicitly reversed once (the original subtask 3.7 text: "the obvious fix
(refuse to evict a live entry) reverses a documented Tasks 1-3 design decision"). `File_storage.create`
instead gains:

```ocaml
?may_evict:(op_number:int -> bool)
```

Before a ring write would overwrite (evict) an existing slot, if the predicate returns `false`, the
write backs off with a bounded retry/backoff; if backpressure persists past a configurable
threshold, it raises a loud, distinguishable exception — never a silent data loss, and never a
silent, signal-free wedge either (the original subtask 3.7 failure mode this whole effort exists to
close). `Batch_commit` supplies the predicate: an op-number is safe to evict once its write is
above the current materialization watermark (tracked internally, updated after each
`materialize_up_to` call), or if the write at that op-number never opted into materialization at
all.

**Real design questions the implementation plan must resolve, not fixed here:** the exact shape of
the backoff/threshold (a fixed op-number lag count? a time-based budget? both?); where the
materialization watermark itself is durably tracked (in-memory only, reconstructed at replica
restart by re-scanning committed-but-unmaterialized entries? or persisted alongside the
materializer's own KV store?); whether `on_commit_advanced` needs to be re-invoked (replayed) for
commits the replica already knew about at restart, so a restarted replica's materializer catches
up correctly.

**Testing:** a real multi-replica scenario (mirroring the just-merged Task 9's own adversarial
harness conventions) where a follower's ring genuinely would have evicted an unmaterialized entry
pre-fix, proven safe post-fix by checking the entry's content survives in the materializer even
after the raw WAL slot is gone. A second scenario fault-injects materialization falling genuinely,
permanently behind (e.g., a stuck/crashed materializer) and proves the loud-failure path fires
within its configured threshold, rather than either silently losing data or wedging forever with no
signal.

## Decision 3 (subtask 4.5): Deployment-required encryption via a `propose`-level flag

**Correction to this decision's own earlier framing (recorded honestly, per this project's
disclosure discipline):** `Batch_commit` has no `create`/persistent-state entry point of its own —
confirmed against the real, current code, it is a plain module operating directly on
`Riptide_vsr.Replica.t`, not a functor or an object with its own construction site. There is
therefore no natural "deployment creation time" to attach a policy flag to.

**Mechanism:** `propose` gains `?require_encryption:bool` (default `false`, matching this module's
existing convention for every other opt-in capability flag). When `true` and the call's
`~encryption` argument is `None`, `propose` raises `Invalid_argument` immediately, before any write
is proposed. A real deployment's own calling code always passes
`~require_encryption:true`; `Batch_commit` itself remains a mechanism, never a policy-holder — the
same shape this whole plan already used successfully for `?materialize`/`?encryption` themselves.

**Also included, cheap and independent of the above:** a one-line doc clarification in `lib/log.mli`
(or wherever fits best) stating plainly that `Log`/`Log.append` is a pre-VSR-consensus prototype
module used only by its own unit tests today, not a production write path — confirmed via `grep`:
no file under `lib/` outside `lib/log.ml` itself references `Log.append`. This closes the "second,
uncoverable envelope-construction site" concern honestly, without removing or restructuring
anything.

## Decision 4 (subtask 4.6): Exclusive keystore/materializer directory ownership

**The actual failure mode found** (during the just-merged plan's own Task 9 adversarial
investigation) was accidental misconfiguration — two independent `Kv_store_intf.S` consumers
(a `Redaction_store` keystore and a `Materializer`) pointed at the same on-disk directory — not a
legitimate need for the two to coexist. The fix targets that directly rather than building a more
general (and here, unneeded) namespacing mechanism.

**Mechanism:** `File_kv_store.create` gains `?owner:string` (optional, for backward compatibility
with existing callers/tests that don't care). When supplied: on first creation of a fresh
directory, write a marker file (e.g. `.riptide-kv-owner`) recording the tag; on every subsequent
`create` against an existing directory, read the marker and compare — a mismatch raises
`Invalid_argument` immediately, at construction time, naming both the expected and actual owner
tags.

**What actually shipped, corrected after implementation (was: "`Redaction_store.create` and
`Materializer.create` are updated to require (not merely accept) a real, purpose-specific owner
tag from their own callers"):** neither constructor requires a tag at the type level.
`Materializer.create` takes its `kv` already built, through the deliberately backend-agnostic
`Kv_store_intf.S`, which carries no ownership concept — requiring a tag there is a real interface
change to that module type, not a call-site addition. `Redaction_store.create` similarly takes an
already-built `File_kv_store.t` (`~kv ~kek`) and does not itself validate or require a tag, even
though (unlike the materializer) it could — `File_kv_store.t` is concrete there, so exposing and
checking its owner tag is feasible without touching `Kv_store_intf.S`. What shipped instead: every
real construction site in this repo (all keystore and materializer callers) passes `~owner`, so
the protection is real end-to-end today, backed by a running negative control proving the
documented opt-out failure mode (both sides omitting `~owner`) still reproduces the original
hazard. Requiring the tag at the constructor level for either module remains open, tracked
separately (task-master, not this spec) rather than closed here.

**Testing:** the existing pinned collision-reproduction test (added by the just-merged plan's own
Task 9) is updated to prove construction-time rejection with a clear error, going through the real
`Materializer`-constructing call path rather than an inline `File_kv_store.create` built only to
demonstrate the guard — replacing its prior role of documenting three ways the collision silently
corrupts data. A second, restored test proves the still-open opt-out case (both sides omitting
`~owner`) still reproduces two of those three original corruption directions.

## Decision 5 (subtask 3.8): Deterministic `dst_scenarios` fix

**Root cause, already confirmed** (independently reproduced twice during the just-merged plan's own
final whole-branch review, 2/40 isolated runs): `lib/dst/cluster.ml`'s `settle()` uses a real
wall-clock `Eio.Time.sleep clock 0.0001` as part of its `wait_io` budget, and the bounded
`delivery_rounds`/`io_waits` budgets it's checked against depend on real I/O batching timing, which
shifts the order the seeded network fault stream gets consumed in — a genuine, pre-existing timing
sensitivity in every `run_on_file_storage`-backed DST test, unrelated in cause to any of the other
five items in this spec.

**Mechanism:** replace the wall-clock-based `wait_io`/budget mechanism with one driven entirely by
a deterministic round or tick count, removing the dependency on real I/O timing from `settle()`'s
completion criterion altogether. Exact mechanism (a virtual/mock clock already available to this
harness, or a pure step-counter) is an implementation-plan decision, not fixed here — read the
real, current `cluster.ml` before choosing.

**Testing:** the previously-flaky test run repeatedly (50+ times, matching or exceeding the
reproduction rate that originally surfaced the flake) with zero failures, both standalone and under
whatever induced load originally triggered the ~5% failure rate.

## Decision 6 (subtask 4.7): PKI certificate/key persistence (library capability only)

**Scope, confirmed with the user:** library capabilities only — no runnable replica binary. This
repo remains library-only (no `bin/` directory) after this work.

**One asymmetry worth naming explicitly:** a KEK is *always* externally sourced (Decision 5 of the
just-merged plan — Riptide never generates or persists its own KEK). This project's self-managed CA
is the opposite: it is explicitly *generated by* Riptide itself (`Ca.generate_root`, the whole point
of the "minimal, self-managed PKI" decision). So this decision is not "load an externally-provided
credential" the way `Kek.load` is — it is "save what this process itself created, then load it back
later, possibly in a different process." The persistence mechanism reflects that.

**Mechanism:**

```ocaml
val save : t -> dir:string -> unit
val load : dir:string -> t
```

on `Riptide_pki.Ca`, round-tripping through `X509.Certificate.encode_pem`/
`X509.Private_key.encode_pem` (confirm these exact function names against the real, installed
`x509` library `.mli` before implementation — every prior task in this project's session has found
at least one brief-assumed API call that didn't match the real installed library, and this decision
should not assume it's the exception). The CA's own private-key file gets the same
restrictive-permission-check discipline `Kek.load` already established as this project's own
precedent (verified via `Unix.fstat` on the already-open descriptor, not a separate `Unix.stat` on
the path, closing the same TOCTOU `Kek.load` already closes) — a compromised CA private key is more
severe than any single leaf key, since it can mint arbitrary trusted identities for the whole
cluster. `load` re-validates that the loaded key matches the loaded certificate on the way back in,
reusing (or mirroring) `Tls_identity.create`'s own existing `check_key_matches_cert` logic rather
than duplicating a weaker check.

**Testing:** a real save/load round-trip proving a loaded `Ca.t` can still sign a new leaf
certificate that validates against the original (pre-save) root's own in-memory certificate —
proving the persisted and reconstructed identity are genuinely equivalent, not merely that the
files exist and parse.

## Testing section (cross-cutting)

Each decision ships with real, running code and real tests in the same change that introduces any
rule it establishes, per `CLAUDE.md`'s "no spec without running code." Per-decision testing
requirements are listed above; the implementation plan's own Review Focus section should name the
specific non-vacuity proof each decision's test must deliver, following this session's own
established pattern of catching accidentally-vacuous tests (this plan has twice found and fixed
exactly this failure mode in its own prior work — Task 5's nonce test, Task 6's AAD test — the bar
here is the same).

## Non-goals, explicitly out of scope

- **Byzantine fault tolerance for Decision 1** — VSR's crash-fault model is unchanged; a
  cryptographic MAC defending against a malicious-but-credentialed replica is explicitly not this
  decision's goal.
- **A runnable replica server binary** — Decision 6 stays scoped to library capabilities; building
  `bin/riptide-replica` (or similar) that actually wires PKI + mTLS + materializer + redaction +
  VSR into a startable process is real, separate, future scope.
- **Removing `Log`/`Log.append`** — Decision 3 documents it as legacy/prototype-only; deleting it
  is a separate cleanup decision, not required to close subtask 4.5.
- **KEK or CA rotation** — both remain explicit non-goals carried over from the just-merged plan's
  own Decisions 5/6.
- **A watermark observability dashboard** — Decision 2 delivers the loud-failure signal itself, not
  any monitoring/alerting UI built on top of it.
- **A general `Kv_store_intf.S` namespacing combinator** — Decision 4 solves the actual
  misconfiguration failure mode found (exclusive ownership), not a more general "let multiple
  consumers safely share one directory" mechanism nobody currently needs.
