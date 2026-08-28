defmodule Riptide.RaCluster.Placement do
  @moduledoc """
  Placement/metadata Raft cluster addressing and lifecycle: genesis, join,
  remove, leader/liveness checks. Split out of `Riptide.RaCluster` (2026-08-28)
  to separate this one cluster's own specific semantics from `RaCluster`'s
  generic, any-Ra-cluster primitives — `RaCluster` had grown to mix both,
  per a repo-health review. Reuses `RaCluster`'s shared membership-change
  helpers (`add_member/2`, `remove_member/2`, `start_joining_server/4`) for
  the exact same self-correcting `:ra.add_member/2`/`:ra.remove_member/2`/
  `:ra.start_server/5` semantics `RaCluster.replace_member/5` already relies
  on — together with `RaCluster`, the only modules that call into `:ra`
  directly.
  """

  alias Riptide.RaCluster

  @placement_cluster_name :riptide_placement
  @placement_uid "riptide_placement"
  @system :default

  @spec placement_server_id(node()) :: :ra.server_id()
  def placement_server_id(node), do: {@placement_cluster_name, node}

  # Whether THIS node is currently the placement cluster's Raft leader —
  # used by `Riptide.Stream.ReplicaHealer` (Phase 3d-ii) to gate stream
  # replica repair so only one placement-cluster member ever acts on a
  # given sweep, reusing the placement cluster's own existing leader
  # election rather than a new coordination mechanism. Queries the LOCAL
  # member directly (`{@placement_cluster_name, node()}`), since this is
  # only ever meaningful to call from a node that's itself a placement
  # member already running its own local member.
  # Wrapped in `try/catch :exit` because `:ra.members/1` doesn't always turn
  # a bad outcome into an `{:error, _}` tuple: `ra_server_proc`'s own
  # `gen_statem_safe_call/3` only converts `timeout`/`noproc`/`nodedown`/
  # `shutdown` exits into a return value — any OTHER exit (e.g. the local
  # member process crashing for an unrelated reason while this exact call is
  # in flight) propagates straight out of `gen_statem:call/3` as a genuine
  # `exit`, which a plain `case` can't catch. `Riptide.Stream.ReplicaHealer`
  # (Phase 3d-ii) is the first caller to invoke this from a periodic
  # boot-time timer rather than a one-off request path, so a rare exit here
  # would otherwise crash that GenServer outright instead of just skipping a
  # sweep. Any exit is treated as "not the leader" — the same conservative
  # default this function already returns for a plain `{:error, _}`.
  @spec placement_leader?() :: boolean()
  def placement_leader? do
    case :ra.members({@placement_cluster_name, node()}) do
      {:ok, _members, {@placement_cluster_name, leader_node}} -> leader_node == node()
      _ -> false
    end
  catch
    :exit, _ -> false
  end

  # Recovers a member that already has on-disk log data for this uid on
  # THIS EXACT node() identity — only correct to call when the current,
  # freshly-discovered consensus membership already lists `node()` as a
  # member (see `Riptide.PlacementMembership.bootstrap_once/0`), since
  # `:ra.restart_server/2` looks up on-disk state by the exact `{name, node}`
  # server id, not by uid/data_dir alone. Deliberately NOT used to recover a
  # node whose `node()` identity has drifted since its last run (e.g. a real
  # Kubernetes pod restart under a new IP — `node()` is IP-based and
  # unstable, per `RaCluster.data_dir/0`'s own doc): a drifted node is never
  # listed under ITS NEW identity in the old consensus state, so this call
  # would simply fail to find anything to restart. That case is handled
  # instead by the ordinary ambient join loop (this "new" node joins fresh)
  # plus the leader-only repair loop (evicts the stale old identity) — no
  # special casing needed, it falls out of machinery already built for the
  # dead-member-replacement case generally.
  @spec restart_local_placement_member() :: :ok | {:error, term()}
  def restart_local_placement_member do
    RaCluster.ensure_system_started()
    :ra.restart_server(@system, {@placement_cluster_name, node()})
  end

  # A fast, LOCAL-only membership check: does this node currently have a
  # live placement-cluster member, and if so, what does Raft consensus
  # itself say the full current membership is? `:ra.members/1`'s reply is
  # self-describing and authoritative the instant any single caught-up
  # member answers it — not a guess, a consensus fact (the same principle
  # `RaCluster.remove_member/2`'s own `member_removed?/2` helper already
  # relies on). Returns `:error` (not raising) when this node has no live
  # local member, mirroring `placement_leader?/0`'s own `catch :exit`
  # treatment.
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
    RaCluster.ensure_system_started()
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
        if RaCluster.server_alive?(@placement_cluster_name) do
          :ok
        else
          {:error, :cluster_not_formed}
        end
    end
  end

  # This node joins an already-existing placement cluster — the same
  # add-then-start sequence `RaCluster.replace_member/5` already proves
  # correct (add to the existing cluster's configuration FIRST, then start
  # the joining server), just without a matching `remove_member` step, since
  # joining doesn't evict anyone. `:ra.add_member/2` is a command sent TO an
  # existing member; the caller doesn't need to already be one itself, so
  # this node can safely call it before it has any local server running.
  @spec join_placement_cluster([node()]) :: :ok | {:error, term()}
  def join_placement_cluster(existing_nodes) do
    RaCluster.ensure_system_started()
    existing_ids = Enum.map(existing_nodes, &placement_server_id/1)
    my_id = placement_server_id(node())
    machine = {:module, Riptide.Placement.PlacementMachine, %{}}
    cluster_name = "#{@placement_uid}_cluster"

    with :ok <- RaCluster.add_member(existing_ids, my_id) do
      RaCluster.start_joining_server(cluster_name, my_id, machine, existing_ids)
    end
  end

  # Removes `node_to_remove` from the placement cluster with no replacement
  # — used both for a confirmed-dead member (the repair side of
  # `Riptide.PlacementMembership`'s reconciliation loop) and for shrinking
  # to a lowered target size. Thin wrapper over the same
  # `RaCluster.remove_member/2` `RaCluster.replace_member/5` already uses,
  # just without the add-a-replacement half of that pipeline.
  @spec remove_placement_member([node()], node()) :: :ok | {:error, term()}
  def remove_placement_member(survivor_nodes, node_to_remove) do
    RaCluster.ensure_system_started()
    survivor_ids = Enum.map(survivor_nodes, &placement_server_id/1)
    target_id = placement_server_id(node_to_remove)
    RaCluster.remove_member(survivor_ids, target_id)
  end
end
