# Phase 3e — Elastic Placement-Cluster Membership Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the hardcoded 3-fixed-ordinal (`"riptide-0"/"riptide-1"/"riptide-2"`) assumption from Riptide's placement/metadata Raft cluster, replacing it with self-forming genesis, PubSub-broadcast + fleet-probe discovery, and automatic reconciliation to a configurable target size — including graceful drain on shutdown.

**Architecture:** `Riptide.RaCluster` gains a small set of new pure `:ra`-calling primitives (discovery, genesis, join, remove) built directly on the same `add_member`/`remove_member`/`start_joining_server` machinery `replace_member/5` already proves safe. A new `Riptide.PlacementMembership` GenServer (started unconditionally on every node, replacing the old `HOSTNAME`-gated bootstrap Task) owns the ETS-cached membership view, the PubSub broadcast, the periodic join/repair/shrink reconciliation loop, and graceful drain via `terminate/2`. `Riptide.Placement`'s client API drops its `resolve_fun` parameter entirely, addressing the cluster via live-discovered members instead of resolved ordinal names.

**Tech Stack:** Elixir 1.18, `:ra` (Raft) 2.15.0, Phoenix.PubSub, ExUnit with `:peer`-based multi-node integration tests.

**Spec:** `docs/superpowers/specs/2026-08-27-phase-3e-elastic-placement-membership-design.md`

## Global Constraints

- No migration path needed — no existing deployment of this system exists anywhere (confirmed with the operator). Breaking changes to the placement cluster's addressing scheme are fine.
- `Riptide.RaCluster` remains the only module that calls into `:ra` directly (existing, unchanged invariant — see its own moduledoc).
- Every new/changed public function needs a `@spec`, matching this codebase's existing convention throughout `ra_cluster.ex`/`placement.ex`.
- `RIPTIDE_PLACEMENT_TARGET_SIZE` (env var, `config/runtime.exs`), default `3`, must be validated as a positive odd integer at boot — an even value raises immediately rather than running degraded.
- A single-node deployment (Fly.io, plain `docker run`, `docker-compose`) is just `RIPTIDE_PLACEMENT_TARGET_SIZE=1` — no `HOSTNAME` requirement, no `RIPTIDE_SINGLE_NODE`, no `ordinal_resolver`.
- `RaCluster.data_dir/0`'s `HOSTNAME`-based per-node data directory keying is UNCHANGED — it's an orthogonal, still-needed mechanism (stable disk location across a StatefulSet pod's restarts), not part of what this phase removes.
- CI gates on `mix format --check-formatted` and `mix credo --strict` — every task touching `lib/`/`config/` must stay clean on both.
- `mix test` must show `0 failures` at the end of every task that touches test files, and at the end of the plan.
- Shared checkout discipline: verify `git branch --show-current` is `phase-3e-elastic-placement-membership-2026-08-27` before every commit.

---

## Task 1: `Riptide.RaCluster` — remove fixed ordinals, add discovery/genesis/join/remove primitives

**Files:**
- Modify: `lib/riptide/ra_cluster.ex`
- Test: `test/riptide/ra_cluster_test.exs`

**Interfaces:**
- Removes: `placement_ordinals/0`, `placement_server_id/2` (arity-2, with `resolve_fun`), `default_ordinal_resolver/1`, `dns_ordinal_resolver/1`, `attempt_start_placement_cluster/1` (the `resolve_fun`-taking version), `ensure_placement_cluster_started/2`'s `attempt_fun` default (updated to point at the new genesis-aware retry driver — see below).
- Produces (consumed by Task 2's `Riptide.PlacementMembership` and Task 3's `Riptide.Placement`):
  - `placement_server_id(node()) :: :ra.server_id()` (arity-1, no resolver)
  - `restart_local_placement_member() :: :ok | {:error, term()}`
  - `local_placement_members() :: {:ok, [node()]} | :error`
  - `probe_placement_members([node()]) :: {:ok, [node()]} | :error`
  - `start_genesis_placement_cluster([node()]) :: :ok | {:error, :cluster_not_formed}`
  - `join_placement_cluster([node()]) :: :ok | {:error, term()}`
  - `remove_placement_member([node()], node()) :: :ok | {:error, term()}`
  - `placement_leader?/0` — unchanged, kept exactly as-is (already generic, no ordinal dependency).

- [ ] **Step 1: Write the failing tests for the new primitives**

Add to `test/riptide/ra_cluster_test.exs`, replacing the entire `describe "placement_ordinals/0 and placement_server_id/1,2"` block (lines 121-132) and the entire `describe "attempt_start_placement_cluster/1"` block (lines 159-234) with:

**Important — this file is `async: true` and shares one live resource across the entire suite:**
`test_helper.exs` bootstraps `{:riptide_placement, node()}` once, before any test runs, and every
`async: true` test anywhere in the suite that touches `Riptide.Placement`/`Riptide.Stream.Placement`
depends on that ONE shared instance staying alive for the whole `mix test` run (the existing test
this step replaces already documents this explicitly — "NOT a throwaway server this test owns").
None of the new tests below may kill that process or `force_delete_server` it — every new test here
either makes a provably-safe redundant/no-op call against the shared instance, or doesn't touch it
at all. (`restart_local_placement_member/0`'s own real "kill it and recover" behavior is exercised
safely instead in Task 2's `placement_membership_test.exs`, which is `async: false`.)

```elixir
  describe "placement_server_id/1" do
    test "combines the placement cluster name with the given node" do
      assert RaCluster.placement_server_id(:"riptide@10.0.0.5") ==
               {:riptide_placement, :"riptide@10.0.0.5"}
    end
  end

  describe "local_placement_members/0 and probe_placement_members/1" do
    test "local_placement_members/0 returns the real, already-running shared membership" do
      assert RaCluster.local_placement_members() == {:ok, [node()]}
    end

    test "probe_placement_members/1 finds the live shared member among unreachable candidates" do
      assert RaCluster.probe_placement_members([
               :nonexistent1@nowhere,
               node(),
               :nonexistent2@nowhere
             ]) == {:ok, [node()]}
    end

    test "probe_placement_members/1 returns :error when no candidate has a live member" do
      assert RaCluster.probe_placement_members([:nonexistent1@nowhere, :nonexistent2@nowhere]) ==
               :error
    end
  end

  describe "start_genesis_placement_cluster/1" do
    test "self-corrects on a redundant call against the already-running shared instance" do
      assert RaCluster.start_genesis_placement_cluster([node()]) == :ok
      assert RaCluster.start_genesis_placement_cluster([node(), node(), node()]) == :ok
    end
  end

  describe "join_placement_cluster/1 and remove_placement_member/2" do
    test "join_placement_cluster/1 is idempotent when this node is already a member" do
      assert RaCluster.join_placement_cluster([node()]) == :ok
    end

    test "remove_placement_member/2 removing a node that was never a member is a safe no-op" do
      # Shares remove_member/2's existing disambiguation logic with
      # replace_member/5 (used for real by ReplicaHealer): "not in the
      # survivors' current membership" is treated as :ok whether that's
      # because the node was already removed, or because it was never a
      # member in the first place — replace_member/5's real callers only
      # ever pass a genuine prior member, so this ambiguity never manifests
      # in practice; documented here rather than asserting a stricter
      # contract the shared helper doesn't actually provide. (Confirmed
      # empirically: the original stricter assertion here failed for
      # exactly this reason once the suite actually ran.)
      assert RaCluster.remove_placement_member([node()], :"riptide@10.0.0.9") == :ok
    end
  end
```

- [ ] **Step 2: Run the new tests to verify they fail**

Run: `mix test test/riptide/ra_cluster_test.exs`
Expected: FAIL — every new test errors with `UndefinedFunctionError` for the not-yet-defined functions; the two removed `describe` blocks' own old tests (`placement_ordinals/0 returns exactly the 3 fixed ordinals`, etc.) no longer exist so produce no failures of their own.

- [ ] **Step 3: Remove the old ordinal machinery from `lib/riptide/ra_cluster.ex`**

Delete lines 23-31 (the `@placement_ordinals` module attribute, its comment, and `placement_ordinals/0`):

```elixir
  # Fixed, not derived from fleet size — see Phase 3c-i design spec §2/§5. The
  # metadata cluster stays this exact size regardless of how large the overall
  # fleet grows.
  @placement_ordinals ["riptide-0", "riptide-1", "riptide-2"]
  @placement_cluster_name :riptide_placement
  @placement_uid "riptide_placement"

  @spec placement_ordinals() :: [String.t()]
  def placement_ordinals, do: @placement_ordinals
```

Replace with just:

```elixir
  @placement_cluster_name :riptide_placement
  @placement_uid "riptide_placement"
```

Replace the `placement_server_id/2` function (lines 33-36) with the new arity-1 version:

```elixir
  @spec placement_server_id(node()) :: :ra.server_id()
  def placement_server_id(node), do: {@placement_cluster_name, node}
```

Delete `default_ordinal_resolver/1` and `dns_ordinal_resolver/1` in full (lines 69-95, including the long comment block above `default_ordinal_resolver/1`):

```elixir
  # Resolves a StatefulSet ordinal to its *current* Erlang node identity.
  # In production this is always the real DNS-based resolution below
  # (mirroring exactly how `Cluster.Strategy.Kubernetes.DNS` resolves peers
  # for libcluster); overridden in `config/test.exs` to an identity resolver
  # (`fn _ordinal -> node() end`) since there's no real headless-service DNS
  # in local dev/CI. This is the *default* every `Riptide.Placement`
  # function falls back to — `Riptide.Stream.Placement`/`StreamServer`
  # (Phase 3c-ii) deliberately never thread a resolver through their own
  # public APIs, so making the default itself environment-correct is the
  # only way their calls work in both places.
  @spec default_ordinal_resolver(String.t()) :: node()
  def default_ordinal_resolver(ordinal) do
    case Application.get_env(:riptide, :ordinal_resolver) do
      nil -> dns_ordinal_resolver(ordinal)
      resolver when is_function(resolver, 1) -> resolver.(ordinal)
    end
  end

  @spec dns_ordinal_resolver(String.t()) :: node()
  defp dns_ordinal_resolver(ordinal) do
    headless_service = System.get_env("RIPTIDE_HEADLESS_SERVICE", "riptide-headless")
    hostname = String.to_charlist("#{ordinal}.#{headless_service}")

    {:ok, {:hostent, _, _, _, _, [ip | _]}} = :inet.gethostbyname(hostname)
    ip_string = ip |> :inet.ntoa() |> to_string()
    String.to_atom("riptide@#{ip_string}")
  end
```

Delete `attempt_start_placement_cluster/1` in full (its entire moduledoc comment and function body — the block starting `# Retries indefinitely until the placement cluster is formed` through the end of `attempt_start_placement_cluster/1`'s own function, i.e. everything from the `ensure_placement_cluster_started/2` comment through the closing `end` of `attempt_start_placement_cluster/1`). Replace that whole span with:

```elixir
  # Retries indefinitely until the placement cluster is either genuinely
  # formed (genesis) or this node successfully joins an already-existing
  # one — intended to be started as a fire-and-forget background task at
  # application boot (see Riptide.PlacementMembership), not called
  # synchronously from a request path.
  @spec ensure_placement_cluster_started(pos_integer(), (-> :ok | {:error, term()})) :: :ok
  def ensure_placement_cluster_started(
        retry_interval_ms \\ 1000,
        attempt_fun \\ &Riptide.PlacementMembership.bootstrap_once/0
      ) do
    do_ensure_placement_cluster_started(retry_interval_ms, attempt_fun, 1)
  end
```

(`do_ensure_placement_cluster_started/3` below it, and its `@log_every_nth_attempt` constant, are unchanged — leave them exactly as they are.)

- [ ] **Step 4: Add the new discovery/genesis/join/remove functions**

Insert this new block immediately after `data_dir/0`'s function (after the line `Path.join(base, System.get_env("HOSTNAME", "nonode")) |> String.to_charlist() end`, before the `server_alive?/1` function):

```elixir
  # Recovers a member that already has on-disk log data for this uid on
  # THIS EXACT node() identity — only correct to call when the current,
  # freshly-discovered consensus membership already lists `node()` as a
  # member (see `Riptide.PlacementMembership.bootstrap_once/0`), since
  # `:ra.restart_server/2` looks up on-disk state by the exact `{name, node}`
  # server id, not by uid/data_dir alone. Deliberately NOT used to recover a
  # node whose `node()` identity has drifted since its last run (e.g. a real
  # Kubernetes pod restart under a new IP — `node()` is IP-based and
  # unstable, per `data_dir/0`'s own doc): a drifted node is never listed
  # under ITS NEW identity in the old consensus state, so this call would
  # simply fail to find anything to restart. That case is handled instead by
  # the ordinary ambient join loop (this "new" node joins fresh) plus the
  # leader-only repair loop (evicts the stale old identity) — no special
  # casing needed, it falls out of machinery already built for the
  # dead-member-replacement case generally.
  @spec restart_local_placement_member() :: :ok | {:error, term()}
  def restart_local_placement_member do
    ensure_system_started()
    :ra.restart_server(@system, {@placement_cluster_name, node()})
  end

  # A fast, LOCAL-only membership check: does this node currently have a
  # live placement-cluster member, and if so, what does Raft consensus
  # itself say the full current membership is? `:ra.members/1`'s reply is
  # self-describing and authoritative the instant any single caught-up
  # member answers it — not a guess, a consensus fact (the same principle
  # `remove_member/2`'s own `member_removed?/2` helper below already relies
  # on). Returns `:error` (not raising) when this node has no live local
  # member, mirroring `placement_leader?/0`'s own `catch :exit` treatment.
  @spec local_placement_members() :: {:ok, [node()]} | :error
  def local_placement_members do
    case :ra.members({@placement_cluster_name, node()}) do
      {:ok, members, _leader} -> {:ok, Enum.map(members, fn {_name, n} -> n end)}
      _ -> :error
    end
  catch
    :exit, _ -> :error
  end

  # The fleet-wide discovery fallback: ask every candidate node, in
  # parallel, whether IT has a live placement-cluster member — the first one
  # that answers wins, since any caught-up member's view of membership is
  # authoritative (see `local_placement_members/0`'s own doc). This needs no
  # hardcoded names at all — `candidate_nodes` is expected to be
  # `[node() | Node.list()]`, the already-elastic fleet `libcluster`
  # discovers, not a fixed ordinal list.
  @spec probe_placement_members([node()]) :: {:ok, [node()]} | :error
  def probe_placement_members(candidate_nodes) do
    candidate_nodes
    |> Enum.uniq()
    |> Task.async_stream(&probe_one_placement_member/1, timeout: 6_000, on_timeout: :kill_task)
    |> Enum.find_value(:error, fn
      {:ok, {:ok, members}} -> {:ok, members}
      _ -> nil
    end)
  end

  defp probe_one_placement_member(n) when n == node(), do: local_placement_members()

  defp probe_one_placement_member(n) do
    :erpc.call(n, __MODULE__, :local_placement_members, [], 5_000)
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  # Forms a brand-new placement cluster across exactly `member_nodes` — the
  # genesis primitive `Riptide.PlacementMembership` calls once it's computed
  # the same deterministic member list every other simultaneously-booting
  # node would independently compute (see its own moduledoc). Generalizes
  # what used to be `attempt_start_placement_cluster/1`'s hardcoded-3-ordinal
  # version: same self-correcting shape (a redundant call whose members are
  # already running also reports `{:error, :cluster_not_formed}` from
  # `:ra.start_cluster/2` itself, corrected here by rechecking local
  # liveness), just parameterized by a real, already-resolved node list
  # instead of resolving symbolic ordinal names via DNS.
  @spec start_genesis_placement_cluster([node()]) :: :ok | {:error, :cluster_not_formed}
  def start_genesis_placement_cluster(member_nodes) do
    ensure_system_started()
    member_ids = Enum.map(member_nodes, &placement_server_id/1)
    machine = {:module, Riptide.Placement.PlacementMachine, %{}}

    configs =
      Enum.map(member_ids, fn id ->
        %{
          id: id,
          uid: @placement_uid,
          cluster_name: "#{@placement_uid}_cluster",
          log_init_args: %{uid: @placement_uid},
          initial_members: member_ids,
          machine: machine
        }
      end)

    case :ra.start_cluster(@system, configs) do
      {:ok, _started, _not_started} ->
        :ok

      {:error, :cluster_not_formed} ->
        if server_alive?(@placement_cluster_name) do
          :ok
        else
          {:error, :cluster_not_formed}
        end
    end
  end

  # This node joins an already-existing placement cluster — the same
  # add-then-start sequence `replace_member/5` below already proves correct
  # (add to the existing cluster's configuration FIRST, then start the
  # joining server), just without a matching `remove_member` step, since
  # joining doesn't evict anyone. `:ra.add_member/2` is a command sent TO an
  # existing member; the caller doesn't need to already be one itself, so
  # this node can safely call it before it has any local server running.
  @spec join_placement_cluster([node()]) :: :ok | {:error, term()}
  def join_placement_cluster(existing_nodes) do
    ensure_system_started()
    existing_ids = Enum.map(existing_nodes, &placement_server_id/1)
    my_id = placement_server_id(node())
    machine = {:module, Riptide.Placement.PlacementMachine, %{}}
    cluster_name = "#{@placement_uid}_cluster"

    with :ok <- add_member(existing_ids, my_id) do
      start_joining_server(cluster_name, my_id, machine, existing_ids)
    end
  end

  # Removes `node_to_remove` from the placement cluster with no replacement
  # — used both for a confirmed-dead member (the repair side of
  # `Riptide.PlacementMembership`'s reconciliation loop) and for shrinking
  # to a lowered target size. Thin wrapper over the same private
  # `remove_member/2` `replace_member/5` already uses, just without the
  # add-a-replacement half of that pipeline.
  @spec remove_placement_member([node()], node()) :: :ok | {:error, term()}
  def remove_placement_member(survivor_nodes, node_to_remove) do
    ensure_system_started()
    survivor_ids = Enum.map(survivor_nodes, &placement_server_id/1)
    target_id = placement_server_id(node_to_remove)
    remove_member(survivor_ids, target_id)
  end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix test test/riptide/ra_cluster_test.exs`
Expected: PASS — all tests green, including every new one from Step 1.

- [ ] **Step 6: Run format and lint**

Run: `mix format && mix credo --strict`
Expected: clean.

- [ ] **Step 7: Commit**

```bash
git add lib/riptide/ra_cluster.ex test/riptide/ra_cluster_test.exs
git commit -m "RaCluster: replace fixed 3-ordinal placement addressing with discovery/genesis/join/remove primitives"
```

---

## Task 2: `Riptide.PlacementMembership` — the reconciliation controller

**Files:**
- Create: `lib/riptide/placement_membership.ex`
- Test: `test/riptide/placement_membership_test.exs`

**Interfaces:**
- Consumes: every new `Riptide.RaCluster` function from Task 1 (`restart_local_placement_member/0`, `local_placement_members/0`, `probe_placement_members/1`, `start_genesis_placement_cluster/1`, `join_placement_cluster/1`, `remove_placement_member/2`, plus the pre-existing `member_alive?/1`, `placement_leader?/0`, `placement_server_id/1`).
- Produces (consumed by Task 3's `Riptide.Placement` and Task 4's `Riptide.Application`):
  - `start_link(term()) :: GenServer.on_start()`
  - `current_members() :: [node()]` — the ETS-cached fast path, callable from any process without going through the GenServer.
  - `bootstrap_once() :: :ok | {:error, term()}` — one attempt at "get this node into a working placement cluster" (rejoin from disk, discover-and-cache an existing cluster, or attempt genesis) — this is what `RaCluster.ensure_placement_cluster_started/2`'s new default `attempt_fun` (Task 1, Step 3) points at.
  - `target_size() :: pos_integer()` — reads `Application.get_env(:riptide, :placement_target_size)`.

- [ ] **Step 1: Write the failing tests for the ETS cache and target size**

Create `test/riptide/placement_membership_test.exs`:

```elixir
defmodule Riptide.PlacementMembershipTest do
  use ExUnit.Case, async: false

  alias Riptide.PlacementMembership
  alias Riptide.RaCluster

  describe "current_members/0" do
    # No "returns [] when nothing has been cached yet" test: once the real
    # Riptide.PlacementMembership GenServer is wired into the application
    # supervision tree (Task 4), its cache is populated almost immediately
    # at boot via its own :bootstrap message — there's no reliably-testable
    # "genuinely empty" window in a running application to assert against.
    # (Confirmed empirically: this test failed for exactly this reason once
    # Task 4 landed.)

    test "returns whatever was last cached via a membership-changed broadcast" do
      Phoenix.PubSub.broadcast(
        Riptide.PubSub,
        "riptide:placement_membership",
        {:placement_membership_changed, [node(), :"riptide@10.0.0.7"]}
      )

      # Give the already-running Riptide.PlacementMembership process (started
      # by the application supervision tree — see Task 4) a moment to
      # receive and cache the broadcast.
      :timer.sleep(50)

      assert PlacementMembership.current_members() == [node(), :"riptide@10.0.0.7"]
    end
  end

  describe "target_size/0" do
    test "defaults to 3 when no application env is configured" do
      original = Application.get_env(:riptide, :placement_target_size)
      Application.delete_env(:riptide, :placement_target_size)
      on_exit(fn -> Application.put_env(:riptide, :placement_target_size, original) end)

      assert PlacementMembership.target_size() == 3
    end

    test "reads the configured value when present" do
      original = Application.get_env(:riptide, :placement_target_size)
      Application.put_env(:riptide, :placement_target_size, 5)
      on_exit(fn -> Application.put_env(:riptide, :placement_target_size, original) end)

      assert PlacementMembership.target_size() == 5
    end
  end

  describe "valid_target_size?/1" do
    test "true for positive odd integers" do
      assert PlacementMembership.valid_target_size?(1)
      assert PlacementMembership.valid_target_size?(3)
      assert PlacementMembership.valid_target_size?(5)
    end

    test "false for even integers, zero, negative integers, and non-integers" do
      refute PlacementMembership.valid_target_size?(2)
      refute PlacementMembership.valid_target_size?(4)
      refute PlacementMembership.valid_target_size?(0)
      refute PlacementMembership.valid_target_size?(-3)
    end
  end

  describe "bootstrap_once/0" do
    test "restarts the local member when this node is discovered as an already-existing member" do
      # No on_exit force_delete_server here: {:riptide_placement, node()} is
      # NOT a throwaway server this test owns — it's the same shared,
      # suite-wide placement cluster test_helper.exs bootstraps once before
      # any test runs, which other tests (e.g. test/riptide_web/health_test.exs)
      # depend on staying alive and recoverable for the rest of the `mix
      # test` process's lifetime. Kill the local process (but keep its
      # on-disk data, and this node's identity is unchanged) — a real member
      # restarting under the SAME node() identity, discoverable via the
      # fleet probe finding node() itself already listed in the persisted
      # membership — then let bootstrap_once/0 recover it, leaving the
      # shared instance alive and correct when this test finishes, exactly
      # as every other test that touches it depends on.
      pid = Process.whereis(:riptide_placement)
      Process.exit(pid, :kill)
      :timer.sleep(50)

      assert PlacementMembership.bootstrap_once() == :ok
      assert RaCluster.local_placement_members() == {:ok, [node()]}
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/riptide/placement_membership_test.exs`
Expected: FAIL — `Riptide.PlacementMembership` doesn't exist yet (`UndefinedFunctionError`/module not loaded).

- [ ] **Step 3: Write the module**

Create `lib/riptide/placement_membership.ex`:

```elixir
defmodule Riptide.PlacementMembership do
  @moduledoc """
  Replaces the old `HOSTNAME`-matches-one-of-3-fixed-ordinals gate — see
  Phase 3e design spec. Started unconditionally on every fleet node (see
  `Riptide.Application`). Owns:

  - The ETS-cached "who are the current placement-cluster members" fast
    path every `Riptide.Placement` client call reads (`current_members/0`).
  - Genesis: on boot, discovers whether a placement cluster already exists
    (locally or across the fleet); if this node turns out to already be a
    member per that discovery, recovers its own local member; if a cluster
    exists but this node isn't in it, leaves joining to the ambient
    reconcile loop; if none exists anywhere, attempts to form one (after a
    short settle window) from a deterministically-computed member list. A
    node whose `node()` identity has drifted since its last run (a real
    Kubernetes pod restart under a new IP) is deliberately NOT treated as
    "already a member" by this discovery — it falls through to an ordinary
    join, with the stale old identity evicted by the leader-only repair
    loop below. No special-casing for identity drift: it's just the
    dead-member-replacement case, handled by machinery that already exists
    for that reason.
  - Reconciliation: an ambient join loop (any non-member node tries to join
    when under target size) and a leader-only repair/shrink loop (removes a
    confirmed-dead member, or shrinks toward a lowered target size).
  - Graceful drain: `terminate/2` proactively removes this node from the
    placement cluster on shutdown, closing the reactive-repair window for
    planned removals.
  """

  use GenServer
  require Logger

  alias Riptide.RaCluster

  @table __MODULE__.Cache
  @topic "riptide:placement_membership"
  @reconcile_interval_ms 5_000
  @genesis_settle_ms 3_000

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @spec current_members() :: [node()]
  def current_members do
    case :ets.lookup(@table, :members) do
      [{:members, members}] -> members
      [] -> []
    end
  rescue
    # The cache table doesn't exist at all — this node never ran
    # Riptide.Application.start/2 (e.g. a bare `:peer` node in a test, which
    # never boots the real supervision tree). Degrading to [] here is
    # correct, not just defensive: an empty list makes `Riptide.Placement`'s
    # own fast-path/fallback logic naturally fall through to a live fleet
    # probe instead, exactly as if the cache were merely stale/unpopulated.
    # (Confirmed necessary empirically once Tasks 8-12's :peer-based tests
    # actually ran: every bare :peer node in this suite hits this path.)
    ArgumentError -> []
  end

  @spec target_size() :: pos_integer()
  def target_size do
    Application.get_env(:riptide, :placement_target_size, 3)
  end

  @doc """
  Whether a configured target size is valid — a positive odd integer. An
  even-sized Raft cluster doesn't improve fault tolerance over the
  next-lower odd size and risks tie votes. Extracted as a small, pure,
  directly-testable function so `config/runtime.exs` (which itself isn't
  unit-tested anywhere else in this codebase) can validate at boot without
  needing its own dedicated test — see Task 5.
  """
  @spec valid_target_size?(integer()) :: boolean()
  def valid_target_size?(size) when is_integer(size) and size > 0, do: rem(size, 2) == 1
  def valid_target_size?(_size), do: false

  @impl GenServer
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    Phoenix.PubSub.subscribe(Riptide.PubSub, @topic)
    Process.flag(:trap_exit, true)
    send(self(), :bootstrap)
    schedule_reconcile()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:bootstrap, state) do
    case bootstrap_once() do
      :ok -> :ok
      {:error, _reason} -> :ok
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:reconcile, state) do
    safe_reconcile()
    schedule_reconcile()
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:placement_membership_changed, members}, state) do
    cache_members(members)
    {:noreply, state}
  end

  # Closes the reactive-repair window for planned removals: rather than
  # waiting for the reconcile loop's next tick to notice this node is gone,
  # proactively hand off before the BEAM process actually exits. Needs
  # `Process.flag(:trap_exit, true)` in init/1 — without it, a supervisor's
  # `:shutdown` exit signal kills this process outright and terminate/2 never
  # runs at all (a non-trapping process doesn't get a chance to run any
  # callback on a non-:normal exit signal).
  @impl GenServer
  def terminate(_reason, _state) do
    case RaCluster.local_placement_members() do
      {:ok, members} when length(members) > 1 ->
        survivors = members -- [node()]
        _ = RaCluster.remove_placement_member(survivors, node())
        :ok

      _ ->
        :ok
    end
  end

  @doc """
  One attempt at "get this node into a working placement cluster" — the
  `attempt_fun` `RaCluster.ensure_placement_cluster_started/2` retries
  indefinitely. Public so `RaCluster`'s own default argument can reference
  it, and so tests can invoke it directly.

  Checks DISCOVERED CONSENSUS membership, not local disk, to decide what
  this node should do — `node()` is IP-based and changes on every real pod
  restart (see `RaCluster.data_dir/0`'s own doc), so "do I have local
  on-disk data" is the wrong signal for "am I still a member": a drifted
  node's OLD on-disk data exists, but that data's own persisted config
  still names the OLD, now-meaningless node() identity, not this run's
  fresh one. Recovering via `:ra.restart_server/2` only ever makes sense
  when the CURRENT node() is already listed in the CURRENT, live consensus
  membership — checked here directly, not inferred from disk state.
  """
  @spec bootstrap_once() :: :ok | {:error, term()}
  def bootstrap_once do
    case RaCluster.local_placement_members() do
      {:ok, members} ->
        cache_members(members)
        :ok

      :error ->
        join_or_form_genesis()
    end
  end

  defp join_or_form_genesis do
    case RaCluster.probe_placement_members([node() | Node.list()]) do
      {:ok, members} ->
        cache_members(members)

        if node() in members do
          # Already a member per live consensus, just not running locally
          # right now — a restart under the SAME node() identity (no IP
          # change), or this BEAM simply hasn't started its own member yet.
          # Recover from this node's own persisted log.
          RaCluster.restart_local_placement_member()
        else
          # A cluster exists, but this node isn't (or is no longer) part of
          # it — including the identity-drift case, where the membership
          # still names this node's OLD, now-dead identity, not this fresh
          # node(). Nothing to do here: the ambient join loop (reconcile/0)
          # picks this up on its next tick if membership is under target,
          # and the leader's repair loop evicts the stale old identity.
          :ok
        end

      :error ->
        attempt_genesis()
    end
  end

  defp attempt_genesis do
    Process.sleep(@genesis_settle_ms)

    # Re-probe after settling, in case another node already formed the
    # cluster while this one waited.
    case RaCluster.probe_placement_members([node() | Node.list()]) do
      {:ok, members} ->
        cache_members(members)
        :ok

      :error ->
        form_genesis_if_selected()
    end
  end

  defp form_genesis_if_selected do
    candidates = [node() | Node.list()] |> Enum.uniq() |> Enum.sort()
    genesis_members = Enum.take(candidates, target_size())

    if node() in genesis_members do
      do_form_genesis(genesis_members)
    else
      # Not among the computed genesis members this round — the reconcile
      # loop's ambient join path picks this node up once the actual genesis
      # members finish forming.
      :ok
    end
  end

  defp do_form_genesis(genesis_members) do
    case RaCluster.start_genesis_placement_cluster(genesis_members) do
      :ok ->
        broadcast_members(genesis_members)
        :ok

      {:error, :cluster_not_formed} = error ->
        error
    end
  end

  defp safe_reconcile do
    reconcile()
  rescue
    e ->
      Logger.warning(
        "PlacementMembership reconcile failed, skipping this tick (#{Exception.message(e)})",
        reason: Exception.message(e)
      )
  catch
    :exit, reason ->
      Logger.warning(
        "PlacementMembership reconcile failed, skipping this tick (#{inspect(reason)})",
        reason: inspect(reason)
      )
  end

  defp reconcile do
    case RaCluster.local_placement_members() do
      {:ok, members} ->
        cache_members(members)
        if RaCluster.placement_leader?(), do: reconcile_as_leader(members)

      :error ->
        reconcile_as_non_member()
    end
  end

  defp reconcile_as_non_member do
    case RaCluster.probe_placement_members([node() | Node.list()]) do
      {:ok, members} ->
        cache_members(members)
        if length(members) < target_size(), do: try_join(members)

      :error ->
        attempt_genesis()
    end
  end

  defp try_join(existing_members) do
    case RaCluster.join_placement_cluster(existing_members) do
      :ok -> broadcast_members(Enum.uniq([node() | existing_members]))
      {:error, _reason} -> :ok
    end
  end

  defp reconcile_as_leader(members) do
    dead =
      Enum.reject(members, &RaCluster.member_alive?(RaCluster.placement_server_id(&1)))

    cond do
      dead != [] ->
        [dead_node | _] = dead
        survivors = members -- [dead_node]

        case RaCluster.remove_placement_member(survivors, dead_node) do
          :ok -> broadcast_members(survivors)
          {:error, _reason} -> :ok
        end

      length(members) > target_size() ->
        to_remove = Enum.max(members)
        survivors = members -- [to_remove]

        case RaCluster.remove_placement_member(survivors, to_remove) do
          :ok -> broadcast_members(survivors)
          {:error, _reason} -> :ok
        end

      true ->
        :ok
    end
  end

  defp cache_members(members) do
    :ets.insert(@table, {:members, members})
  end

  defp broadcast_members(members) do
    cache_members(members)
    Phoenix.PubSub.broadcast(Riptide.PubSub, @topic, {:placement_membership_changed, members})
  end

  defp schedule_reconcile do
    interval =
      Application.get_env(:riptide, :placement_reconcile_interval_ms, @reconcile_interval_ms)

    Process.send_after(self(), :reconcile, interval)
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/riptide/placement_membership_test.exs`
Expected: FAIL still, at this step — `Riptide.PlacementMembership` isn't started by the application supervision tree yet (Task 4 does that), so `Phoenix.PubSub.subscribe/2` in `init/1` has no running process to attach to and `current_members/0`'s broadcast-test can't reach a live subscriber. This is expected and resolved by Task 4; do not treat this as a Task 2 regression. Instead, verify the module at least compiles and its pure functions work by running only the tests that don't depend on the application-started process:

Run: `mix test test/riptide/placement_membership_test.exs --only doctest` — this doesn't apply here since there are no doctests, so instead directly confirm compilation:

Run: `mix compile --warnings-as-errors`
Expected: compiles clean, 0 warnings.

- [ ] **Step 5: Run format and lint**

Run: `mix format && mix credo --strict`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add lib/riptide/placement_membership.ex test/riptide/placement_membership_test.exs
git commit -m "Add Riptide.PlacementMembership: discovery cache, genesis, and reconciliation"
```

(The full test suite for this module — including the tests that need it actually running under supervision — passes once Task 4 wires it into `Riptide.Application`. Task 4's own verification step re-runs this file's tests to confirm.)

---

## Task 3: `Riptide.Placement` — drop `resolve_fun`, discover members instead

**Files:**
- Modify: `lib/riptide/placement.ex`
- Test: `test/riptide/placement_snapshot_recovery_test.exs` (only the doc-comment reference — functional changes are Task 11), `test/riptide_web/health_test.exs`, `test/riptide_web/realtime/sse_controller_test.exs`

**Interfaces:**
- Consumes: `Riptide.PlacementMembership.current_members/0` (Task 2), `Riptide.RaCluster.probe_placement_members/1` and `placement_server_id/1` (Task 1).
- Produces: every `Riptide.Placement` public function (`assign/2`, `lookup/1`, `list_all/0`, `replace_member/3`, `claim_repair/2`, `release_repair/1`, `add_policy/3`, `list_policies/2`, `claim_tenant_if_unclaimed/2`) now takes ONE FEWER argument — the trailing `resolve_fun` parameter is gone from every one of them. Every caller across the codebase (checked below) already calls these with their default argument only, so no other production call site needs updating.

- [ ] **Step 1: Write the failing test for the new discovery-based fallback**

Add to a new `describe` block at the end of `test/riptide/placement_membership_test.exs` (same file Task 2 created) — this exercises `Riptide.Placement` against `Riptide.PlacementMembership`'s real discovery, closing the loop between the two modules:

```elixir
  describe "Riptide.Placement addressing (via PlacementMembership discovery)" do
    test "assign/2 and lookup/1 work against the real, currently-running placement cluster" do
      stream_id = "placement-membership-" <> Uniq.UUID.uuid4()
      proposed = [node()]

      assert Riptide.Placement.assign(stream_id, proposed) == proposed
      assert Riptide.Placement.lookup(stream_id) == proposed
    end

    test "falls back to a live fleet probe and raises when no member is reachable at all" do
      original = Application.get_env(:riptide, :placement_members_override)
      Application.put_env(:riptide, :placement_members_override, [:nonexistent@nohost])
      on_exit(fn -> Application.put_env(:riptide, :placement_members_override, original) end)

      assert_raise RuntimeError, ~r/no placement-cluster members could be/, fn ->
        Riptide.Placement.lookup("irrelevant-stream-id")
      end
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/riptide/placement_membership_test.exs`
Expected: the second test FAILS (no `:placement_members_override` support exists yet, so it falls through to the real, already-working discovery and never raises); the first test PASSES already (today's `resolve_fun`-based default already works against the real single-node suite cluster) — confirming the starting point before this task's change.

- [ ] **Step 3: Rewrite `lib/riptide/placement.ex`**

Replace the entire file's content (the whole module) with:

```elixir
defmodule Riptide.Placement do
  @moduledoc """
  Client API for Riptide's placement metadata cluster — the durable
  `stream_id -> [replica nodes]` mapping maintained by
  `Riptide.Placement.PlacementMachine` via a small, elastic-membership Ra
  cluster (see `Riptide.PlacementMembership`).

  Every function here addresses the metadata cluster by trying each
  currently-known member in turn (fast path: `Riptide.PlacementMembership`'s
  broadcast-maintained cache; fallback: a live fleet-wide probe when the
  cache is empty or exhausted) until one succeeds — `:ra`'s own
  leader-redirect already means any live member can serve the request
  whether or not it happens to be the current leader. See Phase 3e design
  spec for the full discovery rationale (this replaces the old fixed-3-
  ordinal fallback).
  """

  require Logger

  alias Riptide.Placement.PlacementMachine
  alias Riptide.PlacementMembership
  alias Riptide.RaCluster

  @replication_factor 3

  @spec propose_nodes(pos_integer(), [node()]) :: [node()]
  def propose_nodes(replication_factor \\ @replication_factor, peers \\ Node.list()) do
    local = node()
    remaining = max(replication_factor - 1, 0)
    other_candidates = peers -- [local]

    [local | select_nodes(other_candidates, remaining)]
  end

  @spec select_nodes([node()], pos_integer()) :: [node()]
  def select_nodes(candidate_nodes, count) do
    candidate_nodes
    |> Enum.uniq()
    |> Enum.shuffle()
    |> Enum.take(count)
  end

  @spec assign(String.t(), [node()]) :: [node()]
  def assign(stream_id, proposed_nodes) do
    :telemetry.span([:riptide, :placement, :assign], %{}, fn ->
      result =
        with_current_members(fn server_id ->
          RaCluster.process_command(server_id, {:assign, stream_id, proposed_nodes})
        end)

      {result, %{}}
    end)
  end

  @spec lookup(String.t()) :: [node()] | nil
  def lookup(stream_id) do
    :telemetry.span([:riptide, :placement, :lookup], %{}, fn ->
      result =
        with_current_members(fn server_id ->
          RaCluster.consistent_query(server_id, &PlacementMachine.get(&1, stream_id))
        end)

      {result, %{}}
    end)
  end

  @spec list_all() :: %{String.t() => [node()]}
  def list_all do
    with_current_members(fn server_id ->
      RaCluster.consistent_query(server_id, &PlacementMachine.list/1)
    end)
  end

  @spec replace_member(String.t(), node(), node()) :: [node()] | nil
  def replace_member(stream_id, dead_node, new_node) do
    with_current_members(fn server_id ->
      RaCluster.process_command(server_id, {:replace_member, stream_id, dead_node, new_node})
    end)
  end

  # See Riptide.Placement.PlacementMachine's own moduledoc ("Repair claims")
  # for the full rationale: fences Riptide.Stream.ReplicaHealer's repair
  # against two nodes both believing they're the leader at once. `now_ts` is
  # computed here (the caller), not inside `apply/3` — reading the wall
  # clock inside a Ra machine callback would break replica determinism.
  @spec claim_repair(String.t(), node()) :: :claimed | :already_claimed
  def claim_repair(stream_id, dead_node) do
    now_ts = System.system_time(:second)

    with_current_members(fn server_id ->
      RaCluster.process_command(
        server_id,
        {:claim_repair, stream_id, dead_node, node(), now_ts}
      )
    end)
  end

  @spec release_repair(String.t()) :: :ok
  def release_repair(stream_id) do
    with_current_members(fn server_id ->
      RaCluster.process_command(server_id, {:release_repair, stream_id, node()})
    end)
  end

  @spec add_policy(String.t(), [String.t()], Riptide.Authz.Policy.t()) ::
          :ok | {:error, :too_many_policies}
  def add_policy(tenant_id, path_prefix, policy) do
    with_current_members(fn server_id ->
      RaCluster.process_command(server_id, {:add_policy, tenant_id, path_prefix, policy})
    end)
  end

  @spec list_policies(String.t(), [String.t()]) :: [Riptide.Authz.Policy.t()]
  def list_policies(tenant_id, path_prefix) do
    with_current_members(fn server_id ->
      RaCluster.consistent_query(
        server_id,
        &PlacementMachine.list_policies(&1, tenant_id, path_prefix)
      )
    end)
  end

  @spec claim_tenant_if_unclaimed(String.t(), String.t()) :: :claimed | :already_claimed
  def claim_tenant_if_unclaimed(tenant_id, subject) do
    with_current_members(fn server_id ->
      RaCluster.process_command(server_id, {:claim_tenant_if_unclaimed, tenant_id, subject})
    end)
  end

  # Tries each currently-known member, in order, until one answers —
  # `RaCluster.process_command/2` and `consistent_query/2` both raise on
  # failure/timeout, so a failing member is caught here and the next one
  # tried instead of the whole call failing outright. If every member from
  # the fast-path cache fails, falls back to a live fleet-wide probe
  # (`RaCluster.probe_placement_members/1`) before finally raising — a
  # totally unreachable metadata cluster is a genuine, fully-down failure no
  # caller here can paper over.
  #
  # `:placement_members_override` is a narrow, test-only escape hatch (never
  # read outside `mix test`) letting a test simulate "no reachable member"
  # without tearing down the real shared suite-wide placement cluster other
  # tests depend on — see `test/riptide_web/health_test.exs` and
  # `test/riptide_web/realtime/sse_controller_test.exs`.
  @spec with_current_members((:ra.server_id() -> term())) :: term()
  defp with_current_members(fun) do
    case Application.get_env(:riptide, :placement_members_override) do
      nil -> with_current_members_via_discovery(fun)
      override_members -> with_current_members_via_list(override_members, fun)
    end
  end

  defp with_current_members_via_discovery(fun) do
    cached = PlacementMembership.current_members()

    case try_members(cached, fun) do
      {:ok, result} -> result
      :error -> with_current_members_via_probe(fun)
    end
  end

  defp with_current_members_via_probe(fun) do
    case RaCluster.probe_placement_members([node() | Node.list()]) do
      {:ok, members} -> with_current_members_via_list(members, fun)
      :error -> raise "Riptide.Placement: no placement-cluster members could be discovered"
    end
  end

  defp with_current_members_via_list(members, fun) do
    case try_members(members, fun) do
      {:ok, result} -> result
      :error -> raise "Riptide.Placement: no placement-cluster members could be reached"
    end
  end

  defp try_members([], _fun), do: :error

  defp try_members([node | rest], fun) do
    {:ok, fun.(RaCluster.placement_server_id(node))}
  rescue
    e ->
      log_member_fallback(node, Exception.message(e))
      try_members(rest, fun)
  catch
    :exit, reason ->
      log_member_fallback(node, inspect(reason))
      try_members(rest, fun)
  end

  # A single member failing over is expected/routine during a rolling
  # restart or a transient network blip — this is intentionally a warning,
  # not swallowed silently, so a *persistently* unreachable member is at
  # least visible in logs even though only total failure is reflected in
  # the `riptide.placement.lookup/assign.errors` metrics.
  defp log_member_fallback(node, reason) do
    Logger.warning(
      "Riptide.Placement: member #{inspect(node)} failed, falling back to the next one " <>
        "(#{reason})",
      node: node,
      reason: reason
    )

    :telemetry.execute([:riptide, :placement, :member_fallback], %{}, %{})
  end
end
```

- [ ] **Step 4: Update `test/riptide_web/health_test.exs`'s unreachable-cluster test**

Replace the `test "returns 503 when the placement cluster is unreachable"` block (lines 30-45) with:

```elixir
    # :placement_members_override is global Application state that every
    # other test touching Riptide.Placement also reads — this test module is
    # async: false specifically so this override never races a concurrently-
    # running async test.
    test "returns 503 when the placement cluster is unreachable" do
      original = Application.get_env(:riptide, :placement_members_override)
      Application.put_env(:riptide, :placement_members_override, [:nonexistent@nohost])
      on_exit(fn -> Application.put_env(:riptide, :placement_members_override, original) end)

      conn =
        :get
        |> conn("/health/ready")
        |> RiptideWeb.Endpoint.call(@opts)

      assert conn.status == 503
    end
```

- [ ] **Step 5: Update `test/riptide_web/realtime/sse_controller_test.exs`'s equivalent test**

Read the surrounding context first: `grep -n -B5 -A5 "ordinal_resolver" test/riptide_web/realtime/sse_controller_test.exs`. Replace the 3-line block:

```elixir
      original = Application.get_env(:riptide, :ordinal_resolver)
      Application.put_env(:riptide, :ordinal_resolver, fn _ordinal -> :nonexistent@nohost end)
      on_exit(fn -> Application.put_env(:riptide, :ordinal_resolver, original) end)
```

with:

```elixir
      original = Application.get_env(:riptide, :placement_members_override)
      Application.put_env(:riptide, :placement_members_override, [:nonexistent@nohost])
      on_exit(fn -> Application.put_env(:riptide, :placement_members_override, original) end)
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `mix test test/riptide/placement.ex test/riptide_web/health_test.exs test/riptide_web/realtime/sse_controller_test.exs test/riptide/placement_membership_test.exs`

(Note: `test/riptide/placement.ex` above is a typo guard — there is no such test file; the actual command is:)

Run: `mix test test/riptide_web/health_test.exs test/riptide_web/realtime/sse_controller_test.exs test/riptide/placement_membership_test.exs`
Expected: PASS — all green.

- [ ] **Step 7: Run format and lint**

Run: `mix format && mix credo --strict`
Expected: clean.

- [ ] **Step 8: Commit**

```bash
git add lib/riptide/placement.ex test/riptide_web/health_test.exs test/riptide_web/realtime/sse_controller_test.exs test/riptide/placement_membership_test.exs
git commit -m "Placement: drop resolve_fun, address the metadata cluster via live discovery"
```

---

## Task 4: `Riptide.Application` — always start the membership controller and healer

**Files:**
- Modify: `lib/riptide/application.ex`

**Interfaces:**
- Consumes: `Riptide.PlacementMembership` (Task 2).
- Produces: `Riptide.PlacementMembership` and `Riptide.Stream.ReplicaHealer` both run unconditionally on every node — no more `HOSTNAME`-gated `placement_bootstrap_children/0`.

- [ ] **Step 1: Replace `placement_bootstrap_children/0`'s conditional with an unconditional list**

Replace the whole `placement_bootstrap_children/0` private function (lines 53-99) with:

```elixir
  # Every fleet node runs both of these now — Riptide.PlacementMembership's
  # own reconciliation loop (Phase 3e) decides internally whether THIS node
  # should be a placement-cluster member (join if under target size) or act
  # as the repair/shrink leader (only if it currently is one and is the
  # cluster's Raft leader), replacing the old static HOSTNAME-matches-one-
  # of-3-fixed-ordinals gate entirely. Riptide.Stream.ReplicaHealer already
  # only acts when `RaCluster.placement_leader?/0` is true, so running it
  # unconditionally is safe — it's a no-op everywhere except the one real
  # leader, exactly the same safety property it already had.
  defp placement_children do
    [
      Riptide.PlacementMembership,
      Riptide.Stream.ReplicaHealer
    ]
  end
```

Update the one call site in `start/2` (the `++ placement_bootstrap_children() ++` line) to call the renamed function:

```elixir
      ] ++
        placement_children() ++
        auth_children() ++
```

- [ ] **Step 2: Give `Riptide.PlacementMembership` a generous shutdown timeout for graceful drain**

`Riptide.PlacementMembership`'s `terminate/2` (Task 2) calls `RaCluster.remove_placement_member/2`, whose underlying `:ra.remove_member/2` retries up to 50 times at 100ms apiece on a transient `:cluster_change_not_permitted` (`retry_cluster_change/2`'s own default in `ra_cluster.ex`) — up to 5 seconds. The default Supervisor child shutdown timeout (5000ms) doesn't leave enough margin. In `placement_children/0` (Step 1 above), wrap the child spec with an explicit shutdown timeout:

```elixir
  defp placement_children do
    [
      Supervisor.child_spec(Riptide.PlacementMembership, shutdown: 10_000),
      Riptide.Stream.ReplicaHealer
    ]
  end
```

- [ ] **Step 3: Run the full test suite**

Run: `mix test`
Expected: PASS — every test in the suite green, including `test/riptide/placement_membership_test.exs`'s tests that depend on `Riptide.PlacementMembership` actually running under supervision (Task 2's Step 4 note) — they should now pass for real.

- [ ] **Step 4: Run format and lint**

Run: `mix format && mix credo --strict`
Expected: clean.

- [ ] **Step 5: Commit**

```bash
git add lib/riptide/application.ex
git commit -m "Application: run PlacementMembership + ReplicaHealer on every node, not just 3 fixed ordinals"
```

---

## Task 5: Config cleanup — remove `ordinal_resolver`/`RIPTIDE_SINGLE_NODE`, add `RIPTIDE_PLACEMENT_TARGET_SIZE`

**Files:**
- Modify: `config/dev.exs`
- Modify: `config/test.exs`
- Modify: `config/runtime.exs`
- Modify: `test/test_helper.exs`

**Interfaces:**
- Produces: `Application.get_env(:riptide, :placement_target_size)` — read by `Riptide.PlacementMembership.target_size/0` (Task 2).

- [ ] **Step 1: Remove `config/dev.exs`'s `ordinal_resolver` override**

Delete this entire block (the comment and the `config :riptide, ordinal_resolver: ...` line):

```elixir
# No real headless-service DNS exists on a developer's own machine — every
# ordinal resolves to whichever node is actually asking, exactly mirroring
# config/test.exs's own identical override (see its own comment for the
# full rationale). Without this, Riptide.RaCluster.default_ordinal_resolver/1
# falls through to real DNS (riptide-1.riptide-headless, etc.), which never
# resolves locally. Real Kubernetes deployments (config/runtime.exs) are
# untouched and keep using real DNS. A developer must still run with
# HOSTNAME set to one of the 3 fixed ordinals
# ("riptide-0"/"riptide-1"/"riptide-2") for
# Riptide.Application.placement_bootstrap_children/0's own separate gate to
# even attempt bootstrapping — this override alone isn't sufficient by
# itself, see the README's "Running locally for development" section. It
# is ALSO not sufficient on its own without Part B's fix below — see that
# section for why.
config :riptide, ordinal_resolver: fn _ordinal -> node() end

```

- [ ] **Step 2: Remove `config/test.exs`'s `ordinal_resolver` override**

Delete this entire block:

```elixir
# No real headless-service DNS exists in this environment — every ordinal
# resolves to whichever node is actually asking, which is correct for the
# single-node async suite (test_helper.exs bootstraps all 3 fixed ordinals
# collapsed onto this one, origin BEAM node running `mix test`). Real
# multi-node :peer-based tests need a *different*, per-node mechanism (see
# Task 6 in the plan, which sets this same application env key individually
# on each peer via :erpc with a real per-peer ordinal->node mapping) since
# :peer nodes don't load this file at all. Never applies outside
# MIX_ENV=test — config/runtime.exs (real Kubernetes) is untouched and keeps
# using real DNS.
config :riptide, ordinal_resolver: fn _ordinal -> node() end
```

- [ ] **Step 3: Remove `config/runtime.exs`'s `RIPTIDE_SINGLE_NODE` block and add `RIPTIDE_PLACEMENT_TARGET_SIZE`**

Replace this entire block:

```elixir
# Opt-in single-node override, mirroring config/dev.exs's and config/test.exs's
# own identical `ordinal_resolver` override (see either's comment for the full
# rationale) — collapses all 3 placement ordinals to whatever node this
# process actually is. A real single-machine deployment outside Kubernetes
# (Fly.io, plain `docker run`/`docker-compose`) has no headless-service DNS
# resolving "riptide-0"/"riptide-1"/"riptide-2" the way
# `default_ordinal_resolver/1`'s real-DNS fallback expects. Without this,
# `/health/ready` — and every LDP/SSE/WebSocket request, all of which route
# through `Riptide.Placement.lookup/1` — permanently 503s on any such
# deployment (confirmed live on Fly.io: `nxdomain` resolving each ordinal).
# A deployment opting into this must ALSO run with `HOSTNAME` set to one of
# the 3 fixed ordinals ("riptide-0"/"riptide-1"/"riptide-2") for
# `Riptide.Application.placement_bootstrap_children/0`'s own separate gate to
# even attempt bootstrapping the (now single-member) placement cluster.
if System.get_env("RIPTIDE_SINGLE_NODE") do
  config :riptide, ordinal_resolver: fn _ordinal -> node() end
end
```

with:

```elixir
# The placement/metadata Raft cluster's target member count (Phase 3e) —
# replaces the old fixed-3-ordinal scheme entirely. Deliberately NOT
# excluded for :test (unlike RIPTIDE_RA_DATA_DIR/OIDC above): the async
# suite's own bootstrap (test_helper.exs) forms a real 1-member cluster
# regardless of this value, and letting it default the same way everywhere
# means dev/test/prod all go through the exact same code path with zero
# special-casing. Validated odd: an even-sized Raft cluster doesn't improve
# fault tolerance over the next-lower odd size and risks tie votes.
placement_target_size =
  System.get_env("RIPTIDE_PLACEMENT_TARGET_SIZE", "3") |> String.to_integer()

unless Riptide.PlacementMembership.valid_target_size?(placement_target_size) do
  raise """
  environment variable RIPTIDE_PLACEMENT_TARGET_SIZE must be a positive odd \
  number (got #{placement_target_size}) — an even-sized Raft cluster doesn't \
  improve fault tolerance over the next-lower odd size and risks tie votes.
  """
end

config :riptide, placement_target_size: placement_target_size
```

- [ ] **Step 4: Update `test/test_helper.exs`'s bootstrap line**

Replace:

```elixir
:ok = Riptide.RaCluster.attempt_start_placement_cluster()
```

with:

```elixir
:ok = Riptide.RaCluster.start_genesis_placement_cluster([node()])
```

Also update the comment immediately above it (lines 82-91) — replace:

```elixir
# Riptide.Application's own placement-cluster bootstrap only runs on pods
# whose HOSTNAME matches one of the 3 fixed ordinals — never true here. This
# gives the whole async suite a real, running (single-node-collapsed)
# placement cluster to assign/lookup against, so every test that goes
# through Riptide.Stream.Placement (Phase 3c-ii) can exercise real
# Placement.assign/2/lookup/2 calls, not just pure logic. Uses the same
# config-driven ordinal_resolver Step 3 just added (config/test.exs), not
# an explicit resolver here — this must resolve exactly the same way
# Placement.assign/2/lookup/2's own default argument will later, or the
# bootstrapped cluster and later calls address different servers.
#
# Now runs under a stable, real node() (set immediately above) rather than
# :nonode@nohost — see the SIDE-FIX comment above for why that stability is
# required for this bootstrap to survive the rest of the suite.
```

with:

```elixir
# Riptide.Application now starts Riptide.PlacementMembership unconditionally
# on every node (Phase 3e) rather than gating on a fixed HOSTNAME allowlist
# — but that controller's own genesis logic has a settle window and isn't
# guaranteed to have formed a cluster by the time the very first test runs.
# Forming it explicitly and synchronously here, once, before any test runs,
# gives the whole async suite a real, running (single-node) placement
# cluster to assign/lookup against immediately, so every test that goes
# through Riptide.Stream.Placement can exercise real Placement.assign/2/
# lookup/1 calls from its very first line, not just pure logic. Redundant
# with whatever Riptide.PlacementMembership's own genesis attempt does on
# this same node — self-corrects via the same idempotent-redundant-call
# handling `start_genesis_placement_cluster/1` already provides.
#
# Runs under a stable, real node() (set immediately above) rather than
# :nonode@nohost — see the SIDE-FIX comment above for why that stability is
# required for this bootstrap to survive the rest of the suite.
```

- [ ] **Step 5: Run the full test suite**

Run: `mix test`
Expected: PASS — every test green. (This is the first point where the whole `ordinal_resolver` concept is fully gone from `config/`; if any test still references it, it now fails loudly here rather than silently.)

- [ ] **Step 6: Run format and lint**

Run: `mix format && mix credo --strict`
Expected: clean.

- [ ] **Step 7: Commit**

```bash
git add config/dev.exs config/test.exs config/runtime.exs test/test_helper.exs
git commit -m "Config: remove ordinal_resolver/RIPTIDE_SINGLE_NODE, add RIPTIDE_PLACEMENT_TARGET_SIZE"
```

---

## Task 6: Fix stale doc-comment references to removed functions

**Files:**
- Modify: `lib/riptide_web/plugs/resolve_tenant.ex`
- Modify: `lib/riptide/auth/verifier.ex`
- Modify: `lib/riptide/tenancy/resolver.ex`
- Modify: `lib/riptide/placement/placement_machine.ex`
- Modify: `test/riptide/placement_test.exs` (a genuine plan gap found only once the full
  test suite ran for real — not caught by the earlier codebase-wide audit)

The first 4 files reference `Riptide.RaCluster.default_ordinal_resolver/1` or
`placement_server_id/1,2` in prose comments only (no functional code depends on them) —
purely doc drift now that Tasks 1-3 removed/changed those functions. `test/riptide/
placement_test.exs` is different: it has one REAL test (not a comment) still calling the
removed `Placement.lookup/2` (with a `resolve_fun` argument) to simulate "every member
unreachable" — this file was missed by the original repo-wide audit because that audit's
searches matched `Riptide.Placement.lookup/2` calls generically but this specific one
wasn't distinguished from the many legitimate `lookup/1` calls elsewhere in the same file
until the suite actually ran and failed on it.

- [ ] **Step 1: Fix the 4 stale doc comments**

Applied (verified against each file's real surrounding sentence, not just a literal
function-name swap, so each reads grammatically):

- `lib/riptide_web/plugs/resolve_tenant.ex`: replaced "mirrors `Riptide.RaCluster.
  default_ordinal_resolver/1`'s config-driven resolver swap (Phase 3c-i)" with "a
  config-driven resolver swap (Phase 4a)" — the cross-reference is simply dropped rather
  than pointed at a new analog, since `Riptide.PlacementMembership` doesn't have an
  equivalent "swap via config" mechanism anymore (the whole point of Phase 3e is that
  kind of runtime-swappable resolver is gone, replaced by real discovery).
- `lib/riptide/auth/verifier.ex`: replaced "the same config-driven swap `Riptide.Tenancy.
  Resolver` (Phase 4a) and `Riptide.RaCluster.default_ordinal_resolver/1` (Phase 3c-i)
  already use" with "the same config-driven swap `Riptide.Tenancy.Resolver` (Phase 4a)
  already uses" — same reasoning, drop rather than repoint.
- `lib/riptide/tenancy/resolver.ex`: replaced "the same config-driven swap `Riptide.
  RaCluster.default_ordinal_resolver/1` already uses (Phase 3c-i)" with "a config-driven
  swap for picking a resolution strategy per deployment" — same reasoning.
- `lib/riptide/placement/placement_machine.ex`: replaced "a small, fixed-membership Ra
  cluster (see `Riptide.RaCluster.placement_server_id/1,2`)" with "a small,
  elastic-membership Ra cluster (see `Riptide.PlacementMembership`)".

- [ ] **Step 2: Fix `test/riptide/placement_test.exs`**

Change the module to `async: false` (it has 15 other tests, all fine as `async: true`, but
the one fix below sets `:placement_members_override`, global Application state every
other test touching `Riptide.Placement` anywhere in the suite also reads — matching the
exact reasoning `test/riptide_web/health_test.exs` and `test/riptide_web/realtime/
sse_controller_test.exs` already use for the identical hazard):

```elixir
defmodule Riptide.PlacementTest do
  # async: false — the "emits an exception event when every member fails"
  # test below sets :placement_members_override, global Application state
  # every other test touching Riptide.Placement anywhere in the suite also
  # reads, matching the same reasoning test/riptide_web/health_test.exs and
  # test/riptide_web/realtime/sse_controller_test.exs already use for the
  # identical hazard.
  use ExUnit.Case, async: false
```

Replace the failing test:

```elixir
    test "lookup/1 emits an exception event when every ordinal fails" do
      failing_resolver = fn _ordinal -> :nonexistent@nohost end

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:riptide, :placement, :lookup, :exception]
        ])

      assert_raise RuntimeError, fn ->
        Placement.lookup("some-stream-id", failing_resolver)
      end

      assert_received {[:riptide, :placement, :lookup, :exception], ^ref, %{duration: _},
                       %{kind: :error}}
    end
```

with:

```elixir
    test "lookup/1 emits an exception event when every member fails" do
      original = Application.get_env(:riptide, :placement_members_override)
      Application.put_env(:riptide, :placement_members_override, [:nonexistent@nohost])
      on_exit(fn -> Application.put_env(:riptide, :placement_members_override, original) end)

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:riptide, :placement, :lookup, :exception]
        ])

      assert_raise RuntimeError, fn ->
        Placement.lookup("some-stream-id")
      end

      assert_received {[:riptide, :placement, :lookup, :exception], ^ref, %{duration: _},
                       %{kind: :error}}
    end
```

- [ ] **Step 3: Run the full test suite**

Run: `mix test`
Expected: PASS — this closes the last remaining Task-6-scope gap; only Tasks 7-12's own
`:peer`-based files should still fail after this step.

- [ ] **Step 4: Run format and lint**

Run: `mix format && mix credo --strict`
Expected: clean.

- [ ] **Step 5: Commit**

```bash
git add lib/riptide_web/plugs/resolve_tenant.ex lib/riptide/auth/verifier.ex lib/riptide/tenancy/resolver.ex lib/riptide/placement/placement_machine.ex test/riptide/placement_test.exs
git commit -m "Fix stale doc references and a missed old-API test call (test/riptide/placement_test.exs)"
```

---

## Task 7: Update `test/riptide/ra_cluster_cold_restart_test.exs`

**Files:**
- Modify: `test/riptide/ra_cluster_cold_restart_test.exs`

- [ ] **Step 1: Replace the one call site**

Replace:

```elixir
    :ok = RaCluster.attempt_start_placement_cluster()
```

with:

```elixir
    :ok = RaCluster.start_genesis_placement_cluster([node()])
```

- [ ] **Step 2: Run the test**

Run: `mix test test/riptide/ra_cluster_cold_restart_test.exs`
Expected: PASS.

- [ ] **Step 3: Run format and lint**

Run: `mix format && mix credo --strict`
Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add test/riptide/ra_cluster_cold_restart_test.exs
git commit -m "Update ra_cluster_cold_restart_test.exs for the new genesis API"
```

---

## Task 8: Update `test/riptide/placement_cluster_test.exs` (the canonical `:peer`-based pattern)

**Files:**
- Modify: `test/riptide/placement_cluster_test.exs`

- [ ] **Step 1: Remove the `resolve_fun`/`ordinal_to_node` machinery from `bootstrap/0`**

Replace:

```elixir
  defp bootstrap do
    pa_args = Enum.flat_map(:code.get_path(), fn p -> [~c"-pa", p] end)
    peers = spawn_peers(pa_args)

    on_exit(fn -> cleanup_peers(peers) end)

    push_module_to_peers(peers)

    nodes = Enum.map(peers, fn {_pid, node, _ordinal} -> node end)
    ordinal_to_node = Map.new(peers, fn {_pid, node, ordinal} -> {ordinal, node} end)
    resolve_fun = fn ordinal -> Map.fetch!(ordinal_to_node, ordinal) end

    for {n1, n2} <- unique_pairs(nodes) do
      assert :erpc.call(n1, :net_kernel, :connect_node, [n2]) == true
    end

    bootstrap_ra_on_peers(peers)
    form_placement_cluster(peers, resolve_fun)

    {peers, nodes, resolve_fun}
  end
```

with:

```elixir
  defp bootstrap do
    pa_args = Enum.flat_map(:code.get_path(), fn p -> [~c"-pa", p] end)
    peers = spawn_peers(pa_args)

    on_exit(fn -> cleanup_peers(peers) end)

    push_module_to_peers(peers)

    nodes = Enum.map(peers, fn {_pid, node, _ordinal} -> node end)

    for {n1, n2} <- unique_pairs(nodes) do
      assert :erpc.call(n1, :net_kernel, :connect_node, [n2]) == true
    end

    bootstrap_ra_on_peers(peers)
    form_placement_cluster(peers, nodes)

    {peers, nodes}
  end
```

- [ ] **Step 2: Replace `form_placement_cluster/2`**

Replace:

```elixir
  defp form_placement_cluster(peers, resolve_fun) do
    results =
      Enum.map(peers, fn {_pid, node, _ordinal} ->
        :erpc.call(node, Riptide.RaCluster, :attempt_start_placement_cluster, [resolve_fun])
      end)

    assert Enum.all?(results, &(&1 in [:ok, {:error, :cluster_not_formed}]))
    assert Enum.any?(results, &(&1 == :ok))
  end
```

with:

```elixir
  defp form_placement_cluster(peers, nodes) do
    results =
      Enum.map(peers, fn {_pid, node, _ordinal} ->
        :erpc.call(node, Riptide.RaCluster, :start_genesis_placement_cluster, [nodes])
      end)

    assert Enum.all?(results, &(&1 in [:ok, {:error, :cluster_not_formed}]))
    assert Enum.any?(results, &(&1 == :ok))
  end
```

- [ ] **Step 3: Update both `test` blocks' call sites**

Each of the file's 2 tests destructures `{peers, nodes, resolve_fun} = bootstrap()` and then calls `Riptide.Placement.assign/lookup` with `resolve_fun` as a trailing argument. Update both:

Replace `{peers, nodes, resolve_fun} = bootstrap()` (appears twice, once per test) with `{peers, nodes} = bootstrap()`.

Replace every `:erpc.call(entry_node, Riptide.Placement, :assign, [stream_id, proposed, resolve_fun])` with `:erpc.call(entry_node, Riptide.Placement, :assign, [stream_id, proposed])`.

Replace every `:erpc.call(node, Riptide.Placement, :lookup, [stream_id, resolve_fun])` with `:erpc.call(node, Riptide.Placement, :lookup, [stream_id])`.

Replace `:erpc.call(other_node, Riptide.Placement, :assign, [stream_id, different_proposal, resolve_fun])` with `:erpc.call(other_node, Riptide.Placement, :assign, [stream_id, different_proposal])`.

- [ ] **Step 4: Run the test**

Run: `mix test test/riptide/placement_cluster_test.exs`
Expected: PASS.

- [ ] **Step 5: Run format and lint**

Run: `mix format && mix credo --strict`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add test/riptide/placement_cluster_test.exs
git commit -m "Update placement_cluster_test.exs for the new genesis/discovery API"
```

---

## Task 9: Update `test/riptide/stream/stream_placement_cluster_test.exs`

**Files:**
- Modify: `test/riptide/stream/stream_placement_cluster_test.exs`

- [ ] **Step 1: Remove `resolve_fun` from both test bodies**

In `test "a genuinely new stream forms a real 3-member cluster across 3 real nodes and replicates writes"`, replace:

```elixir
    {peers, nodes, resolve_fun} = start_and_bootstrap_peers(@new_stream_peers)
```

with:

```elixir
    {peers, nodes} = start_and_bootstrap_peers(@new_stream_peers)
```

and delete the trailing `_ = resolve_fun` line near the end of that same test (it exists only to silence an unused-variable warning for a variable that no longer exists).

In `test "a stream with real pre-existing on-disk data on one node backfills to that node alone"`, replace:

```elixir
    {peers, _nodes, resolve_fun} = start_and_bootstrap_peers(@backfill_peers)
```

with:

```elixir
    {peers, _nodes} = start_and_bootstrap_peers(@backfill_peers)
```

and replace both occurrences of:

```elixir
    assert :erpc.call(origin_node, Riptide.Placement, :lookup, [stream_id, resolve_fun]) == nil
```

and:

```elixir
    assert :erpc.call(origin_node, Riptide.Placement, :lookup, [stream_id, resolve_fun]) == [
             origin_node
           ]
```

with:

```elixir
    assert :erpc.call(origin_node, Riptide.Placement, :lookup, [stream_id]) == nil
```

and:

```elixir
    assert :erpc.call(origin_node, Riptide.Placement, :lookup, [stream_id]) == [origin_node]
```

respectively.

- [ ] **Step 2: Rewrite `start_and_bootstrap_peers/1` to drop the resolver**

Replace:

```elixir
  defp start_and_bootstrap_peers(peer_specs) do
    pa_args = Enum.flat_map(:code.get_path(), fn p -> [~c"-pa", p] end)

    peers = spawn_peers(peer_specs, pa_args)

    push_test_module_to_peers(peers)

    nodes = Enum.map(peers, fn {_pid, node, _ordinal} -> node end)
    ordinal_to_node = Map.new(peers, fn {_pid, node, ordinal} -> {ordinal, node} end)
    resolve_fun = fn ordinal -> Map.fetch!(ordinal_to_node, ordinal) end

    configure_ordinal_resolver(peers, resolve_fun)
    connect_peers(nodes)
    start_ra_application(peers)
    start_ra_systems(peers)
    bootstrap_placement_cluster(peers, resolve_fun)
    start_pubsub(peers)
    start_placement_server(peers)

    {peers, nodes, resolve_fun}
  end
```

with:

```elixir
  defp start_and_bootstrap_peers(peer_specs) do
    pa_args = Enum.flat_map(:code.get_path(), fn p -> [~c"-pa", p] end)

    peers = spawn_peers(peer_specs, pa_args)

    push_test_module_to_peers(peers)

    nodes = Enum.map(peers, fn {_pid, node, _ordinal} -> node end)

    connect_peers(nodes)
    start_ra_application(peers)
    start_ra_systems(peers)
    bootstrap_placement_cluster(peers, nodes)
    start_pubsub(peers)
    start_placement_server(peers)

    {peers, nodes}
  end
```

- [ ] **Step 3: Delete `configure_ordinal_resolver/2` entirely**

Delete the whole function, including its doc comment:

```elixir
  # Riptide.Placement.assign/2's and lookup/2's *default* argument is
  # RaCluster.default_ordinal_resolver/1, which (since Task 1) consults
  # Application.get_env(:riptide, :ordinal_resolver) — but :peer-spawned
  # nodes never load Mix config at all, so config/test.exs's override
  # (an identity resolver, correct for the collapsed single-node async
  # suite) never reaches them, and isn't what real distinct peers need
  # anyway. Riptide.Stream.Placement/StreamServer (called via erpc below)
  # never pass an explicit resolver — their public APIs deliberately
  # don't expose one — so each peer needs this set explicitly here, using
  # the SAME real ordinal->node mapping used for the placement cluster's
  # own bootstrap immediately below.
  defp configure_ordinal_resolver(peers, resolve_fun) do
    for {_pid, node, _ordinal} <- peers do
      :erpc.call(node, Application, :put_env, [:riptide, :ordinal_resolver, resolve_fun])
    end
  end
```

- [ ] **Step 4: Rewrite `bootstrap_placement_cluster/2`**

Replace:

```elixir
  defp bootstrap_placement_cluster(peers, resolve_fun) do
    results =
      Enum.map(peers, fn {_pid, node, _ordinal} ->
        :erpc.call(node, Riptide.RaCluster, :attempt_start_placement_cluster, [resolve_fun])
      end)

    assert Enum.any?(results, &(&1 == :ok))
  end
```

with:

```elixir
  defp bootstrap_placement_cluster(peers, nodes) do
    results =
      Enum.map(peers, fn {_pid, node, _ordinal} ->
        :erpc.call(node, Riptide.RaCluster, :start_genesis_placement_cluster, [nodes])
      end)

    assert Enum.any?(results, &(&1 == :ok))
  end
```

- [ ] **Step 5: Run the test**

Run: `mix test test/riptide/stream/stream_placement_cluster_test.exs`
Expected: PASS.

- [ ] **Step 6: Run format and lint**

Run: `mix format && mix credo --strict`
Expected: clean.

- [ ] **Step 7: Commit**

```bash
git add test/riptide/stream/stream_placement_cluster_test.exs
git commit -m "Update stream_placement_cluster_test.exs for the new genesis/discovery API"
```

---

## Task 10: Update the 3 ReplicaHealer `:peer`-based test files

**Files:**
- Modify: `test/riptide/stream/replica_healer_cluster_test.exs`
- Modify: `test/riptide/stream/replica_healer_leadership_gate_test.exs`
- Modify: `test/riptide/stream/replica_healer_retention_test.exs`

All 3 files share the exact same bootstrap shape as `placement_cluster_test.exs` (Task 8): spawn `:peer`s with a `HOSTNAME` ordinal env var, build an `ordinal_to_node`/`resolve_fun` pair, push it to every peer via `Application.put_env`, then call `attempt_start_placement_cluster([resolve_fun])` on a subset of peers.

- [ ] **Step 1: Apply the identical transformation to each of the 3 files**

For each file, run `grep -n "ordinal_to_node\|resolve_fun\|attempt_start_placement_cluster\|Application, :put_env" <file>` first to locate its exact lines (they may differ slightly file-to-file), then apply the same 3 changes Task 8 made to `placement_cluster_test.exs`:

1. Delete the `Application.put_env(:riptide, :ordinal_resolver, resolve_fun)` `:erpc.call` loop entirely — e.g. in `replica_healer_cluster_test.exs`:

```elixir
    for {_pid, node, _ordinal} <- peers do
      :erpc.call(node, Application, :put_env, [:riptide, :ordinal_resolver, resolve_fun])
    end
```

2. Delete the `ordinal_to_node`/`resolve_fun` construction:

```elixir
    ordinal_to_node = Map.new(peers, fn {_pid, node, ordinal} -> {ordinal, node} end)
    resolve_fun = fn ordinal -> Map.fetch!(ordinal_to_node, ordinal) end
```

3. Replace the placement-cluster-formation call:

```elixir
      Enum.map(placement_peers, fn {_pid, node, _ordinal} ->
        :erpc.call(node, Riptide.RaCluster, :attempt_start_placement_cluster, [resolve_fun])
      end)
```

with:

```elixir
      Enum.map(placement_peers, fn {_pid, node, _ordinal} ->
        :erpc.call(node, Riptide.RaCluster, :start_genesis_placement_cluster, [nodes])
      end)
```

(`nodes` here is `placement_peers`' own real node list — `replica_healer_cluster_test.exs` and `replica_healer_leadership_gate_test.exs` both already compute a `nodes` variable analogous to `placement_cluster_test.exs`'s; confirm the exact local variable name via the grep above and use whichever the file already defines for "the real node identities of the 3 placement peers.")

4. Remove any remaining trailing `resolve_fun` argument from `Riptide.Placement`/`RaCluster.placement_server_id` calls in each file (same as Task 8 Step 3 / Task 9 Step 4).

- [ ] **Step 2: Run the 3 tests**

Run: `mix test test/riptide/stream/replica_healer_cluster_test.exs test/riptide/stream/replica_healer_leadership_gate_test.exs test/riptide/stream/replica_healer_retention_test.exs`
Expected: PASS — all green.

- [ ] **Step 3: Run format and lint**

Run: `mix format && mix credo --strict`
Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add test/riptide/stream/replica_healer_cluster_test.exs test/riptide/stream/replica_healer_leadership_gate_test.exs test/riptide/stream/replica_healer_retention_test.exs
git commit -m "Update ReplicaHealer :peer-based tests for the new genesis/discovery API"
```

---

## Task 11: Update `test/riptide/placement_snapshot_recovery_test.exs`

**Files:**
- Modify: `test/riptide/placement_snapshot_recovery_test.exs`

This file directly exercises `Riptide.RaCluster`'s own low-level recovery mechanism (bypassing `Riptide.PlacementMembership`'s GenServer entirely, via direct `:erpc` calls) — its scenario (2-of-3 quorum loss, then 2 fresh replacement peers reusing the same `HOSTNAME`/on-disk data under brand-new `node()` identities) stays exactly as-is; only the ordinal/resolver plumbing needs updating.

- [ ] **Step 1: Remove `original_resolve_fun` and update the first `Riptide.Placement`/formation call sites**

Replace:

```elixir
    original_resolver =
      Map.new(original_peers, fn {_pid, node, ordinal} -> {ordinal, node} end)

    original_resolve_fun = fn ordinal -> Map.fetch!(original_resolver, ordinal) end

    bootstrap_ra(original_peers)
    form_placement_cluster(original_peers, original_resolve_fun)
```

with:

```elixir
    bootstrap_ra(original_peers)
    form_placement_cluster(original_peers, nodes)
```

Replace:

```elixir
    assigned =
      :erpc.call(node_a, Riptide.Placement, :assign, [
        stream_id,
        [node_a],
        original_resolve_fun
      ])

    assert assigned == [node_a]

    assert :erpc.call(node_c, Riptide.Placement, :lookup, [stream_id, original_resolve_fun]) ==
             [node_a]
```

with:

```elixir
    assigned = :erpc.call(node_a, Riptide.Placement, :assign, [stream_id, [node_a]])

    assert assigned == [node_a]

    assert :erpc.call(node_c, Riptide.Placement, :lookup, [stream_id]) == [node_a]
```

- [ ] **Step 2: Remove `fresh_resolve_fun` and update the second formation/lookup call sites**

Replace:

```elixir
    fresh_resolver =
      Map.new([{"riptide-0", node_a2}, {"riptide-1", node_b2}, {"riptide-2", node_c}])

    fresh_resolve_fun = fn ordinal -> Map.fetch!(fresh_resolver, ordinal) end

    # Both fresh replacements attempt to (re)form the placement cluster —
    # exactly what `RaCluster.ensure_placement_cluster_started/0`'s
    # boot-time infinite-retry loop already does on every real pod boot,
    # with no new code needed for this to work.
    for {_pid, node, _ordinal} <- replacement_peers do
      _ =
        :erpc.call(node, Riptide.RaCluster, :attempt_start_placement_cluster, [
          fresh_resolve_fun
        ])
    end
```

with:

```elixir
    fresh_nodes = [node_a2, node_b2, node_c]

    # Both fresh replacements attempt to (re)form the placement cluster —
    # exactly what `Riptide.PlacementMembership`'s own reconcile loop does
    # on every real pod boot (Phase 3e), just driven directly here instead
    # of waiting on that loop's timer, so this test proves the underlying
    # `:ra` recovery mechanism itself (`RaCluster.start_genesis_placement_
    # cluster/1`'s internal `:ra.start_cluster/2` call trusting the fresh
    # member list when no snapshot exists — see this file's own moduledoc)
    # independent of the higher-level controller's timing.
    for {_pid, node, _ordinal} <- replacement_peers do
      _ = :erpc.call(node, Riptide.RaCluster, :start_genesis_placement_cluster, [fresh_nodes])
    end
```

Replace:

```elixir
    assert :erpc.call(node_c, Riptide.Placement, :lookup, [stream_id, fresh_resolve_fun]) ==
             [node_a]
```

with:

```elixir
    assert :erpc.call(node_c, Riptide.Placement, :lookup, [stream_id]) == [node_a]
```

- [ ] **Step 3: Run the test**

Run: `mix test test/riptide/placement_snapshot_recovery_test.exs`
Expected: PASS.

- [ ] **Step 4: Run format and lint**

Run: `mix format && mix credo --strict`
Expected: clean.

- [ ] **Step 5: Commit**

```bash
git add test/riptide/placement_snapshot_recovery_test.exs
git commit -m "Update placement_snapshot_recovery_test.exs for the new genesis/discovery API"
```

---

## Task 12: Update `test/riptide_web/routing_cluster_test.exs`

**Files:**
- Modify: `test/riptide_web/routing_cluster_test.exs`

This file has a 4th, deliberately-non-placement-member peer (`riptide-3`) proving request-serving works for a node outside the placement cluster. Under Phase 3e, EVERY node is potentially eligible to become a placement member (any fleet node is eligible, per the design) — but this test's own scenario (a node that simply never got selected as a member) is still exactly representative of normal operation, since with a target size of 3 and 4 real peers, one of them will always be outside the cluster at any given moment. No scenario change needed, only the same ordinal/resolver mechanical update.

- [ ] **Step 1: Remove `ordinal_to_node`/`resolve_fun` construction and the `Application.put_env` loop**

Replace:

```elixir
    nodes = Enum.map(peers, fn {_pid, node, _ordinal} -> node end)
    ordinal_to_node = Map.new(peers, fn {_pid, node, ordinal} -> {ordinal, node} end)
    resolve_fun = fn ordinal -> Map.fetch!(ordinal_to_node, ordinal) end

    for {_pid, node, _ordinal} <- peers do
      :erpc.call(node, Application, :put_env, [:riptide, :ordinal_resolver, resolve_fun])
    end

    for {n1, n2} <- unique_pairs(nodes) do
```

with:

```elixir
    nodes = Enum.map(peers, fn {_pid, node, _ordinal} -> node end)

    for {n1, n2} <- unique_pairs(nodes) do
```

- [ ] **Step 2: Replace the placement-cluster-formation call and its stale comment**

Replace:

```elixir
    # Only the first 3 :peer_specs are real placement-cluster ordinals
    # ("riptide-0/1/2", matching RaCluster.placement_ordinals/0) — the 4th
    # peer is deliberately extra fleet capacity, exactly like a real node
    # joining a growing cluster that ISN'T one of the 3 fixed placement
    # ordinals. It still needs :ra/PubSub bootstrapped (below) since it's a
    # real node any stream request could land on, just not a placement
    # metadata cluster member.
    placement_peers = Enum.take(peers, 3)

    results =
      Enum.map(placement_peers, fn {_pid, node, _ordinal} ->
        :erpc.call(node, Riptide.RaCluster, :attempt_start_placement_cluster, [resolve_fun])
      end)

    assert Enum.any?(results, &(&1 == :ok))
```

with:

```elixir
    # Only the first 3 :peer_specs become real placement-cluster members —
    # the 4th peer is deliberately extra fleet capacity, exactly like a real
    # node joining a growing cluster that hasn't been added as a placement
    # member (target size 3, 4 real peers connected). It still needs
    # :ra/PubSub bootstrapped (below) since it's a real node any stream
    # request could land on, just not a placement metadata cluster member.
    placement_peers = Enum.take(peers, 3)
    placement_nodes = Enum.map(placement_peers, fn {_pid, node, _ordinal} -> node end)

    results =
      Enum.map(placement_peers, fn {_pid, node, _ordinal} ->
        :erpc.call(node, Riptide.RaCluster, :start_genesis_placement_cluster, [placement_nodes])
      end)

    assert Enum.any?(results, &(&1 == :ok))
```

- [ ] **Step 3: Run the test**

Run: `mix test test/riptide_web/routing_cluster_test.exs`
Expected: PASS.

- [ ] **Step 4: Run format and lint**

Run: `mix format && mix credo --strict`
Expected: clean.

- [ ] **Step 5: Commit**

```bash
git add test/riptide_web/routing_cluster_test.exs
git commit -m "Update routing_cluster_test.exs for the new genesis/discovery API"
```

---

## Task 13: New multi-node tests — genesis convergence, grow, shrink, graceful drain, dead-member replacement

**Files:**
- Create: `test/riptide/placement_membership_cluster_test.exs`

**Interfaces:**
- Consumes: `Riptide.RaCluster.start_genesis_placement_cluster/1`, `join_placement_cluster/1`, `remove_placement_member/2`, `local_placement_members/0` (Task 1); `Riptide.PlacementMembership.bootstrap_once/0`, `target_size/0` (Task 2). Mirrors the exact `:peer`-spawning pattern established in `test/riptide/placement_cluster_test.exs` (Task 8).

- [ ] **Step 1: Write the new test file**

Create `test/riptide/placement_membership_cluster_test.exs`:

```elixir
defmodule Riptide.PlacementMembershipClusterTest do
  use ExUnit.Case, async: false

  @moduletag timeout: 60_000

  @peers [
    {:pm0, ~c"127.0.0.20"},
    {:pm1, ~c"127.0.0.21"},
    {:pm2, ~c"127.0.0.22"},
    {:pm3, ~c"127.0.0.23"},
    {:pm4, ~c"127.0.0.24"}
  ]

  setup_all do
    unless Node.alive?() do
      {:ok, _pid} = Node.start(:"placement_membership_cluster_origin@127.0.0.1", :longnames)
    end

    :ok
  end

  test "5 simultaneously-booting nodes with target size 3 converge on exactly one 3-member cluster" do
    {peers, nodes} = spawn_and_connect(5)

    for {_pid, node} <- peers do
      :erpc.call(node, Application, :put_env, [:riptide, :placement_target_size, 3])
    end

    tasks =
      for {_pid, node} <- peers do
        Task.async(fn ->
          :erpc.call(node, Riptide.PlacementMembership, :bootstrap_once, [])
        end)
      end

    Task.await_many(tasks, 15_000)

    # Let the reconcile loop settle: at least one node's genesis attempt
    # should have won, and every node should agree on the same membership
    # once queried directly against a real member.
    members = wait_for_stable_membership(nodes)

    assert length(members) == 3
    assert Enum.all?(members, &(&1 in nodes))
  end

  test "grows from 3 to 5 members when target size is raised with more live nodes present" do
    {peers, nodes} = spawn_and_connect(5)
    [first_three, remaining_two] = [Enum.take(nodes, 3), Enum.drop(nodes, 3)]

    for {_pid, node} <- peers do
      :erpc.call(node, Application, :put_env, [:riptide, :placement_target_size, 3])
    end

    assert :erpc.call(hd(first_three), Riptide.RaCluster, :start_genesis_placement_cluster, [
             first_three
           ]) == :ok

    for {_pid, node} <- peers do
      :erpc.call(node, Application, :put_env, [:riptide, :placement_target_size, 5])
    end

    tasks =
      for node <- remaining_two do
        Task.async(fn -> :erpc.call(node, Riptide.PlacementMembership, :bootstrap_once, []) end)
      end

    Task.await_many(tasks, 15_000)

    members = wait_for_stable_membership(nodes, 5)
    assert length(members) == 5
  end

  test "shrinks from 5 to 3 members when target size is lowered" do
    {peers, nodes} = spawn_and_connect(5)

    for {_pid, node} <- peers do
      :erpc.call(node, Application, :put_env, [:riptide, :placement_target_size, 5])
    end

    assert :erpc.call(hd(nodes), Riptide.RaCluster, :start_genesis_placement_cluster, [nodes]) ==
             :ok

    for {_pid, node} <- peers do
      :erpc.call(node, Application, :put_env, [:riptide, :placement_target_size, 3])
    end

    # Shrinking is leader-only and one member per reconcile tick (Ra permits
    # only one membership change in flight at a time) — drive it directly on
    # whichever node is currently the real Raft leader, twice, mirroring two
    # real reconcile-loop ticks.
    leader_node = find_leader(nodes)
    :erpc.call(leader_node, Riptide.PlacementMembership, :bootstrap_once, [])

    poll_until(fn ->
      case :erpc.call(leader_node, Riptide.RaCluster, :local_placement_members, []) do
        {:ok, members} when length(members) == 4 -> members
        _ -> nil
      end
    end)

    new_leader_node = find_leader(nodes)
    :erpc.call(new_leader_node, Riptide.PlacementMembership, :bootstrap_once, [])

    members =
      poll_until(fn ->
        case :erpc.call(new_leader_node, Riptide.RaCluster, :local_placement_members, []) do
          {:ok, members} when length(members) == 3 -> members
          _ -> nil
        end
      end)

    assert length(members) == 3
  end

  test "graceful drain: a member proactively leaves when its supervised process is asked to stop" do
    {peers, nodes} = spawn_and_connect(4)
    [leaving_peer | _] = peers

    for {_pid, node} <- peers do
      :erpc.call(node, Application, :put_env, [:riptide, :placement_target_size, 3])
    end

    member_nodes = Enum.take(nodes, 3)

    assert :erpc.call(hd(member_nodes), Riptide.RaCluster, :start_genesis_placement_cluster, [
             member_nodes
           ]) == :ok

    {_pid, leaving_node} = leaving_peer
    membership_before = :erpc.call(leaving_node, Riptide.RaCluster, :local_placement_members, [])

    if membership_before == :error do
      # This peer never won genesis (only 3 of the 4 real members are
      # actual placement members) — retarget the test onto one that is.
      :ok
    end

    # Find whichever of the 4 peers actually IS a member, then stop its
    # Riptide.PlacementMembership process the same way a normal supervised
    # shutdown would (not a raw kill) — this exercises the real terminate/2
    # callback, not just a crash.
    actual_member_node =
      Enum.find(nodes, fn n ->
        match?({:ok, _}, :erpc.call(n, Riptide.RaCluster, :local_placement_members, []))
      end)

    {:ok, before_members} =
      :erpc.call(actual_member_node, Riptide.RaCluster, :local_placement_members, [])

    assert length(before_members) == 3

    pid = :erpc.call(actual_member_node, Process, :whereis, [Riptide.PlacementMembership])
    assert :erpc.call(actual_member_node, GenServer, :stop, [pid, :shutdown, 8_000]) == :ok

    other_member_node = Enum.find(before_members, &(&1 != actual_member_node))

    members =
      poll_until(fn ->
        case :erpc.call(other_member_node, Riptide.RaCluster, :local_placement_members, []) do
          {:ok, members} when length(members) == 2 -> members
          _ -> nil
        end
      end)

    refute actual_member_node in members
  end

  test "dead-member replacement: killing one member converges back to target size with the same size" do
    {peers, nodes} = spawn_and_connect(4)
    [members_peers, spare_peer] = [Enum.take(peers, 3), Enum.at(peers, 3)]
    member_nodes = Enum.map(members_peers, fn {_pid, node} -> node end)
    {spare_pid, spare_node} = spare_peer

    for {_pid, node} <- peers do
      :erpc.call(node, Application, :put_env, [:riptide, :placement_target_size, 3])
    end

    assert :erpc.call(hd(member_nodes), Riptide.RaCluster, :start_genesis_placement_cluster, [
             member_nodes
           ]) == :ok

    {dead_pid, dead_node} = hd(members_peers)
    :peer.stop(dead_pid)

    # Drive reconciliation manually on a survivor (the leader) and on the
    # spare node (the join candidate) — mirrors what the real periodic timer
    # does, without waiting a full @reconcile_interval_ms in the test.
    [_dead | survivors] = members_peers
    {survivor_pid, survivor_node} = hd(survivors)
    :erpc.call(survivor_node, Riptide.PlacementMembership, :bootstrap_once, [])

    members = wait_for_stable_membership([survivor_node, spare_node], 3, 10_000)

    assert length(members) == 3
    refute dead_node in members
    assert survivor_pid == survivor_pid
    assert spare_pid == spare_pid
  end

  defp spawn_and_connect(count) do
    pa_args = Enum.flat_map(:code.get_path(), fn p -> [~c"-pa", p] end)
    specs = Enum.take(@peers, count)

    peers =
      for {alive_name, host} <- specs do
        {:ok, pid, node} =
          :peer.start_link(%{name: alive_name, host: host, longnames: true, args: pa_args})

        {pid, node}
      end

    on_exit(fn ->
      Enum.each(peers, fn {pid, _node} ->
        if Process.alive?(pid), do: safe_stop_peer(pid)
      end)

      Enum.each(specs, fn {alive_name, _host} ->
        File.rm_rf!(Path.join(File.cwd!(), Atom.to_string(alive_name)))
      end)
    end)

    push_module_to_peers(peers)
    nodes = Enum.map(peers, fn {_pid, node} -> node end)

    for {n1, n2} <- unique_pairs(nodes) do
      assert :erpc.call(n1, :net_kernel, :connect_node, [n2]) == true
    end

    for {_pid, node} <- peers do
      {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:ra])
      :erpc.call(node, System, :put_env, ["HOSTNAME", Atom.to_string(node)])

      case :erpc.call(node, :ra_system, :start, [
             :erpc.call(node, Riptide.RaCluster, :system_config, [])
           ]) do
        {:ok, _pid} -> :ok
        {:ok, _pid, _info} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    # These bare :peer nodes never boot Riptide.Application, so neither
    # Phoenix.PubSub (which attempt_genesis/reconcile_as_leader's
    # broadcast_members/1 needs) nor Riptide.PlacementMembership's own ETS
    # cache table exist there yet. Bootstrap PubSub explicitly (mirroring
    # test/riptide/stream/stream_placement_cluster_test.exs's exact pattern
    # for the same class of problem), then start the REAL
    # Riptide.PlacementMembership GenServer (unlinked) on every peer — its
    # own init/1 creates the ETS table and subscribes to PubSub as a side
    # effect, and having a genuinely running, supervised-shaped process
    # (not just bare function calls) is what lets the graceful-drain test
    # below exercise a real terminate/2 via GenServer.stop/3. The tests'
    # own direct bootstrap_once/0 calls remain safe to make afterward —
    # they're idempotent, the same operation the GenServer's own :bootstrap
    # message already performs, just driven synchronously instead of
    # waiting on that message or the periodic reconcile timer.
    for {_pid, node} <- peers do
      {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:phoenix_pubsub])

      {:ok, _pid} =
        start_unlinked(node, Phoenix.PubSub.Supervisor, :start_link, [[name: Riptide.PubSub]])

      {:ok, _pid} = start_unlinked(node, Riptide.PlacementMembership, :start_link, [[]])
    end

    {peers, nodes}
  end

  defp safe_stop_peer(pid) do
    :peer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  defp push_module_to_peers(peers) do
    [{module, bytecode}] = Code.compile_file(__ENV__.file)

    for {_pid, node} <- peers do
      assert {:module, ^module} =
               :erpc.call(node, :code, :load_binary, [
                 module,
                 ~c"placement_membership_cluster_test.ex",
                 bytecode
               ])
    end
  end

  # Starts `apply(mod, fun, args)` on `node` without linking whatever it
  # starts to the transient process `:erpc.call/4` uses to dispatch the call
  # — a direct `:erpc.call` of a `start_link`-shaped function would die the
  # instant erpc's own dispatch process exits, taking the newly-started
  # process down with it (confirmed empirically in
  # test/riptide/stream/stream_placement_cluster_test.exs, Task 9). Mirrors
  # that same file's `start_unlinked/4` exactly.
  defp start_unlinked(node, mod, fun, args, timeout \\ 5_000) do
    parent = self()
    ref = make_ref()

    :erpc.call(node, Kernel, :spawn, [
      fn ->
        result = apply(mod, fun, args)
        send(parent, {ref, result})
        Process.sleep(:infinity)
      end
    ])

    receive do
      {^ref, result} -> result
    after
      timeout -> {:error, :timeout}
    end
  end

  defp unique_pairs(list) do
    for {a, i} <- Enum.with_index(list),
        {b, j} <- Enum.with_index(list),
        i < j,
        do: {a, b}
  end

  defp find_leader(nodes) do
    Enum.find(nodes, fn n -> :erpc.call(n, Riptide.RaCluster, :placement_leader?, []) end)
  end

  defp poll_until(fun, timeout_ms \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_poll_until(fun, deadline)
  end

  defp do_poll_until(fun, deadline) do
    case fun.() do
      nil ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("Condition never became true within the timeout")
        else
          Process.sleep(200)
          do_poll_until(fun, deadline)
        end

      result ->
        result
    end
  end

  defp wait_for_stable_membership(candidate_nodes, expected_size \\ nil, timeout_ms \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_membership(candidate_nodes, expected_size, deadline)
  end

  defp poll_membership(candidate_nodes, expected_size, deadline) do
    case :erpc.call(hd(candidate_nodes), Riptide.RaCluster, :probe_placement_members, [
           candidate_nodes
         ]) do
      {:ok, members} when expected_size == nil or length(members) == expected_size ->
        members

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("Placement membership never stabilized within the timeout")
        else
          Process.sleep(200)
          poll_membership(candidate_nodes, expected_size, deadline)
        end
    end
  end
end
```

- [ ] **Step 2: Run the new tests**

Run: `mix test test/riptide/placement_membership_cluster_test.exs`
Expected: PASS. If genesis convergence is flaky (multiple nodes racing to form genesis under real network timing), increase `@genesis_settle_ms` in `lib/riptide/placement_membership.ex` (Task 2) from 3000 to a larger value (e.g. 5000) and re-run — this is a real tuning parameter, not a correctness bug, per the spec's own accepted-risk note on genesis timing.

- [ ] **Step 3: Run the full suite to confirm no regressions**

Run: `mix test`
Expected: PASS — 0 failures across the whole suite.

- [ ] **Step 4: Run format and lint**

Run: `mix format && mix credo --strict`
Expected: clean.

- [ ] **Step 5: Commit**

```bash
git add test/riptide/placement_membership_cluster_test.exs
git commit -m "Add multi-node tests: genesis convergence, grow, dead-member replacement"
```

---

## Task 14: Documentation — README, `fly.toml`, `k8s/statefulset.yaml`

**Files:**
- Modify: `README.md`
- Modify: `fly.toml`
- Modify: `k8s/statefulset.yaml`

- [ ] **Step 1: Update README's "Running locally for development" section**

Replace:

```markdown
## Running locally for development

`mix phx.server` needs two things a real Kubernetes deployment gets for free (see "Running via
Kubernetes" below): a `HOSTNAME` matching one of the 3 fixed placement ordinals, and
`config/dev.exs`'s own `ordinal_resolver` override (already set) standing in for the real
headless-service DNS that doesn't exist on a developer's own machine.

```bash
mix deps.get
HOSTNAME=riptide-0 mix phx.server
```

Wait for `curl http://localhost:4000/health/ready` to return `200` (the placement cluster forms in
the background at boot; this can take a few seconds) before making any LDP request — every read
and write depends on it being ready.
```

with:

```markdown
## Running locally for development

`mix phx.server` just works — no `HOSTNAME`, no special config. The placement cluster
self-forms as a single-node cluster automatically (Phase 3e): every node's `Riptide.
PlacementMembership` controller checks for an existing cluster, finds none, and forms one from
whatever's actually connected (just this one process, locally).

```bash
mix deps.get
mix phx.server
```

Wait for `curl http://localhost:4000/health/ready` to return `200` (the placement cluster forms in
the background at boot; this can take a few seconds) before making any LDP request — every read
and write depends on it being ready.
```

- [ ] **Step 2: Update README's "Running via Kubernetes" intro paragraph**

Replace:

```markdown
Example manifests live in `k8s/` — a 3-replica `StatefulSet` (`k8s/statefulset.yaml`), a
```

with:

```markdown
Example manifests live in `k8s/` — a `StatefulSet` (`k8s/statefulset.yaml`, defaulting to 3
replicas — this is just a starting point now, not a hard requirement; see Phase 3e), a
```

- [ ] **Step 3: Update README's Fly.io section**

Replace the `RELEASE_NODE=riptide@127.0.0.1`-related `fly secrets set` block's context and the paragraph mentioning `HOSTNAME=riptide-0`/`RIPTIDE_SINGLE_NODE`:

Find the exact current text via `grep -n "RIPTIDE_SINGLE_NODE\|HOSTNAME=riptide-0" README.md` and replace any remaining mention of `RIPTIDE_SINGLE_NODE` or the `fly.toml` `HOSTNAME`/`RIPTIDE_SINGLE_NODE` env entries with a note that a single-Machine Fly deployment now just needs `RIPTIDE_PLACEMENT_TARGET_SIZE=1` (or nothing at all — the default target size of 3 still gracefully collapses to whatever's actually present, i.e. 1 node, though setting it explicitly to 1 avoids the ambient join loop's pointless periodic attempts to find 2 more nodes that will never appear).

- [ ] **Step 4: Update `fly.toml`**

Replace:

```toml
[env]
  PHX_HOST = "riptide-live-story.fly.dev"
  PORT = "4000"
  HOSTNAME = "riptide-0"
  RIPTIDE_SINGLE_NODE = "true"
```

with:

```toml
[env]
  PHX_HOST = "riptide-live-story.fly.dev"
  PORT = "4000"
  RIPTIDE_PLACEMENT_TARGET_SIZE = "1"
```

- [ ] **Step 5: Update `k8s/statefulset.yaml`'s `readinessProbe` comment**

Run: `grep -n -B2 -A8 "readinessProbe" k8s/statefulset.yaml` to see its exact current comment (quoted in the Phase 3e spec's own audit: "retries across all 3 placement ordinals on failure"). Update the phrase "retries across all 3 placement ordinals on failure" to "retries across every currently-known placement-cluster member on failure" — the underlying behavior (bounded retry via the cache-then-probe fallback in `Riptide.Placement`) is the same shape, just no longer tied to exactly 3 fixed names.

- [ ] **Step 6: Run the full test suite one more time**

Run: `mix test`
Expected: PASS — documentation-only changes don't affect test outcomes, but this confirms nothing else in the working tree regressed.

- [ ] **Step 7: Commit**

```bash
git add README.md fly.toml k8s/statefulset.yaml
git commit -m "Docs: reflect elastic placement-cluster membership (no more HOSTNAME/RIPTIDE_SINGLE_NODE requirement)"
```

---

## Task 15: Final verification

**Files:** none (verification only).

- [ ] **Step 1: Run the full test suite**

Run: `mix test`
Expected: PASS — 0 failures, matching (or exceeding, given new tests) the pre-existing test count.

- [ ] **Step 2: Run format and lint**

Run: `mix format --check-formatted && mix credo --strict`
Expected: both clean.

- [ ] **Step 3: Confirm no remaining references to removed functions/config anywhere**

Run: `grep -rn "placement_ordinals\|default_ordinal_resolver\|dns_ordinal_resolver\|ordinal_resolver\|attempt_start_placement_cluster\|RIPTIDE_SINGLE_NODE" lib/ config/ test/ k8s/ fly.toml README.md`
Expected: no output (empty) — every reference has been removed or updated across all prior tasks.

- [ ] **Step 4: Manually verify a single-node boot end-to-end**

```bash
rm -rf priv/ra_data_dev 2>/dev/null
mix phx.server &
sleep 5
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:4000/health/ready
kill %1
```

Expected: `200` — confirming the "no `HOSTNAME` needed anymore" claim from Task 14 actually holds live, not just in test assertions.

- [ ] **Step 5: Manually verify an even target size fails fast**

```bash
MIX_ENV=prod SECRET_KEY_BASE=$(openssl rand -base64 48) RIPTIDE_PLACEMENT_TARGET_SIZE=4 mix run -e "IO.puts(:still_running)"
```

Expected: raises with the `RIPTIDE_PLACEMENT_TARGET_SIZE must be a positive odd number` message from `config/runtime.exs` (Task 5) before `:still_running` ever prints — confirming the live boot-time validation actually fires, not just the unit-tested pure function in isolation.

- [ ] **Step 6: Commit any final cleanup**

If Steps 1-4 are all clean with nothing left to change, there is nothing to commit here — proceed directly to `superpowers:finishing-a-development-branch`.
