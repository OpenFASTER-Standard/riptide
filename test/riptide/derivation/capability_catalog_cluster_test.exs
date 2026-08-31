defmodule Riptide.Derivation.CapabilityCatalogClusterTest do
  use ExUnit.Case, async: false

  import Riptide.MultiNodeTestHelpers, only: [unique_pairs: 1]

  @moduletag timeout: 120_000

  @peers [
    {:cap_a, "cap-a", ~c"127.0.0.60"},
    {:cap_b, "cap-b", ~c"127.0.0.61"},
    {:cap_c, "cap-c", ~c"127.0.0.62"}
  ]

  # A 4th, spare node. With exactly 3 peers total and the default
  # replication factor also 3, BlobStore.put/1's own other_nodes/0
  # (Node.list() sorted, first RF-1) always replicates to *every* other
  # connected node deterministically — there's no node left over to prove a
  # genuine remote fetch. Naming this one alphabetically last means
  # other_nodes/0's own sort-and-take-first-2 always excludes it, mirroring
  # blob_store_cluster_test.exs's own @spare fix for the identical class of
  # problem (found live by running this test, not anticipated up front).
  @spare {:cap_d, "cap-d", ~c"127.0.0.63"}

  setup_all do
    unless Node.alive?() do
      {:ok, _pid} = Node.start(:"capability_catalog_cluster_origin@127.0.0.1", :longnames)
    end

    :ok
  end

  test "materialize/1 fetches from a remote replica and caches it locally, without registering with LocationIndex" do
    peers = bootstrap_peers(@peers ++ [@spare])
    [{_pid_a, node_a, _}, _peer_b, _peer_c, {_pid_d, node_d, _}] = peers

    bytes = :crypto.strong_rand_bytes(1024)
    {:ok, hash} = :erpc.call(node_a, Riptide.BlobStore, :put, [bytes])

    # node_d never received a local replica from put/1's own replication —
    # excluded deterministically by other_nodes/0's own sort (see @spare).
    entry = %Riptide.Derivation.CapabilityCatalogEntry{
      name: RDF.iri("urn:riptide:capability:cluster-#{System.unique_integer([:positive])}"),
      kind: :effect,
      component_hash: hash,
      function: "run",
      fuel_limit: 10_000_000,
      timeout_ms: 5_000,
      memory_limits: %{
        max_memory_size: nil,
        max_table_elements: nil,
        max_instances: nil,
        max_tables: nil
      }
    }

    assert {:ok, definition} =
             :erpc.call(node_d, Riptide.Derivation.CapabilityCatalog, :materialize, [entry])

    assert {:ok, bytes_on_d} = :erpc.call(node_d, File, :read, [definition.component])
    assert bytes_on_d == bytes

    # Never registered as an official BlobStore replica — only a private
    # materialize cache.
    assert {:ok, locations} =
             :erpc.call(node_a, Riptide.BlobStore.LocationIndex, :list_locations, [hash])

    refute node_d in locations
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

    bytecode = Riptide.MultiNodeTestHelpers.own_module_bytecode(__MODULE__)

    for {_pid, node, _ordinal} <- peers do
      assert {:module, __MODULE__} =
               :erpc.call(node, :code, :load_binary, [
                 __MODULE__,
                 ~c"capability_catalog_cluster_test.ex",
                 bytecode
               ])
    end

    nodes = Enum.map(peers, fn {_pid, node, _ordinal} -> node end)

    for {n1, n2} <- unique_pairs(nodes) do
      assert :erpc.call(n1, :net_kernel, :connect_node, [n2]) == true
    end

    for {_pid, node, ordinal} <- peers do
      bootstrap_node(node, ordinal)
    end

    for {_pid, node, _ordinal} <- peers do
      :ok = :erpc.call(node, Riptide.PlacementMembership, :bootstrap_once, [])
    end

    core_peers = Enum.take(peers, Riptide.PlacementMembership.target_size())

    assert eventually(fn ->
             Enum.all?(core_peers, fn {_pid, node, _ordinal} ->
               match?(
                 {:ok, _},
                 :erpc.call(node, Riptide.RaCluster.Placement, :local_placement_members, [])
               )
             end)
           end)

    peers
  end

  defp bootstrap_node(node, ordinal) do
    :erpc.call(node, System, :put_env, [
      "RIPTIDE_BLOB_DATA_DIR",
      Path.join(File.cwd!(), "#{ordinal}/blob_data")
    ])

    :erpc.call(node, System, :put_env, [
      "RIPTIDE_CAPABILITY_CACHE_DIR",
      Path.join(File.cwd!(), "#{ordinal}/capability_cache")
    ])

    {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:ra])

    case :erpc.call(node, :ra_system, :start, [
           :erpc.call(node, Riptide.RaCluster, :system_config, [])
         ]) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:phoenix_pubsub])

    {:ok, _} =
      start_unlinked(node, Phoenix.PubSub.Supervisor, :start_link, [[name: Riptide.PubSub]])

    {:ok, _} = start_unlinked(node, Riptide.PlacementMembership, :start_link, [[]])
    {:ok, _} = start_unlinked(node, Riptide.Stream.Placement, :start_link, [[]])

    {:ok, _} =
      start_unlinked(node, Registry, :start_link, [
        [keys: :unique, name: Riptide.SupervisedProcess.Registry]
      ])

    {:ok, _} =
      start_unlinked(node, DynamicSupervisor, :start_link, [
        [strategy: :one_for_one, name: Riptide.SupervisedProcess.DynamicSupervisor]
      ])

    {:ok, _} = start_unlinked(node, Riptide.BlobStore, :start_link, [[]])
  end

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
