# Phase 3c-ii: Real Multi-Member Ra Cluster Formation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every stream a real, multi-node Ra cluster (RF=3) driven by `Riptide.Placement`'s durable assignment store, replacing today's hardcoded single-member-always-local `Riptide.RaCluster.start_or_restart/2` call inside `StreamServer`.

**Architecture:** `Riptide.RaCluster` gains one new generalized primitive that forms/rejoins an N-member Ra cluster from an arbitrary node list (the same per-member-config + `:ra.start_cluster/2` pattern already proven by `attempt_start_placement_cluster/1`). A new `Riptide.Stream.Placement` module orchestrates the lookup/backfill/propose decision flow, forms the cluster via that primitive, and caches the resolved server IDs forever in a local ETS table (safe, since placement never changes once assigned). `Riptide.Stream.StreamServer` becomes a thin caller of the new module instead of `RaCluster` directly.

**Tech Stack:** Elixir/OTP, `:ra` (Erlang Raft, pinned `2.15.4`, vendored at `deps/ra/src/`), ExUnit, OTP 25's `:peer` module for real multi-node integration tests.

**Spec:** `docs/superpowers/specs/2026-08-25-phase-3c-ii-multi-member-ra-clusters-design.md`

## Global Constraints

- `Riptide.RaCluster` remains the sole module that calls `:ra` directly (standing invariant since sub-project 1).
- Genuinely new streams get RF=3; streams backfilled from before this phase shipped get RF=1 (matching what already exists on disk for them) — not a contradiction of the RF=3 default.
- A stream's cached server IDs are safe to hold indefinitely for the BEAM node's lifetime — no invalidation logic, ever, since placement is permanent once assigned.
- Cluster-formation bounded retry: exactly 3 attempts, 250ms fixed backoff between attempts, then surface `{:error, :cluster_not_formed}` to the caller.
- No HTTP/SSE/WebSocket routing changes (Phase 3c-iii's job).
- No change to steady-state `process_command/2`/`consistent_query/2` error handling beyond the formation step itself (pre-existing, already-flagged gap, deliberately deferred).
- No change to the fixed RF=3 constant or to the metadata cluster itself (unchanged from Phase 3c-i).

---

### Task 1: Test infrastructure — bootstrap a real placement cluster for the async test suite

**Files:**
- Modify: `test/test_helper.exs`
- Modify: `test/riptide/placement_test.exs`

**Interfaces:**
- Consumes: `Riptide.RaCluster.attempt_start_placement_cluster/1` (existing, from Phase 3c-i).
- Produces: a real, running (single-node-collapsed) placement metadata cluster for the entire `mix test` run — every later task's tests that call `Riptide.Placement.assign/2`/`lookup/2` for real depend on this.

Today, `Riptide.Application`'s placement-cluster boot-time bootstrap only runs on pods whose `HOSTNAME` matches one of the 3 fixed ordinals (`riptide-0`/`riptide-1`/`riptide-2`) — never true in local dev or CI. This means `Riptide.Placement.assign/2`/`lookup/2` have never been exercised for real in the regular async `mix test` suite (only in the separate `:peer`-based `placement_cluster_test.exs`, and only in Phase 3c-i's own `ra_cluster_test.exs` regression test, which calls `attempt_start_placement_cluster/1` directly). From this plan onward, `Riptide.Stream.Placement` will call `Riptide.Placement.assign/2`/`lookup/2` for real on every new stream in every `StreamServer` test — so the async suite needs a real, running metadata cluster from the start.

- [ ] **Step 1: Write a failing test proving `Placement.assign/lookup` don't work yet in the async suite**

Add to `test/riptide/placement_test.exs`:

```elixir
  describe "assign/2 and lookup/2 against the real metadata cluster" do
    test "a real assignment round-trips through the real placement cluster" do
      stream_id = "placement-roundtrip-" <> Uniq.UUID.uuid4()
      assigned = Placement.assign(stream_id, [node()])

      assert assigned == [node()]
      assert Placement.lookup(stream_id) == [node()]
    end
  end
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `mix test test/riptide/placement_test.exs --trace`
Expected: FAIL — the placement server_id (`{:riptide_placement, node()}`) was never started, so `RaCluster.process_command/2`/`consistent_query/2` raise (`Ra command failed`/`Ra consistent query failed`) rather than returning a value.

- [ ] **Step 3: Bootstrap a real placement cluster once for the whole test run**

Modify `test/test_helper.exs`:

```elixir
ExUnit.start()

# Riptide.Application's own placement-cluster bootstrap only runs on pods
# whose HOSTNAME matches one of the 3 fixed ordinals — never true here. A
# resolver that maps every ordinal to this same test node collapses all 3
# configs to the same real {:riptide_placement, node()} id, exactly the
# pattern already proven safe by ra_cluster_test.exs's own redundant-call
# regression test (Phase 3c-i) — this gives the whole async suite a real,
# running (single-node) placement cluster to assign/lookup against, so
# every test that goes through Riptide.Stream.Placement (Phase 3c-ii) can
# exercise real Placement.assign/2/lookup/2 calls, not just pure logic.
:ok = Riptide.RaCluster.attempt_start_placement_cluster(fn _ordinal -> node() end)
```

- [ ] **Step 4: Run the test again to verify it passes**

Run: `mix test test/riptide/placement_test.exs --trace`
Expected: PASS.

- [ ] **Step 5: Run the full suite to confirm nothing else broke**

Run: `mix test`
Expected: PASS, same pass count as before this change (no new failures — this only ADDS a working capability, it doesn't change any existing behavior).

- [ ] **Step 6: Commit**

```bash
git add test/test_helper.exs test/riptide/placement_test.exs
git commit -m "Bootstrap a real placement cluster for the async test suite"
```

---

### Task 2: `RaCluster.start_or_join_replicated/3` — generalized multi-member cluster formation

**Files:**
- Modify: `lib/riptide/ra_cluster.ex`
- Test: `test/riptide/ra_cluster_test.exs`

**Interfaces:**
- Consumes: nothing new — pure generalization of `attempt_start_placement_cluster/1`'s existing pattern (`:ra.start_cluster/2`, `server_alive?/1`, both already in this file).
- Produces: `Riptide.RaCluster.start_or_join_replicated(uid :: String.t(), member_nodes :: [node()], machine :: :ra_machine.machine()) :: {:ok, [:ra.server_id()]} | {:error, :cluster_not_formed}` — consumed by `Riptide.Stream.Placement` (Task 4).

- [ ] **Step 1: Write the failing tests**

Add to `test/riptide/ra_cluster_test.exs` (inside the existing `Riptide.RaClusterTest` module, alongside the other `describe` blocks):

```elixir
  describe "start_or_join_replicated/3" do
    test "forms a real cluster and returns one server_id per member_node" do
      uid = "sojr-" <> Uniq.UUID.uuid4()
      name = String.to_atom(uid)
      on_exit(fn -> :ra.force_delete_server(:default, {name, node()}) end)

      # A single real node repeated 3x collapses to one real member, exactly
      # the same "collapsed" pattern Phase 3c-i's own redundant-call
      # regression test already uses to exercise multi-member config-building
      # without needing real distinct nodes — real distinctness is proven
      # separately by the :peer-based integration test (Task 6).
      assert {:ok, server_ids} =
               RaCluster.start_or_join_replicated(uid, [node(), node(), node()], {:module, EchoMachine, %{}})

      assert length(server_ids) == 3
      assert Enum.uniq(server_ids) == [{name, node()}]

      pid = Process.whereis(name)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "self-corrects on a redundant call once the local member is already running" do
      uid = "sojr-redundant-" <> Uniq.UUID.uuid4()
      name = String.to_atom(uid)
      on_exit(fn -> :ra.force_delete_server(:default, {name, node()}) end)
      machine = {:module, EchoMachine, %{}}

      assert {:ok, first_ids} = RaCluster.start_or_join_replicated(uid, [node(), node()], machine)
      assert {:ok, second_ids} = RaCluster.start_or_join_replicated(uid, [node(), node()], machine)
      assert first_ids == second_ids
    end

    test "returns {:error, :cluster_not_formed} when this node isn't among member_nodes and they're unreachable" do
      uid = "sojr-unreachable-" <> Uniq.UUID.uuid4()
      machine = {:module, EchoMachine, %{}}

      assert RaCluster.start_or_join_replicated(uid, [:"nonexistent@nowhere"], machine) ==
               {:error, :cluster_not_formed}
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/riptide/ra_cluster_test.exs --trace`
Expected: FAIL with "function start_or_join_replicated/3 is undefined or private".

- [ ] **Step 3: Implement `start_or_join_replicated/3`**

Add to `lib/riptide/ra_cluster.ex`, near `attempt_start_placement_cluster/1` (which this generalizes):

```elixir
  # Generalizes `attempt_start_placement_cluster/1`'s per-member-config +
  # `:ra.start_cluster/2` pattern beyond the hardcoded 3 placement ordinals
  # to an arbitrary node list — used by `Riptide.Stream.Placement` (Phase
  # 3c-ii) to form a real, multi-node cluster for a single stream. Shares
  # `uid` across every member's config (each member's data still lives in a
  # distinct, non-colliding directory because it's nested under that node's
  # own HOSTNAME-scoped data_dir — see `data_dir/0`).
  #
  # Self-corrects the same false-failure case documented on
  # `attempt_start_placement_cluster/1`: a redundant call whose members
  # (including this node's own, if present) are already running also
  # reports `{:error, :cluster_not_formed}` from `:ra.start_cluster/2`
  # itself, since its `Started` list only counts servers *this call* newly
  # started, not servers merely alive. This rechecks local liveness before
  # treating that as a genuine failure — but only if this node is actually
  # one of `member_nodes`; if it isn't, the local liveness check is always
  # false, and the error correctly propagates (this node has no way to know
  # whether the *actual* members formed successfully elsewhere).
  @spec start_or_join_replicated(String.t(), [node()], :ra_machine.machine()) ::
          {:ok, [:ra.server_id()]} | {:error, :cluster_not_formed}
  def start_or_join_replicated(uid, member_nodes, machine) do
    ensure_system_started()
    name = String.to_atom(uid)
    member_ids = Enum.map(member_nodes, &{name, &1})

    configs =
      Enum.map(member_ids, fn id ->
        %{
          id: id,
          uid: uid,
          cluster_name: uid <> "_cluster",
          log_init_args: %{uid: uid},
          initial_members: member_ids,
          machine: machine
        }
      end)

    case :ra.start_cluster(@system, configs) do
      {:ok, _started, _not_started} ->
        {:ok, member_ids}

      {:error, :cluster_not_formed} ->
        if server_alive?(name) do
          {:ok, member_ids}
        else
          {:error, :cluster_not_formed}
        end
    end
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/riptide/ra_cluster_test.exs --trace`
Expected: PASS.

- [ ] **Step 5: Run the full suite**

Run: `mix test`
Expected: PASS, no regressions.

- [ ] **Step 6: Commit**

```bash
git add lib/riptide/ra_cluster.ex test/riptide/ra_cluster_test.exs
git commit -m "Add RaCluster.start_or_join_replicated/3: generalized multi-member cluster formation"
```

---

### Task 3: `Placement.propose_nodes/2` — always include the declaring node

**Files:**
- Modify: `lib/riptide/placement.ex`
- Test: `test/riptide/placement_test.exs`

**Interfaces:**
- Consumes: nothing new.
- Produces: `Riptide.Placement.propose_nodes(replication_factor :: pos_integer() \\ 3, peers :: [node()] \\ Node.list()) :: [node()]` — the calling/declaring node is now always the first element. Consumed by `Riptide.Stream.Placement` (Task 4).

Today, `propose_nodes/1` shuffles `Node.list() ++ [node()]` and takes `replication_factor` — for a fleet larger than the replication factor, this does NOT guarantee the calling/declaring node is among the chosen set. Phase 3c-i's own research cites RabbitMQ's quorum-queue placement precedent explicitly: "random selection, declaring node always included." Without this fix, a genuinely new stream's first `StreamServer.start_link/1` call could pick a replica set that excludes the very node handling the request — leaving no local process for `Process.whereis/1` to find. This is a real, previously-latent gap in already-shipped Phase 3c-i code (nothing called `propose_nodes/1` for real until now), fixed here since this is the phase that starts actually using it.

- [ ] **Step 1: Write the failing test**

Add to `test/riptide/placement_test.exs`, inside `describe "propose_nodes/1"`:

```elixir
    test "always includes the local node first, even with other candidates and RF > 1" do
      result = Placement.propose_nodes(3, [:peer_a, :peer_b, :peer_c])

      assert hd(result) == node()
      assert length(result) == 3
      assert Enum.uniq(result) == result
    end

    test "never duplicates the local node if it's already present in the given peer list" do
      result = Placement.propose_nodes(3, [node(), :peer_a, :peer_b])

      assert result == [node() | Enum.sort(result -- [node()])] or
               Enum.sort(result) == Enum.sort([node(), :peer_a, :peer_b])

      assert Enum.uniq(result) == result
      assert hd(result) == node()
    end

    test "returns just the local node when replication_factor is 1, regardless of peers" do
      assert Placement.propose_nodes(1, [:peer_a, :peer_b]) == [node()]
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/riptide/placement_test.exs --trace`
Expected: FAIL — `propose_nodes/2` doesn't exist yet (current arity is 1), and the existing `propose_nodes/1` doesn't guarantee local-node inclusion against a non-empty peer list.

- [ ] **Step 3: Fix `propose_nodes/1` and add the injectable peers parameter**

Modify `lib/riptide/placement.ex`:

```elixir
  @spec propose_nodes(pos_integer(), [node()]) :: [node()]
  def propose_nodes(replication_factor \\ @replication_factor, peers \\ Node.list()) do
    local = node()
    remaining = max(replication_factor - 1, 0)
    other_candidates = peers -- [local]

    [local | select_nodes(other_candidates, remaining)]
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/riptide/placement_test.exs --trace`
Expected: PASS, including the pre-existing "always includes the local node, even alone" test (unchanged behavior when `Node.list()` is empty).

- [ ] **Step 5: Run the full suite**

Run: `mix test`
Expected: PASS, no regressions.

- [ ] **Step 6: Commit**

```bash
git add lib/riptide/placement.ex test/riptide/placement_test.exs
git commit -m "Placement.propose_nodes/2: always include the declaring node (RabbitMQ precedent)"
```

---

### Task 4: `Riptide.Stream.Placement` — orchestration, cache, and app-boot wiring

**Files:**
- Create: `lib/riptide/stream/placement.ex`
- Test: `test/riptide/stream/placement_test.exs`
- Modify: `lib/riptide/application.ex`

**Interfaces:**
- Consumes: `Riptide.Placement.lookup/2`, `Riptide.Placement.assign/3`, `Riptide.Placement.propose_nodes/2` (Task 3); `Riptide.RaCluster.start_or_join_replicated/3` (Task 2), `Riptide.RaCluster.uid_for/1`, `Riptide.RaCluster.data_dir/0`, `Riptide.RaCluster.start_or_restart/2` (existing, used only in this task's own tests to simulate pre-existing on-disk data).
- Produces:
  - `Riptide.Stream.Placement.start_link/1` — supervised by `Riptide.Application`.
  - `Riptide.Stream.Placement.ensure_started(stream_id :: String.t(), machine :: :ra_machine.machine(), formation_fun :: (String.t(), [node()], :ra_machine.machine() -> {:ok, [:ra.server_id()]} | {:error, term()}) \\ &RaCluster.start_or_join_replicated/3, sleep_fun :: (pos_integer() -> :ok) \\ &Process.sleep/1) :: {:ok, [:ra.server_id()]} | {:error, :cluster_not_formed}` — consumed by `Riptide.Stream.StreamServer` (Task 5).
  - `Riptide.Stream.Placement.server_ids!(stream_id :: String.t()) :: [:ra.server_id()]` — consumed by `Riptide.Stream.StreamServer` (Task 5).

- [ ] **Step 1: Write the failing tests**

Create `test/riptide/stream/placement_test.exs`:

```elixir
defmodule Riptide.Stream.PlacementTest do
  use ExUnit.Case, async: true

  alias Riptide.Placement
  alias Riptide.RaCluster
  alias Riptide.Stream.Placement, as: StreamPlacement
  alias Riptide.Stream.RaMachine
  alias Riptide.Test.EchoMachine

  describe "ensure_started/4" do
    test "a genuinely new stream gets real placement and forms a real cluster" do
      stream_id = "stream-placement-new-" <> Uniq.UUID.uuid4()
      on_exit(fn -> RaCluster.force_delete(stream_id) end)

      assert {:ok, server_ids} =
               StreamPlacement.ensure_started(stream_id, {:module, EchoMachine, %{}})

      # Node.list() is empty in this single-node test env, so RF=3 collapses
      # to just the local node — same degradation `Placement.propose_nodes/2`
      # already guarantees.
      assert server_ids == [{String.to_atom(RaCluster.uid_for(stream_id)), node()}]
      assert Placement.lookup(stream_id) == [node()]
    end

    test "a stream already cached is returned without calling the formation function again" do
      stream_id = "stream-placement-cache-" <> Uniq.UUID.uuid4()
      on_exit(fn -> RaCluster.force_delete(stream_id) end)
      machine = {:module, EchoMachine, %{}}

      {:ok, server_ids} = StreamPlacement.ensure_started(stream_id, machine)

      unreachable_formation_fun = fn _uid, _nodes, _machine -> raise "should never be called" end
      assert {:ok, ^server_ids} =
               StreamPlacement.ensure_started(stream_id, machine, unreachable_formation_fun)
    end

    test "a stream with real pre-existing on-disk data backfills to its own node, not a fresh proposal" do
      stream_id = "stream-placement-backfill-" <> Uniq.UUID.uuid4()
      on_exit(fn -> RaCluster.force_delete(stream_id) end)
      machine = {:module, RaMachine, %{retention: :infinity}}

      # Simulate a pre-3c-ii stream: real on-disk data, created by calling
      # RaCluster directly, bypassing Riptide.Stream.Placement entirely — so
      # there's real data on disk but no Placement entry for it at all.
      RaCluster.start_or_restart(stream_id, machine)
      assert Placement.lookup(stream_id) == nil

      assert {:ok, server_ids} = StreamPlacement.ensure_started(stream_id, machine)
      assert server_ids == [{String.to_atom(RaCluster.uid_for(stream_id)), node()}]
      assert Placement.lookup(stream_id) == [node()]
    end

    test "bounded retry: succeeds once the formation function stops failing" do
      stream_id = "stream-placement-retry-ok-" <> Uniq.UUID.uuid4()
      on_exit(fn -> RaCluster.force_delete(stream_id) end)
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      real_formation_fun = &RaCluster.start_or_join_replicated/3

      formation_fun = fn uid, nodes, machine ->
        count = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
        if count < 2, do: {:error, :cluster_not_formed}, else: real_formation_fun.(uid, nodes, machine)
      end

      assert {:ok, _server_ids} =
               StreamPlacement.ensure_started(
                 stream_id,
                 {:module, EchoMachine, %{}},
                 formation_fun,
                 fn _ms -> :ok end
               )

      assert Agent.get(counter, & &1) == 3
    end

    test "bounded retry: gives up and returns an error after 3 failed attempts" do
      stream_id = "stream-placement-retry-fail-" <> Uniq.UUID.uuid4()
      on_exit(fn -> RaCluster.force_delete(stream_id) end)
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      formation_fun = fn _uid, _nodes, _machine ->
        Agent.update(counter, &(&1 + 1))
        {:error, :cluster_not_formed}
      end

      assert StreamPlacement.ensure_started(
               stream_id,
               {:module, EchoMachine, %{}},
               formation_fun,
               fn _ms -> :ok end
             ) == {:error, :cluster_not_formed}

      assert Agent.get(counter, & &1) == 3
    end
  end

  describe "server_ids!/1" do
    test "raises if ensure_started/2 has never run for this stream on this node" do
      stream_id = "stream-placement-unstarted-" <> Uniq.UUID.uuid4()

      assert_raise RuntimeError, ~r/before ensure_started\/2 ever ran/, fn ->
        StreamPlacement.server_ids!(stream_id)
      end
    end

    test "returns the cached server_ids after ensure_started/2 has run" do
      stream_id = "stream-placement-started-" <> Uniq.UUID.uuid4()
      on_exit(fn -> RaCluster.force_delete(stream_id) end)

      {:ok, server_ids} = StreamPlacement.ensure_started(stream_id, {:module, EchoMachine, %{}})
      assert StreamPlacement.server_ids!(stream_id) == server_ids
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/riptide/stream/placement_test.exs --trace`
Expected: FAIL — `Riptide.Stream.Placement` doesn't exist yet.

- [ ] **Step 3: Implement `Riptide.Stream.Placement`**

Create `lib/riptide/stream/placement.ex`:

```elixir
defmodule Riptide.Stream.Placement do
  @moduledoc """
  Orchestrates a stream's real, multi-node Ra cluster: resolves which nodes
  should host a stream's replicas (via `Riptide.Placement`, backfilling or
  proposing as needed — see Phase 3c-ii design spec §4), forms/rejoins the
  cluster (via `Riptide.RaCluster.start_or_join_replicated/3`), and caches
  the resolved server IDs locally for the life of this BEAM node — safe to
  cache forever, since a stream's placement never changes once assigned
  (`Riptide.Placement`'s own permanent-once-assigned invariant, Phase 3c-i).

  A tiny `GenServer` only to own the ETS table's lifetime; every other
  function here operates directly on the table, never routing through the
  GenServer process, so concurrent stream lookups never serialize through a
  single bottleneck.
  """

  use GenServer

  alias Riptide.Placement
  alias Riptide.RaCluster

  @table :riptide_stream_placement_cache
  @replication_factor 3
  @max_formation_attempts 3
  @formation_retry_backoff_ms 250

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl GenServer
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @doc """
  Ensures `stream_id`'s real Ra cluster is formed (or already running,
  locally cached) and returns its member server IDs. See Phase 3c-ii design
  spec §4 for the full lookup/backfill/propose decision flow, and §6 for the
  bounded-retry rationale (unlike the placement cluster's own boot-time,
  infinite-retry bootstrap, this happens synchronously on a live request
  path and must not block indefinitely).
  """
  @spec ensure_started(
          String.t(),
          :ra_machine.machine(),
          (String.t(), [node()], :ra_machine.machine() ->
             {:ok, [:ra.server_id()]} | {:error, term()}),
          (pos_integer() -> :ok)
        ) :: {:ok, [:ra.server_id()]} | {:error, :cluster_not_formed}
  def ensure_started(
        stream_id,
        machine,
        formation_fun \\ &RaCluster.start_or_join_replicated/3,
        sleep_fun \\ &Process.sleep/1
      ) do
    case cached(stream_id) do
      {:ok, server_ids} -> {:ok, server_ids}
      :miss -> resolve_and_start(stream_id, machine, formation_fun, sleep_fun)
    end
  end

  @doc """
  Reads a stream's cached server IDs — never triggers resolution or
  formation. Callers (`Riptide.Stream.StreamServer.append/2`/`get_since/2`)
  are only ever reached after `ensure_started/2` has already run once for
  this stream on this node (via `StreamServer.start_link/1`), so a cache
  miss here means a genuine caller bug, not a normal runtime state.
  """
  @spec server_ids!(String.t()) :: [:ra.server_id()]
  def server_ids!(stream_id) do
    case cached(stream_id) do
      {:ok, server_ids} ->
        server_ids

      :miss ->
        raise "Riptide.Stream.Placement.server_ids!/1 called for #{inspect(stream_id)} " <>
                "before ensure_started/2 ever ran for it on this node"
    end
  end

  @spec cached(String.t()) :: {:ok, [:ra.server_id()]} | :miss
  defp cached(stream_id) do
    case :ets.lookup(@table, stream_id) do
      [{^stream_id, server_ids}] -> {:ok, server_ids}
      [] -> :miss
    end
  end

  defp resolve_and_start(stream_id, machine, formation_fun, sleep_fun) do
    nodes = resolve_nodes(stream_id)
    uid = RaCluster.uid_for(stream_id)

    case start_with_retry(uid, nodes, machine, formation_fun, sleep_fun, @max_formation_attempts) do
      {:ok, server_ids} ->
        :ets.insert(@table, {stream_id, server_ids})
        {:ok, server_ids}

      {:error, _} = error ->
        error
    end
  end

  defp resolve_nodes(stream_id) do
    case Placement.lookup(stream_id) do
      nil -> backfill_or_propose(stream_id)
      nodes -> nodes
    end
  end

  # Disambiguates a nil Placement.lookup/2 result: a genuinely new stream
  # (no on-disk data anywhere this node knows about) gets real RF=3
  # placement; a stream that already has on-disk Ra data on THIS node
  # predates this phase (created under the old always-single-node-local
  # scheme, which never wrote anything to the placement store) and gets
  # backfilled to exactly where its real data already lives. Known,
  # inherited limitation (see design spec §4): this only correctly
  # discriminates if a pre-existing stream's requests keep landing on the
  # same node they always have — already an implicit assumption of today's
  # pre-3c-ii code, fully closed only once Phase 3c-iii's real routing
  # ships.
  defp backfill_or_propose(stream_id) do
    if on_disk?(stream_id) do
      Placement.assign(stream_id, [node()])
    else
      Placement.assign(stream_id, Placement.propose_nodes(@replication_factor))
    end
  end

  @spec on_disk?(String.t()) :: boolean()
  defp on_disk?(stream_id) do
    uid = RaCluster.uid_for(stream_id)
    data_dir = RaCluster.data_dir() |> to_string()
    File.dir?(Path.join(data_dir, uid))
  end

  defp start_with_retry(uid, nodes, machine, formation_fun, sleep_fun, attempts_left) do
    case formation_fun.(uid, nodes, machine) do
      {:ok, _server_ids} = ok ->
        ok

      {:error, _} = error when attempts_left <= 1 ->
        error

      {:error, _} ->
        sleep_fun.(@formation_retry_backoff_ms)
        start_with_retry(uid, nodes, machine, formation_fun, sleep_fun, attempts_left - 1)
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/riptide/stream/placement_test.exs --trace`
Expected: PASS.

- [ ] **Step 5: Wire `Riptide.Stream.Placement` into the application supervision tree**

Modify `lib/riptide/application.ex` — add `Riptide.Stream.Placement` to the `children` list, right after `Phoenix.PubSub`:

```elixir
    children =
      [
        {Phoenix.PubSub, name: Riptide.PubSub},
        Riptide.Stream.Placement,
        {Cluster.Supervisor,
         [Application.get_env(:libcluster, :topologies, []), [name: Riptide.ClusterSupervisor]]}
      ] ++
```

- [ ] **Step 6: Run the full suite**

Run: `mix test`
Expected: PASS, no regressions. `Riptide.Stream.Placement`'s ETS table is now created once at application boot (which `mix test` already triggers, same as `Riptide.PubSub`).

- [ ] **Step 7: Commit**

```bash
git add lib/riptide/stream/placement.ex test/riptide/stream/placement_test.exs lib/riptide/application.ex
git commit -m "Add Riptide.Stream.Placement: per-stream placement orchestration and cache"
```

---

### Task 5: Wire `StreamServer` through `Riptide.Stream.Placement`

**Files:**
- Modify: `lib/riptide/stream/stream_server.ex`

**Interfaces:**
- Consumes: `Riptide.Stream.Placement.ensure_started/2`, `Riptide.Stream.Placement.server_ids!/1` (Task 4).
- Produces: no change to `StreamServer`'s own public API (`start_link/1`, `append/2`, `get_since/2` keep identical signatures/contracts) — this is a refactor task, not a new-behavior task, so the deliverable is "the existing `StreamServerTest` suite passes unchanged against the new implementation."

- [ ] **Step 1: Replace the implementation**

Modify `lib/riptide/stream/stream_server.ex` to its full new content:

```elixir
defmodule Riptide.Stream.StreamServer do
  @moduledoc """
  Per-stream durable event log. A thin client over a real, placement-driven
  `Ra` cluster (see `Riptide.Stream.Placement`, `Riptide.RaCluster`) — no
  GenServer of our own; Ra owns the process(es) and their durability.
  """

  alias Riptide.Event
  alias Riptide.RaCluster
  alias Riptide.Stream.Placement
  alias Riptide.Stream.RaMachine

  # NOTE: `retention` is only applied when a stream's Ra cluster is first
  # created. On any later call for an existing stream this just resumes the
  # already-persisted server(s) from disk (via `Placement.ensure_started/2`,
  # which keeps whatever machine config the cluster was originally formed
  # with) — so passing a *different* `retention:` here for a stream that
  # already exists is silently ignored. Changing a live stream's retention
  # would need an explicit reconfiguration path (not in scope for Phase 1).
  @spec start_link({String.t(), keyword()}) :: {:ok, pid()} | {:error, term()}
  def start_link({stream_id, opts}) do
    retention = Keyword.get(opts, :retention, :infinity)
    machine = {:module, RaMachine, %{retention: retention}}

    case Placement.ensure_started(stream_id, machine) do
      {:ok, server_ids} ->
        {name, _node} = hd(server_ids)

        case Process.whereis(name) do
          pid when is_pid(pid) -> {:ok, pid}
          nil -> {:error, :not_started}
        end

      {:error, _reason} = error ->
        error
    end
  end

  @spec start_link(String.t()) :: {:ok, pid()} | {:error, term()}
  def start_link(stream_id) when is_binary(stream_id) do
    start_link({stream_id, []})
  end

  @spec append(String.t(), Event.t()) :: Event.t()
  def append(stream_id, %Event{} = event) do
    server_id = hd(Placement.server_ids!(stream_id))
    stamped = RaCluster.process_command(server_id, {:append, Event.encode(event)})
    Phoenix.PubSub.broadcast(Riptide.PubSub, "stream:" <> stream_id, {:new_event, stamped})
    stamped
  end

  # Uses `consistent_query/2`, not `local_query/2` — see issue #8. Reads
  # deterministically observe the fully recovered log even immediately after
  # a restart, at the cost of a leader round-trip once the cluster has real
  # peers (Phase 3c-ii onward) — acceptable here since this is called once
  # per connection/request (LDP GET, SSE subscribe, WebSocket replication
  # join), never per event; live delivery after that point is
  # `Phoenix.PubSub`-only (see `append/2`).
  @spec get_since(String.t(), non_neg_integer() | nil) ::
          {:ok, [Event.t()]} | {:gap, pos_integer() | nil}
  def get_since(stream_id, cursor) do
    server_id = hd(Placement.server_ids!(stream_id))
    RaCluster.consistent_query(server_id, &RaMachine.get_since(&1, cursor))
  end
end
```

- [ ] **Step 2: Run the existing `StreamServer` test suite**

Run: `mix test test/riptide/stream/stream_server_test.exs --trace`
Expected: PASS — every existing test (append sequencing, retention trimming, crash-restart durability, the issue #8 100-trial staleness check) passes unchanged, since `Node.list()` is empty in this single-node test env and every stream collapses to RF=1 exactly as before, just now routed through `Riptide.Stream.Placement`.

- [ ] **Step 3: Run the full suite**

Run: `mix test`
Expected: PASS, no regressions anywhere (including `stream_supervisor_test.exs`, which calls `StreamServer.start_link/1` indirectly via `StreamSupervisor.get_or_start/1`).

- [ ] **Step 4: Commit**

```bash
git add lib/riptide/stream/stream_server.ex
git commit -m "Route StreamServer through Riptide.Stream.Placement for real multi-node clusters"
```

---

### Task 6: Real multi-node proof — genuinely new streams and the backfill path

**Files:**
- Create: `test/riptide/stream/stream_placement_cluster_test.exs`

**Interfaces:**
- Consumes: `Riptide.RaCluster.attempt_start_placement_cluster/1` (Phase 3c-i), `Riptide.Stream.Placement.start_link/1`, `ensure_started/2` (Task 4), `Riptide.RaCluster.start_or_restart/2` (existing), `Riptide.RaCluster.process_command/2`, `consistent_query/2` (existing).
- Produces: nothing further downstream — this is the real proof that Tasks 1-5 work together across genuinely distinct nodes, extending Phase 3c-i's own proven `:peer`-based 3-real-node recipe (`test/riptide/placement_cluster_test.exs`).

- [ ] **Step 1: Write the test**

Create `test/riptide/stream/stream_placement_cluster_test.exs`:

```elixir
defmodule Riptide.Stream.StreamPlacementClusterTest do
  use ExUnit.Case, async: false

  @moduletag timeout: 60_000

  @new_stream_peers [
    {:riptide_stream0, "riptide-0", ~c"127.0.0.4"},
    {:riptide_stream1, "riptide-1", ~c"127.0.0.5"},
    {:riptide_stream2, "riptide-2", ~c"127.0.0.6"}
  ]

  @backfill_peers [
    {:riptide_backfill0, "riptide-0", ~c"127.0.0.7"},
    {:riptide_backfill1, "riptide-1", ~c"127.0.0.8"},
    {:riptide_backfill2, "riptide-2", ~c"127.0.0.9"}
  ]

  setup_all do
    unless Node.alive?() do
      {:ok, _pid} = Node.start(:"stream_placement_cluster_origin@127.0.0.1", :longnames)
    end

    :ok
  end

  test "a genuinely new stream forms a real 3-member cluster across 3 real nodes and replicates writes" do
    {peers, nodes, resolve_fun} = start_and_bootstrap_peers(@new_stream_peers)

    on_exit(fn -> stop_peers_and_cleanup(peers, @new_stream_peers) end)

    {_pid, entry_node, _ordinal} = hd(peers)
    stream_id = "stream-placement-cluster-" <> Uniq.UUID.uuid4()

    # Goes through the real StreamServer entry point (not RaCluster/
    # Riptide.Stream.Placement directly) — this is the proof that Task 5's
    # integration, not just the lower-level formation mechanics, works
    # against real distinct nodes. Placement.propose_nodes/2's candidate
    # list is Node.list() ++ [node()] — on a real :peer node this correctly
    # sees its two connected siblings, so a genuinely new stream with RF=3
    # and exactly 3 connected peers gets all 3, deterministically (no
    # randomness needed to reach "take 3 of 3").
    assert {:ok, _pid} =
             :erpc.call(entry_node, Riptide.Stream.StreamServer, :start_link, [stream_id])

    server_ids = :erpc.call(entry_node, Riptide.Stream.Placement, :server_ids!, [stream_id])
    assert length(server_ids) == 3
    assigned_nodes = Enum.map(server_ids, fn {_name, node} -> node end)
    assert Enum.sort(assigned_nodes) == Enum.sort(nodes)

    graph = :erpc.call(entry_node, RDF.Graph, :new, [])
    event = :erpc.call(entry_node, Riptide.Event, :new, [stream_id, :replace, graph])

    stamped = :erpc.call(entry_node, Riptide.Stream.StreamServer, :append, [stream_id, event])
    assert stamped.sequence == 1

    # Read from a *different* peer than the one that wrote — proving real
    # Raft replication through the stream's own multi-member cluster, not
    # local memory. That peer is a legitimate member (one of the 3 assigned
    # nodes), so its own StreamServer.start_link/1 call rediscovers the
    # already-running local member via the self-correcting recheck in
    # RaCluster.start_or_join_replicated/3 (Task 2), not a fresh formation.
    {_pid, reader_node, _ordinal} = Enum.at(peers, 1)

    assert {:ok, _pid} =
             :erpc.call(reader_node, Riptide.Stream.StreamServer, :start_link, [stream_id])

    assert {:ok, [%{sequence: 1}]} =
             :erpc.call(reader_node, Riptide.Stream.StreamServer, :get_since, [stream_id, 0])

    _ = resolve_fun
  end

  test "a stream with real pre-existing on-disk data on one node backfills to that node alone" do
    {peers, _nodes, resolve_fun} = start_and_bootstrap_peers(@backfill_peers)

    on_exit(fn -> stop_peers_and_cleanup(peers, @backfill_peers) end)

    {_pid, origin_node, _ordinal} = hd(peers)
    stream_id = "stream-placement-backfill-" <> Uniq.UUID.uuid4()
    machine = {:module, Riptide.Stream.RaMachine, %{retention: :infinity}}

    # Bypass Riptide.Stream.Placement/StreamServer entirely to create real
    # on-disk data on exactly one node — simulating a stream that already
    # existed before this phase shipped, before any Placement entry for it
    # ever existed.
    :erpc.call(origin_node, Riptide.RaCluster, :start_or_restart, [stream_id, machine])

    assert :erpc.call(origin_node, Riptide.Placement, :lookup, [stream_id, resolve_fun]) == nil

    # Goes through the real StreamServer entry point, same as the other
    # test above, so this proves the backfill path end-to-end through
    # Task 5's integration too, not just Riptide.Stream.Placement in
    # isolation.
    assert {:ok, _pid} =
             :erpc.call(origin_node, Riptide.Stream.StreamServer, :start_link, [stream_id])

    server_ids = :erpc.call(origin_node, Riptide.Stream.Placement, :server_ids!, [stream_id])
    uid = :erpc.call(origin_node, Riptide.RaCluster, :uid_for, [stream_id])
    assert server_ids == [{String.to_atom(uid), origin_node}]
    assert :erpc.call(origin_node, Riptide.Placement, :lookup, [stream_id, resolve_fun]) == [origin_node]
  end

  # Spawns the given peers, connects them, pre-starts each one's local :ra
  # system, bootstraps the real placement metadata cluster across them, and
  # starts Riptide.Stream.Placement's ETS-owning GenServer on each — the
  # same sequential-pass ordering placement_cluster_test.exs (Phase 3c-i)
  # already proved necessary (:ra must be started as an OTP app on every
  # member before any of them attempts cluster formation, since
  # attempt_start_placement_cluster/1 reaches out to the *other* members
  # over RPC too, not just the local one).
  defp start_and_bootstrap_peers(peer_specs) do
    pa_args = Enum.flat_map(:code.get_path(), fn p -> [~c"-pa", p] end)

    peers =
      for {alive_name, ordinal, host} <- peer_specs do
        {:ok, pid, node} =
          :peer.start_link(%{
            name: alive_name,
            host: host,
            longnames: true,
            args: pa_args,
            env: [{~c"HOSTNAME", to_charlist(ordinal)}]
          })

        {pid, node, ordinal}
      end

    [{module, bytecode}] = Code.compile_file(__ENV__.file)

    for {_pid, node, _ordinal} <- peers do
      assert {:module, ^module} =
               :erpc.call(node, :code, :load_binary, [
                 module,
                 ~c"stream_placement_cluster_test.ex",
                 bytecode
               ])
    end

    nodes = Enum.map(peers, fn {_pid, node, _ordinal} -> node end)
    ordinal_to_node = Map.new(peers, fn {_pid, node, ordinal} -> {ordinal, node} end)
    resolve_fun = fn ordinal -> Map.fetch!(ordinal_to_node, ordinal) end

    for {n1, n2} <- unique_pairs(nodes) do
      assert :erpc.call(n1, :net_kernel, :connect_node, [n2]) == true
    end

    for {_pid, node, _ordinal} <- peers do
      {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:ra])
    end

    for {_pid, node, _ordinal} <- peers do
      case :erpc.call(node, :ra_system, :start, [
             :erpc.call(node, Riptide.RaCluster, :system_config, [])
           ]) do
        {:ok, _pid} -> :ok
        {:ok, _pid, _info} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    results =
      Enum.map(peers, fn {_pid, node, _ordinal} ->
        :erpc.call(node, Riptide.RaCluster, :attempt_start_placement_cluster, [resolve_fun])
      end)

    assert Enum.any?(results, &(&1 == :ok))

    # Riptide.Application never boots on a bare :peer node (it never runs
    # Riptide.Application.start/2 at all), so Riptide.Stream.Placement's
    # ETS-owning GenServer needs starting explicitly here, same as the Ra
    # system pre-start above.
    for {_pid, node, _ordinal} <- peers do
      {:ok, _pid} = :erpc.call(node, Riptide.Stream.Placement, :start_link, [[]])
    end

    {peers, nodes, resolve_fun}
  end

  defp stop_peers_and_cleanup(peers, peer_specs) do
    Enum.each(peers, fn {pid, _node, _ordinal} ->
      if Process.alive?(pid) do
        try do
          :peer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    # Same on-disk-leak gotcha as placement_cluster_test.exs (:peer nodes
    # don't load Mix config, so RaCluster.data_dir/0 falls through to
    # File.cwd!()) — clean up every ordinal's data directory under the repo
    # root, which now holds both the placement cluster's own data and any
    # stream data created during the test.
    Enum.each(peer_specs, fn {_alive_name, ordinal, _host} ->
      File.rm_rf!(Path.join(File.cwd!(), ordinal))
    end)
  end

  defp unique_pairs(list) do
    for {a, i} <- Enum.with_index(list),
        {b, j} <- Enum.with_index(list),
        i < j,
        do: {a, b}
  end
end
```

- [ ] **Step 2: Run it**

Run: `mix test test/riptide/stream/stream_placement_cluster_test.exs --trace`
Expected: PASS, both tests. Run it 3 times in a row to confirm no flakiness and that `on_exit` cleanup leaves no leftover peer processes, `epmd` registrations, or on-disk directories (`ps aux | grep beam`, `epmd -names`, `ls` the repo root should show none of the `riptide-0`/`riptide-1`/`riptide-2` directories after each run).

- [ ] **Step 3: Run the full suite**

Run: `mix test`
Expected: PASS, no regressions.

- [ ] **Step 4: Commit**

```bash
git add test/riptide/stream/stream_placement_cluster_test.exs
git commit -m "Add real multi-node proof: genuinely new streams and the backfill path"
```

---

### Task 7: Live proof against the existing Phase 3b StatefulSet

**Files:**
- No new files — this task operates against the real cluster using the existing `k8s/` manifests (no changes needed; already fixed for non-root `/data` writes by Phase 3c-i's `fsGroup` side-fix).

**Interfaces:**
- Consumes: the already-deployed `k8s/*.yaml` manifests, the built Docker image (now including this plan's Tasks 1-6).
- Produces: a written verification record (this task's own report) — no code.

**Note before starting:** deploying this live requires the operator's explicit go-ahead, the same way Phase 3c-i's own live GKE proof did — ask before creating any real cluster resources. Build/push a throwaway-tagged image manually (e.g. `phase-3c-ii-proof`, never touching `:latest`), following Phase 3c-i's own working recipe (`docker buildx build --network=host --push -t ghcr.io/openfaster-standard/riptide:phase-3c-ii-proof .`, `gh auth token | docker login ghcr.io -u <user> --password-stdin`).

- [ ] **Step 1: Build and push a fresh image, deploy to a disposable namespace**

```bash
kubectl create namespace riptide-phase-3c-ii-proof
kubectl config set-context --current --namespace=riptide-phase-3c-ii-proof
```

Follow `k8s/README.md`'s Deploy steps, using the throwaway image tag (override via `sed` + `kubectl apply -f -`, matching Phase 3c-i's Task 5 exactly — never edit the committed manifest). If the ghcr.io package pull fails with `401 Unauthorized` (the `riptide` package is private — already hit once during Phase 3c-i's own Task 5), fix it the same way that task did:

```bash
kubectl create secret docker-registry ghcr-pull-secret \
  --docker-server=ghcr.io \
  --docker-username=<your github username> \
  --docker-password="$(gh auth token)"
kubectl patch statefulset riptide --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/imagePullSecrets","value":[{"name":"ghcr-pull-secret"}]}]'
kubectl delete pod riptide-0 riptide-1 riptide-2 --wait=false
```

Run: `kubectl rollout status statefulset/riptide --timeout=120s`
Expected: all 3 pods reach `Ready`.

- [ ] **Step 2: Verify a genuinely new stream forms a real 3-member cluster and replicates**

```bash
kubectl exec riptide-0 -- bin/riptide rpc "IO.inspect(Riptide.Stream.Placement.ensure_started(\"live-proof-stream\", {:module, Riptide.Stream.RaMachine, %{retention: :infinity}}))"
```

Expected: `{:ok, [server_id_1, server_id_2, server_id_3]}` — 3 distinct `{name, node}` tuples, one per real pod (since `Node.list()` sees the other 2 pods via `libcluster`'s Kubernetes DNS discovery, already proven live in Phase 3b).

- [ ] **Step 3: Verify a write on one pod replicates to the other two**

```bash
kubectl exec riptide-0 -- bin/riptide rpc "IO.inspect(Riptide.Stream.StreamServer.append(\"live-proof-stream\", Riptide.Event.new(\"live-proof-stream\", :replace, RDF.Graph.new())))"
kubectl exec riptide-1 -- bin/riptide rpc "IO.inspect(Riptide.Stream.StreamServer.get_since(\"live-proof-stream\", 0))"
kubectl exec riptide-2 -- bin/riptide rpc "IO.inspect(Riptide.Stream.StreamServer.get_since(\"live-proof-stream\", 0))"
```

Expected: the `append` on `riptide-0` returns an event with `sequence: 1`; both `get_since` calls on the *other* two pods return `{:ok, [%Riptide.Event{sequence: 1, ...}]}` — proving the event actually replicated through the stream's own real multi-member Raft consensus, not local memory.

- [ ] **Step 4: Tear down**

```bash
kubectl delete namespace riptide-phase-3c-ii-proof
kubectl config set-context --current --namespace=default
```

Poll `kubectl get namespace riptide-phase-3c-ii-proof` until `NotFound`. Delete the throwaway image tag from ghcr.io (`gh api --method DELETE` on its package version) and the local docker image. Leave nothing behind.

- [ ] **Step 5: Record the results**

Write a short summary (for Task 8's `PROGRESS.md` update and the PR description) of what was directly observed at Steps 2-3 — the actual command output, not a paraphrased summary.

---

### Task 8: Full verification + PROGRESS.md + wrap-up

**Files:**
- Modify: `PROGRESS.md`

**Interfaces:**
- Consumes: everything from Tasks 1-7, including Task 7's recorded live-proof results.
- Produces: nothing further downstream — terminal task.

- [ ] **Step 1: Run the full test suite**

Run: `mix test`
Expected: PASS, 0 failures — including every test added in Tasks 1-6 and every pre-existing test (Phase 3a/3b/3c-i's suites) unaffected.

- [ ] **Step 2: Run Credo and formatter checks**

Run: `mix credo --strict && mix format --check-formatted`
Expected: both clean. Fix anything flagged and re-run.

- [ ] **Step 3: Update `PROGRESS.md`**

In the `## 3. Clustering / horizontal scale / HA` section's Phase 3c bullet, change the 3c-ii sub-bullet:

```markdown
  - **3c-ii — Real multi-member Ra cluster formation.** Consumes 3c-i's stored assignment to
    actually start an N-member Ra cluster for a stream, replacing the old hardcoded
    single-member `initial_members: [server_id]`. **Shipped 2026-08-25** — see
    `docs/superpowers/specs/2026-08-25-phase-3c-ii-multi-member-ra-clusters-design.md`.
    Live-proved against a real 3-pod GKE StatefulSet: a genuinely new stream formed a real
    3-member cluster across all 3 pods, and a write on one pod replicated to the other two.
```

Change the `**Status**:` line from:

```markdown
**Status**: Phases 3a-3b shipped. Phase 3c-i shipped. 3c-ii (multi-member Ra cluster
formation) not yet started.
```

to:

```markdown
**Status**: Phases 3a-3b shipped. Phase 3c-i and 3c-ii shipped. 3c-iii (request routing)
not yet started.
```

- [ ] **Step 4: Commit**

```bash
git add PROGRESS.md
git commit -m "Mark Phase 3c-ii shipped in PROGRESS.md"
```

- [ ] **Step 5: Push and open a PR**

```bash
git push -u origin <branch-name>
gh pr create --title "Phase 3c-ii: real multi-member Ra cluster formation" --body "$(cat <<'EOF'
## Summary
- Implements the Phase 3c-ii design spec (docs/superpowers/specs/2026-08-25-phase-3c-ii-multi-member-ra-clusters-design.md).
- RaCluster.start_or_join_replicated/3: generalizes attempt_start_placement_cluster/1's per-member-config formation pattern to an arbitrary node list.
- Placement.propose_nodes/2: always includes the declaring node (RabbitMQ quorum-queue placement precedent, cited in Phase 3c-i's own research).
- New Riptide.Stream.Placement: resolves/backfills/proposes a stream's real replica set, forms its cluster, caches the result forever (placement is permanent once assigned).
- StreamServer now routes through Riptide.Stream.Placement instead of RaCluster directly — existing behavior unchanged in single-node test/dev environments, real multi-node replication in a real fleet.
- Includes [Task 7's live-proof results here — paste the recorded observations].

## Test plan
- [x] mix test — full suite passes, including the new RaCluster/Placement/Riptide.Stream.Placement/StreamServer tests and the new :peer-based multi-node integration test
- [x] mix credo --strict
- [x] mix format --check-formatted
- [x] Live proof: a genuinely new stream formed a real 3-member cluster across 3 real GKE StatefulSet pods; a write on one pod replicated to the other two (see Task 7's recorded results)
EOF
)"
```

Report the PR URL and stop — do not merge without explicit human sign-off (ask via AskUserQuestion), matching this project's established practice for every prior PR.
