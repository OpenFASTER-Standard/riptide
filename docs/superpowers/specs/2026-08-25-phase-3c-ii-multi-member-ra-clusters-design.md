# Phase 3c-ii — Real Multi-Member Ra Cluster Formation — Design

**Status:** Approved 2026-08-25.

Sub-project 3 (Clustering / horizontal scale / HA) decomposes Phase 3c ("sharded per-stream
placement + real multi-member Ra clusters") into three sequenced sub-phases (see `PROGRESS.md`,
§ "3. Clustering / horizontal scale / HA"):

- **3c-i — Placement metadata store** (shipped 2026-08-25): a small, dedicated `:ra` cluster
  durably recording `stream_id → [replica nodes]`.
- **3c-ii — Real multi-member Ra cluster formation** (this document): consumes 3c-i's stored
  assignment to actually start an N-member Ra cluster for a stream, replacing today's
  hardcoded single-member `initial_members: [server_id]`.
- **3c-iii — Request routing**: wires the HTTP/SSE/WebSocket layer to consult 3c-i's store and
  dispatch to the correct node(s), replacing today's "always assume local."

## 1. Context and motivation

Today, every stream is a single-member Ra "cluster" of exactly one server, always on whichever
node happens to receive the create request (`Riptide.RaCluster.start_or_restart/2` computes
`server_id = {name, node()}` — always local, never resolved via any placement decision). This
means a stream has zero real replication: losing that one node loses the stream's live
availability (though not its durable data, which recovers on that same node's restart).

3c-i built the mechanism to durably record which nodes *should* host a stream's replicas, but
deliberately stopped short of using it — `Riptide.Placement.assign/propose_nodes` exist but
nothing calls them from the stream lifecycle yet, and `RaCluster`/`StreamServer` are entirely
unaware the placement store exists. This phase closes that gap: it's the first point at which a
stream actually gets real, multi-node Raft replication.

The actual multi-member cluster-formation *mechanism* is not new — 3c-i's own
`RaCluster.attempt_start_placement_cluster/1` already proves the pattern (per-member configs
sharing a deterministic uid, `:ra.start_cluster/2` handling the per-node RPC internally,
quorum-based partial-availability tolerance). This phase generalizes that pattern from the
metadata cluster's fixed 3 ordinals to an arbitrary per-stream node list drawn from
`Riptide.Placement`.

## 2. Scope

- Real N-member Ra cluster formation for streams, driven by `Riptide.Placement`. Genuinely new
  streams get RF=3 (matching 3c-i's already-established constant); streams backfilled from
  before this phase shipped get RF=1, matching what already exists on disk for them (§4) — not
  a contradiction of the RF=3 default, just a one-time accommodation for data that predates
  real placement.
- A local, per-node cache of each stream's resolved replica server IDs — safe to hold
  indefinitely for the life of the BEAM node, since placement is permanent once assigned (3c-i's
  own invariant: no reassignment/rebalancing, ever).
- Backward compatibility for streams that already exist from before this phase ships (see §4).
- Bounded-retry error handling for the cluster-*formation* step only (see §6).
- No HTTP/SSE/WebSocket routing changes — a client's request still needs to land on *a* node
  that's actually one of the stream's replicas (or any node, for read paths that don't strictly
  require it — TBD by 3c-iii) for things to work end-to-end; that dispatch logic is entirely
  3c-iii's job. This phase only makes it *possible* to address the right nodes once a request
  has landed somewhere that knows how to ask.
- No change to steady-state `process_command/2`/`consistent_query/2` error handling
  (redirect-on-`{:error, {:redirect, _}}`, retry-on-timeout) beyond the formation step itself —
  a pre-existing, already-flagged gap (`RaCluster`'s own moduledoc comments), not newly
  introduced here, deliberately deferred.
- No change to the fixed RF=3 constant, and no automatic reconciliation of a stream's own
  membership after a replica node's identity drifts — same "manual-first" posture as 3c-i,
  Phase 3d's job.

## 3. Module layout

- **`Riptide.RaCluster`** gains one new generalized primitive for multi-member cluster
  formation — analogous to `attempt_start_placement_cluster/1`'s per-member-config pattern, but
  parameterized over an arbitrary node list and uid rather than the hardcoded 3 placement
  ordinals. `RaCluster` remains the sole module that calls `:ra` directly (standing invariant
  since sub-project 1).
- **`Riptide.Stream.Placement`** (new) — orchestration layer sitting between `StreamServer` and
  both `RaCluster` and `Riptide.Placement`. Owns:
  - The local ETS cache (`stream_id → [:ra.server_id()]`).
  - The lookup/backfill/propose decision flow (§4).
  - Calling `RaCluster`'s new primitive to actually form the cluster.
- **`Riptide.Stream.StreamServer`** becomes a thin caller of `Riptide.Stream.Placement` instead
  of calling `RaCluster.start_or_restart/2`/`RaCluster.server_id/1` directly. `append/2` and
  `get_since/2` ask `Riptide.Stream.Placement` for the cached server IDs and address
  `RaCluster.process_command/2`/`consistent_query/2` via `hd(server_ids)` — the same
  "pick the first one, let `:ra`'s leader-redirect handle it" pattern
  `Riptide.Placement.assign/2`/`lookup/2` already use for the metadata cluster itself (`:ra`
  server IDs are location-transparent — confirmed during 3c-i's own research — so this works
  regardless of which member is the current leader).

## 4. Placement decision & cluster formation flow

`Riptide.Stream.Placement.ensure_started(stream_id, machine)` (called from
`StreamServer.start_link/1`, replacing today's direct `RaCluster.start_or_restart/2` call):

1. Check the local ETS cache. Hit → use the cached server IDs, done (no Raft round-trip at
   all).
2. Miss → call `Riptide.Placement.lookup/2`.
   - Returns a node list (a real prior assignment — either genuinely proposed or backfilled) →
     build server IDs from it (one `{uid, node}` id per replica node, shared deterministic uid
     across all of them — same pattern as the placement cluster's own multi-member config),
     cache, done.
   - Returns `nil` → ambiguous: this is either a genuinely new stream, or a stream that already
     existed before this phase shipped (created under the old always-single-node-local scheme,
     which never wrote anything to the placement store). Disambiguate:
     - Check whether **this node** already has on-disk Ra data for this stream's deterministic
       uid (a filesystem check under `RaCluster.data_dir()`; exact path verified against the
       pinned `:ra` directory layout during implementation). Present → pre-existing, single-node
       stream that lives here → `Riptide.Placement.assign(stream_id, [node()])` (backfill,
       matching exactly what already exists on disk).
     - Absent → genuinely new → `Riptide.Placement.propose_nodes(3)` +
       `Riptide.Placement.assign/3`.
3. Either way, form the cluster via `RaCluster`'s new generalized primitive using the resolved
   node list, then cache the resulting server IDs in ETS.

**Known, inherited limitation — not new to this phase:** the on-disk check in step 2 only
correctly discriminates "pre-existing stream" if that stream's requests keep landing on the same
node they always have. That's already an implicit assumption of today's pre-3c-ii code (there's
no real cross-node routing yet — that's explicitly 3c-iii's job). If a request for a pre-3c-ii
stream happens to first land on a *different* node after this phase ships, the backfill would
incorrectly treat it as new and could orphan the real data. This is a real, disclosed risk
inherited from the current "always assume local" limitation, not something this phase silently
introduces or fully closes — it's closed only once 3c-iii's real routing ships and consults
`Riptide.Placement` (including already-backfilled entries) for every request.

## 5. Local cache

An ETS table owned by `Riptide.Stream.Placement`, keyed by `stream_id`, valued with the resolved
list of `:ra.server_id()` tuples. Cached indefinitely for the BEAM node's lifetime — no
invalidation logic needed at all, since placement never changes once assigned (§2). A node
restart just starts with an empty table and repopulates lazily, one Raft round-trip per stream,
paid once per stream per node-lifetime (not per request).

## 6. Cluster formation error handling

Unlike 3c-i's placement-cluster bootstrap (boot-time, fire-and-forget, safe to retry forever), a
stream's cluster formation happens synchronously on a live client request's path (that stream's
first access on this node). Blocking indefinitely isn't acceptable here.

On `:ra.start_cluster/2` failure during formation: bounded retry — 3 attempts, 250ms fixed
backoff between attempts (most failures here are momentary, e.g. a proposed node transiently
unreachable or mid-restart; a short, small-N bound resolves those without holding a request open
for long). If still failing after 3 attempts, `Riptide.Stream.Placement.ensure_started/2` (and
therefore `StreamServer.start_link/1`) returns `{:error, _}` and the request fails rather than
hanging; the caller can retry the whole request later.

## 7. Testing

- **Unit tests** for `Riptide.Stream.Placement`'s decision logic (cache hit/miss, the
  backfill-vs-new discrimination) with injectable stand-ins for the on-disk check and
  `Riptide.Placement.lookup/assign`, mirroring the injectable-resolver pattern already
  established throughout 3c-i.
- **Local integration test**, extending 3c-i's proven `:peer`-based 3-real-node recipe
  (`test/riptide/placement_cluster_test.exs`): bootstrap the metadata cluster, create a
  genuinely new stream from one node, confirm its real N-member cluster forms across the actual
  assigned nodes and a write on one node is readable via `get_since` from a *different* node
  (real replication, not local memory). Separately exercise the backfill path: pre-seed on-disk
  Ra data for a stream on one node with no `Placement` entry, confirm `ensure_started/2`
  backfills to `[that node]` rather than proposing a fresh random set.
- **Live proof**, deployed against the existing `k8s/` StatefulSet manifests, same disposable
  proof-namespace pattern as 3c-i's Task 5: create a genuinely new stream via the live cluster,
  confirm real N-member replication end-to-end on GKE.

## 8. Out of scope

- HTTP/SSE/WebSocket routing to the correct replica node(s) — 3c-iii. `:ra`'s leader-redirect
  only means *sending a command to any replica* works correctly; it says nothing about which
  node a client's connection actually lands on.
- Steady-state `process_command`/`consistent_query` resilience (redirect/timeout handling)
  beyond the formation step — pre-existing, already-flagged gap, deliberately deferred (§2).
- Reassignment/rebalancing of an already-assigned stream's replicas — inherited from 3c-i,
  Phase 3d's job.
- Fixing the "wrong-node backfill" inherited limitation described in §4 — closed only by
  3c-iii's real routing.
- Any change to the fixed RF=3, or to the metadata cluster itself (unchanged from 3c-i).
