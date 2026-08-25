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

    # PubSub before Placement — Task 5's `Riptide.Stream.Placement.init/1`
    # now subscribes to a PubSub topic on start (tolerating a not-yet-started
    # `Riptide.PubSub` via a scoped rescue, but there's no reason to rely on
    # that here when starting it first is just as easy and matches real
    # `Riptide.Application.start/2`'s own ordering).
    for {_pid, node, _ordinal} <- peers do
      {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:phoenix_pubsub])
      {:ok, _} = start_unlinked(node, Phoenix.PubSub.Supervisor, :start_link, [[name: Riptide.PubSub]])
    end

    for {_pid, node, _ordinal} <- peers do
      {:ok, _} = start_unlinked(node, Riptide.Stream.Placement, :start_link, [[]])
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
