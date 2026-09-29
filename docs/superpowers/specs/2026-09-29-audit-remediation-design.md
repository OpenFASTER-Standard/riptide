# Deep adversarial audit remediation

Design spec closing every finding from the 2026-09-29 five-track adversarial audit of Riptide's
value codec, VSR consensus/replication, storage, materializer/lattice, and transport/crypto
layers. ~25 findings, six of them Critical, all live-reproduced (see the audit agents' own
reports for full reproduction transcripts and file:line citations — this document does not
repeat evidence already established there, only the fix). Per `CLAUDE.md`'s "no spec without
running code" rule, every decision below ships with real tests in the implementation plan that
follows this spec, not as prose alone.

Per explicit user direction, this is deliberately one spec covering all seven finding-groups
rather than seven separate ones — the groups are presented as sections below for navigability,
not as independent projects with their own approval gates.

## Context

Tasks 1-4 (envelope/value, consensus, lattice/materialization, plus the crypto/transport work
folded into Task 4's broader scope) are marked `done`. The audit found that "done" correctly
describes the *documented, tested* behavior of each layer, but did not mean adversarially robust
— several gaps are real, live-reproduced defects in code that already shipped. This is Layer 0
hardening, not new Layer 0 scope: no new capability is added, no public contract not already
promised by an existing `.mli` is introduced, except where a `.mli` was found to overclaim (fixed
by narrowing the claim, never by widening it further).

This work is scoped as a new task-master task (see "Task-master structure" below) sequenced as a
prerequisite to Task 5, since Task 5 defines the Layer 0/Layer 2 boundary and that boundary is
not worth defining precisely on top of a Layer 0 with known Critical safety gaps.

## Group 1: Sender-authenticated transport + consensus forgery closure

The audit's single highest-leverage finding: `Transport_intf.S.receive : t -> string` carries no
sender, `Prepare` and `Start_view` carry no sender field on the wire, and `Tcp`'s handshake
preamble binds a claimed peer id to nothing cryptographic. One design closes both the
cluster-wide log-rewrite finding (Track B) and the peer-ID-spoofing finding (Track E) at their
shared root.

### Decision 1.1: `Transport_intf.S.receive` returns the authenticated sender

```ocaml
val receive : t -> string * int  (* payload, authenticated sender peer id *)
```

`Tcp`'s implementation binds the returned id to the TLS certificate actually presented on that
connection, not to the handshake preamble's claim. `lib/pki/ca.ml:164` already encodes each
replica's numeric id into its leaf certificate's SAN — `Tcp.create` decodes the SAN of the
*verified* peer certificate itself (not the preamble) and uses that as the authenticated id. The
preamble's claimed id becomes redundant and is removed from the wire format (Decision 1.3) rather
than kept as an unverified hint. `Sim_transport` returns each simulated peer's already-known id
verbatim — no behavior change, only a signature change.

### Decision 1.2: `Tcp` rejects a second connection claiming an already-connected id

Today `Hashtbl.replace` (`tcp.ml:159`) silently evicts the legitimate writer when a new connection
claims an id already present. After Decision 1.1, "claims" becomes "is authenticated as" — but the
same hijack is possible if a replica's real certificate is compromised or if two connections from
the same legitimate replica race (e.g. across a reconnect). `create` refuses the second connection
outright (closes it, logs, does not touch the existing table entry) rather than replacing silently.
No reconnection logic exists yet (a separately disclosed, not-yet-fixed gap — see Non-Goals), so
this is conservative: a replica that needs to reconnect today gets a new `Tcp.t` anyway.

### Decision 1.3: `Prepare` and `Start_view` carry a real sender field; `Replica.handle_message` cross-checks it against the transport-authenticated id

`Message.ml`'s wire format gains a `source : int` field on `Prepare` and `Start_view` (every other
message type already carries `i`). `Replica.handle_message` changes signature to accept the
authenticated sender alongside the payload bytes, and for every message type checks the payload's
own claimed sender (`i` or the new `source` field) against the transport-authenticated one,
rejecting on mismatch with `Invalid_argument` (mirroring the existing convention: guard failure ⇒
total no-op, counted, never a partial state change). This closes 4a/4b/4d/4e from the consensus
audit and A3/A3b/A3c from the transport audit in one mechanism: a message's claimed sender can no
longer diverge from who actually holds the TLS session it arrived on.

### Decision 1.4: `Tcp.send` validates against the membership table it was actually given

`send` (`tcp.ml:514`) currently accepts any id with a live connection, including one an attacker
caused to be inserted (pre-Decision-1.2). Once 1.1/1.2 close the insertion path, this becomes
defense in depth rather than the primary fix: `send` additionally checks `to_` against the
membership `create` was given, matching the doc's own long-standing claim (`tcp.mli:147`).

**Migration:** this is a wire-format-breaking change to `Prepare`/`Start_view` and a
signature-breaking change to `Transport_intf.S`/`Replica.handle_message`. No production binary
exists (confirmed by the audit: no `bin/` entrypoint, no non-test caller of either signature), so
there is no live wire compatibility to preserve — every caller is in `test/`, `lib/dst/cluster.ml`,
and `explore/`, all updated in the same change.

## Group 2: Value/data-model codec hardening

### Decision 2.1: Decode a `Map` key in place; drop the `String.sub` copy

`lib/value.ml:238-240`'s `decode_value_exact kblob` recursion, fed by a freshly copied sub-buffer
at each nesting level, is O(N²) in both time and simultaneously-live memory. Replace it with
decoding directly against the outer buffer `s` at the current `pos`, passing the key blob's end
offset as an expected-consumption bound and raising if the nested decode doesn't consume exactly
that many bytes. This removes the copy entirely — O(1) extra space per nesting level instead of
O(remaining blob size). Mirror the same in-place approach in `encode_into`'s `Map` case (currently
allocates a fresh `Buffer` per key level).

### Decision 2.2: `canonical_decode` enforces strict canonical ordering and rejects duplicates

`Record` fields and `Map` entries must decode in strictly increasing key order (the same order
`canonical_encode` already produces via `List.stable_sort`); a decode that finds two adjacent keys
not strictly increasing (equal — a duplicate — or out of order) raises `Invalid_argument`. This
closes both 3a (malleable non-canonical byte strings — now unrepresentable) and 3b (duplicate keys
breaking the documented order-independence guarantee — now impossible to construct via decode).
`canonical_encode`'s own `List.stable_sort` gains a companion duplicate check for values
constructed directly in memory (not via decode) — a `Record`/`Map` with a duplicate key raises at
encode time rather than silently producing a doubly-keyed value.

**Migration:** any hand-constructed test fixture relying on duplicate keys or non-canonical byte
order must be found and fixed or retired — the plan's own task will grep for and enumerate these.

### Decision 2.3: Bounded decode depth and an output-size budget

`decode_value`/`encode_into` gain an explicit nesting-depth counter, threaded as an extra
parameter, raising `Invalid_argument` past a fixed limit (1000 — deep enough for any real payload
this codebase produces, since the deepest real nesting today is `Envelope`'s own handful of
levels; shallow enough to keep worst-case stack frames bounded regardless of the runtime's stack
size). Separately, `canonical_decode` tracks total decoded node count against a budget derived from
`lib/transport/tcp.ml`'s `max_message_size` (currently 64 MiB) — since 1c's measurement showed a
64 MiB frame's worst-case decode can reach ~9 GB live memory even without 2.1's quadratic bug, a
node-count budget scaled to the wire size (not just the wire size itself) is the only bound that
actually caps memory. `value.mli` is corrected to document these as real limits, not aspirational
ones, closing the "raises cleanly" gap that a lowered stack limit exposed.

### Decision 2.4: Doc corrections

`value.mli:36-39`'s "need not be pre-sorted... encode identically" claim is now true unconditionally
post-2.2 (duplicates can no longer exist) — the wording is simplified rather than caveated.
`envelope.ml:26-32`/`envelope.mli:33-40`/`test_envelope.ml:67-79`'s "can never collide... even under
adversarial construction" is corrected to state the actual, narrower property: collision is
possible only for a payload of the literal shape `Sum ("Envelope", to_value e)`, which is an
intentional, tested equivalence (`test_envelope.ml:88-94`), not a defect — the three sites are
reworded to agree with each other and with that test instead of contradicting it. The dead
`L4/final-review.md` reference in `test_value.ml:141-149` is replaced with a reference to this
spec.

## Group 3: Storage layer hardening

### Decision 3.1: Replace per-I/O `mmap` with a reusable aligned-buffer pool

`alloc_aligned_buffer` (`file_storage.ml:141-151`, duplicated in `file_kv_store.ml:106-116`)
allocates a throwaway-file `mmap` per read/write with no explicit release. Replace with a small
fixed-size pool of aligned buffers owned by `t` (allocated once at `create`/`restart`, sized to the
handful of buffers a single-fiber storage backend needs concurrently — this codebase's own
concurrency model is one Eio domain per replica, so a pool of a few buffers suffices), acquired and
explicitly released around each I/O rather than left to GC finalization. This is a purely internal
change — `Storage_intf.S`/`Kv_store_intf.S` are unaffected.

### Decision 3.2: A real filesystem-level lock on `create`

`File_storage.create` and `File_kv_store.create` each take an `flock(LOCK_EX | LOCK_NB)` on a
`.riptide-lock` file in the target directory, held for the handle's lifetime, released on close.
A second `create` against an already-locked directory raises `Invalid_argument` immediately rather
than silently interleaving writes with the first holder. This is a genuine new physical guard
alongside the existing logical owner-tag mechanism (Decision 3.2 does not replace or change the
owner tag — the two serve different failure modes: the lock stops concurrent processes: the owner
tag stops sequential misuse by different logical consumers).

### Decision 3.3: Classify real I/O failures the same way guard-failures are already classified

`Replica.durable_append`'s `classify_append_refusal` today only recognizes `Invalid_argument`
shapes. Extend `append_refusals` with a new bucket, `storage_fault`, populated when `wal_append`
raises anything else recognizable as a real I/O failure (`Eio.Io`, `Sys_error`, `Out_of_memory`).
`durable_append` catches these alongside the existing `Invalid_argument` match, increments
`storage_fault`, and returns `false` exactly as an ordinary refusal does — turning an unclassified
process-killing escape into the same "counted, total no-op" shape every other guard already
guarantees. This directly fixes Storage-Important-1 (ENOSPC escaping `Replica`) and gives Group 7's
telemetry hook (Decision 7.4) something real to report.

### Decision 3.4: A superblock-rebuild entry point

`Storage_intf.S` gains `superblock_rebuild_from_wal : t -> unit`, callable only when
`superblock_read` returns `None` over a non-empty WAL (Storage-Important-2's softlock). It
reconstructs a fresh superblock from the WAL's own recoverable state (`recover_highest_op_number`'s
scan, which `create` already performs) — the same information `Replica.create`/`restart` already
use to detect this exact state, now exposed as a real repair action instead of a dead end.
`Replica.restart`'s error message on this state is updated to name the new entry point.

### Decision 3.5: Validate `ring_capacity >= 1` at `create`

`File_storage.create` raises `Invalid_argument "ring_capacity must be >= 1"` for
`ring_capacity <= 0`, closing Storage-Important-3's `Division_by_zero`/negative-offset escapes at
the earliest possible point — configuration-time, not first-request-time.

### Decision 3.6: Atomic owner-marker writes; a 0-byte marker is treated as unclaimed

`check_or_write_owner_marker` (`file_kv_store.ml:332-339`) changes from create-then-write to
write-temp-then-rename, matching the durability pattern `durable_write` already uses elsewhere in
the same module — closing the crash-between-create-and-write window entirely. As defense in depth
against any remaining torn state, a marker read as exactly 0 bytes is treated as "no marker present"
(same as a missing file) rather than as a claimed empty-string owner, so a torn marker from before
this fix ships is self-healing on next `create` rather than a permanent brick.

### Decision 3.7: Randomize `File_kv_store`'s temp-file suffix per call

`tmp_suffix` (`file_kv_store.ml:200-206`) becomes unique per call (e.g. a counter plus the calling
fiber's identity) instead of the fixed `".put.tmp"`. This does not change the documented contract
that concurrent same-key writers have an undefined winner — it removes the *unintended* failure
mode the audit found on top of that (interleaved writes into one shared temp file producing a torn,
unreadably-checksummed record — Storage-Important-6's "phantom None"/2% full-destruction result).
POSIX `rename`'s atomicity then guarantees whichever writer's `rename` lands last, its complete
record is what a reader sees — never a mix of two writers' bytes.

### Decision 3.8: Temp files live in the target directory, not `TMPDIR`

`alloc_aligned_buffer` and `File_kv_store`'s put-path both move their temp-file creation into the
target storage directory itself (already the same filesystem as the final destination — required
for the existing `rename`-based durability pattern to be atomic in the first place) instead of
`Filename.temp_file`'s `TMPDIR`-rooted default. This removes the hard cross-filesystem `TMPDIR`
dependency (Storage-Important-7) as a side effect of removing a real correctness risk (a `TMPDIR`
on a different filesystem than the target directory would make `rename` non-atomic even before this
fix — the audit didn't find that path exercised only because `TMPDIR` and the storage directory
happened to share a filesystem in every test run).

### Decision 3.9: `File_kv_store` shards its flat directory

`path_for`'s `hash_to_hex (content_hash key)` filename gains a two-level directory prefix (first 2
and next 2 hex characters of the hash, matching common content-addressed-store convention — e.g.
git's own object store), bounding any single directory's entry count to roughly 1/65536th of the
total key count. This does not fix the ~123× space amplification or the one-inode-per-key ceiling
(Storage-Important-5's other two findings) — those are inherent to the fixed 8192-byte slot
layout and are accepted as a documented, disclosed limit (see Non-Goals) rather than redesigned
here, since fixing them would mean a variable-size value format, a materially larger change out of
proportion to this remediation's scope. `file_kv_store.mli` gains an explicit "supported key-count
range" note stating the inode/space costs plainly so an operator can plan around them.

**Migration:** the directory-sharding change is a breaking on-disk layout change. No production
data exists (no `bin/` entrypoint), so no migration tooling is needed — every test fixture is
regenerated by the tests themselves on the next run.

### Decision 3.10 (Minor bundle): O_DIRECT misdetection, use-after-close, and startup cost

Three small, independent fixes bundled into one task since none needs its own design discussion:
`perform_write`/`perform_read`'s `with Eio.Io _ when h.direct_capable` narrows to the specific
errno shapes that actually indicate O_DIRECT-unsupported (not a blanket catch-all);
`downgrade_to_dsync_only` sets `h.direct_capable <- false` *before* attempting the reopen, so a
failed reopen never leaves a closed fd paired with a stale "still direct-capable" flag; and
`recover_highest_op_number`'s O(`ring_capacity`) startup scan gets a doc note quantifying the real
cost next to the sizing guidance that already argues for large `ring_capacity` values (a resumable
or hinted scan is judged out of scope — see Non-Goals — since it is a pure performance concern with
a documented, bounded cost, not a correctness gap).

## Group 4: Materializer concurrency + divergence fixes

### Decision 4.1: Per-`merge_key` serialization inside `Materializer`

`Materializer.write`'s read-join-put is wrapped in an in-process lock keyed by `merge_key` (a small
hashtable of `Eio.Mutex.t`, created on first use per key, matching the concurrency model already
established elsewhere in this codebase). This closes the "exactly one concurrent writer survives"
finding for the realistic deployment shape — one `Materializer` instance per replica process — by
making concurrent writers to the same key serialize rather than race. Combined with Decision 3.7
(no more torn temp-file writes), this closes both halves of the Critical concurrent-write finding:
no more lost updates within a process, and no more possible full-accumulator destruction from a
torn write. Cross-process concurrent writers to the same `File_kv_store` directory remain outside
this module's contract (unchanged, and now physically locked out entirely by Decision 3.2).

### Decision 4.2: Per-write materialization failure no longer aborts the whole batch or the whole replay

`Batch_commit.propose`'s write loop and `materialize_up_to`'s replay loop both change from
"the first raising `Materializer.write` aborts everything after it" to "a raising write is caught,
counted, and the loop continues to the next write." This directly fixes the Critical restart-
divergence finding (a poisoned key today permanently blocks *every other* key's materialization
from that point in the log onward, on every future restart) and the batch-atomicity finding (one
oversized write in a batch today silently drops sibling writes' materialization). The two loops
share one already-existing helper (or gain one, if none currently exists) so the fix is written
once. `materialize_up_to`'s doc comment is corrected: the accumulator is "a function of the
committed log plus each key's own size-bound history" rather than "the committed log alone" —
narrowing the claim to what is actually now true, rather than promising full log-determinism a
4096-byte cap makes structurally impossible to fully honor.

### Decision 4.3: A useful error message names the `merge_key`

`Materializer.write`'s `Invalid_argument` on overflow includes the `merge_key` (currently omits
it — the audit found the message names only the byte counts). This does not add a scanning/health
API (judged out of proportion to the finding — see Non-Goals) but makes the one signal that does
exist actionable: an operator who is already logging `storage_fault`-classified exceptions
(Decision 3.3's sibling for the KV layer) can now tell which key overflowed without decoding the
value themselves.

### Decision 4.4: Promote `Lattice_conformance` to an installable library

`test/lattice_conformance.ml` moves to `lib/lattice/lattice_conformance.ml` (or a new
`lib/lattice_conformance/` library, matching this codebase's existing one-library-per-concern
convention) so a caller implementing their own `Lattice_intf.S` can actually run the law-checking
property tests `lattice_intf.ml`'s own doc comment already points them to. `test/dune`'s existing
lattice conformance tests become consumers of the new library rather than the library itself. No
runtime enforcement of the laws is added (see Non-Goals) — this closes the "the one tool that could
have caught this is unreachable" gap, not the "a badly-behaved user lattice can hang a fiber" gap,
which Non-Goals explicitly declines.

## Group 5: Crypto/redaction policy

### Decision 5.1: Retract the keystore-backup recommendation; state the real guarantee precisely

`redaction_store.mli`'s existing recommendation to back up the keystore directory "with the same
care the KEK file gets" is removed and replaced with the precise, honestly-disclosed guarantee:
redaction deletes the live keystore's only pointer to a record's wrapped DEK; it has no effect on
any copy of that pointer made before the redaction, wherever that copy lives (a filesystem
snapshot, an out-of-band backup, forensic recovery of unallocated blocks — the last of which was
already disclosed). The durability a keystore backup exists to provide is instead obtained from
this system's own replication: a wrapped DEK already lives on every replica via ordinary VSR
commit, and `redact` must be applied to every replica's keystore to be effective cluster-wide
(this was already implicitly true; it is now stated explicitly). An operator's backup/retention
policy for anything derived from the keystore must independently prune entries once redacted, or
must not exist at all past the shortest tolerable redaction-latency window — this is an operational
requirement this module cannot enforce in code, so it is documented as a hard requirement rather
than a suggestion. A new test (`test_a_pre_redaction_keystore_backup_defeats_redaction`) pins the
real behavior the audit reproduced, matching this codebase's established pattern of disclosing a
real residual limitation via a running negative-control test rather than prose alone.

### Decision 5.2: `Kv_store_intf.S` gains enumeration; `Redaction_store` gains KEK rotation

`Kv_store_intf.S` gains `val fold : t -> init:'a -> (key:string -> 'a -> 'a) -> 'a` (visiting every
key currently present — `File_kv_store`'s real implementation is a directory listing over
Decision 3.9's now-sharded layout; every other implementer, if any existed, would need the same).
Each wrapped-DEK record `Redaction_store` writes gains its plaintext `event_id` stored alongside
the wrapped bytes (the `event_id` is not secret — it is already the AAD `Kek.unwrap` requires as a
caller-supplied input, and storing it removes the current requirement that a rotation tool already
know every `event_id` out of band). `Redaction_store` gains
`rotate_kek : t -> new_kek:Kek.t -> unit`, which folds over the keystore via the new primitive,
unwraps each entry under the current KEK, re-wraps under `new_kek`, and writes back — per-entry,
so a rotation interrupted partway through leaves a mix of old- and new-KEK-wrapped entries rather
than a torn one (each individual entry's write is already atomic per Decision 3.6/3.7's mechanisms).
`redaction_store.mli` documents this as the KEK-compromise remediation path that did not exist
before.

**Migration:** storing `event_id` alongside each wrapped record is a breaking on-disk format
change for `Redaction_store` entries specifically (not `File_kv_store` generally). No production
data exists, so no migration tooling is needed.

### Decision 5.3: `require_encryption` becomes a construction-time policy, not a per-call flag

`Batch_commit`'s constructor gains `?require_encryption:bool` (default `false`, matching today's
default), stored on the handle. `propose`'s existing `?require_encryption` parameter, if supplied,
overrides the handle's default for that one call (unusual, deliberate opt-outs remain possible);
if omitted, the handle's own policy applies. This closes the finding that the mitigation and the
gap it exists to catch live at the exact same call site (a call site that forgets `~encryption`
was, by construction, equally likely to forget `~require_encryption`) — a deployment now sets the
policy once, centrally, and every `propose` call site inherits it.

## Group 6: Transport resource limits

### Decision 6.1: A configurable cap on concurrent accepted connections

`Tcp.create` gains `?max_connections:int` (a sane default — e.g. `replica_count * 4`, generous
enough for normal reconnect churn, far below any realistic fd ulimit). The accept loop refuses
(closes immediately, no handshake attempted) any connection beyond the cap. This directly bounds
Track E's fd-exhaustion finding at its source rather than only softening its failure mode.

### Decision 6.2: `EMFILE` on `accept` is not counted toward the fatal error budget

`accept_max_consecutive_errors`'s counter (`tcp.ml:62-63`) currently treats `EMFILE` the same as a
genuine protocol/transport error and re-raises fatally past the threshold. `EMFILE` specifically is
excluded from that counter — the accept loop instead logs and backs off briefly before retrying,
since Decision 6.1 should make sustained `EMFILE` rare in the first place, and the failure mode for
a resource-transient condition should never be "the listener process exits."

### Decision 6.3: A bounded inbox and a read-idle timeout on established connections

`Eio.Stream.create max_int` (`tcp.ml:457`) becomes a finite, configurable capacity — a full inbox
blocks the sending fiber (real backpressure) rather than growing without bound, closing the
unbounded-memory-growth finding. Separately, `run_connection`/`reader_body` gain a read-idle
timeout (matching the shape of the existing 10s handshake/preamble timeouts, reused rather than a
new mechanism invented) so a connection that completes its handshake and then goes silent
indefinitely is eventually closed rather than held forever — closing the gap the audit found
between the doc's claim ("bounded only by ~10s handshake/preamble timeouts") and the real,
unbounded post-preamble behavior.

## Group 7: Consensus operability

### Decision 7.1: Ring-wedge early warning, and a documented, tested resize-before-wedge procedure

`Storage_intf.S` gains a `ring_margin : t -> int` accessor (`ring_capacity` minus the count of
not-yet-evicted entries) reachable through `Replica`'s existing abstract-storage boundary the same
way `wal_highest_op_number` already is. `?may_evict` (already defined but never wired — the
audit's finding that `eviction_blocked` is structurally pinned at zero) gets threaded through every
real `File_storage.create` call site (`lib/dst/cluster.ml` and any other production-shaped caller),
so the counter `replica.mli` already documents actually increments as promised. Because data
already evicted from the ring is physically gone and no code can un-evict it, the "fully
satisfactory" resolution here is early, actionable warning plus a documented, tested recovery
runbook performed *before* the wedge: a new test demonstrates copying a replica's still-live
entries into a freshly created, larger-capacity `File_storage`, and `file_storage.mli` documents
this as the supported resize procedure. This is the same "disclose the real limitation honestly,
pin it with running code, don't pretend to magically cure a physical constraint" pattern this
project already used for the same-owner-tag residual gap.

### Decision 7.2: A stranded replica keeps retrying its view-change broadcast

`try_forfeit_view_change`/`check_timeout`'s current behavior — one `StartViewChange` broadcast,
then silent inaction below quorum on every subsequent timeout — changes to re-broadcast on each
timeout while below quorum, bounded by the existing `svc_limit` retry budget. The "coupled minor"
(`svc_count` not incremented on the below-quorum path) is fixed in the same change, since the fix
requires the counter to be accurate for the bound to mean anything. This closes the transient-
partition-permanently-strands-a-replica finding: a dropped broadcast is no longer a permanent,
silent exit from the cluster's fault-tolerance budget.

### Decision 7.3: Content-check the committed prefix, not just its length

`truncate_wal` and `handle_start_view`'s guards both gain a check that the incoming log's entries
covering `[1, local commit_number]` match the locally held committed entries' content hashes
exactly, refusing wholesale (the existing "stop rather than destroy" convention, same as the C1
`restart` finding already established) on any mismatch. This is inert for every correct execution
(`NoLogDivergence` already holds for all honest traffic per the TLA+ spec) and, combined with
Group 1's sender-authentication fix, converts what would otherwise still be a silent-substitution
risk into a loud, safe refusal — genuine defense in depth rather than the sole safety mechanism.

### Decision 7.4: A generic event hook for observability, plus `peer_op_number` exposure

`Replica.create`/`restart` gain `?on_event:(replica_event -> unit)`, mirroring the existing
`?on_commit_advanced` pattern already in the module rather than introducing a new mechanism or a
logging library dependency. `replica_event` is a closed variant covering: every guard rejection
(already-classified via Decisions 1.3/3.3's refusal buckets), every status transition, and —
critically — `commit_number` decreases specifically (today filtered out of the one existing push
channel, `on_commit_advanced`, per `replica.mli:465`'s own documented filter; the new hook does not
filter this out, closing the "the most alarming event this module can produce is invisible" gap).
`peer_op_number` gains a real accessor (not test-only), giving a primary a way to report which
followers are lagging or silent — the audit's own "the single most useful consensus health signal
there is" and currently the only internal field with no accessor of any kind.

### Decision 7.5: Doc corrections

The `2026-09-24-layer0-followup-hardening-design.md` spec's still-present claim that disk-full
"raises a loud, distinguishable exception" (superseded, per the audit, by the later
`2026-09-25` spec, but never removed from the earlier document) is corrected in place — the earlier
spec's relevant paragraph is rewritten to point forward to Decision 3.3 rather than describing
behavior that never shipped. `replica.mli:538`'s reference to a non-existent `svc_count` accessor
is resolved by adding the accessor (useful for the same reason `peer_op_number`'s is, and cheap
now that Decision 7.2 already needs `svc_count` to be accurate).

## Task-master structure

One new task-master task (next available id — the CLI assigns it; referred to here as **Task N**
since the exact id is a mechanical detail this spec doesn't need to predict) titled "Harden Layer 0
against adversarial real-world conditions (deep audit remediation)", `dependencies: ["4"]`. Task
5's own `dependencies` gains Task N's id, inserting this work as a logical prerequisite without
renumbering any existing task. One subtask per Decision above (33 subtasks, grouped in the same
1.1-7.5 order used throughout this document), each carrying its own `evidence.commits` on
completion per this repo's existing "task status is derived, never asserted" convention.

## Non-goals

- **No fix for `File_kv_store`'s fundamental space/inode amplification.** Decision 3.9 shards the
  directory but does not redesign the fixed 8192-byte slot layout; that would require a
  variable-size value format, out of proportion to this remediation.
- **No runtime enforcement of user-supplied lattice laws.** Decision 4.4 makes the conformance
  tests reachable; it does not add a runtime guard that detects a non-conformant `join` in
  production, which is not generally decidable and would add overhead to every call for a
  misuse case this codebase cannot fully prevent by construction.
- **No resumable/incremental ring-capacity recovery scan.** Decision 3.10 documents the real
  O(`ring_capacity`) startup cost; a faster scan is a pure performance improvement with no
  correctness implication, deferred as out of scope.
- **No general reconnection/retry logic for `Tcp`.** Decision 1.2 conservatively refuses a
  duplicate-id connection rather than adding reconnection semantics, which remains a
  separately-disclosed, not-yet-designed gap.
- **No certificate revocation (CRL/OCSP) and no ongoing re-validation of already-established
  connections' certificate expiry.** Both remain disclosed, not fixed here — closing them would
  mean designing a revocation-distribution mechanism, a materially separate project from this
  remediation's scope.
- **No true prevention of "a KEK is lost" being unrecoverable.** Decision 5.2 adds rotation (the
  remediation for suspected *compromise*); it does not add key escrow or secondary-wrap recovery
  for outright *loss*, which is a deliberate design choice (an escrow mechanism is itself a new
  key-management surface with its own risk, not something to add as a side effect of an audit
  remediation).
