# Phase 3c-i — Placement Metadata Store — Design

**Status:** Approved 2026-08-25.

Sub-project 3 (Clustering / horizontal scale / HA) is decomposed into phases 3a-3d (see
`PROGRESS.md`, § "3. Clustering / horizontal scale / HA"). Phase 3c ("sharded per-stream
placement + real multi-member Ra clusters") is itself decomposed into three sequenced
sub-phases, each independently specced/planned/implemented:

- **3c-i — Placement metadata store** (this document): a small, dedicated `:ra` cluster
  durably recording `stream_id → [replica nodes]`, so a placement decision survives fleet
  growth. Fully foundational — nothing else in 3c can be built without it.
- **3c-ii — Real multi-member Ra cluster formation**: consumes 3c-i's stored assignment to
  actually start an N-member Ra cluster for a stream, replacing today's hardcoded
  single-member `initial_members: [server_id]`.
- **3c-iii — Request routing**: wires the HTTP/SSE/WebSocket layer to consult 3c-i's store
  and dispatch to the correct node(s), replacing today's "always assume local."

## 1. Context and motivation

Before any of 3c's actual clustering work could be designed, a foundational question had to
be resolved: how does a Riptide node — landing an HTTP/SSE/WebSocket request for a stream it
may not itself host — find out *which* nodes actually hold that stream's replicas? Extensive
research (RabbitMQ Khepri/quorum-queue placement, CockroachDB meta-ranges, TiKV's Placement
Driver, Kafka KRaft, the actual consistent-hashing/rendezvous-hashing literature, and this
project's own `:ra` internals) converged on two findings that shape this whole design:

1. **No pure function of current fleet membership can answer this question correctly once
   the fleet has grown since a stream was placed.** This isn't a hunch — it's confirmed
   against the actual consistent-hashing literature (Karger et al.'s original paper, Jump
   Consistent Hash, AnchorHash): every scheme that claims to need "no persisted state"
   turns out to smuggle the equivalent of persisted placement history in some other form
   (e.g. a globally-agreed sequential node ID, itself a coordination problem). Every real
   production system that shards data — RabbitMQ (Khepri), Kafka (KRaft), Redpanda
   (`raft0`), TiDB (PD, which embeds etcd), CockroachDB (self-referential meta-ranges),
   MongoDB (config-server replica sets) — solves this with a small, dedicated,
   strongly-consistent metadata store, not a hash function, and none of them wait until
   they're large to adopt it.
2. **`:ra` server IDs are already location-transparent.** Confirmed directly against the
   pinned `:ra` 2.15.4 source (`ra_server_proc.erl`): `:ra.process_command/2` and
   `:ra.consistent_query/2` work identically whether the target `{name, node}` is local or
   remote, with `:ra` internally redirecting to the current leader if needed — plain
   `gen_statem:call`, no custom RPC wrapper required. This means "routing a request to the
   right node" is not a dispatch-mechanism problem at all; it reduces entirely to "how does
   any node learn the right `{name, node}` tuples in the first place" — which is exactly
   the problem this phase solves.

RabbitMQ's Khepri (a small `:ra`-based tree store, now RabbitMQ's default metadata store) is
the closest real precedent, and its own hot-path mechanism is directly informative: writes go
through Raft consensus, but rarely (only at declare-time); reads are served from a
locally-materialized cache, never a per-request consensus round-trip. Riptide's own version of
this pattern is deliberately narrower — a flat `stream_id → node list` map, not a general
hierarchical tree — and (per the operator's explicit choice) hand-rolled directly on `:ra`
rather than depending on the `khepri` library itself, which is pre-1.0 with acknowledged API
churn risk and more machinery (pattern-matching paths, transactions, triggers) than this
narrow need requires. Direct precedent for "hand-roll a small `:ra` state machine instead of
depending on Khepri" exists independently in the BEAM ecosystem (`ex_esdb`, `Ram`).

## 2. Scope

- Placement metadata store only: a durable, queryable `stream_id → [node()]` mapping.
- Metadata cluster membership is small and fixed (3 members), decoupled from total fleet
  size — not mirrored 1:1 with the whole fleet the way RabbitMQ's Khepri mirrors its whole
  broker cluster. Chosen specifically because Riptide's fleet is meant to keep growing (10+
  nodes and up), and a metadata Raft group that grows unbounded with total fleet size would
  become exactly the kind of bottleneck this phase exists to avoid.
- No local read-cache/projection layer — reads go via a direct `:ra` query per lookup.
  Already-confirmed cheap (`:ra` query latency measured in Phase 3b's own work at
  microseconds-to-low-single-digit-milliseconds on a LAN); caching is a future optimization
  only if it turns out to matter in practice, not designed here.
- No general N-of-fleet placement algorithm beyond a simple random-selection helper — the
  actual *use* of a placement decision (starting a real multi-member per-stream Ra cluster)
  is 3c-ii's job, not this phase's.
- No *deliberately designed* reconciliation of the metadata cluster's own membership after a
  member's identity drifts (e.g. after a pod restart under a new IP) — this was originally
  scoped as manual-only, matching Phase 3d's "manual grow/shrink first, deliberately deferring
  sophisticated auto-rebalancing" philosophy. **Correction, see §5:** this turns out to
  self-heal automatically anyway, as a side effect of mechanisms this phase and Phase 3b
  already ship — not because it was designed to.
- No reassignment/rebalancing of already-assigned streams, ever, in this design — placement
  is permanent once made, matching RabbitMQ's own explicit, deliberate precedent (their core
  team has repeatedly rejected automatic rebalancing, citing SLA/predictability concerns).
- No HTTP/SSE/WebSocket routing changes — that's 3c-iii.

## 3. State machine shape & module layout

New `Riptide.Placement` namespace, mirroring the existing `Riptide.Stream` pattern:

- `Riptide.Placement.PlacementMachine` — the `:ra_machine`, parallel to
  `Riptide.Stream.RaMachine`. State is a plain map: `%{stream_id() => [node()]}`.
- `Riptide.Placement` — the client API, parallel to `Riptide.Stream.StreamServer`.

`Riptide.RaCluster` remains the sole module that calls `:ra` directly (its own moduledoc's
standing invariant, maintained since sub-project 1) — it gains new functions for
multi-member cluster bootstrap (an `initial_members` list spanning several nodes, resolved
via DNS — see §5) rather than a second `:ra`-touching module being introduced.

Command: `{:assign, stream_id, proposed_nodes}`. Query: direct `Map.get(state, stream_id)`.

## 4. Placement decision & race-safety

`PlacementMachine.apply/3`'s `{:assign, stream_id, proposed_nodes}` clause is idempotent by
construction:

```elixir
def apply(_meta, {:assign, stream_id, proposed_nodes}, state) do
  case Map.fetch(state, stream_id) do
    {:ok, existing_nodes} ->
      {state, existing_nodes, []}

    :error ->
      new_state = Map.put(state, stream_id, proposed_nodes)
      {new_state, proposed_nodes, []}
  end
end
```

Since every command is serialized through Raft consensus, this makes concurrent creation
races safe for free: if two nodes concurrently propose different node lists for the same new
`stream_id`, whichever command lands first in the Raft log wins, and the losing caller simply
gets back the winning assignment instead of an error or a conflicting write. No separate
locking or coordination is needed beyond what `:ra` already provides.

`Riptide.Placement.propose_nodes/1` is a thin client-side helper for computing a candidate
list before proposing: replication factor hardcoded to `3` (matching this sub-project's
established assumption throughout), nodes chosen via `Enum.take(Enum.shuffle(Node.list() ++
[node()]), 3)` — deliberately simple, matching RabbitMQ's own "random, no cleverness"
placement precedent for quorum queues. Constraint-aware placement (AZ-awareness, load-aware
selection) is explicitly out of scope — RabbitMQ itself only began adding this in an
unreleased 2026 feature, years after quorum queues shipped with plain random placement.

## 5. Metadata cluster bootstrap

The metadata cluster always lives on 3 fixed StatefulSet ordinals — `riptide-0`, `riptide-1`,
`riptide-2` — a hardcoded convention, not something computed or discovered.

Each of those 3 pods, on boot, resolves all 3 ordinals' *current* Erlang node identities via
DNS through the existing headless Service (`riptide-N.riptide-headless.<namespace>.svc.cluster.local`
→ current pod IP → `riptide@<ip>`, mirroring exactly how `Cluster.Strategy.Kubernetes.DNS`
already resolves peers for `libcluster`), then attempts `:ra.start_cluster/2` with
`initial_members` naming all 3 resolved identities. This resolution step is written as an
injectable function (not hardcoded to real DNS calls) specifically so local tests can
substitute a stub — see §6.

Bootstrap is retried, not one-shot: StatefulSet pods start ordinally by default (pod N+1
doesn't start until pod N is Ready), so early bootstrap attempts on `riptide-0` will
legitimately fail while `riptide-1`/`riptide-2` aren't yet reachable. `:ra.start_cluster/2`
itself already tolerates partial member availability (confirmed against the pinned `:ra`
source: it succeeds once a majority — 2 of 3 — are reachable), so the retry only needs to
keep calling it until that quorum threshold is met.

**Correction (Phase 3d-i HA-proof spike, 2026-08-25):** the paragraph above, as originally
written, was wrong. Post-restart identity drift (one of the 3 ordinals restarts under a new
IP, having lost real quorum first) turns out to be reconciled automatically, with zero data
loss, by mechanisms *already present* in this phase and Phase 3b — no manual operator action
or Phase 3d tooling required. Confirmed via a live GKE spike (kill 2-of-3 placement-cluster
pods, observe recovery) and reproduced/root-caused via a controlled `:peer`-based test plus
direct `:ra`/`ra_server` source reading:

- `RaCluster.data_dir/0`'s directory scheme is keyed by Kubernetes `HOSTNAME` (the stable
  StatefulSet pod name, e.g. `riptide-0`), not by `node()`/pod IP — so a restarted pod, even
  under a brand-new IP (and therefore a brand-new `node()` identity), recovers its own prior
  on-disk `:ra` data via the same PVC mount path.
- `ra_server:init/1`'s cluster-membership recovery branches on whether a snapshot exists: with
  no snapshot, it trusts the *freshly passed* `initial_members` config (the restarted pod's
  new identity); with a snapshot, it trusts the snapshot's own recorded membership instead.
- `PlacementMachine.apply/3` never emits a `{:release_cursor, ...}` effect, so the placement
  cluster itself never snapshots — meaning the first branch above always applies today, and a
  freshly-restarted member's `ensure_placement_cluster_started/0` boot-time retry loop
  (already shipped, originally written only to handle StatefulSet ordinal startup ordering)
  ends up reconciling membership to the new identity as a side effect, for free.

This is a **real but load-bearing structural assumption, not a coincidence**: it holds only as
long as the placement cluster never snapshots. If `PlacementMachine` ever gains a
`release_cursor` effect (e.g. for compaction/performance), this self-healing property would
silently stop holding. A regression test (`test/riptide/placement_snapshot_recovery_test.exs`)
exists specifically as a tripwire for that case — see its own moduledoc for the full mechanism
and citations. The exact mechanism by which the *fresh* replacement peers' local view
reconciles with the surviving member's committed log (rather than, e.g., forming an
independent parallel cluster) is empirically confirmed and consistent with the above, though
not proven exhaustively for every possible interleaving.

## 6. Testing

- **Unit tests** for `PlacementMachine.apply/3`'s pure state-machine logic (a plain map, no
  real `:ra` involved) — the idempotent-assign/race-safety behavior, mirroring how
  `Riptide.Stream.RaMachine`'s own tests work.
- **Local integration test**, using OTP 25's `:peer` module (the same verified recipe from
  Phase 3b's own multi-node connectivity test) to spawn 3 real, separate Erlang nodes,
  substituting the injectable ordinal-resolution function (§5) with a stub that maps
  directly to the test's own `:peer`-spawned node names — proving the *core* multi-member
  bootstrap, `assign`, and `lookup` logic works for real, without needing real Kubernetes
  DNS to exercise it.
- **Live proof**, deployed against the existing `k8s/` StatefulSet manifests from Phase 3b
  (no new manifests needed — the metadata cluster is application-level logic running inside
  the same pods, not a separate deployment) — confirms the real DNS-resolution bootstrap
  path specifically, the one thing the local test's stub can't cover.

## 7. Out of scope

- Local read-cache/projection layer — see §2.
- General N-of-fleet placement algorithm beyond the simple random-selection helper — see §4.
- Automatic reconciliation of the metadata cluster's own membership — see §5, Phase 3d.
- Reassignment/rebalancing of already-assigned streams — see §2.
- Actual per-stream multi-member Ra cluster formation that *consumes* a placement
  assignment — Phase 3c-ii.
- HTTP/SSE/WebSocket routing wiring — Phase 3c-iii.
