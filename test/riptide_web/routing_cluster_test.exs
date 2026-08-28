defmodule RiptideWeb.RoutingClusterTest do
  use ExUnit.Case, async: false

  import Riptide.MultiNodeTestHelpers, only: [unique_pairs: 1]

  @moduletag timeout: 60_000

  @peer_specs [
    {:riptide_routing0, "riptide-0", ~c"127.0.0.10"},
    {:riptide_routing1, "riptide-1", ~c"127.0.0.11"},
    {:riptide_routing2, "riptide-2", ~c"127.0.0.12"},
    {:riptide_routing3, "riptide-3", ~c"127.0.0.13"}
  ]

  setup_all do
    unless Node.alive?() do
      {:ok, _pid} = Node.start(:"routing_cluster_origin@127.0.0.1", :longnames)
    end

    :ok
  end

  test "a node that isn't one of a stream's 3 replicas still serves requests for it correctly" do
    pa_args = Enum.flat_map(:code.get_path(), fn p -> [~c"-pa", p] end)

    peers =
      for {alive_name, ordinal, host} <- @peer_specs do
        {:ok, pid, _not_yet_named} =
          :peer.start_link(%{
            connection: :standard_io,
            args: pa_args,
            env: [{~c"HOSTNAME", to_charlist(ordinal)}]
          })

        node = :"#{alive_name}@#{to_string(host)}"

        {:ok, _kernel_pid} =
          :peer.call(pid, :net_kernel, :start, [node, %{name_domain: :longnames}])

        assert :net_kernel.hidden_connect_node(node) == true

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

      Enum.each(@peer_specs, fn {_alive_name, ordinal, _host} ->
        File.rm_rf!(Path.join(File.cwd!(), ordinal))
      end)
    end)

    [{module, bytecode}] = Code.compile_file(__ENV__.file)

    for {_pid, node, _ordinal} <- peers do
      assert {:module, ^module} =
               :erpc.call(node, :code, :load_binary, [
                 module,
                 ~c"routing_cluster_test.ex",
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

    # Only the first 3 peers form the placement cluster (a fixed genesis
    # target size of 3, independent of total fleet size) — the 4th peer is
    # deliberately extra fleet capacity, exactly like a real node joining a
    # growing cluster that isn't a placement-cluster member. It still needs
    # :ra/PubSub bootstrapped (below) since it's a real node any stream
    # request could land on, just not a placement metadata cluster member.
    placement_peers = Enum.take(peers, 3)
    placement_nodes = Enum.map(placement_peers, fn {_pid, node, _ordinal} -> node end)

    results =
      Enum.map(placement_peers, fn {_pid, node, _ordinal} ->
        :erpc.call(node, Riptide.RaCluster, :start_genesis_placement_cluster, [placement_nodes])
      end)

    assert Enum.any?(results, &(&1 == :ok))

    for {_pid, node, _ordinal} <- peers do
      {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:phoenix_pubsub])

      {:ok, _pid} =
        start_unlinked(node, Phoenix.PubSub.Supervisor, :start_link, [[name: Riptide.PubSub]])
    end

    for {_pid, node, _ordinal} <- peers do
      {:ok, _pid} = start_unlinked(node, Riptide.Stream.Placement, :start_link, [[]])
    end

    {_pid, entry_node, _ordinal} = hd(peers)
    stream_id = "routing-cluster-" <> Uniq.UUID.uuid4()

    # RF=3 with 4 connected peers: propose_nodes/2 always puts the entry
    # (proposing) node first, then picks 2 more at random from the other 3
    # — so exactly one of the 4 peers is NOT assigned. Which one is random;
    # find out for real rather than assuming, so the assertions below always
    # target the actual non-member peer.
    assert :ok =
             :erpc.call(entry_node, Riptide.Stream.StreamSupervisor, :ensure_ready, [stream_id])

    server_ids = :erpc.call(entry_node, Riptide.Stream.Placement, :server_ids!, [stream_id])
    assert length(server_ids) == 3
    assigned_nodes = Enum.map(server_ids, fn {_name, node} -> node end)
    assert length(Enum.uniq(assigned_nodes)) == 3
    assert Enum.all?(assigned_nodes, &(&1 in nodes))

    [non_member_node] = nodes -- assigned_nodes

    graph = :erpc.call(entry_node, RDF.Graph, :new, [])
    event = :erpc.call(entry_node, Riptide.Event, :new, [stream_id, :replace, graph])
    stamped = :erpc.call(entry_node, Riptide.Stream.StreamServer, :append, [stream_id, event])
    assert stamped.sequence == 1

    # The real proof: the ONE peer that was never assigned as a replica —
    # never ran Riptide.Stream.Placement.ensure_started/2's formation
    # branch for this stream at all, has no local Ra process for it — still
    # correctly serves the same request path a member node would.
    assert :ok =
             :erpc.call(non_member_node, Riptide.Stream.StreamSupervisor, :ensure_ready, [
               stream_id
             ])

    non_member_server_ids =
      :erpc.call(non_member_node, Riptide.Stream.Placement, :server_ids!, [stream_id])

    assert Enum.sort(non_member_server_ids) == Enum.sort(server_ids)

    {:ok, read_back} =
      :erpc.call(non_member_node, Riptide.Stream.StreamServer, :get_since, [stream_id, 0])

    assert [%{sequence: 1}] = read_back

    # Confirm no local Ra process for this stream's uid ever started on the
    # non-member node — it served the request purely via remote :ra
    # addressing, never local formation.
    uid = :erpc.call(non_member_node, Riptide.RaCluster, :uid_for, [stream_id])
    assert :erpc.call(non_member_node, Process, :whereis, [String.to_atom(uid)]) == nil
  end

  # NOTE (found empirically, not in the brief): plain `spawn(node, fun)` is
  # not valid Elixir — `Kernel.spawn/2` only accepts `(fun, opts)`, never
  # `(node, fun)`; that arity/signature belongs to Erlang's `:erlang.spawn/2`
  # BIF, which Kernel does not re-export. `Node.spawn/2` is Elixir's actual
  # wrapper for "unlinked spawn of `fun` on a remote `node`" and is what's
  # needed here.
  defp start_unlinked(node, mod, fun, args, timeout \\ 5_000) do
    parent = self()

    Node.spawn(node, fn ->
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
