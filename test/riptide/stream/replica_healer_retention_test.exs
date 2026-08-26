defmodule Riptide.Stream.ReplicaHealerRetentionTest do
  use ExUnit.Case, async: false

  @moduletag timeout: 60_000

  # Reproduces finding 1 from the Phase 3d-ii final review: `ReplicaHealer`
  # used to hardcode `retention: :infinity` for the JOINING replacement
  # member's machine config, regardless of the stream's actual retention —
  # silently diverging a repaired replica from its peers for any
  # finite-retention stream with too few events to have snapshotted yet
  # (`RaMachine`'s own `min_snapshot_interval` default is 4096 entries). This
  # test forms a real finite-retention stream cluster directly via
  # `RaCluster.start_or_join_replicated/3` (bypassing
  # `Riptide.Stream.StreamSupervisor.ensure_ready/1`, which today always
  # hardcodes `:infinity` itself — a separate, pre-existing limitation the
  # finding notes is why this exact gap isn't yet reachable in production;
  # see that finding's own text), kills a replica, runs the healer's real
  # repair, and asserts the joined replacement's local machine state carries
  # the *real* retention, not `:infinity`.
  @peers [
    {:ret_a, "riptide-0", ~c"127.0.0.60"},
    {:ret_b, "riptide-1", ~c"127.0.0.61"},
    {:ret_c, "riptide-2", ~c"127.0.0.62"}
  ]

  @replacement {:ret_d, "healer-retention-d", ~c"127.0.0.63"}

  setup_all do
    unless Node.alive?() do
      {:ok, _pid} = Node.start(:"replica_healer_retention_origin@127.0.0.1", :longnames)
    end

    :ok
  end

  test "a repaired replica of a finite-retention stream is joined with its stream's real retention, not :infinity" do
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
                 ~c"replica_healer_retention_test.ex",
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
      {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:phoenix_pubsub])

      {:ok, _} =
        start_unlinked(node, Phoenix.PubSub.Supervisor, :start_link, [[name: Riptide.PubSub]])
    end

    for {_pid, node, _ordinal} <- peers do
      {:ok, _} = start_unlinked(node, Riptide.Stream.Placement, :start_link, [[]])
    end

    stream_id = "healer-retention-" <> Uniq.UUID.uuid4()
    original_nodes = [node_a, node_b, node_c]

    assert Enum.sort(:erpc.call(node_a, Riptide.Placement, :assign, [stream_id, original_nodes])) ==
             Enum.sort(original_nodes)

    uid = :erpc.call(node_a, Riptide.RaCluster, :uid_for, [stream_id])
    # A real, finite retention — deliberately NOT :infinity, and small enough
    # that no snapshot will ever fire (RaMachine's min_snapshot_interval
    # default is 4096 entries), so a repaired replica can only recover the
    # right retention by discovering it live, never by inheriting it from a
    # snapshot.
    machine = {:module, Riptide.Stream.RaMachine, %{retention: 3}}

    assert {:ok, _server_ids} =
             :erpc.call(node_a, Riptide.RaCluster, :start_or_join_replicated, [
               uid,
               original_nodes,
               machine
             ])

    name = String.to_atom(uid)

    # Kill node_c for real — the replica being replaced.
    stop_peer_for(peers, node_c)

    assert eventually(fn ->
             :erpc.call(node_a, Riptide.Stream.ReplicaHealer, :sweep, []) == :ok and
               Enum.sort(:erpc.call(node_a, Riptide.Placement, :lookup, [stream_id])) !=
                 Enum.sort(original_nodes)
           end)

    repaired_nodes = :erpc.call(node_a, Riptide.Placement, :lookup, [stream_id])
    [new_node] = repaired_nodes -- [node_a, node_b]

    assert :erpc.call(new_node, Riptide.RaCluster, :server_alive?, [name])

    # The real assertion for finding 1: the joined replacement's own LOCAL
    # machine state carries the stream's REAL retention (3), not the
    # previously-hardcoded :infinity. Deliberately `local_query/2`, not
    # `consistent_query/2` — `consistent_query/2` always answers via
    # whichever node is the current Raft LEADER (per its own moduledoc),
    # so it can't observe a divergence in one specific follower's own local
    # state; `local_query/2` reads that exact node's possibly-stale/diverged
    # state directly, which is the whole point of this test.
    retention =
      :erpc.call(new_node, Riptide.RaCluster, :local_query, [
        {name, new_node},
        &Map.get(&1, :retention)
      ])

    assert retention == 3
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
      fun.() ->
        true

      attempts_left <= 1 ->
        false

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
