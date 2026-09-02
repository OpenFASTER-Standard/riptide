defmodule Riptide.BlobStoreClusterTest do
  use ExUnit.Case, async: false

  import Riptide.MultiNodeTestHelpers, only: [unique_pairs: 1]

  @moduletag timeout: 120_000

  @peers [
    {:blob_a, "blob-a", ~c"127.0.0.50"},
    {:blob_b, "blob-b", ~c"127.0.0.51"},
    {:blob_c, "blob-c", ~c"127.0.0.52"}
  ]

  # A 4th, spare node — only the healer test needs it. With exactly 3 peers
  # total (RF), killing one leaves only 2 remaining nodes, both already
  # holding a copy — there's no unused node anywhere for the healer to
  # promote as a replacement, so "repair" could never be observed. Mirrors
  # ra_cluster_replace_member_test.exs's own @peers ++ [@replacement] shape
  # for the exact same reason.
  @spare {:blob_d, "blob-d", ~c"127.0.0.53"}

  setup_all do
    unless Node.alive?() do
      {:ok, _pid} = Node.start(:"blob_store_cluster_origin@127.0.0.1", :longnames)
    end

    :ok
  end

  test "put/2 replicates to RF other live nodes; get/2 succeeds from a node that never wrote it" do
    peers = bootstrap_peers(@peers)
    [{_pid_a, node_a, _}, {_pid_b, node_b, _}, {_pid_c, node_c, _}] = peers

    tenant_id = "blob-cluster-" <> Uniq.UUID.uuid4()
    bytes = :crypto.strong_rand_bytes(1024)

    assert {:ok, hash} = :erpc.call(node_a, Riptide.BlobStore, :put, [tenant_id, bytes])

    assert eventually(fn ->
             case :erpc.call(node_a, Riptide.BlobStore.LocationIndex, :list_locations, [
                    tenant_id,
                    hash
                  ]) do
               {:ok, nodes} -> Enum.sort(nodes) == Enum.sort([node_a, node_b, node_c])
               _ -> false
             end
           end)

    # node_c never received the original put/2 directly from a test call —
    # it only has a copy because put/2's own replication pushed one there.
    assert {:ok, ^bytes} = :erpc.call(node_c, Riptide.BlobStore, :get, [tenant_id, hash])
  end

  test "a corrupted local copy is rejected on read, not silently served" do
    peers = bootstrap_peers(@peers)
    [{_pid_a, node_a, _}, _peer_b, _peer_c] = peers

    tenant_id = "blob-cluster-" <> Uniq.UUID.uuid4()
    bytes = :crypto.strong_rand_bytes(1024)
    {:ok, hash} = :erpc.call(node_a, Riptide.BlobStore, :put, [tenant_id, bytes])

    # Corrupt node_a's own local copy directly on disk.
    path = :erpc.call(node_a, Riptide.BlobStore, :path_for, [tenant_id, hash])
    :erpc.call(node_a, File, :write, [path, "corrupted"])

    assert {:error, :not_found} = :erpc.call(node_a, Riptide.BlobStore, :get, [tenant_id, hash])
  end

  test "healer repairs a blob after its holding node dies" do
    peers = bootstrap_peers(@peers ++ [@spare])
    [{_pid_a, node_a, _}, {_pid_b, _node_b, _}, {_pid_c, node_c, _}, {_pid_d, _node_d, _}] = peers

    # Healer.sweep/0's own known_tenant_ids/0 discovers tenants via the name
    # registry — a tenant with no claimed name is invisible to it, so the
    # tenant must actually claim one here just like a real signup would.
    tenant_id = "blob-cluster-healer-" <> Uniq.UUID.uuid4()
    assert :claimed = :erpc.call(node_a, Riptide.Placement, :claim_name, [tenant_id, tenant_id])

    bytes = :crypto.strong_rand_bytes(1024)
    {:ok, hash} = :erpc.call(node_a, Riptide.BlobStore, :put, [tenant_id, bytes])

    assert eventually(fn ->
             match?(
               {:ok, [_, _, _]},
               :erpc.call(node_a, Riptide.BlobStore.LocationIndex, :list_locations, [
                 tenant_id,
                 hash
               ])
             )
           end)

    stop_peer_for(peers, node_c)

    assert eventually(
             fn ->
               :erpc.call(node_a, Riptide.BlobStore.Healer, :sweep, [])

               case :erpc.call(node_a, Riptide.BlobStore.LocationIndex, :list_locations, [
                      tenant_id,
                      hash
                    ]) do
                 {:ok, nodes} -> length(nodes) == 3 and node_c not in nodes
                 _ -> false
               end
             end,
             100
           )

    # The repaired-in replica set still serves the original bytes correctly.
    {:ok, [n | _]} =
      :erpc.call(node_a, Riptide.BlobStore.LocationIndex, :list_locations, [tenant_id, hash])

    assert {:ok, ^bytes} = :erpc.call(n, Riptide.BlobStore, :get, [tenant_id, hash])
  end

  # Bare `:peer` nodes never boot the full Riptide.Application (its
  # RiptideWeb.Endpoint/MetricsEndpoint would conflict on the same ports
  # across multiple simultaneously-running peers on this one machine) —
  # mirrors test/riptide/placement_membership_cluster_test.exs's own
  # established pattern of starting only the specific pieces this test
  # actually needs, not the whole app.
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
                 ~c"blob_store_cluster_test.ex",
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

    # PlacementMembership's own genesis formation normally waits on a short
    # settle window (Phase 3e) plus the periodic :reconcile tick — too slow
    # for a test. bootstrap_once/0 is the public, synchronous, idempotent
    # "join or form genesis right now" entry point tests are meant to call
    # directly (see its own doc). Called on every peer since any of them
    # might be the one that actually forms the cluster; the others just
    # discover it as already-formed.
    for {_pid, node, _ordinal} <- peers do
      :ok = :erpc.call(node, Riptide.PlacementMembership, :bootstrap_once, [])
    end

    # Only the first `target_size/0` (default 3) sorted candidates ever
    # become placement-cluster members — form_genesis_if_selected/0 caps
    # genesis at target_size(), and reconcile/0's own ambient try_join only
    # fires `if length(members) < target_size()`, which is never true again
    # once exactly 3 have joined. A 4th, spare peer (see @spare) is
    # therefore NEVER expected to join the placement cluster itself — it
    # only needs distributed-Erlang connectivity (already established above
    # via connect_node/1) to run its own BlobStore/Healer and receive
    # replicated blob bytes. Waiting on ALL of `peers` here would never
    # converge whenever a spare is present.
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
    {:ok, _} = start_unlinked(node, Riptide.BlobStore.Healer, :start_link, [[]])
  end

  # Starts `apply(mod, fun, args)` on `node` without linking whatever it
  # starts to the transient process `:erpc.call/4` uses to dispatch the
  # call — mirrors placement_membership_cluster_test.exs's own helper of
  # the same name/shape exactly.
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

  defp stop_peer_for(peers, target_node) do
    {pid, ^target_node, _ordinal} =
      Enum.find(peers, fn {_pid, node, _ordinal} -> node == target_node end)

    stop_peer({pid, target_node, nil})
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
