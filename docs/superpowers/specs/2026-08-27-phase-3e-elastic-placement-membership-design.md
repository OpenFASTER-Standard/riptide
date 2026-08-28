# Phase 3e — Elastic Placement-Cluster Membership

## Context & motivation

Riptide's placement/metadata cluster — a small, dedicated `:ra` (Raft) group whose entire job is
answering "which real nodes currently hold stream X's replicas" (plus, since Phase 4c, co-located
auth-policy and repair-claim bookkeeping) — has had its membership hardcoded since Phase 3c-i to
the literal 3 strings `"riptide-0"`, `"riptide-1"`, `"riptide-2"` (`Riptide.RaCluster.
placement_ordinals/0`). Every node whose `HOSTNAME` env var doesn't match one of those exact
strings never attempts to host a placement-cluster member; every `Riptide.Placement` client call
tries only those 3 names, in that fixed order, before giving up.

This was a deliberate, reasoned choice at the time — an unbounded metadata Raft group that grows
1:1 with total fleet size becomes a consensus bottleneck, the same reason etcd, Kafka KRaft, and
CockroachDB's meta-ranges all keep their control-plane consensus group small and decoupled from
total node count (`2026-08-25-phase-3c-i-placement-metadata-design.md` §2). That reasoning still
holds and this phase does not change it: the placement cluster should stay small (an odd number,
typically 3 or 5), independent of total fleet size.

What's actually missing is the ability to *change* which specific nodes make up that small group,
live, without a code change or full redeploy — and to recover automatically when one is
*permanently* lost, not just transiently restarted. Every prior spec in this lineage (3c-i §5's
correction, informed by the 3d-i HA-proof spike) only ever solved *identity drift* — the same
named slot (`riptide-1`) restarting under a new IP and correctly rejoining. Permanently replacing
a dead ordinal with a *different* identity, or resizing the group from 3 to 5, was never designed,
and isn't possible today without editing `@placement_ordinals` and redeploying every node.

Separately, and worth stating plainly since it came up directly: **almost everything else in
Riptide already handles an arbitrary, elastic node count.** General fleet connectivity
(`libcluster` + Kubernetes DNS polling) already discovers however many pods exist, with zero
hardcoding. Per-stream replica selection (`Riptide.Placement.propose_nodes/2`) already draws from
`Node.list()` — the whole connected fleet. `Riptide.Stream.ReplicaHealer`'s replacement-candidate
selection already does the same. A real 5-pod GKE test (documented in `PROGRESS.md`) already
proved a pod outside the 3 fixed ordinals fully serving requests. The placement cluster's own
membership is the one place this doesn't hold, and it's what this phase fixes.

## Scope

- Remove `@placement_ordinals`'s hardcoded literal and every direct dependent (`Riptide.
  Application`'s `HOSTNAME`-matching boot gate, `Riptide.Placement`'s fixed-3-name client
  fallback).
- A discovery mechanism for "who are the current placement-cluster members" that needs no
  hardcoded names: a broadcast-maintained cache with a self-healing fleet-probe fallback.
- A self-forming genesis protocol: the very first placement cluster on a fresh deployment forms
  automatically, with no manual bootstrap step, and no risk of two nodes racing to form two
  independent clusters under normal (non-partitioned) startup.
- A reconciliation controller that continuously keeps live membership at a configured target
  size: joins when under target, removes a confirmed-dead member (backfilled by the same join
  path), and shrinks when an operator lowers the target.
- Graceful drain: a node that's a placement-cluster member proactively removes itself on shutdown
  signal, rather than waiting for the reconciliation controller to notice it's gone.
- `RIPTIDE_SINGLE_NODE` (added earlier this session as a stopgap for the Fly.io single-node
  deployment) is **removed** — a single-node deployment becomes the natural degenerate case of
  this design with target size 1, needing no special-casing.
- `config/dev.exs`'s and `config/test.exs`'s `ordinal_resolver` overrides are **removed** along
  with the `ordinal_resolver`/`default_ordinal_resolver`/`dns_ordinal_resolver` concept entirely —
  there's no longer a symbolic "ordinal" to resolve to a node; node identity is just `node()`
  directly, everywhere, in every environment.

## Out of scope

- **Migration of an existing deployment.** Confirmed with the operator: no existing deployment of
  this system exists anywhere. This phase makes a clean, breaking change to the placement
  cluster's addressing scheme with no upgrade path, no dual-read-old-and-new-scheme period, and no
  deprecation window.
- **Auto-scaling the target size based on fleet size.** The target size is an explicit,
  operator-set configuration value (default 3). This phase does not add logic that changes it
  automatically as the fleet grows or shrinks — that would reintroduce exactly the "metadata
  cluster grows unbounded with fleet size" problem Phase 3c-i correctly avoided.
- **Per-stream replication factor changes.** `@replication_factor 3` (in `Riptide.Placement` and
  `Riptide.Stream.Placement`) is a separate, already-decoupled-from-placement-ordinals constant.
  Making it configurable is a reasonable future improvement but isn't part of this phase.
- **Graceful drain for stream replicas.** The "include graceful drain" decision covers the
  placement cluster's own membership specifically. Extending the same proactive-handoff idea to a
  node's stream replicas (today handled reactively by `ReplicaHealer`) is a natural follow-up but
  is a larger, separately-scoped change (it needs to enumerate and hand off potentially many
  streams within a shutdown grace period, not one membership slot) — noted here so it isn't lost,
  not built now.
- **Network-partition-proof genesis.** As discussed and accepted below, genesis under a
  partitioned startup has a residual (bounded, documented) risk of forming two independent
  clusters. Solving this fully (e.g., via an external lock service) is not undertaken here.

## Current architecture (for reference)

Two conceptually distinct tiers, confirmed by direct code audit:

1. **The placement/metadata cluster** — exactly one `:ra` group, name `:riptide_placement`,
   membership currently fixed to the 3 ordinals. Stores `%{stream_id => [node()]}` assignments,
   auth policies, and repair-claim fencing state (`Riptide.Placement.PlacementMachine`). Every
   `Riptide.Placement` client call (`assign/2,3`, `lookup/1,2`, `list_all/1`, `replace_member/3,4`,
   `claim_repair/2,3`, `release_repair/1,2`, `add_policy/3,4`, `list_policies/2,3`,
   `claim_tenant_if_unclaimed/2,3`) addresses this cluster via `with_ordinal_fallback/2`, which
   today tries `RaCluster.placement_ordinals()`'s 3 fixed names in order.
2. **One `:ra` group per stream** — arbitrary membership drawn from `Node.list()`, RF=3 by
   convention, entirely independent of the placement ordinals. Unaffected by this phase.

`Riptide.Application.placement_bootstrap_children/0` is the sole gate deciding which nodes attempt
to host tier-1 membership: `if System.get_env("HOSTNAME") in Riptide.RaCluster.
placement_ordinals()`. This phase replaces that static gate with the reconciliation controller
described below.

`RaCluster.replace_member/5` (built for `ReplicaHealer`'s per-stream repair) already implements
the correct, safe, tested add-then-remove sequence for changing a `:ra` group's membership live:
add the new member to the existing configuration first (via `:ra.add_member/2`), start the joining
server, then remove the dead member (via `:ra.remove_member/2`). This phase generalizes that same
sequence — already proven — to the placement cluster's own membership. `:ra`'s own README
("Dynamically Changing Cluster Membership") confirms a cluster can start as a single node and grow
one member at a time via `:ra.add_member/2`, safely by design ("only one cluster membership change
at a time is allowed").

## Discovery: finding current placement-cluster membership without hardcoded names

Two layers, in order:

1. **Fast path — broadcast + local cache.** A new `Phoenix.PubSub` topic,
   `"riptide:placement_membership"`, mirroring the existing `stream_placement_changed` pattern
   already used for per-stream cache invalidation. Whenever placement-cluster membership changes
   (a join lands, a member is removed), the node that performed the change broadcasts the new
   member list. Every node subscribes and keeps the latest broadcast in a local ETS table
   (`Riptide.RaCluster.MembershipCache` or similar), used as the default answer for "who's
   currently a member" — no network round trip needed for the common case.

2. **Slow path — fleet-wide probe, the self-healing fallback.** If the cache is empty (fresh
   boot, before any broadcast has ever been received) or every cached member is unreachable
   (missed broadcast, long partition, or a fully cold restart of the whole fleet with no in-memory
   state anywhere), probe `Node.list()` — already fully populated by `libcluster`'s existing DNS
   polling, independent of this phase — asking each connected node, in parallel, whether it's a
   live placement-cluster member. A node answers this by calling `:ra.members({:riptide_placement,
   node()})` locally: if it has a live local member, this call succeeds and returns the *entire
   current membership* as understood by Raft consensus — self-describing and authoritative the
   moment you reach any single real member. The first node that answers wins; its answer is
   trusted (an already-caught-up Raft member's view of membership is a consensus fact, not a
   guess — same principle `RaCluster.remove_member/2`'s own `member_removed?/2` helper already
   relies on today).

Correctness never depends on the broadcast actually arriving — the fleet-wide probe always finds
the truth eventually, given enough connected fleet visibility. Broadcast is purely a latency
optimization to avoid probing the whole fleet on every single client call.

`Riptide.Placement.with_ordinal_fallback/2` is replaced by `with_current_members/2`, which uses
this two-layer discovery instead of iterating a fixed list.

## Genesis: forming the cluster for the first time

Every node's boot sequence checks **local disk first**, exactly as today: if `RIPTIDE_RA_DATA_DIR`
already has data for the `:riptide_placement` `:ra` system, this node is an existing member
restarting — it just starts its local Ra server and rejoins normally (`:ra`'s own log-based
recovery), completely unchanged from today's behavior. Genesis logic below only runs when there's
no local data.

For a genuinely fresh deployment (no node anywhere has local placement data — the common case is
"every node in the fleet," since there's never been a cluster yet):

1. Each such node first runs the discovery probe above. If it finds an existing live member
   (another node in the fleet won the genesis race microseconds earlier), it does *not* attempt
   genesis — it just falls through to the reconciliation controller's ordinary join path (below).
2. If discovery finds nothing anywhere, the node enters a short **settle window** (a bounded delay,
   configurable, defaulting to a few seconds) — the same tolerance today's `attempt_start_
   placement_cluster/1` retry loop already has for "the fleet is still converging" at boot.
3. After settling, the node computes the **same deterministic genesis member list** every other
   simultaneously-booting node would independently compute from the same inputs: sort the
   currently-connected fleet (`[node() | Node.list()]`) and take the first *target size* names,
   lexicographically. Because this is a pure function of the (converged) connected-node set, every
   node that ran the same computation at roughly the same time agrees on the same list — without
   any of them needing to have been told each other's identities in advance.
4. All nodes in that computed list redundantly attempt `:ra.start_cluster/2` with it, exactly as
   today's `attempt_start_placement_cluster/1` already does for the fixed 3-ordinal case — self-
   correcting via the same existing retry-and-recheck-liveness pattern when multiple nodes race to
   form the identical cluster concurrently. No code changes needed here beyond generalizing the
   member list from a literal to the computed one.

**Accepted, bounded risk:** if the fleet is genuinely network-partitioned *during* the settle
window, two disjoint subsets could each converge on their own local view of "the connected set,"
compute two different genesis lists, and form two independent placement clusters — a fundamental
bootstrap problem in any such system, not unique to this design (today's fixed-3 scheme has a
narrower version of the same risk: it requires all 3 fixed names to be mutually reachable at
bootstrap, which is also not partition-proof). Mitigated by a configurable settle timeout and by
operational discipline (a healthy platform like Kubernetes reliably converges pod-to-pod
connectivity within seconds under normal conditions); not solved outright. This is stated
explicitly rather than glossed over.

## Reconciliation controller (replaces the static `HOSTNAME` gate)

Runs on every node, in a new supervised process started unconditionally in `Riptide.Application`
(replacing `placement_bootstrap_children/0`'s conditional list). Two independent loops:

**Join loop (every non-member node, periodic, same cadence as today's bootstrap retry):**
- Discover current membership and its size.
- If size < target size and this node isn't already a member: call `:ra.add_member(existing_
  members, self_id)` directly against a discovered existing member (Ra's `add_member` is a
  command sent *to* an existing member — the caller doesn't need to already be one), then start
  its own local Ra server per `RaCluster.replace_member/5`'s already-proven ordering (add to
  config first, then start the joining server).
- Naturally idempotent and race-safe: if multiple non-member nodes race to fill the same slot,
  Ra's own "one membership change at a time" rule serializes them; the loser's next periodic check
  observes the target has already been reached and stops trying.
- No leader/single-writer gating needed here — a non-member node has no well-defined "am I the
  leader" answer for a group it isn't in yet, and doesn't need one for this action.

**Repair/shrink loop (leader-only, single-writer, reusing `RaCluster.placement_leader?/0` exactly
as `ReplicaHealer` already does today):**
- Only the current placement-cluster Raft leader runs this loop's mutating actions — the same
  single-writer safety property `ReplicaHealer` already relies on for per-stream repair.
- If a current member is confirmed dead (`RaCluster.member_alive?/1`, unchanged): remove it via
  `:ra.remove_member/2`. Backfill (if this drops size below target) is *not* this loop's job — it
  falls out naturally from the ambient join loop running on every non-member node, which will
  notice the drop and fill it.
- If current size > target size (an operator just lowered the configured target): remove one
  member — deterministically chosen (e.g., the highest-sorted node name, for a stable, boring
  choice) — via the same `:ra.remove_member/2` path. One change per sweep, same as repair, letting
  Ra's own membership-change serialization naturally throttle a multi-step shrink (5→3 takes two
  sweeps, removing one member each time) rather than attempting a single unsafe multi-member
  change.

## Graceful drain

On receiving a shutdown signal (wired via the OTP application's `prep_stop`/`stop` callback,
mirroring how `rel/env.sh.eex` already hooks into the release's lifecycle), a node that is
currently a placement-cluster member calls `:ra.remove_member/2` for itself against the other
current members, *before* the BEAM process actually exits — handing off cleanly rather than
leaving the repair/shrink loop to notice it's gone after the fact. This eliminates the reactive-repair window
entirely for planned removals (a `kubectl scale down`, a rolling upgrade) — the only remaining
reactive case is a genuinely unplanned/crashed node, which the repair loop above still handles.

If the shutdown signal arrives while this node is mid-membership-change (e.g., it's the one
executing a repair), the drain still runs after: `:ra.remove_member/2` failing with `{:error,
:not_member}` when the node was already removed by its own now-superseded action is handled by the
exact same disambiguation `RaCluster.remove_member/2`'s existing `member_removed?/2` helper already
performs (check the survivors' own view of membership rather than trusting the ambiguous error
atom) — reused as-is, not reimplemented.

## Configuration surface

One new setting, replacing all `HOSTNAME`-allowlist and `ordinal_resolver` configuration entirely:

- `RIPTIDE_PLACEMENT_TARGET_SIZE` (env var, `config/runtime.exs`), default `3`. Validated at boot
  to be a positive odd integer (even sizes don't improve fault tolerance over the next-lower odd
  size and introduce tie-vote risk — standard Raft/Paxos guidance) — an even value fails fast with
  a clear error rather than silently running in production with degraded majority semantics.
- A single-node deployment (Fly.io, plain `docker run`, `docker-compose`) is now just
  `RIPTIDE_PLACEMENT_TARGET_SIZE=1` (or the default, changed to `1` for those specific deployment
  configs) — genesis forms a 1-node placement cluster automatically, with no `HOSTNAME` matching,
  no `RIPTIDE_SINGLE_NODE`, no `ordinal_resolver` override. `fly.toml`'s `HOSTNAME=riptide-0` and
  `RIPTIDE_SINGLE_NODE=true` env entries are removed and replaced with
  `RIPTIDE_PLACEMENT_TARGET_SIZE=1`.
- `config/dev.exs` and `config/test.exs` need no placement-specific override at all after this
  phase — local dev and the test suite get the same self-forming genesis as any other deployment,
  naturally producing a 1-node (dev) or however-many-`:peer`-nodes-are-started (test) placement
  cluster with zero special-casing.

## Testing strategy

Existing tests requiring rewrite (not deletion of intent — the scenarios they cover remain
relevant, just against the new mechanism):

- `test/riptide/ra_cluster_test.exs`'s `placement_ordinals() == [...]` assertion — the function is
  removed; replaced with tests of the new discovery/genesis functions directly.
- Every `:peer`-based multi-node test that hardcodes `"riptide-0"/"riptide-1"/"riptide-2"` literal
  names to set up a placement cluster (`test/riptide/placement_cluster_test.exs`, `test/riptide/
  stream/replica_healer_cluster_test.exs`, `test/riptide/stream/replica_healer_leadership_gate_
  test.exs`, `test/riptide/stream/stream_placement_cluster_test.exs`, `test/riptide/ra_cluster_
  data_dir_test.exs`, `test/riptide/placement_snapshot_recovery_test.exs`, `test/riptide_web/
  routing_cluster_test.exs`) — setup changes from "directly call `attempt_start_placement_cluster`
  with the literal 3-name list" to "start N `:peer` nodes and let them run genesis themselves,
  then assert convergence" (a small, mechanical, per-test-file change; assertions about behavior
  *after* the cluster exists are largely unaffected).

New tests needed:

- Genesis convergence: N nodes booting roughly simultaneously with no prior state converge on
  exactly one placement cluster of the configured target size.
- Grow: starting at target size 3, raising target to 5 with 2 additional live nodes present
  results in a 5-member cluster within a bounded number of sweeps, with no manual action.
- Shrink: starting at target size 5, lowering target to 3 results in exactly 2 members removed
  (one per sweep), converging to 3.
- Dead-member replacement: kill a member outright (not a graceful shutdown); confirm the repair
  loop removes it and the ambient join loop backfills a replacement, converging back to target
  size, with no data loss to the placement machine's own state (assignments, policies, repair
  claims all intact post-recovery — mirroring `placement_snapshot_recovery_test.exs`'s existing
  rigor).
- Graceful drain: send a shutdown signal to a member node; confirm it proactively leaves *before*
  the repair loop's sweep interval would have noticed, and that the ambient join loop backfills it
  without ever dropping below `target_size - 1` members observably.
- Discovery fallback: clear a node's local membership cache and disconnect it from PubSub delivery
  (simulating a missed broadcast); confirm the fleet-wide probe still correctly discovers current
  membership.
- Single-node degenerate case: `RIPTIDE_PLACEMENT_TARGET_SIZE=1` produces a working placement
  cluster with no `HOSTNAME` requirement at all, and `/health/ready` passes — directly replacing
  the manual verification this phase's motivating Fly.io work did by hand.
- Even-target-size validation: boot with `RIPTIDE_PLACEMENT_TARGET_SIZE=4` fails fast with a clear
  error rather than starting degraded.
