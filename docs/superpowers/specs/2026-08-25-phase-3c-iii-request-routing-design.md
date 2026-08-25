# Phase 3c-iii — Request Routing — Design

**Status:** Approved 2026-08-25.

Sub-project 3 (Clustering / horizontal scale / HA) decomposes Phase 3c ("sharded per-stream
placement + real multi-member Ra clusters") into three sequenced sub-phases (see `PROGRESS.md`,
§ "3. Clustering / horizontal scale / HA"):

- **3c-i — Placement metadata store** (shipped 2026-08-25): a small, dedicated `:ra` cluster
  durably recording `stream_id → [replica nodes]`.
- **3c-ii — Real multi-member Ra cluster formation** (shipped 2026-08-25): consumes 3c-i's
  stored assignment to actually start an N-member Ra cluster for a stream.
- **3c-iii — Request routing** (this document): wires the HTTP/SSE/WebSocket layer to consult
  3c-i's store and serve requests correctly regardless of which node they land on, replacing
  today's "always assume local."

## 1. Context and motivation

Today, all 3 request entry points (`RiptideWeb.LDP.ResourceController`, the SSE controller, the
WebSocket replication channel) call `Riptide.Stream.StreamSupervisor.get_or_start/1` and then
`Riptide.Stream.StreamServer.append/2`/`get_since/2` directly, implicitly assuming the node that
receives the request always hosts the stream. Since Phase 3c-ii shipped real multi-node
placement, this assumption is now false in general: a stream's 3 replicas are a subset of a
larger fleet, and nothing yet ensures a request actually lands on one of them.

Tracing the actual code answers the "how do we fix this" question directly, without needing an
HTTP-level proxy layer:

- **`:ra` command/query addressing is already location-transparent.** `Riptide.RaCluster.
  process_command/2` and `consistent_query/2` work identically whether the target `{name, node}`
  is local or remote — confirmed during Phase 3c-i's own research (`gen_statem:call`, no custom
  RPC wrapper). `StreamServer.append/2`/`get_since/2` only ever need `Riptide.Stream.Placement.
  server_ids!/1`'s cached list and a `RaCluster` call — never a local process.
- **`Phoenix.PubSub` broadcasts are already cluster-wide.** The `pg`-based adapter propagates a
  broadcast to every connected node's local subscribers (confirmed by this project's own
  `libcluster` setup since Phase 3b) — a client subscribed on a non-member node already receives
  live-tail events correctly regardless of which node performed the write.
- **The only thing that actually forces "must be a member node" today is `StreamServer.
  start_link/1`'s own contract** — it must return a local `pid` (`Process.whereis(name)`), which
  a non-member node genuinely cannot produce. Every real caller of `StreamSupervisor.
  get_or_start/1` already discards the returned pid (confirmed by reading all 3 controllers), so
  this contract is enforcing a constraint nothing actually needs.

There is a second, closely related gap: `Riptide.Stream.Placement.ensure_started/2` (Phase
3c-ii) always calls `RaCluster.start_or_join_replicated/3` when a stream already has a real
assignment — even when this node isn't one of the assigned replicas. Since this node was never
in the `:ra.start_cluster/2` config, that call is guaranteed to fail with
`{:error, :cluster_not_formed}`, even though the stream is completely healthy elsewhere. This is
the second half of what needs fixing.

## 2. Scope

- No HTTP-level proxy, redirect, or forwarding layer — routing reduces entirely to correctly
  resolving and remotely addressing a stream's real replica nodes, leaning on `:ra`'s and
  `Phoenix.PubSub`'s already-proven location transparency.
- `Riptide.Stream.Placement.ensure_started/2` gains a member/non-member branch (§4) so a
  non-member node resolving an existing assignment never attempts (and never needs) cluster
  formation.
- `Riptide.Stream.StreamSupervisor.get_or_start/1` is renamed to `ensure_ready/1` and its return
  contract changes from a pid to `:ok | {:error, term()}` (§3), matching what every real caller
  already does with it.
- `StreamServer.start_link/1` itself is unchanged — still a fully valid, fully tested function;
  it simply stops being the production request path.
- The 3 web entry points switch from `get_or_start/1` to `ensure_ready/1` and explicitly handle
  its `{:error, _}` case with a clean `503`, replacing today's implicit reliance on an unhandled
  `Placement.server_ids!/1` raise falling through to Phoenix's generic crash-to-500.
- No load/latency-aware replica preference, no new steady-state resilience beyond what 3c-ii
  already established, no placement-algorithm changes — all unchanged from 3c-i/3c-ii.

## 3. `StreamSupervisor.ensure_ready/1`

Replaces `get_or_start/1`. Calls `Riptide.Stream.Placement.ensure_started/2` directly — no
longer routes through `StreamServer.start_link/1` at all for the production path:

```elixir
@spec ensure_ready(String.t()) :: :ok | {:error, term()}
def ensure_ready(stream_id) do
  case Riptide.Stream.Placement.ensure_started(stream_id, {:module, Riptide.Stream.RaMachine, %{retention: :infinity}}) do
    {:ok, _server_ids} -> :ok
    {:error, _reason} = error -> error
  end
end
```

All 3 web entry points (`ResourceController`, the SSE controller, the WebSocket channel) replace
`StreamSupervisor.get_or_start(stream_id)` with `StreamSupervisor.ensure_ready(stream_id)` and
branch on the result — `:ok` proceeds exactly as today; `{:error, _}` responds `503` (HTTP) or
the channel/SSE-appropriate equivalent, instead of relying on an unhandled exception from
`Placement.server_ids!/1` to fall through to a generic crash response.

`StreamServer.start_link/1` is untouched — still valid, still covered by its own existing test
suite, just no longer called by any production code path.

## 4. `ensure_started/2`'s member/non-member branch

Current flow (Phase 3c-ii): on a cache miss, `Placement.lookup/1` → if `nil`, disambiguate
(backfill vs. genuinely new) → propose/backfill → `Placement.assign/3` → **always** call
`RaCluster.start_or_join_replicated/3` → cache.

New flow: once `Placement.lookup/1` returns a *real* node list (not `nil`), branch on whether
`node()` is among them:

- **This node is a replica** — unchanged: call `start_or_join_replicated/3` to (re)join/confirm,
  then cache the result.
- **This node is not a replica** — skip `start_or_join_replicated/3` entirely (nothing to form
  or join locally); build the server IDs directly as `Enum.map(nodes, &{String.to_atom(uid), &1})`
  and cache them.

The genuinely-new-stream path is unaffected: `Placement.propose_nodes/2` (Phase 3c-ii's own fix)
always puts the proposing/local node first, so a stream this node just proposed always includes
itself and always takes the "this node is a replica" branch.

## 5. Testing

- **Unit tests** for `Riptide.Stream.Placement`'s new member/non-member branch, using real
  `Placement.assign/lookup` calls (working since Phase 3c-ii's own test-infrastructure fix) and
  the existing injectable `formation_fun`/`sleep_fun` pattern.
- **`StreamSupervisor` tests** updated for the `get_or_start/1` → `ensure_ready/1` rename and its
  new `:ok | {:error, term()}` contract.
- **Controller error-mapping** tested as a small, directly-unit-testable helper function fed a
  fabricated `{:error, _}` result — not by forcing a genuine end-to-end failure through the whole
  request stack, which would need artificial dependency injection into Phoenix controllers for
  no real benefit.
- **Real multi-node integration test**, extending Phase 3c-ii's own `:peer`-based recipe: after a
  stream's cluster forms across 3 real peers, a 4th peer (deliberately not a replica) exercises
  the request path for that stream and confirms it works correctly via remote addressing, with
  no local process ever created on that 4th peer.
- **Live proof**, deployed against a StatefulSet with more pods than RF=3 (e.g. 4-5), so at least
  one pod is guaranteed non-member for some stream — confirms a request landing there succeeds.

## 6. Out of scope

- Load- or latency-aware replica preference — any replica works, matching `:ra`'s own
  redirect-to-leader handling; no ranking or proximity logic.
- Any HTTP-level proxy, redirect, or forwarding mechanism — explicitly ruled out in §1/§2.
- Any change to placement itself (RF=3, permanent-once-assigned) — unchanged from 3c-i/3c-ii.
- New handling for "all replicas simultaneously unreachable from this node" beyond the existing
  bounded-retry-then-`{:error, _}` behavior already established in 3c-ii — matches that phase's
  own already-deferred steady-state resilience scope.
- Any change to `StreamServer.start_link/1`'s own existing behavior or contract.
