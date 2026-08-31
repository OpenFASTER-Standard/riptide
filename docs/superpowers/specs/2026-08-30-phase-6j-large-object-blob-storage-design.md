# Phase 6j — Large Object (Blob) Storage

## 1. Context and motivation

Sub-project 6 (Derivation and execution layer) is being built phase-by-phase against
`docs/superpowers/specs/2026-08-27-derivation-and-execution-layer-design.md`. This phase implements
**6j — Large object (blob) storage**, a Track C phase (`depends on: 6b-ii`, already shipped) that
was originally scheduled independently of the rest of Sub-project 6 — but turned out, during
brainstorming for a reactive Capability-triggering design (not yet its own phase), to be a hard,
concrete prerequisite: `Riptide.Capability.invoke/4` shells out to the `wasmtime` CLI against a
**local filesystem path** (`definition.component`), and there is currently no mechanism for a
dynamically-registered Capability's WASM bytes to become available, byte-identical, on whichever
node in the fleet ends up invoking it. That need is real, but out of scope here — this phase builds
the general-purpose blob primitive; wiring a Capability-registration flow on top of it is separate,
future work.

The parent spec's own §3.3 already made the core architectural calls for this phase (content
addressing, splitting identity from bytes, building on 6b-ii's supervised-process primitive rather
than the WASI-sandboxed Capability path) and named three things explicitly open: a garbage-collection
scheme, the security boundary for the privileged blob-serving process, and node-replication of the
bytes themselves. This spec resolves all three.

## 2. Scope

- A privileged, Riptide-native `Riptide.BlobStore` API: `put/1` (bytes → content hash), `get/1`
  (hash → bytes), backed by real durability — RF-replicated across nodes, not single-node.
- Content addressing via SHA-256 over the full blob (whole-blob hashing, not content-defined
  chunking — see §5).
- A dedicated, Ra-replicated location index (`hash → [nodes]`) enabling any node to serve a `get/1`
  regardless of which node originally received the `put/1`, mirroring `Riptide.Placement`'s own
  `stream_id → [nodes]` tracking but for a different concern (§7).
- A background repair sweep that detects a blob whose replica count has dropped below the
  configured factor (a node holding a copy died) and re-replicates it from a surviving copy,
  mirroring `Riptide.Stream.ReplicaHealer`'s existing shape (§7).
- A fully written, adopted garbage-collection scheme (reference-counted manifest state machine),
  documented in this spec as the intended future mechanism — **not implemented this phase** (§8).
- An explicit security-boundary statement for the blob-serving process (§9).

## 3. Out of scope

- Content-defined sub-chunking (casync/desync-style buzhash chunking) for streaming very large
  blobs without full in-memory buffering, or for deduplicating partially-similar files. Whole-blob
  hashing satisfies this phase's own exit criterion; chunking is a genuine future refinement, not
  required here (§5).
- Implementing garbage collection (deletion). The scheme is fully specified (§8) so a future phase
  can implement it directly; this phase's own data model only carries what `get`/`put`/replication
  actually need (`hash → [nodes]`), not unused reference-tracking fields (YAGNI).
- Any HTTP endpoint for blob upload/download. Like most Sub-project 6 primitives (Catalog, DedupGate,
  Discovery before 6h-ii wired Hub-scope HTTP), this ships as a library-level API first; HTTP surface
  is added later by whichever consumer needs it (a future Capability-registration phase, or a
  generic upload endpoint).
- Dynamic Capability registration itself (the motivating consumer). This phase builds the general
  blob primitive only.
- Tenant-scoped access control on blob bytes. `BlobStore` performs no authorization of its own —
  see §9.

## 4. API and layering

```elixir
@spec put(binary()) :: {:ok, hash :: String.t()} | {:error, term()}
@spec get(String.t()) :: {:ok, binary()} | {:error, :not_found}
```

`Riptide.BlobStore` is privileged, Riptide-native code — the same trust tier as `StreamServer`,
`Catalog`, `Authz.Store` — explicitly outside the WASI sandbox, per the parent spec's own direction
(§3.3: "not by routing blob storage through the general-purpose, tenant-facing, WASI-sandboxed
Capability path"). It performs **zero** independent authorization. Every caller — a future
Capability-registration flow after already checking Capability-invocation authorization, a future
resource-download endpoint after already checking the referencing resource's own ACP — is
responsible for authorizing *before* calling `put/1`/`get/1`. This mirrors exactly how `Catalog`/
`DedupGate` have no auth logic of their own; authorization lives one layer up, per Sub-project 4's
existing layering discipline.

Started as an instance of `Riptide.SupervisedProcess` (6b-ii, already shipped) — the same
revocable/restartable-safety primitive the parent spec's own research (§8.12, research log Part 2)
concluded both a native blob store and a future persistent Capability should share.

## 5. Content addressing

Each blob is identified by the SHA-256 hash of its full byte sequence, computed on `put/1` and
re-verified on every `get/1` (a read whose bytes don't match their own claimed hash is corruption,
not a valid result). The parent spec's own research (casync/desync, IPFS/UnixFS) converges on
content-*defined chunking* (variable-size sub-chunks named by a rolling hash) as the real-world
architecture for this problem space — but that technique's value is streaming very large files
without full in-memory buffering, and deduplicating *partial* overlap between similar-but-not-
identical files. Neither is required by this phase's own exit criterion (a blob >10MB, addressed by
hash, retrievable via a hash-pointer Fact). Whole-blob hashing is fully content-addressed and fully
verifiable; chunking is documented here as a legitimate future refinement, not built now.

## 6. Storage layout and replication

Blob bytes live on local disk, one file per hash, under a configurable directory
(`RIPTIDE_BLOB_DATA_DIR`, mirroring the existing `RIPTIDE_RA_DATA_DIR` convention for Ra's own data),
backed by the same kind of persistent volume every node already has.

Bytes are **not** replicated through Ra consensus — pushing multi-MB/GB values through consensus on
every write, and growing every replica's snapshot with them, is exactly the anti-pattern this whole
phase exists to avoid (§3.3: "does not belong directly in that log"). Content-addressed, immutable
bytes don't need consensus to replicate safely: any node holding hash `H`'s bytes is equally
authoritative, verifiable just by re-hashing — there's no ordering question the way there is for an
append-only Fact log. This is why CORFU/Delos and Riak CS (both already in the parent spec's own
research) keep the bulk-data plane fully separate from the coordination plane.

**Write path (`put/1`):** the receiving node writes locally, then pushes verified copies to
`RF - 1` other live nodes, where `RF` defaults to `3` — the same replication factor
`Riptide.Placement.propose_nodes/2` already uses for ordinary stream placement (one consistent
operational story, not a new number to reason about) — via a direct distributed-Erlang call
(`GenServer.call({Riptide.BlobStore, target_node}, ...)`, the same `{name, node}` addressing
`RaCluster`/`Placement` already use throughout). Each receiving node re-verifies the hash before
accepting a copy — corruption or tampering in transit is rejected, not silently stored.

**Read path (`get/1`):** checks local disk first; on a local miss, consults the location index (§7)
for another node known to hold a copy and fetches from it directly — the same "try each known
replica in turn" shape `StreamServer.try_replicas/2` already uses for stream reads.

## 7. Location index and repair

A small, dedicated Ra-replicated machine — **not** the shared placement-metadata cluster (which
tracks infrastructure-level `stream_id → [nodes]` assignments; mixing that low-frequency metadata
concern with blob-count-proportional data would be a scaling/blast-radius mismatch, the same reason
Catalog/PendingReview/Crosswalk each already get their own dedicated stream rather than reusing
placement) — storing `hash → [nodes currently holding a verified copy]`. Updated by `put/1`'s own
replication step and by the repair sweep below.

`Riptide.BlobStore.Healer` (or folded into `Riptide.BlobStore` itself as a periodic tick — exact
module boundary is an implementation decision, not a design one) mirrors `Riptide.Stream.
ReplicaHealer`'s existing shape: a periodic sweep over the location index, and for any hash whose
live replica count has dropped below the configured factor (a node holding a copy died, detected via
`RaCluster.member_alive?/1`-style liveness checking), fetches the bytes from a surviving replica and
writes a new copy to a live node not already holding one, then updates the index. No new coordination
primitive — this is a direct application of the exact repair pattern already shipped and live-proved
in production for stream replicas.

## 8. Garbage collection — documented scheme, not implemented this phase

Riptide has no cheap way to count how many Facts reference a given blob hash by scanning — Facts
live scattered across many independent per-resource streams. So reference counting here is
**explicit, not derived**: whoever writes a hash-pointer Fact (`<resource> :attachment
<urn:riptide-blob:sha256:...>`) also calls `BlobStore.add_reference(hash, referencing_stream_id)`;
removing or overwriting that Fact calls `remove_reference/2`. This adapts Riak CS's own manifest
state machine (the parent spec's own research, Part 2): a blob's manifest moves `active →
pending_delete` once its reference set becomes empty (with a grace period, so a fast
remove-then-re-add doesn't trigger a spurious delete), then `pending_delete → scheduled_delete` and
actual deletion if it's still unreferenced after that window — driven by the same kind of periodic
sweep as §7's repair process, just walking manifests instead of replica counts.

This phase's own location index only carries `hash → [nodes]` — no `references`/`state` fields,
since nothing in this phase's own scope would populate them (YAGNI). Implementing this scheme is
explicit follow-on work, gated on a real consumer (e.g. Capability registration) actually writing
`:attachment`-shaped Facts and needing the reference hooks wired at those write sites.

## 9. Security boundary

`Riptide.BlobStore` is privileged, Riptide-native code — outside the WASI sandbox by design (§4).
It performs no Tenant/ACP checks; every caller authorizes before calling it.

**Cross-tenant deduplication is accepted at the storage layer.** Content-addressing means identical
bytes uploaded by two different Tenants hash identically and are stored once — standard practice in
every real precedent this design draws on (git, IPFS, casync). Access stays fully Tenant-scoped at
the Fact layer: a Tenant can only reach a blob via a hash-pointer Fact *they* wrote; they never see
another Tenant's Fact. The one residual risk this model carries — a side channel where confirming
"hash `H` already exists" reveals that *someone* has uploaded specific, already-suspected content,
without ever exposing its bytes — is a known, industry-accepted property of every content-addressed
system that exists. Named here explicitly as an accepted residual risk, not defended against, the
same way Phase 6h-i named anonymous-read Hub enumeration as accepted rather than solved.

## 10. Testing

- `put/1`/`get/1` round-trip for a blob well over 10MB (this phase's own exit-criterion size),
  verifying hash-addressing and byte-for-byte fidelity.
- A `put/1` writes locally and to `RF - 1` other live nodes; verified via the location index's own
  recorded node set, against a real multi-node test cluster (`:peer`-based, matching Phase 3e's own
  multi-node test convention).
- `get/1` succeeds from a node that never received the original `put/1`, by fetching from another
  node listed in the location index (proves the write-once/read-anywhere property this phase exists
  to provide).
- A tampered/corrupted local copy is rejected on read (hash mismatch), not silently served.
- Repair sweep: a live multi-node test kills a node holding one of a blob's replicas, confirms the
  sweep detects the drop below RF and re-replicates to a live node, mirroring `ReplicaHealerTest`'s
  own existing shape for stream repair.
- **Capstone, proving the exit criterion literally**: a hand-authored fixture Capability (mirroring
  every other Sub-project 6 capstone test's own established convention — e.g. `greetPerson`/
  `deployService` in 6d-i/6e-iii's own tests) whose output is routed into `BlobStore.put/1`, with a
  hash-pointer Fact written pointing at the resulting hash, then read back via `get/1` through that
  Fact. This is a single, narrow, hand-wired integration test proving "a Capability can write a
  blob... retrievable via a hash-pointer Fact" is literally true today — it does **not** mean this
  phase builds any general mechanism routing arbitrary Capability output into the blob store; that
  general wiring is exactly the future Capability-registration work named out of scope in §3.

## 11. Exit criterion

Restated from the roadmap (§7 of the parent spec): a Capability can write a blob larger than 10MB,
addressed by content hash, retrievable via a hash-pointer Fact replicated through Riptide's existing
per-stream Ra log — satisfied by this phase's `put/1`/`get/1` API and RF-replicated storage — with a
documented (even if provisional) garbage-collection scheme (§8) and an explicit statement of what
security boundary governs the privileged blob-serving process (§9), both delivered in this spec.
