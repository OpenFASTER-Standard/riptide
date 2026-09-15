defmodule Riptide.Decade.Chaos do
  @moduledoc """
  Reusable wrapper around this codebase's existing `:peer`-based multi-node
  test pattern (see `test/riptide/stream/replica_healer_leadership_gate_test.exs`,
  the first place this sequence was proven) — bootstraps a real N-node
  cluster with `:ra`, `Phoenix.PubSub`, `Riptide.Stream.Placement`, and
  `Riptide.Stream.ReplicaHealer` running on every node, and exposes
  `kill_node/2` to drive the real production repair path during Phase 7's
  decade simulation.

  By convention (matching the reference test's own `placement_peers =
  Enum.take(peers, 3)` and every caller of this module, Task 6's and Task
  7's own tests alike): the FIRST 3 entries of `peer_specs` are the
  placement cluster's real, genesis members; any further entries are
  "spare" nodes — fully live, Erlang-connected, `:ra`-system-started peers
  that intentionally never join the genesis placement Raft cluster, so
  they stay eligible as `ReplicaHealer.pick_replacement/2` candidates
  (which only consults `[node() | Node.list()]`, not placement-cluster
  membership) without ever being able to win its leader election
  themselves. Getting this wrong — e.g. including a spare in the genesis
  member list — risks the spare winning that election after a real member
  is killed, which a caller polling only the original 3 nodes for a leader
  (as both this module's own test and Task 7's umbrella test do) would
  never observe, manifesting as flaky, hard-to-diagnose timeouts rather
  than a clean failure.
  """

  import Riptide.MultiNodeTestHelpers, only: [unique_pairs: 1]

  @type peer_spec :: {atom(), String.t(), charlist()}
  @type started_peer :: {pid(), node(), String.t()}

  @genesis_member_count 3

  @spec start_cluster([peer_spec()]) :: [started_peer()]
  def start_cluster(peer_specs) do
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

    # Everything past this point (connect_node, :ra startup, genesis
    # placement, PubSub/Placement/ReplicaHealer start) can fail partway
    # through on a real, already-spawned peer fleet — mirroring the
    # reference file's own `on_exit` registered immediately after its
    # peer-spawn loop, before any of these same failure-prone steps, so a
    # partial failure there still reaps every peer process and its on-disk
    # Ra data dir. Here, `start_cluster/1` returning is what lets a caller
    # register that `on_exit`, so the same safety has to live inside this
    # try/rescue/catch instead: clean up whatever was already spawned, then
    # re-raise (`reraise`/`:erlang.raise/3`, both preserving the original
    # stacktrace) so the caller still sees a real failure, not a silently
    # swallowed one.
    try do
      bootstrap_peers(peers)
      peers
    rescue
      e ->
        stop_cluster(peers, peer_specs)
        reraise e, __STACKTRACE__
    catch
      kind, reason ->
        stop_cluster(peers, peer_specs)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp bootstrap_peers(peers) do
    nodes = Enum.map(peers, fn {_pid, node, _ordinal} -> node end)

    for {_pid, node, _ordinal} <- peers do
      :erpc.call(node, Application, :put_env, [
        :riptide,
        :replica_healer_sweep_interval_ms,
        3_600_000
      ])
    end

    for {n1, n2} <- unique_pairs(nodes) do
      true = :erpc.call(n1, :net_kernel, :connect_node, [n2])
    end

    for {_pid, node, _ordinal} <- peers do
      {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:ra])

      case :erpc.call(node, :ra_system, :start, [
             :erpc.call(node, Riptide.RaCluster, :system_config, [])
           ]) do
        {:ok, _pid} -> :ok
        {:ok, _pid, _info} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    # Only the first @genesis_member_count peers ever become members of the
    # genesis placement Raft cluster — see moduledoc. Any further peers
    # ("spares") are left out of `genesis_nodes` entirely so they can never
    # be elected that cluster's leader.
    genesis_peers = Enum.take(peers, @genesis_member_count)
    genesis_nodes = Enum.map(genesis_peers, fn {_pid, node, _ordinal} -> node end)

    :ok =
      case Enum.map(genesis_peers, fn {_pid, node, _ordinal} ->
             :erpc.call(node, Riptide.RaCluster.Placement, :start_genesis_placement_cluster, [
               genesis_nodes
             ])
           end) do
        results -> if Enum.any?(results, &(&1 == :ok)), do: :ok
      end

    for {_pid, node, _ordinal} <- peers do
      {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:phoenix_pubsub])

      {:ok, _} =
        start_unlinked(node, Phoenix.PubSub.Supervisor, :start_link, [[name: Riptide.PubSub]])

      {:ok, _} = start_unlinked(node, Riptide.Stream.Placement, :start_link, [[]])
      {:ok, _} = start_unlinked(node, Riptide.Stream.ReplicaHealer, :start_link, [[]])
    end

    :ok
  end

  @spec stop_cluster([started_peer()], [peer_spec()]) :: :ok
  def stop_cluster(peers, peer_specs) do
    Enum.each(peers, fn {pid, _node, _ordinal} ->
      if Process.alive?(pid) do
        try do
          :peer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    Enum.each(peer_specs, fn {_alive_name, ordinal, _host} ->
      File.rm_rf!(Path.join(File.cwd!(), ordinal))
    end)

    :ok
  end

  @spec kill_node([started_peer()], node()) :: :ok
  def kill_node(peers, target_node) do
    {pid, ^target_node, _ordinal} =
      Enum.find(peers, fn {_pid, node, _ordinal} -> node == target_node end)

    try do
      :peer.stop(pid)
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  @spec await_leader([node()], pos_integer()) :: node() | nil
  def await_leader(candidate_nodes, attempts_left \\ 50) do
    case Enum.find(candidate_nodes, fn node ->
           :erpc.call(node, Riptide.RaCluster.Placement, :placement_leader?, [])
         end) do
      nil when attempts_left > 1 ->
        Process.sleep(200)
        await_leader(candidate_nodes, attempts_left - 1)

      found ->
        found
    end
  end

  defp start_unlinked(node, mod, fun, args, timeout \\ 5_000) do
    parent = self()

    :erlang.spawn(node, fn ->
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
end
