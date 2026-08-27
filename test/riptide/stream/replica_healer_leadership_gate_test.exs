defmodule Riptide.Stream.ReplicaHealerLeadershipGateTest do
  use ExUnit.Case, async: false

  @moduletag timeout: 60_000

  # Design spec §9's own testing requirement, never previously implemented
  # (Phase 3d-ii final review, finding 2): a real multi-node test proving
  # only the placement cluster's actual current leader ever performs a
  # repair. `Riptide.Stream.ReplicaHealer.sweep/0` itself has no leader
  # check — the gate lives entirely in `handle_info(:sweep, state)` — so
  # this exercises that REAL production message-handling path (sending
  # `:sweep` to each node's own registered `ReplicaHealer` process), unlike
  # `replica_healer_cluster_test.exs`'s existing test, which deliberately
  # calls `sweep/0` directly and bypasses the gate entirely.
  @peers [
    {:gate_a, "riptide-0", ~c"127.0.0.70"},
    {:gate_b, "riptide-1", ~c"127.0.0.71"},
    {:gate_c, "riptide-2", ~c"127.0.0.72"}
  ]

  @replacement {:gate_d, "healer-gate-d", ~c"127.0.0.73"}

  setup_all do
    unless Node.alive?() do
      {:ok, _pid} = Node.start(:"replica_healer_leadership_gate_origin@127.0.0.1", :longnames)
    end

    :ok
  end

  test "only the placement cluster's actual leader repairs a dead replica when :sweep is sent to every ordinal" do
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
                 ~c"replica_healer_leadership_gate_test.ex",
                 bytecode
               ])
    end

    nodes = Enum.map(peers, fn {_pid, node, _ordinal} -> node end)

    for {_pid, node, _ordinal} <- peers do
      # Prevent each node's own real 30s sweep timer from firing mid-test and
      # confusing which send/handle_info actually caused a given repair —
      # this test drives every sweep explicitly.
      :erpc.call(node, Application, :put_env, [
        :riptide,
        :replica_healer_sweep_interval_ms,
        3_600_000
      ])
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

    placement_nodes = Enum.map(placement_peers, fn {_pid, node, _ordinal} -> node end)

    results =
      Enum.map(placement_peers, fn {_pid, node, _ordinal} ->
        :erpc.call(node, Riptide.RaCluster, :start_genesis_placement_cluster, [placement_nodes])
      end)

    assert Enum.any?(results, &(&1 == :ok))

    for {_pid, node, _ordinal} <- peers do
      {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:phoenix_pubsub])

      {:ok, _} =
        start_unlinked(node, Phoenix.PubSub.Supervisor, :start_link, [[name: Riptide.PubSub]])
    end

    for {_pid, node, _ordinal} <- peers do
      {:ok, _} = start_unlinked(node, Riptide.Stream.Placement, :start_link, [[]])
    end

    stream_id = "healer-gate-" <> Uniq.UUID.uuid4()
    original_nodes = [node_a, node_b, node_c]

    assert Enum.sort(:erpc.call(node_a, Riptide.Placement, :assign, [stream_id, original_nodes])) ==
             Enum.sort(original_nodes)

    assert :ok = :erpc.call(node_a, Riptide.Stream.StreamSupervisor, :ensure_ready, [stream_id])

    graph = :erpc.call(node_a, RDF.Graph, :new, [])
    event = :erpc.call(node_a, Riptide.Event, :new, [stream_id, :replace, graph])
    stamped = :erpc.call(node_a, Riptide.Stream.StreamServer, :append, [stream_id, event])
    assert stamped.sequence == 1

    # Kill node_c for real — the replica being replaced AND one of the 3
    # placement ordinals. The 2 survivors still hold quorum (2 of 3) for the
    # placement cluster itself.
    stop_peer_for(peers, node_c)

    survivors = [node_a, node_b]

    # Find which of the 2 survivors is the placement cluster's actual
    # current Raft leader — may take a moment to settle if node_c happened
    # to be the leader itself.
    leader_node =
      eventually_find(survivors, fn node ->
        :erpc.call(node, Riptide.RaCluster, :placement_leader?, [])
      end)

    assert leader_node != nil, "no survivor became the placement leader in time"
    [non_leader_node] = survivors -- [leader_node]

    for node <- survivors do
      {:ok, _} = start_unlinked(node, Riptide.Stream.ReplicaHealer, :start_link, [[]])
    end

    # Send :sweep to the NON-leader's real, registered ReplicaHealer process
    # first — exercising the exact production `handle_info(:sweep, state)`
    # path, including its `RaCluster.placement_leader?/0` gate. Synchronize
    # with `:sys.get_state/2` (blocks until every message queued ahead of it,
    # including this :sweep, has been handled) before checking anything, so
    # this is a deterministic observation, not a timing guess.
    :erpc.call(non_leader_node, :erlang, :send, [Riptide.Stream.ReplicaHealer, :sweep])
    :erpc.call(non_leader_node, :sys, :get_state, [Riptide.Stream.ReplicaHealer, 30_000])

    assert Enum.sort(:erpc.call(node_a, Riptide.Placement, :lookup, [stream_id])) ==
             Enum.sort(original_nodes),
           "the non-leader's ReplicaHealer must not have repaired anything"

    # Now send :sweep to the ACTUAL leader's ReplicaHealer — this one must
    # perform the real repair, synchronously (the whole add_member/
    # start_server/remove_member sequence runs inside handle_info/2 before
    # it replies), so the sync call above already means the repair is done
    # by the time this call returns too.
    :erpc.call(leader_node, :erlang, :send, [Riptide.Stream.ReplicaHealer, :sweep])
    :erpc.call(leader_node, :sys, :get_state, [Riptide.Stream.ReplicaHealer, 30_000])

    repaired_nodes = :erpc.call(node_a, Riptide.Placement, :lookup, [stream_id])
    assert length(repaired_nodes) == 3
    refute node_c in repaired_nodes
    assert node_a in repaired_nodes
    assert node_b in repaired_nodes

    [new_node] = repaired_nodes -- [node_a, node_b]

    # No data loss, and no over-replication: exactly one real repair
    # happened, driven only by the leader.
    assert :erpc.call(new_node, Riptide.RaCluster, :server_alive?, [
             String.to_atom(:erpc.call(node_a, Riptide.RaCluster, :uid_for, [stream_id]))
           ])

    assert :ok = :erpc.call(new_node, Riptide.Stream.StreamSupervisor, :ensure_ready, [stream_id])

    {:ok, read_back} =
      :erpc.call(new_node, Riptide.Stream.StreamServer, :get_since, [stream_id, 0])

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

  # Like `eventually/2` but returns whichever candidate first satisfies
  # `pred`, or `nil` if none does within the retry budget — used here to
  # find the placement cluster's actual leader among the 2 survivors.
  defp eventually_find(candidates, pred, attempts_left \\ 50) do
    case Enum.find(candidates, pred) do
      nil when attempts_left > 1 ->
        Process.sleep(200)
        eventually_find(candidates, pred, attempts_left - 1)

      found ->
        found
    end
  end

  defp unique_pairs(list) do
    for {a, i} <- Enum.with_index(list),
        {b, j} <- Enum.with_index(list),
        i < j,
        do: {a, b}
  end
end
