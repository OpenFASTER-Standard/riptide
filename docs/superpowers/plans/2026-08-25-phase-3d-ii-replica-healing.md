# Phase 3d-ii: Automatic Stream Replica Healing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect a stream with exactly one dead replica and automatically replace it with a live fleet node — no operator action required — closing the gap where a stream's frozen `node()`-based replica assignment never re-resolves after a pod restart (unlike the placement cluster, which self-heals for free per Phase 3d-i).

**Architecture:** A new `Riptide.Stream.ReplicaHealer` `GenServer`, started only on the 3 placement ordinals (same gating as `ensure_placement_cluster_started/0`), ticks on a timer and — only when this node is the placement cluster's current Raft leader — lists every known stream (`Riptide.Placement.list_all/1`, new), checks each replica's real liveness, and for any stream with exactly one dead member, picks a live replacement and repairs it: joins the replacement into the stream's own `:ra` cluster (`RaCluster.replace_member/5`, new — verified against the pinned `:ra` source's real `add_member`/`start_server`/`remove_member` sequence), updates the durable placement assignment (`PlacementMachine`'s new `{:replace_member, ...}` command), and broadcasts a `Phoenix.PubSub` invalidation so any node's stale in-memory cache of that stream's server ids gets corrected.

**Tech Stack:** Elixir/OTP, `:ra` (Erlang Raft, pinned `2.15.4`), `Phoenix.PubSub`, ExUnit, OTP 25's `:peer` module for real multi-node integration tests.

**Spec:** `docs/superpowers/specs/2026-08-25-phase-3d-ii-replica-healing-design.md`

## Global Constraints

- Only streams with exactly one dead member (of RF=3) are auto-repaired. A stream with 2+ dead members has already lost quorum — `:ra`'s own membership-change primitives require consensus to commit, so they fail/timeout harmlessly against such a cluster rather than making anything worse. This is never special-cased in code; it falls out of the underlying primitives.
- No deliberate replication-factor changes (this only replaces a dead member 1-for-1) and no proactive node decommissioning/evacuation — both explicitly out of scope (spec §3).
- No new locking/coordination primitive — single-writer safety across the 3 ordinals comes from the placement cluster's own existing Raft leader election.
- No explicit flapping/debounce state — a node that reconnects before the next sweep is simply observed alive again next tick and left untouched.
- `RaCluster` remains the sole module that calls `:ra` directly (standing invariant since Phase 3c-i) — `Riptide.Stream.ReplicaHealer` never calls `:ra` itself, only `RaCluster`/`Placement` functions.

---

### Task 1: `PlacementMachine`'s `list/1` query + `{:replace_member, ...}` command

**Files:**
- Modify: `lib/riptide/placement/placement_machine.ex`
- Test: `test/riptide/placement/placement_machine_test.exs`

**Interfaces:**
- Consumes: nothing new — pure state-machine logic on the existing `state()` type (`%{String.t() => [node()]}`).
- Produces: `PlacementMachine.list/1` (`state() -> state()`, i.e. returns the full map) and the new `{:replace_member, stream_id, dead_node, new_node}` command handled by `apply/3`. Task 2 wraps both in `Riptide.Placement`'s client API.

- [ ] **Step 1: Write the failing tests**

Add to `test/riptide/placement/placement_machine_test.exs`, after the existing `get/2` tests:

```elixir
  test "list/1 returns the full stream_id => nodes map" do
    state = %{"s1" => [:a, :b, :c], "s2" => [:d, :e, :f]}
    assert PlacementMachine.list(state) == state
  end

  test "list/1 returns an empty map when nothing is assigned yet" do
    assert PlacementMachine.list(PlacementMachine.init(%{})) == %{}
  end

  test "apply/3 {:replace_member, ...} swaps a dead node for a new one in an existing assignment" do
    state = %{"s1" => [:a, :b, :c]}

    {new_state, reply, effects} =
      PlacementMachine.apply(%{index: 1}, {:replace_member, "s1", :b, :z}, state)

    assert new_state == %{"s1" => [:a, :z, :c]}
    assert reply == [:a, :z, :c]
    assert effects == []
  end

  test "apply/3 {:replace_member, ...} is a no-op if the named dead node is no longer present" do
    state = %{"s1" => [:a, :z, :c]}

    {new_state, reply, effects} =
      PlacementMachine.apply(%{index: 2}, {:replace_member, "s1", :b, :y}, state)

    assert new_state == %{"s1" => [:a, :z, :c]}
    assert reply == [:a, :z, :c]
    assert effects == []
  end

  test "apply/3 {:replace_member, ...} is a no-op for an unknown stream_id" do
    state = %{}

    {new_state, reply, effects} =
      PlacementMachine.apply(%{index: 1}, {:replace_member, "unknown", :a, :b}, state)

    assert new_state == %{}
    assert reply == nil
    assert effects == []
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/riptide/placement/placement_machine_test.exs --trace`
Expected: FAIL — `PlacementMachine.list/1` is undefined, and `apply/3` has no clause matching `{:replace_member, ...}`.

- [ ] **Step 3: Implement `list/1` and the `{:replace_member, ...}` command**

Modify `lib/riptide/placement/placement_machine.ex` — add after the existing `{:assign, ...}` clause of `apply/3`:

```elixir
  # Idempotent the same way {:assign, ...} is: if `dead_node` is no longer
  # part of `stream_id`'s stored assignment (e.g. a different placement-
  # cluster leader, from a prior Raft term, already won this exact repair),
  # this is a no-op that returns the current assignment unchanged rather
  # than erroring — safe to call redundantly from a racing leader.
  @impl :ra_machine
  def apply(_meta, {:replace_member, stream_id, dead_node, new_node}, state) do
    case Map.fetch(state, stream_id) do
      {:ok, nodes} ->
        if dead_node in nodes do
          new_nodes = Enum.map(nodes, fn n -> if n == dead_node, do: new_node, else: n end)
          new_state = Map.put(state, stream_id, new_nodes)
          {new_state, new_nodes, []}
        else
          {state, nodes, []}
        end

      :error ->
        {state, nil, []}
    end
  end

  @spec list(state()) :: state()
  def list(state), do: state
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/riptide/placement/placement_machine_test.exs --trace`
Expected: PASS, all tests including the pre-existing ones.

- [ ] **Step 5: Commit**

```bash
git add lib/riptide/placement/placement_machine.ex test/riptide/placement/placement_machine_test.exs
git commit -m "Add PlacementMachine.list/1 and {:replace_member, ...} command"
```

---

### Task 2: `Riptide.Placement.list_all/1` and `replace_member/3` client functions

**Files:**
- Modify: `lib/riptide/placement.ex`
- Test: `test/riptide/placement_test.exs`

**Interfaces:**
- Consumes: `PlacementMachine.list/1`, the `{:replace_member, ...}` command (Task 1); the existing private `with_ordinal_fallback/2` helper (Phase 3d-i fix 2) for ordinal-fallback addressing.
- Produces: `Placement.list_all/1` (`(String.t() -> node()) -> %{String.t() => [node()]}`) and `Placement.replace_member/4` (`(stream_id, dead_node, new_node, resolve_fun) -> [node()] | nil`). Both consumed by Task 6's healer.

- [ ] **Step 1: Write the failing tests**

Add to `test/riptide/placement_test.exs`, inside the existing `describe "assign/2 and lookup/2 against the real metadata cluster"` block:

```elixir
    test "list_all/1 includes every real assignment made so far" do
      stream_id = "placement-list-all-" <> Uniq.UUID.uuid4()
      Placement.assign(stream_id, [node()])

      assert Placement.list_all()[stream_id] == [node()]
    end

    test "replace_member/3 swaps a dead node for a new one in a real assignment" do
      stream_id = "placement-replace-member-" <> Uniq.UUID.uuid4()
      fake_dead_node = :"fake-dead@nowhere"
      Placement.assign(stream_id, [node(), fake_dead_node])

      replaced = Placement.replace_member(stream_id, fake_dead_node, :"fake-new@nowhere")

      assert Enum.sort(replaced) == Enum.sort([node(), :"fake-new@nowhere"])
      assert Enum.sort(Placement.lookup(stream_id)) == Enum.sort([node(), :"fake-new@nowhere"])
    end

    test "replace_member/3 is a no-op if the dead node named is no longer part of the assignment" do
      stream_id = "placement-replace-member-noop-" <> Uniq.UUID.uuid4()
      Placement.assign(stream_id, [node()])

      result = Placement.replace_member(stream_id, :"never-was-here@nowhere", :"new@nowhere")

      assert result == [node()]
      assert Placement.lookup(stream_id) == [node()]
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/riptide/placement_test.exs --trace`
Expected: FAIL — `Placement.list_all/1` and `Placement.replace_member/4` are undefined.

- [ ] **Step 3: Implement `list_all/1` and `replace_member/4`**

Modify `lib/riptide/placement.ex` — add after the existing `lookup/2` function, before `defp placement_server_id/1`:

```elixir
  @spec list_all((String.t() -> node())) :: %{String.t() => [node()]}
  def list_all(resolve_fun \\ &RaCluster.default_ordinal_resolver/1) do
    with_ordinal_fallback(resolve_fun, fn server_id ->
      RaCluster.consistent_query(server_id, &PlacementMachine.list/1)
    end)
  end

  @spec replace_member(String.t(), node(), node(), (String.t() -> node())) :: [node()] | nil
  def replace_member(
        stream_id,
        dead_node,
        new_node,
        resolve_fun \\ &RaCluster.default_ordinal_resolver/1
      ) do
    with_ordinal_fallback(resolve_fun, fn server_id ->
      RaCluster.process_command(server_id, {:replace_member, stream_id, dead_node, new_node})
    end)
  end
```

Note: `with_ordinal_fallback/2` is renamed from its current 2-arity private form only if needed — check the existing signature at `lib/riptide/placement.ex` (added in Phase 3d-i fix 2) before adding these; it already takes `(resolve_fun, fun)` and works unchanged for both new functions.

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/riptide/placement_test.exs --trace`
Expected: PASS, all tests including the pre-existing ones.

- [ ] **Step 5: Commit**

```bash
git add lib/riptide/placement.ex test/riptide/placement_test.exs
git commit -m "Add Riptide.Placement.list_all/1 and replace_member/4"
```

---

### Task 3: `RaCluster.member_alive?/1` made public + `RaCluster.placement_leader?/0`

**Files:**
- Modify: `lib/riptide/ra_cluster.ex`
- Test: `test/riptide/ra_cluster_test.exs`

**Interfaces:**
- Consumes: the existing private `member_alive?/1` (Phase 3d-i fix 1, currently `defp` at `lib/riptide/ra_cluster.ex:313`) and the existing `@placement_cluster_name` module attribute.
- Produces: `RaCluster.member_alive?/1` (now public — `(:ra.server_id()) -> boolean()`) and `RaCluster.placement_leader?/0` (`() -> boolean()`). Both consumed by Task 6's healer.

- [ ] **Step 1: Write the failing test for `placement_leader?/0`**

Add to `test/riptide/ra_cluster_test.exs`, in a new `describe` block after the existing `describe "attempt_start_placement_cluster/1"` block. Note: `test_helper.exs` always bootstraps a real, running (single-node-collapsed) placement cluster on the test-runner's own node before any test file runs, so there is no honest way to observe a "not running locally" state from within this async suite — only the positive case is tested here; the collapsed cluster's sole member is trivially always its own leader:

```elixir
  describe "placement_leader?/0" do
    test "returns true for this node's own already-running (collapsed) placement cluster" do
      assert RaCluster.placement_leader?()
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/riptide/ra_cluster_test.exs --trace`
Expected: FAIL — `RaCluster.placement_leader?/0` is undefined. (The first test, checking the not-yet-formed case, may pass vacuously depending on test order since `test_helper.exs` already bootstraps a shared placement cluster at suite boot — this is expected and fine; the second test is the real proof.)

- [ ] **Step 3: Make `member_alive?/1` public and add `placement_leader?/0`**

Modify `lib/riptide/ra_cluster.ex`:

Change the two `member_alive?/1` clauses (currently around line 313) from `defp` to `def`, keeping their bodies and the comment above them unchanged:

```elixir
  # Public (not `defp`) so callers beyond this module — e.g.
  # `Riptide.Stream.ReplicaHealer` (Phase 3d-ii) — can check a specific
  # stream replica's real liveness, local or remote, the same way this
  # module already does internally for `start_or_join_replicated/3`'s own
  # `NotStarted` handling.
  @spec member_alive?(:ra.server_id()) :: boolean()
  def member_alive?({name, node}) when node == node() do
    server_alive?(name)
  end

  def member_alive?({name, node}) do
    case :erpc.call(node, __MODULE__, :server_alive?, [name], 5_000) do
      true -> true
      false -> false
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end
```

Add `placement_leader?/0` after `placement_server_id/2` (around line 45, right before the `default_ordinal_resolver/1` comment block):

```elixir
  # Whether THIS node is currently the placement cluster's Raft leader —
  # used by `Riptide.Stream.ReplicaHealer` (Phase 3d-ii) to gate stream
  # replica repair so only one of the 3 placement ordinals ever acts on a
  # given sweep, reusing the placement cluster's own existing leader
  # election rather than a new coordination mechanism. Queries the LOCAL
  # member directly (`{@placement_cluster_name, node()}`) rather than going
  # through `placement_server_id/2`'s ordinal/DNS resolution, since this is
  # only ever meaningful to call from a node that's itself a placement
  # ordinal already running its own local member.
  @spec placement_leader?() :: boolean()
  def placement_leader? do
    case :ra.members({@placement_cluster_name, node()}) do
      {:ok, _members, {@placement_cluster_name, leader_node}} -> leader_node == node()
      _ -> false
    end
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/riptide/ra_cluster_test.exs --trace`
Expected: PASS, all tests including the pre-existing ones.

- [ ] **Step 5: Run the full suite**

Run: `mix test`
Expected: PASS, 0 failures — `member_alive?/1` becoming public doesn't change any existing caller's behavior.

- [ ] **Step 6: Commit**

```bash
git add lib/riptide/ra_cluster.ex test/riptide/ra_cluster_test.exs
git commit -m "Expose RaCluster.member_alive?/1 publicly, add placement_leader?/0"
```

---

### Task 4: `RaCluster.replace_member/5` — the real `:ra` join-and-evict primitive

**Files:**
- Modify: `lib/riptide/ra_cluster.ex`
- Test: `test/riptide/ra_cluster_test.exs` (collapsed-node case), `test/riptide/ra_cluster_replace_member_test.exs` (new — real multi-node `:peer` proof)

**Interfaces:**
- Consumes: `ensure_system_started/0`, `uid_for/1`, `member_alive?/1` (Task 3), the module's own `@system` attribute.
- Produces: `RaCluster.replace_member/5` (`(uid, survivor_nodes, dead_node, new_node, machine) -> :ok | {:error, term()}`). Consumed by Task 6's healer.

This is verified against the pinned `:ra` source (`deps/ra/src/ra.erl`) and its own README
(`deps/ra/README.md`, "Dynamically Changing Cluster Membership" section): growing a running
cluster is `:ra.add_member(existing_member_id_or_ids, new_member_id)` **first** (tells the
existing cluster about the new member), **then** `:ra.start_server/5` on the new member (config's
`initial_members` set to just the existing survivor(s), not a fresh `initial_members` list) so it
starts as a joining follower and catches up via ordinary log replication — the reverse order of
`start_or_join_replicated/3`'s fresh-cluster-formation case. `:ra.start_server/2,5` internally
RPCs to whichever node the target server id names (confirmed in
`deps/ra/src/ra_server_sup_sup.erl:41-48`), so this can be called from any connected node, not
just the joining node itself — consistent with every other `RaCluster` primitive's
location-transparent style.

- [ ] **Step 1: Write the failing collapsed-node test**

Add to `test/riptide/ra_cluster_test.exs`, in a new `describe` block after `describe "start_or_join_replicated/3"`:

```elixir
  describe "replace_member/5" do
    test "replaces a member with a fresh one, collapsed onto a single real node" do
      uid = "replace-member-" <> Uniq.UUID.uuid4()
      name = String.to_atom(uid)
      machine = {:module, EchoMachine, %{}}
      on_exit(fn -> :ra.force_delete_server(:default, {name, node()}) end)

      assert {:ok, _server_ids} =
               RaCluster.start_or_join_replicated(uid, [node()], machine)

      # A single real node standing in for both "the dead node" and "the
      # replacement" is nonsensical for a real repair, but proves the
      # function's own call sequence (add_member, start_server, remove_member)
      # doesn't blow up against a real, already-running single-member
      # cluster — real distinctness is proven separately by Step 5's
      # `:peer`-based test.
      assert RaCluster.replace_member(uid, [node()], :"dead@nowhere", node(), machine) ==
               {:error, :already_member}
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/riptide/ra_cluster_test.exs --trace`
Expected: FAIL — `RaCluster.replace_member/5` is undefined.

- [ ] **Step 3: Implement `replace_member/5`**

Modify `lib/riptide/ra_cluster.ex` — add after `start_or_join_replicated/3` (end of the module, before the final `end`):

```elixir
  # Grows a stream's already-running `:ra` cluster by one member (`new_node`)
  # and evicts a dead one (`dead_node`) — the real repair primitive behind
  # Phase 3d-ii's automatic replica healing. `survivor_nodes` must be at
  # least one currently-alive member of the cluster (never `dead_node`
  # itself); passing every survivor (not just one) lets `:ra` itself pick a
  # reachable one to route the membership-change commands through, the same
  # `ra_server_id() | [ra_server_id()]` flexibility `:ra.add_member/2` and
  # `:ra.remove_member/2` already support directly.
  #
  # Order matters and is NOT `start_or_join_replicated/3`'s "form a fresh
  # cluster" order — verified against `:ra`'s own growing-a-cluster
  # documentation (`deps/ra/README.md`, "Dynamically Changing Cluster
  # Membership"): add the member to the existing cluster's configuration
  # FIRST, then start the joining server itself with `initial_members` set
  # to just the survivor(s) — reversed, a freshly-started server with no
  # cluster membership entry yet has nothing to catch up from.
  @spec replace_member(String.t(), [node()], node(), node(), :ra_machine.machine()) ::
          :ok | {:error, term()}
  def replace_member(uid, survivor_nodes, dead_node, new_node, machine) do
    ensure_system_started()
    name = String.to_atom(uid)
    survivor_ids = Enum.map(survivor_nodes, &{name, &1})
    dead_id = {name, dead_node}
    new_id = {name, new_node}
    cluster_name = uid <> "_cluster"

    with {:ok, _reply, _leader} <- :ra.add_member(survivor_ids, new_id),
         :ok <- :ra.start_server(@system, cluster_name, new_id, machine, survivor_ids),
         {:ok, _reply, _leader} <- :ra.remove_member(survivor_ids, dead_id) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      {:timeout, _} -> {:error, :timeout}
    end
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/riptide/ra_cluster_test.exs --trace`
Expected: PASS, all tests including the pre-existing ones. The collapsed-node test expects `{:error, :already_member}` because `node()` is already a member of its own single-node cluster — this is expected and correct; it proves the call sequence executes against real `:ra` without crashing, not a successful 3-node repair (that's Step 5).

- [ ] **Step 5: Write the real multi-node proof**

Create `test/riptide/ra_cluster_replace_member_test.exs`:

```elixir
defmodule Riptide.RaClusterReplaceMemberTest do
  use ExUnit.Case, async: false

  @moduletag timeout: 60_000

  alias Riptide.Test.EchoMachine

  @peers [
    {:repl_a, "repl-a", ~c"127.0.0.40"},
    {:repl_b, "repl-b", ~c"127.0.0.41"},
    {:repl_c, "repl-c", ~c"127.0.0.42"}
  ]

  @replacement {:repl_d, "repl-d", ~c"127.0.0.43"}

  setup_all do
    unless Node.alive?() do
      {:ok, _pid} = Node.start(:"ra_cluster_replace_member_origin@127.0.0.1", :longnames)
    end

    :ok
  end

  test "replace_member/5 evicts a dead real member and joins a fresh real replacement, preserving data" do
    pa_args = Enum.flat_map(:code.get_path(), fn p -> [~c"-pa", p] end)
    all_specs = @peers ++ [@replacement]

    peers =
      for {alive_name, ordinal, host} <- all_specs do
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

    on_exit(fn ->
      Enum.each(peers, fn {pid, _node, _ordinal} ->
        if Process.alive?(pid) do
          try do
            :peer.stop(pid)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      Enum.each(all_specs, fn {_alive_name, ordinal, _host} ->
        File.rm_rf!(Path.join(File.cwd!(), ordinal))
      end)
    end)

    [{module, bytecode}] = Code.compile_file(__ENV__.file)

    for {_pid, node, _ordinal} <- peers do
      assert {:module, ^module} =
               :erpc.call(node, :code, :load_binary, [
                 module,
                 ~c"ra_cluster_replace_member_test.ex",
                 bytecode
               ])
    end

    nodes = Enum.map(peers, fn {_pid, node, _ordinal} -> node end)

    for {n1, n2} <- unique_pairs(nodes) do
      assert :erpc.call(n1, :net_kernel, :connect_node, [n2]) == true
    end

    for {_pid, node, _ordinal} <- peers do
      {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:ra])
    end

    [{_pid_a, node_a, _}, {_pid_b, node_b, _}, {_pid_c, node_c, _}, {_pid_d, node_d, _}] = peers
    original_nodes = [node_a, node_b, node_c]

    uid = "replace-member-real-" <> Uniq.UUID.uuid4()
    machine = {:module, EchoMachine, %{}}

    assert {:ok, _server_ids} =
             :erpc.call(node_a, Riptide.RaCluster, :start_or_join_replicated, [
               uid,
               original_nodes,
               machine
             ])

    name = String.to_atom(uid)

    # Write real data before the repair, to prove it survives.
    :erpc.call(node_a, Riptide.RaCluster, :process_command, [{name, node_a}, {:add, "a"}])

    # Kill node_c for real — the member being replaced.
    stop_peer_for(peers, node_c)

    survivor_nodes = [node_a, node_b]

    assert :ok =
             :erpc.call(node_a, Riptide.RaCluster, :replace_member, [
               uid,
               survivor_nodes,
               node_c,
               node_d,
               machine
             ])

    assert eventually(fn ->
             case :erpc.call(node_a, :ra, :members, [{name, node_a}]) do
               {:ok, members, _leader} ->
                 member_nodes = Enum.map(members, fn {_name, n} -> n end)
                 Enum.sort(member_nodes) == Enum.sort([node_a, node_b, node_d])

               _ ->
                 false
             end
           end)

    assert :erpc.call(node_d, Riptide.RaCluster, :server_alive?, [name])
    refute :erpc.call(node_a, Riptide.RaCluster, :member_alive?, [{name, node_c}])

    # No data loss: the write made before the repair is still there,
    # readable through the NEW member.
    assert :erpc.call(node_d, Riptide.RaCluster, :local_query, [{name, node_d}, & &1]) == ["a"]
  end

  defp stop_peer_for(peers, target_node) do
    {pid, ^target_node, _ordinal} = Enum.find(peers, fn {_pid, node, _ordinal} -> node == target_node end)

    try do
      :peer.stop(pid)
    catch
      :exit, _ -> :ok
    end
  end

  defp eventually(fun, attempts_left \\ 50) do
    cond do
      fun.() -> true
      attempts_left <= 1 -> false
      true ->
        Process.sleep(100)
        eventually(fun, attempts_left - 1)
    end
  end

  defp unique_pairs(list) do
    for {a, i} <- Enum.with_index(list),
        {b, j} <- Enum.with_index(list),
        i < j,
        do: {a, b}
  end
end
```

- [ ] **Step 6: Run it**

Run: `mix test test/riptide/ra_cluster_replace_member_test.exs --trace`
Expected: PASS. Run it 3 times in a row to confirm no flakiness and clean cleanup (no leftover `repl-*` directories in the repo root after each run).

- [ ] **Step 7: Run the full suite**

Run: `mix test`
Expected: PASS, 0 failures.

- [ ] **Step 8: Commit**

```bash
git add lib/riptide/ra_cluster.ex test/riptide/ra_cluster_test.exs test/riptide/ra_cluster_replace_member_test.exs
git commit -m "Add RaCluster.replace_member/5: real Ra membership-change repair primitive"
```

---

### Task 5: `Riptide.Stream.Placement` cache invalidation via PubSub

**Files:**
- Modify: `lib/riptide/stream/placement.ex`
- Test: `test/riptide/stream/placement_test.exs`

**Interfaces:**
- Consumes: `Phoenix.PubSub` (already started before this `GenServer` in `Riptide.Application`'s children list), `RaCluster.uid_for/1`.
- Produces: a `{:stream_placement_changed, stream_id, new_nodes}` message contract on the `"stream_placement_changed"` PubSub topic. Task 6's healer broadcasts this after every successful repair.

- [ ] **Step 1: Write the failing test**

Add to `test/riptide/stream/stream_supervisor_test.exs` a new test (this module already has the right aliases and `on_exit`/cleanup pattern):

```elixir
  test "the local cache is corrected when a stream_placement_changed PubSub message arrives" do
    stream_id = "stream-#{System.unique_integer([:positive])}"
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id) end)

    assert StreamSupervisor.ensure_ready(stream_id) == :ok
    uid = Riptide.RaCluster.uid_for(stream_id)
    original_server_ids = Riptide.Stream.Placement.server_ids!(stream_id)
    assert original_server_ids == [{String.to_atom(uid), node()}]

    fake_new_node = :"fake-replacement@nowhere"

    Phoenix.PubSub.broadcast(
      Riptide.PubSub,
      "stream_placement_changed",
      {:stream_placement_changed, stream_id, [fake_new_node]}
    )

    # PubSub delivery is async even within one BEAM — poll briefly rather
    # than asserting immediately.
    assert Enum.any?(1..20, fn _ ->
             Process.sleep(10)
             Riptide.Stream.Placement.server_ids!(stream_id) == [{String.to_atom(uid), fake_new_node}]
           end)
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/riptide/stream/stream_supervisor_test.exs --trace`
Expected: FAIL — the cache never updates because `Riptide.Stream.Placement` isn't subscribed to the topic yet, so the poll loop times out without ever seeing the fake node.

- [ ] **Step 3: Subscribe and handle the invalidation message**

Modify `lib/riptide/stream/placement.ex`:

Change `init/1`:

```elixir
  @impl GenServer
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    Phoenix.PubSub.subscribe(Riptide.PubSub, "stream_placement_changed")
    {:ok, %{}}
  end
```

Add a new `handle_info/2` clause, placed after `init/1` and before the module's existing `@doc` for `ensure_started/4`:

```elixir
  # Corrects this node's cached server ids the moment `Riptide.Stream.ReplicaHealer`
  # (Phase 3d-ii) repairs a stream elsewhere in the fleet — without this, a
  # node that already cached the old (now partially dead) server ids would
  # keep them until it happened to restart, per this module's own
  # cache-forever design (see moduledoc). Overwrites directly rather than
  # evicting, since the correct value is already known from the broadcast —
  # no need to force a re-resolution round-trip through the placement
  # cluster.
  @impl GenServer
  def handle_info({:stream_placement_changed, stream_id, new_nodes}, state) do
    uid = RaCluster.uid_for(stream_id)
    server_ids = Enum.map(new_nodes, &{String.to_atom(uid), &1})
    :ets.insert(@table, {stream_id, server_ids})
    {:noreply, state}
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/riptide/stream/stream_supervisor_test.exs --trace`
Expected: PASS, all tests including the pre-existing ones.

- [ ] **Step 5: Run the full suite**

Run: `mix test`
Expected: PASS, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add lib/riptide/stream/placement.ex test/riptide/stream/stream_supervisor_test.exs
git commit -m "Riptide.Stream.Placement: invalidate cached server ids via PubSub broadcast"
```

---

### Task 6: `Riptide.Stream.ReplicaHealer` — the sweep loop, wired into `Riptide.Application`

**Files:**
- Create: `lib/riptide/stream/replica_healer.ex`
- Modify: `lib/riptide/application.ex`
- Test: `test/riptide/stream/replica_healer_test.exs`

**Interfaces:**
- Consumes: `Riptide.Placement.list_all/1`, `replace_member/4` (Task 2); `RaCluster.member_alive?/1`, `placement_leader?/0`, `replace_member/5`, `uid_for/1` (Tasks 3-4); `Riptide.Placement.select_nodes/2` (existing, Phase 3c-i).
- Produces: `ReplicaHealer.pick_replacement/2` (`([node()], [node()]) -> node() | nil`) and `ReplicaHealer.sweep/0` (`() -> :ok`), both public for direct testing without waiting on the timer. Consumed by Task 7's integration test.

- [ ] **Step 1: Write the failing unit tests for `pick_replacement/2`**

Create `test/riptide/stream/replica_healer_test.exs`:

```elixir
defmodule Riptide.Stream.ReplicaHealerTest do
  use ExUnit.Case, async: true

  alias Riptide.Stream.ReplicaHealer

  describe "pick_replacement/2" do
    test "picks a live node not already among the current members" do
      result = ReplicaHealer.pick_replacement([:a, :b], [:a, :b, :c, :d])
      assert result in [:c, :d]
    end

    test "returns nil when every live node is already a current member" do
      assert ReplicaHealer.pick_replacement([:a, :b, :c], [:a, :b, :c]) == nil
    end

    test "returns nil when there are no live candidate nodes at all" do
      assert ReplicaHealer.pick_replacement([:a, :b], []) == nil
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/riptide/stream/replica_healer_test.exs --trace`
Expected: FAIL — `Riptide.Stream.ReplicaHealer` doesn't exist yet.

- [ ] **Step 3: Create the `ReplicaHealer` module**

Create `lib/riptide/stream/replica_healer.ex`:

```elixir
defmodule Riptide.Stream.ReplicaHealer do
  @moduledoc """
  Fully automatic background repair for a stream's replica set — see Phase
  3d-ii design spec for the full motivation. Runs only on the 3 placement
  ordinals (wired in `Riptide.Application`, same gating as
  `Riptide.RaCluster.ensure_placement_cluster_started/0`), and only the
  placement cluster's current Raft leader ever acts on a given sweep
  (`RaCluster.placement_leader?/0`) — reusing that cluster's own existing
  leader election as single-writer safety, rather than a new coordination
  mechanism. No operator action is required in the steady-state case.
  """

  use GenServer
  require Logger

  alias Riptide.Placement
  alias Riptide.RaCluster
  alias Riptide.Stream.RaMachine

  @sweep_interval_ms 30_000
  @stream_machine {:module, RaMachine, %{retention: :infinity}}

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl GenServer
  def init(:ok) do
    schedule_sweep()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    if RaCluster.placement_leader?() do
      sweep()
    end

    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep do
    interval = Application.get_env(:riptide, :replica_healer_sweep_interval_ms, @sweep_interval_ms)
    Process.send_after(self(), :sweep, interval)
  end

  @doc """
  One full pass over every known stream: find any with exactly one dead
  member and repair it. Public (not just reachable via the timer) so tests
  can invoke it directly rather than waiting on a real interval.
  """
  @spec sweep() :: :ok
  def sweep do
    Placement.list_all()
    |> Enum.each(&maybe_repair/1)
  end

  defp maybe_repair({stream_id, nodes}) do
    uid = RaCluster.uid_for(stream_id)
    name = String.to_atom(uid)
    dead_nodes = Enum.reject(nodes, &RaCluster.member_alive?({name, &1}))

    case dead_nodes do
      [dead_node] -> repair(stream_id, uid, nodes, dead_node)
      _ -> :ok
    end
  end

  defp repair(stream_id, uid, nodes, dead_node) do
    survivor_nodes = nodes -- [dead_node]

    case pick_replacement(nodes) do
      nil ->
        :ok

      new_node ->
        case RaCluster.replace_member(uid, survivor_nodes, dead_node, new_node, @stream_machine) do
          :ok ->
            new_nodes = Placement.replace_member(stream_id, dead_node, new_node)

            Phoenix.PubSub.broadcast(
              Riptide.PubSub,
              "stream_placement_changed",
              {:stream_placement_changed, stream_id, new_nodes}
            )

            Logger.info(
              "ReplicaHealer repaired #{stream_id}: replaced #{inspect(dead_node)} with #{inspect(new_node)}"
            )

          {:error, reason} ->
            Logger.warning(
              "ReplicaHealer failed to repair #{stream_id} (dead: #{inspect(dead_node)}): #{inspect(reason)}"
            )
        end
    end
  end

  @doc """
  Picks a live fleet node to replace a dead member with — a candidate not
  already among `current_nodes`, chosen the same random-selection way
  `Riptide.Placement.propose_nodes/2` already picks a new stream's initial
  replicas. `live_nodes` defaults to `Node.list()` but is overridable for
  tests, mirroring `propose_nodes/2`'s own `peers \\\\ Node.list()` pattern.
  """
  @spec pick_replacement([node()], [node()]) :: node() | nil
  def pick_replacement(current_nodes, live_nodes \\ Node.list()) do
    case Placement.select_nodes(live_nodes -- current_nodes, 1) do
      [node] -> node
      [] -> nil
    end
  end
end
```

- [ ] **Step 4: Run the unit tests to verify they pass**

Run: `mix test test/riptide/stream/replica_healer_test.exs --trace`
Expected: PASS.

- [ ] **Step 5: Wire `ReplicaHealer` into `Riptide.Application`**

Modify `lib/riptide/application.ex` — change `placement_bootstrap_children/0`:

```elixir
  defp placement_bootstrap_children do
    if System.get_env("HOSTNAME") in Riptide.RaCluster.placement_ordinals() do
      [
        {Task, &Riptide.RaCluster.ensure_placement_cluster_started/0},
        Riptide.Stream.ReplicaHealer
      ]
    else
      []
    end
  end
```

- [ ] **Step 6: Run the full suite**

Run: `mix test`
Expected: PASS, 0 failures. `Riptide.Stream.ReplicaHealer` now starts as part of the application in every test run (since `test_helper.exs` runs on a single collapsed node that's always a placement ordinal — see its own comments) but its sweep only ever runs on its own 30s timer, which no test waits for; nothing in the existing suite should be affected.

- [ ] **Step 7: Commit**

```bash
git add lib/riptide/stream/replica_healer.ex lib/riptide/application.ex test/riptide/stream/replica_healer_test.exs
git commit -m "Add Riptide.Stream.ReplicaHealer: automatic stream replica repair sweep"
```

---

### Task 7: Real multi-node proof — end-to-end automatic repair

**Files:**
- Create: `test/riptide/stream/replica_healer_cluster_test.exs`

**Interfaces:**
- Consumes: everything from Tasks 1-6 — `Riptide.Stream.StreamServer.start_link/1`/`append/2`/`get_since/2` (existing), `Riptide.Stream.ReplicaHealer.sweep/0` (Task 6), `Riptide.Placement.lookup/1` (existing).
- Produces: nothing further downstream — this is the real proof the whole chain works together against genuinely distinct nodes, extending the established `:peer`-based recipe (`test/riptide/stream/stream_placement_cluster_test.exs`) with a real kill + real automatic repair in the middle.

- [ ] **Step 1: Write the test**

Create `test/riptide/stream/replica_healer_cluster_test.exs`:

```elixir
defmodule Riptide.Stream.ReplicaHealerClusterTest do
  use ExUnit.Case, async: false

  @moduletag timeout: 60_000

  @peers [
    {:healer_a, "riptide-0", ~c"127.0.0.50"},
    {:healer_b, "riptide-1", ~c"127.0.0.51"},
    {:healer_c, "riptide-2", ~c"127.0.0.52"}
  ]

  @replacement {:healer_d, "healer-d", ~c"127.0.0.53"}

  setup_all do
    unless Node.alive?() do
      {:ok, _pid} = Node.start(:"replica_healer_cluster_origin@127.0.0.1", :longnames)
    end

    :ok
  end

  test "a stream's dead replica is automatically detected and repaired, with no data loss" do
    pa_args = Enum.flat_map(:code.get_path(), fn p -> [~c"-pa", p] end)
    all_specs = @peers ++ [@replacement]

    peers =
      for {alive_name, ordinal, host} <- all_specs do
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

    on_exit(fn ->
      Enum.each(peers, fn {pid, _node, _ordinal} ->
        if Process.alive?(pid) do
          try do
            :peer.stop(pid)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      Enum.each(all_specs, fn {_alive_name, ordinal, _host} ->
        File.rm_rf!(Path.join(File.cwd!(), ordinal))
      end)
    end)

    [{module, bytecode}] = Code.compile_file(__ENV__.file)

    for {_pid, node, _ordinal} <- peers do
      assert {:module, ^module} =
               :erpc.call(node, :code, :load_binary, [
                 module,
                 ~c"replica_healer_cluster_test.ex",
                 bytecode
               ])
    end

    nodes = Enum.map(peers, fn {_pid, node, _ordinal} -> node end)
    ordinal_to_node = Map.new(peers, fn {_pid, node, ordinal} -> {ordinal, node} end)
    resolve_fun = fn ordinal -> Map.fetch!(ordinal_to_node, ordinal) end

    for {_pid, node, _ordinal} <- peers do
      :erpc.call(node, Application, :put_env, [:riptide, :ordinal_resolver, resolve_fun])
    end

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

    [{_pid_a, node_a, _}, {_pid_b, node_b, _}, {_pid_c, node_c, _}, {_pid_d, _node_d, _}] = peers
    placement_peers = Enum.take(peers, 3)

    results =
      Enum.map(placement_peers, fn {_pid, node, _ordinal} ->
        :erpc.call(node, Riptide.RaCluster, :attempt_start_placement_cluster, [resolve_fun])
      end)

    assert Enum.any?(results, &(&1 == :ok))

    for {_pid, node, _ordinal} <- peers do
      {:ok, _} = start_unlinked(node, Riptide.Stream.Placement, :start_link, [[]])
    end

    for {_pid, node, _ordinal} <- peers do
      {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:phoenix_pubsub])
      {:ok, _} = start_unlinked(node, Phoenix.PubSub.Supervisor, :start_link, [[name: Riptide.PubSub]])
    end

    stream_id = "healer-cluster-" <> Uniq.UUID.uuid4()

    # Explicitly assign the stream to exactly the 3 placement-ordinal nodes
    # (not left to propose_nodes/2's own randomness) so we know precisely
    # which peer to kill and which stays as the extra fleet node available
    # as a replacement candidate for pick_replacement/2.
    original_nodes = [node_a, node_b, node_c]
    assert Enum.sort(:erpc.call(node_a, Riptide.Placement, :assign, [stream_id, original_nodes])) ==
             Enum.sort(original_nodes)

    assert :ok = :erpc.call(node_a, Riptide.Stream.StreamSupervisor, :ensure_ready, [stream_id])

    graph = :erpc.call(node_a, RDF.Graph, :new, [])
    event = :erpc.call(node_a, Riptide.Event, :new, [stream_id, :replace, graph])
    stamped = :erpc.call(node_a, Riptide.Stream.StreamServer, :append, [stream_id, event])
    assert stamped.sequence == 1

    # Kill node_c for real — the replica being replaced.
    stop_peer_for(peers, node_c)

    # Run the sweep directly from node_a rather than waiting on the real
    # 30s timer. `ReplicaHealer.sweep/0` itself performs no leader check —
    # only the timer-driven `handle_info(:sweep, state)` gates on
    # `RaCluster.placement_leader?/0` before calling `sweep/0` — so calling
    # `sweep/0` directly here always attempts the repair regardless of
    # node_a's actual leadership status; this is a deliberate test-only
    # bypass of the production gating path, not a claim about node_a being
    # the leader. The retry loop below exists for a different reason: the
    # kill in the previous step needs a moment to actually disconnect
    # before `RaCluster.member_alive?/1` reliably observes it as dead.
    assert eventually(fn ->
             :erpc.call(node_a, Riptide.Stream.ReplicaHealer, :sweep, []) == :ok and
               Enum.sort(:erpc.call(node_a, Riptide.Placement, :lookup, [stream_id])) !=
                 Enum.sort(original_nodes)
           end)

    repaired_nodes = :erpc.call(node_a, Riptide.Placement, :lookup, [stream_id])
    assert length(repaired_nodes) == 3
    refute node_c in repaired_nodes
    assert node_a in repaired_nodes
    assert node_b in repaired_nodes

    [new_node] = repaired_nodes -- [node_a, node_b]

    # No data loss: the write made before the repair is still there,
    # readable through the fresh replacement.
    assert :ok = :erpc.call(new_node, Riptide.Stream.StreamSupervisor, :ensure_ready, [stream_id])
    {:ok, read_back} = :erpc.call(new_node, Riptide.Stream.StreamServer, :get_since, [stream_id, 0])
    assert [%{sequence: 1}] = read_back
  end

  defp stop_peer_for(peers, target_node) do
    {pid, ^target_node, _ordinal} =
      Enum.find(peers, fn {_pid, node, _ordinal} -> node == target_node end)

    try do
      :peer.stop(pid)
    catch
      :exit, _ -> :ok
    end
  end

  defp start_unlinked(node, mod, fun, args, timeout \\ 5_000) do
    parent = self()

    spawn(node, fn ->
      result = apply(mod, fun, args)
      send(parent, {:start_unlinked_result, result})
      Process.sleep(:infinity)
    end)

    receive do
      {:start_unlinked_result, result} -> result
    after
      timeout -> {:error, :timeout}
    end
  end

  defp eventually(fun, attempts_left \\ 50) do
    cond do
      fun.() -> true
      attempts_left <= 1 -> false
      true ->
        Process.sleep(200)
        eventually(fun, attempts_left - 1)
    end
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

Run: `mix test test/riptide/stream/replica_healer_cluster_test.exs --trace`
Expected: PASS. Run it 3 times in a row to confirm no flakiness and clean cleanup (no leftover `riptide-*`/`healer-d` directories in the repo root after each run).

- [ ] **Step 3: Run the full suite**

Run: `mix test`
Expected: PASS, 0 failures.

- [ ] **Step 4: Commit**

```bash
git add test/riptide/stream/replica_healer_cluster_test.exs
git commit -m "Add real multi-node proof: automatic stream replica repair end-to-end"
```

---

### Task 8: Live proof against a real GKE StatefulSet

**Files:**
- No new files — this task operates against a disposable deployment using the existing `k8s/` manifests.

**Interfaces:**
- Consumes: the already-deployed `k8s/*.yaml` manifests, a built Docker image including this plan's Tasks 1-7.
- Produces: a written verification record (this task's own report) — no code.

**Note before starting:** deploying this live requires the operator's explicit go-ahead — ask before creating any real cluster resources, following the same convention as every prior live-proof task this sub-project has done.

- [ ] **Step 1: Build and push a fresh throwaway-tagged image, deploy to a disposable namespace with 5 replicas**

```bash
kubectl create namespace riptide-phase-3d-ii-proof
kubectl config set-context --current --namespace=riptide-phase-3d-ii-proof
```

```bash
sed -e 's|ghcr.io/openfaster-standard/riptide:latest|ghcr.io/openfaster-standard/riptide:phase-3d-ii-proof|' \
    -e 's|replicas: 3|replicas: 5|' \
    k8s/statefulset.yaml | kubectl apply -f -
```

If ghcr.io pull fails with `401 Unauthorized`, fix it the same way as every prior live proof this sub-project has hit:

```bash
kubectl create secret docker-registry ghcr-pull-secret \
  --docker-server=ghcr.io \
  --docker-username=<your github username> \
  --docker-password="$(gh auth token)"
kubectl patch statefulset riptide --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/imagePullSecrets","value":[{"name":"ghcr-pull-secret"}]}]'
kubectl delete pod riptide-0 riptide-1 riptide-2 riptide-3 riptide-4 --wait=false
```

Run: `kubectl rollout status statefulset/riptide --timeout=180s`
Expected: all 5 pods reach `Ready`.

- [ ] **Step 2: Create a stream assigned to a real pod, then kill that pod**

```bash
kubectl exec riptide-0 -- bin/riptide rpc "IO.inspect(Riptide.Stream.StreamSupervisor.ensure_ready(\"live-heal-proof-stream\")); IO.inspect(Riptide.Stream.Placement.server_ids!(\"live-heal-proof-stream\"))"
```

Expected: `:ok`, then a 3-element `{name, node}` list. Note the 3 assigned pods from the node atoms' IPs (`kubectl get pods -o wide`). Write one real event, then force-kill one of the 3 assigned pods (not `riptide-0`, to keep issuing commands from a live pod):

```bash
kubectl exec riptide-0 -- bin/riptide rpc "IO.inspect(Riptide.Stream.StreamServer.append(\"live-heal-proof-stream\", Riptide.Event.new(\"live-heal-proof-stream\", :replace, RDF.Graph.new())))"
kubectl delete pod <one-of-the-3-assigned-pods> --grace-period=0 --force
kubectl rollout status statefulset/riptide --timeout=180s
```

- [ ] **Step 3: Wait for automatic repair and verify no data loss**

Wait up to the sweep interval (default 30s) plus rollout time, then:

```bash
kubectl exec riptide-0 -- bin/riptide rpc "IO.inspect(Riptide.Placement.lookup(\"live-heal-proof-stream\"))"
```

Expected: a 3-element node list that no longer includes the killed pod's original identity, and does include a live pod not in the original assignment (the fleet's spare capacity, since RF=3 with 5 real pods leaves 2 spares) — with **no operator action taken to produce this**, only waiting. Confirm no data loss by reading back through the new member:

```bash
kubectl exec <the-new-member-pod> -- bin/riptide rpc "IO.inspect(Riptide.Stream.StreamServer.get_since(\"live-heal-proof-stream\", 0))"
```

Expected: `{:ok, [%Riptide.Event{sequence: 1, ...}]}`.

- [ ] **Step 4: Tear down**

```bash
kubectl delete namespace riptide-phase-3d-ii-proof
kubectl config set-context --current --namespace=default
```

Poll `kubectl get namespace riptide-phase-3d-ii-proof` until `NotFound`. Delete the throwaway image tag from ghcr.io and the local docker image. Leave nothing behind.

- [ ] **Step 5: Record the results**

Write a short summary (for Task 9's `PROGRESS.md` update and the PR description) of what was directly observed at Steps 2-3 — the actual command output, not a paraphrased summary.

---

### Task 9: Full verification + `PROGRESS.md` + wrap-up

**Files:**
- Modify: `PROGRESS.md`

**Interfaces:**
- Consumes: everything from Tasks 1-8, including Task 8's recorded live-proof results.
- Produces: nothing further downstream — terminal task.

- [ ] **Step 1: Run the full test suite**

Run: `mix test`
Expected: PASS, 0 failures — including every test added in Tasks 1-7 and every pre-existing test unaffected.

- [ ] **Step 2: Run Credo and formatter checks**

Run: `mix credo --strict && mix format --check-formatted`
Expected: both clean. Fix anything flagged and re-run.

- [ ] **Step 3: Update `PROGRESS.md`**

In the `## 3. Clustering / horizontal scale / HA` section, replace the current 3d-ii placeholder text (the scope-correction paragraph added when the design spec was written) with:

```markdown
  - **3d-ii — Automatic stream replica healing.** A stream with exactly one dead replica (of
    RF=3) is now detected and repaired automatically, with zero operator action — see
    `docs/superpowers/specs/2026-08-25-phase-3d-ii-replica-healing-design.md`. **Shipped
    2026-08-25.** `Riptide.Stream.ReplicaHealer` sweeps every known stream on a timer, gated to
    only the placement cluster's current Raft leader (reusing its existing leader election for
    single-writer safety, no new coordination mechanism), and on finding a dead member: joins a
    live replacement into the stream's real `:ra` cluster (`RaCluster.replace_member/5`),
    updates the durable placement assignment, and broadcasts a PubSub invalidation so no node's
    cache keeps routing to the dead replica. Live-proved against a real 5-pod GKE StatefulSet
    (RF=3): a killed replica pod was automatically replaced with no operator action and no data
    loss.
```

Change the `**Status**:` line to reflect Phase 3d-ii shipped alongside 3d-i.

- [ ] **Step 4: Commit**

```bash
git add PROGRESS.md
git commit -m "Mark Phase 3d-ii shipped in PROGRESS.md"
```
