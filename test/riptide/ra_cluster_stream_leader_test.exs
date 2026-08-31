defmodule Riptide.RaClusterStreamLeaderTest do
  use ExUnit.Case, async: false

  import Riptide.MultiNodeTestHelpers, only: [unique_pairs: 1]

  @moduletag timeout: 60_000

  alias Riptide.Test.EchoMachine

  @peers [
    {:lead_a, "lead-a", ~c"127.0.0.80"},
    {:lead_b, "lead-b", ~c"127.0.0.81"},
    {:lead_c, "lead-c", ~c"127.0.0.82"}
  ]

  setup_all do
    unless Node.alive?() do
      {:ok, _pid} = Node.start(:"ra_cluster_stream_leader_origin@127.0.0.1", :longnames)
    end

    :ok
  end

  test "exactly one node reports itself the leader of a real stream's Ra cluster" do
    peers = bootstrap_peers(@peers)
    nodes = Enum.map(peers, fn {_pid, node, _ordinal} -> node end)
    [{_pid_a, node_a, _} | _] = peers

    stream_id = "stream-leader-" <> Uniq.UUID.uuid4()
    machine = {:module, EchoMachine, %{}}

    # start_or_join_replicated/3's own first argument is a literal uid, not
    # a stream_id it hashes internally (unlike server_id/1) — matching real
    # stream writes (which always go through server_id/1's own uid_for/1
    # hashing) requires passing the already-hashed uid explicitly here, or
    # stream_leader?/1's own uid_for/1-based lookup targets a different
    # cluster_name than the one actually formed.
    uid = Riptide.RaCluster.uid_for(stream_id)

    assert {:ok, _server_ids} =
             :erpc.call(node_a, Riptide.RaCluster, :start_or_join_replicated, [
               uid,
               nodes,
               machine
             ])

    assert eventually(fn ->
             leaders =
               Enum.filter(nodes, fn node ->
                 :erpc.call(node, Riptide.RaCluster, :stream_leader?, [stream_id])
               end)

             length(leaders) == 1
           end)

    # Cross-check against Ra's own real membership/leader view, not just
    # "exactly one" — proves stream_leader?/1 agrees with reality, not just
    # with itself.
    name = String.to_atom(Riptide.RaCluster.uid_for(stream_id))
    {:ok, members, {_name, real_leader}} = :erpc.call(node_a, :ra, :members, [{name, node_a}])
    assert length(members) == 3

    assert :erpc.call(real_leader, Riptide.RaCluster, :stream_leader?, [stream_id])

    for node <- nodes -- [real_leader] do
      refute :erpc.call(node, Riptide.RaCluster, :stream_leader?, [stream_id])
    end
  end

  defp bootstrap_peers(specs) do
    pa_args = Enum.flat_map(:code.get_path(), fn p -> [~c"-pa", p] end)

    peers =
      for {alive_name, ordinal, host} <- specs do
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
      Enum.each(peers, &stop_peer/1)

      Enum.each(specs, fn {_alive_name, ordinal, _host} ->
        File.rm_rf!(Path.join(File.cwd!(), ordinal))
      end)
    end)

    [{module, bytecode}] = Code.compile_file(__ENV__.file)

    for {_pid, node, _ordinal} <- peers do
      assert {:module, ^module} =
               :erpc.call(node, :code, :load_binary, [
                 module,
                 ~c"ra_cluster_stream_leader_test.ex",
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

    for {_pid, node, _ordinal} <- peers do
      case :erpc.call(node, :ra_system, :start, [
             :erpc.call(node, Riptide.RaCluster, :system_config, [])
           ]) do
        {:ok, _pid} -> :ok
        {:ok, _pid, _info} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    peers
  end

  defp stop_peer({pid, _node, _ordinal}) do
    if Process.alive?(pid) do
      try do
        :peer.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp eventually(fun, attempts_left \\ 50) do
    cond do
      fun.() -> true
      attempts_left <= 1 -> false
      true -> Process.sleep(200) && eventually(fun, attempts_left - 1)
    end
  end
end
