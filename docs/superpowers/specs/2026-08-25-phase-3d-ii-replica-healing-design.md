# Phase 3d-ii — Automatic Stream Replica Healing — Design

**Status:** Approved 2026-08-25.

Sub-project 3 (Clustering / horizontal scale / HA) phasing and prior context:
`docs/superpowers/specs/2026-08-25-phase-3c-i-placement-metadata-design.md`,
`docs/superpowers/specs/2026-08-25-phase-3c-ii-multi-member-ra-clusters-design.md`,
`docs/superpowers/specs/2026-08-25-phase-3c-iii-request-routing-design.md`. This phase follows
directly from the Phase 3d-i HA-proof spike (documented in the 3c-i design spec's §5 correction
and `PROGRESS.md`).

## 1. Context & motivation

Phase 3d-i's live GKE spike investigated what happens when nodes are force-killed. One of its
three findings — the placement metadata cluster's own membership self-healing automatically
after quorum loss — turned out to be a solved problem, not something this phase needs to build.
But investigating it surfaced a sharper, still-fully-open gap: **a stream's own replica set has
no equivalent self-healing, and no tooling exists to repair it either.**

The placement cluster self-heals because its 3 members are addressed by re-resolvable ordinal
names (`"riptide-0"` → whatever node currently answers to that hostname) — a restarted pod's
fresh identity is picked up automatically the next time cluster formation is attempted. A
stream's replica assignment (`Riptide.Placement.lookup/1`) is different: it's a **frozen list of
specific `node()` atoms**, fixed permanently at assignment time (Phase 3c-i's own
permanent-once-assigned invariant). There is no ordinal-style re-resolution for it. Worse, stream
cluster formation is purely *reactive* — triggered only when a client request for that specific
stream lands on `Riptide.Stream.StreamSupervisor.ensure_ready/1` — and `resolve_nodes/1` checks
`node() in nodes` against that frozen list, so a freshly-restarted node's new identity will never
match anything in it. The system doesn't just fail to repair the drift; it never even recognizes
that the restarted node *should* be considered for reclaiming that slot.

This isn't a rare failure mode. `node()` identity is IP-based (Phase 3b design), and pod IPs are
not stable across any restart — routine rolling deploys included, not just crashes. Every restart
of every pod hosting a stream replica is, structurally, identity drift. Manual/on-demand operator
tooling for something this frequent doesn't scale operationally — an operator or script would
need to babysit every single pod restart across the fleet. This phase is scoped instead as a
**fully automatic background self-healing process**: detect a stream with a dead replica, pick a
live replacement, repair it — zero operator or human involvement in the steady-state case. This
is a deliberate reversal of the sub-project's earlier "manual grow/shrink first" framing
(originally modeled on RabbitMQ's manual-first precedent) for this specific piece; that framing
fit the placement cluster's own membership question, which turned out not to need tooling at all,
better than it fits a problem this operationally frequent.

## 2. Scope

- Detecting a stream with exactly one dead replica (of its fixed RF=3 members) and automatically
  replacing it with a live fleet node — no operator action required in the steady-state case.
- The full repair chain: joining the replacement into the stream's real `:ra` cluster, evicting
  the dead member, updating the stream's durable placement assignment, and invalidating any
  node's stale in-memory cache of that assignment.
- Single-writer safety across the 3 placement ordinals (which run this process) via the placement
  cluster's own existing Raft leader election — no new locking/coordination mechanism.

## 3. Out of scope

- **Multi-member (quorum-loss) stream recovery** — a stream with 2-of-3 members dead has already
  lost quorum; `:ra.add_member`/`:ra.remove_member` require consensus to commit, so they simply
  fail/timeout harmlessly against such a cluster rather than making things worse. This is
  self-limiting by the underlying primitives, not special-cased logic here. Genuine multi-member
  loss stays separate, rarer, manual disaster-recovery territory — not designed in this phase.
- **Deliberate replication-factor changes** (e.g. RF 3 → 5) — this design only replaces a dead
  member 1-for-1; it never changes how many replicas a stream has.
- **Proactive node decommissioning/evacuation** (moving replicas off a node ahead of a planned
  removal) — this design is reactive (repairs after a node is already gone), not predictive.
- Any change to the placement cluster's own membership handling — solved in 3d-i.

## 4. Architecture

A new `Riptide.Stream.ReplicaHealer` `GenServer`, added to `Riptide.Application`'s existing
`placement_bootstrap_children/0` list alongside `ensure_placement_cluster_started/0` — so it only
runs on the 3 fixed placement ordinals, reusing the existing gating mechanism rather than
inventing a new "which nodes run this" decision.

On a `:timer.send_interval/2` tick (default 30s, configurable via application env), it:

1. Checks whether `node()` is the placement cluster's *current* Raft leader (via
   `:ra.members/1` against `RaCluster.placement_server_id/1,2` — the reply already includes the
   current leader). If not, no-ops until the next tick.
2. If leader: calls `Riptide.Placement.list_all/1` (new — see §5) to enumerate every known
   stream's assignment, and checks each member's real liveness (§6).
3. For any stream with exactly one dead member, performs the repair (§7).

Only the leadership check plus one cheap read runs on all 3 ordinals every tick; only the actual
leader ever executes a repair, so at most one repair attempt per stream happens fleet-wide at a
time — for free, from Raft's own leader election, no new coordination primitive needed.

## 5. Placement metadata additions

Two additions to `Riptide.Placement`/`Riptide.Placement.PlacementMachine`, both following the
existing idempotent-by-construction pattern `:assign` already uses (Phase 3c-i §4):

- **`PlacementMachine.list/1`** (a query function, like the existing `get/2`) returns the full
  `%{stream_id() => [node()]}` state so the healer can enumerate every stream without needing a
  stream_id in hand first. Exposed as `Riptide.Placement.list_all/1`, using the same
  ordinal-fallback addressing `assign/2,3` and `lookup/1,2` already use (Phase 3d-i fix 2).
- **New command `{:replace_member, stream_id, dead_node, new_node}`**, handled by
  `PlacementMachine.apply/3`: if `stream_id`'s stored nodes still contain `dead_node`, replace it
  with `new_node` and return the updated list; if `dead_node` is no longer present (e.g. a
  different placement-cluster leader, from a prior Raft term, already won this exact repair),
  it's a no-op that returns the current list unchanged — the same idempotent race-safety shape
  `:assign` already has for concurrent-proposal races. Exposed as
  `Riptide.Placement.replace_member/3`.

## 6. Detecting a dead replica

For each `{stream_id, nodes}` from `list_all/1`, the healer computes that stream's server ids
(`RaCluster.uid_for(stream_id)` combined with each node) and checks liveness the same way Phase
3d-i's fix 1 already does for `RaCluster.start_or_join_replicated/3`'s own `NotStarted` handling:
a local `Process.whereis/1` check for `node() == node()`, an `:erpc.call/4` to the remote node's
own `RaCluster.server_alive?/1` otherwise. An unreachable node is always treated as not-alive,
never assumed fine — the same conservative default already established there.

Replacement selection reuses `Riptide.Placement.propose_nodes/2`'s existing logic: candidates are
live fleet nodes (`Node.list()`) not already among the stream's surviving members, one chosen at
random via the existing `select_nodes/2`. If no live candidate exists (a saturated or emptied
fleet), the repair is skipped this tick and re-attempted next tick — not treated as an error,
just "nothing to do yet."

## 7. Repair execution

Given a stream with dead member `D` and chosen replacement `R`, addressed against the stream's
own `:ra` cluster (a surviving member's server id, entirely separate from the placement cluster):

1. `:ra.start_server/2` on `R`'s node, using the same config shape
   `RaCluster.start_or_join_replicated/3` already builds (`uid`, `cluster_name`,
   `log_init_args`) — but as a server *joining* an existing cluster, not forming a fresh one.
   Brings up `R`'s local Ra server so it's ready to receive the cluster's replicated log.
2. `:ra.add_member(survivor_id, new_id)` — registers `R` as a cluster member; it begins catching
   up via ordinary Raft log replication.
3. `:ra.remove_member(survivor_id, dead_id)` — evicts `D` from the cluster's membership.
4. `Riptide.Placement.replace_member(stream_id, D, R)` — updates the durable metadata so future
   lookups (and any node's future cache population) return the corrected node list.
5. `Phoenix.PubSub.broadcast(Riptide.PubSub, "stream_placement_changed", {stream_id, new_nodes})`
   — `Riptide.Stream.Placement`'s `GenServer` subscribes to this topic on init and evicts (or
   overwrites) that `stream_id`'s ETS cache entry on receipt, so no node keeps routing to `D`
   indefinitely. This is a new responsibility for that module; its own permanent-once-assigned
   caching invariant (Phase 3c-ii's moduledoc) is superseded by this phase for the specific case
   of an operator-invisible automatic repair — the *value* still only ever changes via this one
   controlled path, never arbitrarily.

The exact `:ra` call shapes for steps 1-2 (join-an-existing-cluster, as opposed to
`start_or_join_replicated/3`'s form-a-fresh-cluster case) get verified against the pinned `:ra`
source during implementation planning, the same way every other `RaCluster` primitive in this
project has been.

## 8. Safety & error handling

- **Only single-dead-member streams are auto-repaired** (§3) — self-limiting via the underlying
  `:ra` consensus requirement, not special-cased logic.
- **No explicit flapping/debounce protection beyond the sweep interval itself.** A node that
  reconnects before the next tick is simply observed as alive again and never touched. Simpler
  than tracking "seen dead N times" state; revisit only if real flapping churn shows up in
  practice.
- **Partial-failure recovery is "try again next tick."** If a repair fails partway (e.g.
  `add_member` succeeds but the metadata update doesn't land), the underlying `:ra` state hasn't
  reached the fully-repaired end state, so the next sweep re-detects the same dead member and
  retries the whole sequence — no separate retry/rollback logic inside the healer.
- **A lost PubSub invalidation degrades, not breaks.** A node that misses the broadcast keeps a
  stale cache entry with 2 correct members and 1 dead one; `:ra` operations still succeed via the
  live members (a single reachable member plus leader-redirect is enough), just with one extra
  doomed RPC attempt possible until that node's cache is otherwise refreshed.
- **Every repair action is logged** (stream_id, dead node, chosen replacement) — the point is
  that an operator doesn't need to *act*, but they should still be able to see what happened
  after the fact.

## 9. Testing

- **Unit tests** for `PlacementMachine`'s new `list/1` query and `{:replace_member, ...}` command
  (pure state-machine logic, no real `:ra`), mirroring the existing `:assign` tests.
- **Unit tests** for replacement-node selection, parallel to `propose_nodes/2`'s own tests.
- **Real multi-node integration test**, using the established `:peer`-based pattern from
  3c-ii/3c-iii/3d-i: form a real 3-node stream cluster, kill one member for real, invoke the
  healer's sweep logic directly (not waiting on the timer), and confirm the dead member is
  evicted, a live replacement joins, `Riptide.Placement.lookup/1` reflects the new node set, and
  the stream's data is still fully readable/writable afterward with no loss.
- **Leadership-gating test** confirming only the placement cluster's actual current leader
  performs a repair when multiple ordinals tick concurrently, mirroring the existing
  redundant-call self-correction tests for `attempt_start_placement_cluster/1`/
  `start_or_join_replicated/3`.
