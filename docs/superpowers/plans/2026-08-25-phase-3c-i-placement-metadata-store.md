# Phase 3c-i — Placement Metadata Store Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A small, dedicated `:ra` cluster durably recording `stream_id → [replica nodes]`, so a placement decision survives fleet growth — the foundation the rest of Phase 3c builds on.

**Architecture:** A new `Riptide.Placement` namespace (mirroring the existing `Riptide.Stream` pattern): `PlacementMachine` is the `:ra_machine` (a plain `stream_id → node-list` map, one idempotent `assign` command), `Riptide.Placement` is the client API. `Riptide.RaCluster` (the sole `:ra`-calling module) gains multi-member cluster bootstrap for a small, fixed-membership cluster (3 hardcoded StatefulSet ordinals), bootstrapped via DNS-resolved current node identities with retry until quorum.

**Tech Stack:** Elixir, `:ra` 2.15.4 (multi-member `start_cluster/2,3` — first use of this API shape in Riptide), OTP 25's `:peer` module (test-only, reusing Phase 3b's verified recipe).

**Spec:** `docs/superpowers/specs/2026-08-25-phase-3c-i-placement-metadata-design.md`

## Global Constraints

- New functions are `Riptide.Placement.PlacementMachine`/`Riptide.Placement` (client API) — mirrors `Riptide.Stream.RaMachine`/`Riptide.Stream.StreamServer`'s existing split.
- `Riptide.RaCluster` remains the sole module that calls `:ra` directly — no second `:ra`-touching module.
- Metadata cluster membership is fixed at exactly 3 members (`riptide-0`, `riptide-1`, `riptide-2`), never mirrored 1:1 with the whole fleet.
- `PlacementMachine`'s `assign` command is idempotent: a proposal for an already-assigned `stream_id` returns the *existing* assignment, never overwrites it. Reassignment/rebalancing is out of scope entirely for this phase.
- No local read-cache/projection layer — reads go via a direct `:ra` query per lookup.
- The ordinal→current-node-identity resolution step is an injectable function (not hardcoded to real DNS calls), so local tests can substitute a stub while production uses the real DNS-based resolver.
- Automatic reconciliation of the metadata cluster's own membership after identity drift is explicitly out of scope (Phase 3d) — manual-only for now.
- Replication factor hardcoded to `3`; node selection is `Enum.shuffle/1` + `Enum.take/2` — deliberately simple, no constraint-awareness.

---

### Task 1: `Riptide.Placement.PlacementMachine`

**Files:**
- Create: `lib/riptide/placement/placement_machine.ex`
- Test: `test/riptide/placement/placement_machine_test.exs`

**Interfaces:**
- Consumes: nothing new.
- Produces: `PlacementMachine.init/1`, `PlacementMachine.apply/3` (the `:ra_machine` behaviour callbacks, consumed by `:ra` itself once wired into a real cluster in Task 2), `PlacementMachine.get/2 :: (state(), String.t()) -> [node()] | nil` (consumed by `Riptide.Placement.lookup/1,2` in Task 3).

- [ ] **Step 1: Write the failing tests**

Create `test/riptide/placement/placement_machine_test.exs`:

```elixir
defmodule Riptide.Placement.PlacementMachineTest do
  use ExUnit.Case, async: true

  alias Riptide.Placement.PlacementMachine

  test "init/1 starts with an empty map" do
    assert PlacementMachine.init(%{}) == %{}
  end

  test "apply/3 stores a new stream's node list" do
    state = PlacementMachine.init(%{})

    {new_state, reply, effects} =
      PlacementMachine.apply(%{index: 1}, {:assign, "s1", [:a, :b, :c]}, state)

    assert new_state == %{"s1" => [:a, :b, :c]}
    assert reply == [:a, :b, :c]
    assert effects == []
  end

  test "apply/3 is idempotent: a second proposal for an already-assigned stream returns the existing assignment" do
    state = PlacementMachine.init(%{})
    {state, _reply, _} = PlacementMachine.apply(%{index: 1}, {:assign, "s1", [:a, :b, :c]}, state)

    {new_state, reply, effects} =
      PlacementMachine.apply(%{index: 2}, {:assign, "s1", [:x, :y, :z]}, state)

    assert new_state == %{"s1" => [:a, :b, :c]}
    assert reply == [:a, :b, :c]
    assert effects == []
  end

  test "apply/3 stores two different streams independently" do
    state = PlacementMachine.init(%{})
    {state, _, _} = PlacementMachine.apply(%{index: 1}, {:assign, "s1", [:a, :b, :c]}, state)
    {state, _, _} = PlacementMachine.apply(%{index: 2}, {:assign, "s2", [:d, :e, :f]}, state)

    assert state == %{"s1" => [:a, :b, :c], "s2" => [:d, :e, :f]}
  end

  test "get/2 returns the assigned nodes for a known stream" do
    assert PlacementMachine.get(%{"s1" => [:a, :b, :c]}, "s1") == [:a, :b, :c]
  end

  test "get/2 returns nil for an unknown stream" do
    assert PlacementMachine.get(%{}, "unknown") == nil
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/riptide/placement/placement_machine_test.exs`
Expected: FAIL — `Riptide.Placement.PlacementMachine` module not found / undefined

- [ ] **Step 3: Implement `PlacementMachine`**

Create `lib/riptide/placement/placement_machine.ex`:

```elixir
defmodule Riptide.Placement.PlacementMachine do
  @moduledoc """
  The `:ra_machine` for Riptide's placement metadata cluster — a small,
  fixed-membership Ra cluster (see `Riptide.RaCluster.placement_server_id/1,2`)
  recording which nodes host each stream's Ra replicas. Pure and process-free
  by design, mirroring `Riptide.Stream.RaMachine`: `init/1`/`apply/3` are the
  only functions Ra itself calls; `get/2` is a plain query function run via
  `Riptide.RaCluster.consistent_query/2`.
  """
  @behaviour :ra_machine

  @type state :: %{String.t() => [node()]}

  @impl :ra_machine
  def init(_config), do: %{}

  # Idempotent by construction — see Phase 3c-i design spec §4. Since every
  # command is serialized through Raft consensus, whichever proposal for a
  # given stream_id lands in the log first wins; a later, different proposal
  # for the same already-assigned stream_id is silently ignored and the
  # caller gets back the existing (winning) assignment instead of an error.
  # This makes concurrent stream-creation races safe with no extra locking.
  @impl :ra_machine
  def apply(_meta, {:assign, stream_id, proposed_nodes}, state) do
    case Map.fetch(state, stream_id) do
      {:ok, existing_nodes} ->
        {state, existing_nodes, []}

      :error ->
        new_state = Map.put(state, stream_id, proposed_nodes)
        {new_state, proposed_nodes, []}
    end
  end

  @spec get(state(), String.t()) :: [node()] | nil
  def get(state, stream_id) do
    Map.get(state, stream_id)
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/riptide/placement/placement_machine_test.exs`
Expected: PASS (all 6 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/riptide/placement/placement_machine.ex test/riptide/placement/placement_machine_test.exs
git commit -m "Add Riptide.Placement.PlacementMachine, the placement metadata state machine"
```

---

### Task 2: `Riptide.RaCluster` multi-member bootstrap for the placement cluster

**Files:**
- Modify: `lib/riptide/ra_cluster.ex`
- Modify: `test/riptide/ra_cluster_test.exs`

**Interfaces:**
- Consumes: `Riptide.Placement.PlacementMachine` (Task 1, referenced by module name in the `machine:` config field — no function calls).
- Produces: `RaCluster.placement_ordinals/0 :: [String.t()]`, `RaCluster.placement_server_id/1,2 :: (String.t(), (String.t() -> node())) -> :ra.server_id()`, `RaCluster.default_ordinal_resolver/1 :: String.t() -> node()` (public — Task 3's `Riptide.Placement` references it as a default argument value), `RaCluster.attempt_start_placement_cluster/0,1 :: (String.t() -> node()) -> :ok | {:error, :cluster_not_formed}`, `RaCluster.ensure_placement_cluster_started/0,1,2 :: (pos_integer(), (-> :ok | {:error, term()})) -> :ok` (consumed by Task 4's application-boot wiring and integration test).

- [ ] **Step 1: Write the failing tests**

Add to `test/riptide/ra_cluster_test.exs` (existing `async: true` module — none of these new tests mutate shared OS/process state, so they're safe to add here):

```elixir
  describe "placement_ordinals/0 and placement_server_id/1,2" do
    test "placement_ordinals/0 returns exactly the 3 fixed ordinals" do
      assert RaCluster.placement_ordinals() == ["riptide-0", "riptide-1", "riptide-2"]
    end

    test "placement_server_id/2 combines the placement cluster name with the resolver's result" do
      resolve_fun = fn "riptide-1" -> :"riptide@10.0.0.5" end

      assert RaCluster.placement_server_id("riptide-1", resolve_fun) ==
               {:riptide_placement, :"riptide@10.0.0.5"}
    end
  end

  describe "ensure_placement_cluster_started/2" do
    test "retries the attempt function until it succeeds" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      attempt_fun = fn ->
        count = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
        if count < 2, do: {:error, :cluster_not_formed}, else: :ok
      end

      assert RaCluster.ensure_placement_cluster_started(1, attempt_fun) == :ok
      assert Agent.get(counter, & &1) == 3
    end

    test "succeeds immediately if the first attempt succeeds" do
      attempt_fun = fn -> :ok end
      assert RaCluster.ensure_placement_cluster_started(1, attempt_fun) == :ok
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/riptide/ra_cluster_test.exs`
Expected: FAIL — `RaCluster.placement_ordinals/0 is undefined`, etc.

- [ ] **Step 3: Implement the new `RaCluster` functions**

In `lib/riptide/ra_cluster.ex`, add (after `uid_for/1`, before `start_or_restart/2` — placement near the other pure/naming helpers):

```elixir
  # Fixed, not derived from fleet size — see Phase 3c-i design spec §2/§5. The
  # metadata cluster stays this exact size regardless of how large the overall
  # fleet grows.
  @placement_ordinals ["riptide-0", "riptide-1", "riptide-2"]
  @placement_cluster_name :riptide_placement
  @placement_uid "riptide_placement"

  @spec placement_ordinals() :: [String.t()]
  def placement_ordinals, do: @placement_ordinals

  @spec placement_server_id(String.t(), (String.t() -> node())) :: :ra.server_id()
  def placement_server_id(ordinal, resolve_fun \\ &default_ordinal_resolver/1) do
    {@placement_cluster_name, resolve_fun.(ordinal)}
  end

  # Resolves a StatefulSet ordinal to its *current* Erlang node identity via
  # the headless Service's DNS, mirroring exactly how `Cluster.Strategy.
  # Kubernetes.DNS` (see `config/runtime.exs`) already resolves peers for
  # libcluster. Public (not private) so `Riptide.Placement`'s client
  # functions can reference it as their own default argument value.
  @spec default_ordinal_resolver(String.t()) :: node()
  def default_ordinal_resolver(ordinal) do
    headless_service = System.get_env("RIPTIDE_HEADLESS_SERVICE", "riptide-headless")
    hostname = String.to_charlist("#{ordinal}.#{headless_service}")

    {:ok, {:hostent, _, _, _, _, [ip | _]}} = :inet.gethostbyname(hostname)
    ip_string = ip |> :inet.ntoa() |> to_string()
    String.to_atom("riptide@#{ip_string}")
  end
```

Add (near the end of the module, after `server_alive?/1`):

```elixir
  # Retries indefinitely until the placement cluster is formed — intended to
  # be started as a fire-and-forget background task at application boot (see
  # Task 4), not called synchronously from a request path. StatefulSet pods
  # start ordinally by default, so early attempts legitimately fail while
  # sibling ordinals aren't yet reachable; `attempt_fun` returning
  # `{:error, :cluster_not_formed}` is the expected, retriable outcome during
  # that startup window, not a bug.
  @spec ensure_placement_cluster_started(pos_integer(), (-> :ok | {:error, term()})) :: :ok
  def ensure_placement_cluster_started(
        retry_interval_ms \\ 1000,
        attempt_fun \\ &attempt_start_placement_cluster/0
      ) do
    case attempt_fun.() do
      :ok ->
        :ok

      {:error, _reason} ->
        Process.sleep(retry_interval_ms)
        ensure_placement_cluster_started(retry_interval_ms, attempt_fun)
    end
  end

  # A single attempt to form (or rejoin) the placement cluster. Safe to call
  # redundantly from multiple ordinals concurrently, and safe to call again
  # on a routine pod restart when the cluster is already running elsewhere —
  # `:ra.start_cluster/2`'s own per-member `{:error, {:already_started, _}}`
  # handling (internal to `:ra`, not surfaced here) means an already-running
  # sibling member is simply not double-started, not an error condition for
  # this call as a whole. Uses the same deterministic, non-random uid for
  # every member's config (`@placement_uid`) — each member's data still lives
  # in a distinct, non-colliding directory because it's nested under that
  # node's own HOSTNAME-scoped data_dir (see `RaCluster.data_dir/0`), so a
  # shared uid string across members is correct here, not a collision risk.
  @spec attempt_start_placement_cluster((String.t() -> node())) :: :ok | {:error, :cluster_not_formed}
  def attempt_start_placement_cluster(resolve_fun \\ &default_ordinal_resolver/1) do
    ensure_system_started()

    member_ids = Enum.map(@placement_ordinals, &placement_server_id(&1, resolve_fun))

    configs =
      Enum.map(member_ids, fn id ->
        %{
          id: id,
          uid: @placement_uid,
          cluster_name: "#{@placement_uid}_cluster",
          log_init_args: %{uid: @placement_uid},
          initial_members: member_ids,
          machine: {:module, Riptide.Placement.PlacementMachine, %{}}
        }
      end)

    case :ra.start_cluster(@system, configs) do
      {:ok, _started, _not_started} -> :ok
      {:error, :cluster_not_formed} -> {:error, :cluster_not_formed}
    end
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/riptide/ra_cluster_test.exs`
Expected: PASS (all tests in the file)

- [ ] **Step 5: Run the full test suite to confirm no regression**

Run: `mix test`
Expected: PASS, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add lib/riptide/ra_cluster.ex test/riptide/ra_cluster_test.exs
git commit -m "Add multi-member placement-cluster bootstrap to RaCluster"
```

---

### Task 3: `Riptide.Placement` client API

**Files:**
- Create: `lib/riptide/placement.ex`
- Test: `test/riptide/placement_test.exs`

**Interfaces:**
- Consumes: `RaCluster.placement_ordinals/0`, `RaCluster.placement_server_id/2`, `RaCluster.default_ordinal_resolver/1`, `RaCluster.process_command/2`, `RaCluster.consistent_query/2` (Task 2, all unchanged existing signatures except the new placement-specific ones); `PlacementMachine.get/2` (Task 1).
- Produces: `Placement.propose_nodes/0,1 :: pos_integer() -> [node()]`, `Placement.select_nodes/2 :: ([node()], pos_integer()) -> [node()]`, `Placement.assign/2,3 :: (String.t(), [node()], (String.t() -> node())) -> [node()]`, `Placement.lookup/1,2 :: (String.t(), (String.t() -> node())) -> [node()] | nil` — consumed by Task 4's integration test (with an injected resolver) and, eventually, Phase 3c-ii/3c-iii (with the default real-DNS resolver).

- [ ] **Step 1: Write the failing tests**

Create `test/riptide/placement_test.exs`:

```elixir
defmodule Riptide.PlacementTest do
  use ExUnit.Case, async: true

  alias Riptide.Placement

  describe "select_nodes/2" do
    test "returns exactly `count` distinct nodes when enough candidates exist" do
      result = Placement.select_nodes([:a, :b, :c, :d, :e], 3)

      assert length(result) == 3
      assert Enum.uniq(result) == result
      assert Enum.all?(result, &(&1 in [:a, :b, :c, :d, :e]))
    end

    test "deduplicates candidate nodes before selecting" do
      result = Placement.select_nodes([:a, :a, :b, :b, :c], 3)
      assert Enum.sort(result) == [:a, :b, :c]
    end

    test "returns all candidates if fewer than `count` are available" do
      result = Placement.select_nodes([:a, :b], 3)
      assert Enum.sort(result) == [:a, :b]
    end
  end

  describe "propose_nodes/1" do
    test "always includes the local node, even alone" do
      # Node.list() is empty on a non-distributed test node, so with
      # replication_factor 1 the only possible candidate is node() itself.
      assert Placement.propose_nodes(1) == [node()]
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/riptide/placement_test.exs`
Expected: FAIL — `Riptide.Placement` module not found

- [ ] **Step 3: Implement `Riptide.Placement`**

Create `lib/riptide/placement.ex`:

```elixir
defmodule Riptide.Placement do
  @moduledoc """
  Client API for Riptide's placement metadata cluster — the durable
  `stream_id -> [replica nodes]` mapping maintained by
  `Riptide.Placement.PlacementMachine` via a small, fixed-membership Ra
  cluster (see `Riptide.RaCluster.placement_server_id/1,2`).

  `assign/2,3` and `lookup/1,2` currently always address the metadata cluster
  via its first fixed ordinal (`RaCluster.placement_ordinals() |> hd()`) —
  `:ra`'s own leader-redirect means this works whether or not that specific
  ordinal happens to be the current leader, but if that one ordinal's own pod
  is unreachable, these calls fail outright rather than falling back to a
  different ordinal. Acceptable for this phase's narrow scope; revisit if it
  proves to matter in practice.
  """

  alias Riptide.Placement.PlacementMachine
  alias Riptide.RaCluster

  @replication_factor 3

  @spec propose_nodes(pos_integer()) :: [node()]
  def propose_nodes(replication_factor \\ @replication_factor) do
    select_nodes(Node.list() ++ [node()], replication_factor)
  end

  @spec select_nodes([node()], pos_integer()) :: [node()]
  def select_nodes(candidate_nodes, count) do
    candidate_nodes
    |> Enum.uniq()
    |> Enum.shuffle()
    |> Enum.take(count)
  end

  @spec assign(String.t(), [node()], (String.t() -> node())) :: [node()]
  def assign(stream_id, proposed_nodes, resolve_fun \\ &RaCluster.default_ordinal_resolver/1) do
    RaCluster.process_command(placement_server_id(resolve_fun), {:assign, stream_id, proposed_nodes})
  end

  @spec lookup(String.t(), (String.t() -> node())) :: [node()] | nil
  def lookup(stream_id, resolve_fun \\ &RaCluster.default_ordinal_resolver/1) do
    RaCluster.consistent_query(placement_server_id(resolve_fun), &PlacementMachine.get(&1, stream_id))
  end

  defp placement_server_id(resolve_fun) do
    RaCluster.placement_server_id(hd(RaCluster.placement_ordinals()), resolve_fun)
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/riptide/placement_test.exs`
Expected: PASS (all 4 tests)

- [ ] **Step 5: Run the full test suite to confirm no regression**

Run: `mix test`
Expected: PASS, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add lib/riptide/placement.ex test/riptide/placement_test.exs
git commit -m "Add Riptide.Placement client API"
```

---

### Task 4: End-to-end multi-node proof + application-boot wiring

**Files:**
- Modify: `lib/riptide/application.ex`
- Create: `test/riptide/placement_cluster_test.exs`

**Interfaces:**
- Consumes: `RaCluster.placement_ordinals/0`, `RaCluster.ensure_placement_cluster_started/0` (Task 2); `Riptide.Placement.assign/3`, `Riptide.Placement.lookup/2` (Task 3, called with an injected resolver in the test — production code, wired here, uses the default real-DNS resolver).
- Produces: no new public interface — this task's deliverable is the passing integration test and the production boot-wiring, as evidence the whole stack (Tasks 1-3) works together under real distributed-node conditions, not just in isolation.

**Context this task's implementer needs, verified empirically for the *same* `:peer`-based recipe during Phase 3b's own multi-node connectivity test (`test/riptide/multi_node_connectivity_test.exs` — read it for the exact, already-working incantation before writing this one):**
- `epmd` registers nodes by alive-name only, shared across all peers on one machine — use distinct alive-names (`riptide0`, `riptide1`, `riptide2`), not distinct hosts with the same name.
- Use `:erpc.call/4`, not `:peer.call/4` (the latter returns `{:error, :noconnection}` in this environment).
- `:peer.start_link/1`'s `args` option needs charlist elements, not binaries.
- Peers don't auto-connect to each other — connect every pair explicitly via `:net_kernel.connect_node/1`.
- Pass the full, unfiltered `:code.get_path()` as `-pa` args.
- `:peer.start_link/1`'s `env` option sets a real OS env var in the spawned peer.
- The origin (test-runner) node must be distributed before spawning named peers.
- Each peer needs `Application.ensure_all_started(:ra)` before Ra-related calls work there.
- The `:peer` control process can die before ExUnit's `on_exit` runs even though the peer was alive at test-body end — guard `on_exit` cleanup with `Process.alive?/1` + `try/catch` around `:peer.stop/1` (see `multi_node_connectivity_test.exs`'s own `on_exit` for the exact working pattern).

**New for this task, not yet empirically verified — confirm for real before relying on it:** this test passes an anonymous function (the resolver stub, a closure over a small map of plain atoms) as an argument to `:erpc.call/4`, unlike Phase 3b's own test (which only called plain MFA-style functions with plain-data arguments). Elixir/Erlang closures are ordinary transferable terms as long as the referenced module's code is available on the target node (which it is here, since the full code path was propagated) — but this specific pattern (closure-as-erpc-argument) hasn't been exercised anywhere in this codebase yet. If it doesn't work as expected, the fallback is to have each peer construct its own equivalent stub locally (passing plain data — e.g. a list of `{ordinal, node}` pairs — instead of a closure, then building the anonymous function on the remote side).

- [ ] **Step 1: Write the test**

Create `test/riptide/placement_cluster_test.exs`:

```elixir
defmodule Riptide.PlacementClusterTest do
  use ExUnit.Case, async: false

  @moduletag timeout: 60_000

  @peers [
    {:riptide0, "riptide-0", ~c"127.0.0.1"},
    {:riptide1, "riptide-1", ~c"127.0.0.2"},
    {:riptide2, "riptide-2", ~c"127.0.0.3"}
  ]

  setup_all do
    unless Node.alive?() do
      {:ok, _pid} = Node.start(:"placement_cluster_origin@127.0.0.1", :longnames)
    end

    :ok
  end

  test "the placement metadata cluster bootstraps across 3 real nodes and agrees on assignments" do
    pa_args = Enum.flat_map(:code.get_path(), fn p -> [~c"-pa", p] end)

    peers =
      for {alive_name, ordinal, host} <- @peers do
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
    end)

    nodes = Enum.map(peers, fn {_pid, node, _ordinal} -> node end)
    ordinal_to_node = Map.new(peers, fn {_pid, node, ordinal} -> {ordinal, node} end)
    resolve_fun = fn ordinal -> Map.fetch!(ordinal_to_node, ordinal) end

    for {n1, n2} <- unique_pairs(nodes) do
      assert :erpc.call(n1, :net_kernel, :connect_node, [n2]) == true
    end

    for {_pid, node, _ordinal} <- peers do
      {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:ra])

      assert :erpc.call(node, Riptide.RaCluster, :attempt_start_placement_cluster, [resolve_fun]) ==
               :ok
    end

    {_pid, entry_node, _ordinal} = hd(peers)
    stream_id = "placement-test-" <> Uniq.UUID.uuid4()
    proposed = Enum.take(nodes, 2)

    assigned = :erpc.call(entry_node, Riptide.Placement, :assign, [stream_id, proposed, resolve_fun])
    assert Enum.sort(assigned) == Enum.sort(proposed)

    # Every member — not just the one that received the assign call — must
    # agree on the same assignment, proving the value actually replicated
    # through the metadata cluster's own Raft consensus rather than just
    # being remembered by whichever node handled the write.
    for {_pid, node, _ordinal} <- peers do
      looked_up = :erpc.call(node, Riptide.Placement, :lookup, [stream_id, resolve_fun])
      assert Enum.sort(looked_up) == Enum.sort(proposed)
    end

    # Idempotency holds across real nodes too: a second, different proposal
    # for the same stream_id from a *different* node must not overwrite the
    # first winning assignment.
    {_pid, other_node, _ordinal} = Enum.at(peers, 1)
    different_proposal = Enum.take(Enum.reverse(nodes), 2)

    reassigned =
      :erpc.call(other_node, Riptide.Placement, :assign, [stream_id, different_proposal, resolve_fun])

    assert Enum.sort(reassigned) == Enum.sort(proposed)
  end

  defp unique_pairs(list) do
    for {a, i} <- Enum.with_index(list),
        {b, j} <- Enum.with_index(list),
        i < j,
        do: {a, b}
  end
end
```

- [ ] **Step 2: Run the test**

Run: `mix test test/riptide/placement_cluster_test.exs --trace`
Expected: PASS. If the closure-as-erpc-argument pattern doesn't work as expected (see the context note above), apply the documented fallback (pass plain `{ordinal, node}` pairs instead of a closure, build the resolver function locally on each remote call site) and re-verify.

- [ ] **Step 3: Wire placement-cluster bootstrap into application boot**

In `lib/riptide/application.ex`, replace the `children` list:

```elixir
  @impl true
  def start(_type, _args) do
    children =
      [
        {Phoenix.PubSub, name: Riptide.PubSub},
        {Cluster.Supervisor,
         [Application.get_env(:libcluster, :topologies, []), [name: Riptide.ClusterSupervisor]]}
      ] ++
        placement_bootstrap_children() ++
        [
          # Start a worker by calling: Riptide.Worker.start_link(arg)
          # {Riptide.Worker, arg},
          # Start to serve requests, typically the last entry
          RiptideWeb.Endpoint
        ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Riptide.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Only the 3 fixed placement-cluster ordinals attempt to host a member of
  # it — every other fleet node just consults it via Riptide.Placement, never
  # hosting a replica itself. Runs as a fire-and-forget Task (not a blocking
  # call in start/2 itself) since ensure_placement_cluster_started/0 retries
  # indefinitely until quorum is reachable, which shouldn't hold up the rest
  # of the application (Phoenix Endpoint, etc.) from booting normally.
  defp placement_bootstrap_children do
    if System.get_env("HOSTNAME") in Riptide.RaCluster.placement_ordinals() do
      [{Task, &Riptide.RaCluster.ensure_placement_cluster_started/0}]
    else
      []
    end
  end
```

- [ ] **Step 4: Run the full test suite to confirm no regression**

Run: `mix test`
Expected: PASS, 0 failures. Confirm no orphaned `:peer`/beam processes lingering afterward (`ps aux | grep beam`) and no stale `epmd` registrations (`epmd -names`).

- [ ] **Step 5: Commit**

```bash
git add lib/riptide/application.ex test/riptide/placement_cluster_test.exs
git commit -m "Wire placement-cluster bootstrap into application boot + end-to-end multi-node proof"
```

---

### Task 5: Live proof against the existing Phase 3b StatefulSet

**Files:**
- No new files — this task operates against the real cluster using the existing `k8s/` manifests from Phase 3b (no changes needed to them; the `StatefulSet`'s pods are already named `riptide-0`/`riptide-1`/`riptide-2` by StatefulSet ordinal convention, exactly matching this phase's fixed ordinals).

**Interfaces:**
- Consumes: the already-deployed `k8s/*.yaml` manifests (Phase 3b), the built Docker image (now including this plan's Tasks 1-4).
- Produces: a written verification record (this task's own report) — no code.

**Note before starting:** deploying this live requires the operator's explicit go-ahead, the same way Phase 3b's own live GKE proof did — ask before creating any real cluster resources, and follow the same image-build approach Phase 3b's Task 5 used (`.github/workflows/release.yml` is tag-triggered only, so build/push a throwaway-tagged image manually, e.g. `phase-3c-i-proof`, never touching `:latest`), since that constraint hasn't changed.

- [ ] **Step 1: Build and push a fresh image**

Follow the same approach as Phase 3b's Task 5 Step 1 (see that task's own report for the exact working incantation, including the documented `docker buildx` + custom-MTU-network workaround for this box's `docker build` environment): build and push a throwaway-tagged image containing this plan's changes.

- [ ] **Step 2: Create a disposable namespace and deploy**

```bash
kubectl create namespace riptide-phase-3c-i-proof
kubectl config set-context --current --namespace=riptide-phase-3c-i-proof
```

Follow `k8s/README.md`'s Deploy steps, using the throwaway image tag from Step 1 (override `k8s/statefulset.yaml`'s image reference the same way Phase 3b's Task 5 did — via `kubectl set image` or a modified copy, not by editing the committed manifest).

Run: `kubectl rollout status statefulset/riptide --timeout=120s`
Expected: all 3 pods reach `Ready`.

- [ ] **Step 3: Verify the placement cluster actually formed**

```bash
kubectl exec riptide-0 -- bin/riptide rpc "IO.inspect(Riptide.RaCluster.attempt_start_placement_cluster())"
```

Expected: `:ok` (idempotent — the cluster should already be running from each pod's own boot-time bootstrap; this just confirms it).

- [ ] **Step 4: Verify a real assignment propagates across all 3 real pods**

```bash
kubectl exec riptide-0 -- bin/riptide rpc "IO.inspect(Riptide.Placement.assign(\"proof-stream\", [Node.self()]))"
kubectl exec riptide-1 -- bin/riptide rpc "IO.inspect(Riptide.Placement.lookup(\"proof-stream\"))"
kubectl exec riptide-2 -- bin/riptide rpc "IO.inspect(Riptide.Placement.lookup(\"proof-stream\"))"
```

Expected: the `assign` call on `riptide-0` returns the proposed node list; both `lookup` calls (on the *other* two pods, not the one that wrote it) return the identical, real assignment — proving the value actually replicated through the metadata cluster's own Raft consensus and is queryable from any member, not just the one that wrote it, using the real DNS-based resolver end-to-end (not a test stub).

- [ ] **Step 5: Tear down**

```bash
kubectl delete namespace riptide-phase-3c-i-proof
kubectl config set-context --current --namespace=default
```

Confirm deletion completed: poll `kubectl get namespace riptide-phase-3c-i-proof` until it returns `NotFound`. Also delete the throwaway image tag from ghcr.io (`gh api --method DELETE` on its package version, matching Phase 3b's Task 5 cleanup) — leave nothing behind, live cluster resources or otherwise.

- [ ] **Step 6: Record the results**

Write a short summary (for Task 6's PROGRESS.md update and the PR description) of what was directly observed at each step — the actual command output from Steps 3-4, not a paraphrased summary.

---

### Task 6: Full verification + PROGRESS.md + wrap-up

**Files:**
- Modify: `PROGRESS.md`
- No new source files.

**Interfaces:**
- Consumes: everything from Tasks 1-5, including Task 5's recorded live-proof results.
- Produces: nothing further downstream — terminal task.

- [ ] **Step 1: Run the full test suite**

Run: `mix test`
Expected: PASS, 0 failures — including Task 1's `PlacementMachine` tests, Task 2's `RaCluster` additions, Task 3's `Riptide.Placement` tests, Task 4's multi-node integration test, and every pre-existing test (issue #6, issue #8, Phase 3a's encode/decode tests, Phase 3b's multi-node connectivity test) unaffected.

- [ ] **Step 2: Run Credo and formatter checks**

Run: `mix credo --strict && mix format --check-formatted`
Expected: both clean. Fix anything flagged and re-run.

- [ ] **Step 3: Update `PROGRESS.md`**

In the `## 3. Clustering / horizontal scale / HA — decomposed into phases` section's Phase 3c bullet, change the 3c-i sub-bullet's trailing `**Design approved 2026-08-25**` to note it shipped:

```markdown
  - **3c-i — Placement metadata store.** A small, dedicated `:ra` cluster (fixed 3 members,
    decoupled from total fleet size) durably recording `stream_id → [replica nodes]`.
    Foundational — nothing else in 3c can be built without it. **Shipped 2026-08-25** — see
    `docs/superpowers/specs/2026-08-25-phase-3c-i-placement-metadata-design.md`.
```

Change the `**Status**:` line from:

```markdown
**Status**: Phases 3a-3b shipped. Phase 3c decomposed into 3c-i/3c-ii/3c-iii; 3c-i's design
approved, implementation not yet started.
```

to:

```markdown
**Status**: Phases 3a-3b shipped. Phase 3c-i shipped. 3c-ii (multi-member Ra cluster
formation) not yet started.
```

- [ ] **Step 4: Commit**

```bash
git add PROGRESS.md
git commit -m "Mark Phase 3c-i shipped in PROGRESS.md"
```

- [ ] **Step 5: Push and open a PR**

```bash
git push -u origin <branch-name>
gh pr create --title "Phase 3c-i: placement metadata store" --body "$(cat <<'EOF'
## Summary
- Implements the Phase 3c-i design spec (docs/superpowers/specs/2026-08-25-phase-3c-i-placement-metadata-design.md).
- New Riptide.Placement.PlacementMachine (:ra_machine) + Riptide.Placement (client API): a durable stream_id -> [replica nodes] mapping, idempotent-assign for race-safety.
- RaCluster gains multi-member cluster bootstrap for a small, fixed 3-member metadata cluster (riptide-0/1/2), bootstrapped via DNS-resolved node identities with retry until quorum.
- Wired into application boot (only the 3 fixed ordinals host a member) via a fire-and-forget Task.
- Includes [Task 5's live-proof results here — paste the recorded observations].

## Test plan
- [x] mix test — full suite passes, including the new PlacementMachine/RaCluster/Placement tests, the :peer-based multi-node integration test, and every pre-existing regression test
- [x] mix credo --strict
- [x] mix format --check-formatted
- [x] Live proof: placement cluster bootstrapped for real across 3 real StatefulSet pods, a real assignment written on one pod was correctly queryable from the other two (see Task 5's recorded results)
EOF
)"
```

Report the PR URL and stop — do not merge without explicit human sign-off (ask via AskUserQuestion), matching this project's established practice for every prior PR this session.
