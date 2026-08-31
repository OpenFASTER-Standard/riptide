defmodule Riptide.PlacementSnapshotRecoveryTest do
  use ExUnit.Case, async: false

  import Riptide.MultiNodeTestHelpers, only: [unique_pairs: 1]

  @moduletag timeout: 60_000

  # This is a tripwire, not just a regression test — see the design spec
  # correction in `docs/superpowers/specs/2026-08-25-phase-3c-i-placement-metadata-design.md`
  # §5 for the full writeup. Short version:
  #
  # Losing genuine quorum on the placement metadata cluster (2-of-3 members
  # killed) and then restarting those members under fresh identities (new
  # pod IPs, same Kubernetes StatefulSet `HOSTNAME`) turns out to self-heal
  # automatically, with zero data loss, via the combination of:
  #
  #   1. `RaCluster.data_dir/0` keys on `HOSTNAME` (the stable pod name),
  #      not `node()`/IP — a restarted member recovers its own prior
  #      on-disk `:ra` data.
  #   2. `ra_server:init/1`'s cluster-membership recovery trusts the
  #      *freshly passed* `initial_members` config when no snapshot exists
  #      on disk, rather than the stale membership from before the restart.
  #   3. `PlacementMachine.apply/3` never emits a `{:release_cursor, ...}`
  #      effect, so the placement cluster never snapshots — meaning
  #      condition 2's "no snapshot exists" branch always applies today.
  #
  # If `PlacementMachine` ever gains a `release_cursor` effect (e.g. for
  # compaction), condition 3 stops holding and this test should start
  # failing — that failure IS the point: it means whoever made that change
  # needs to consciously design real membership-reconciliation tooling
  # (Phase 3d's originally-scoped "manual grow/shrink" territory) rather
  # than unknowingly losing a self-healing property nothing else guards.
  @peers [
    {:snap_a, "riptide-0", ~c"127.0.0.30"},
    {:snap_b, "riptide-1", ~c"127.0.0.31"},
    {:snap_c, "riptide-2", ~c"127.0.0.32"}
  ]

  @replacements [
    {:snap_a2, "riptide-0", ~c"127.0.0.33"},
    {:snap_b2, "riptide-1", ~c"127.0.0.34"}
  ]

  setup_all do
    unless Node.alive?() do
      {:ok, _pid} = Node.start(:"placement_snapshot_recovery_origin@127.0.0.1", :longnames)
    end

    :ok
  end

  test "the placement cluster reconciles membership and preserves all data after losing quorum and restarting under fresh identities" do
    pa_args = Enum.flat_map(:code.get_path(), fn p -> [~c"-pa", p] end)

    original_peers = start_peers(@peers, pa_args)

    on_exit(fn ->
      cleanup_data_dirs(@peers)
    end)

    bytecode = Riptide.MultiNodeTestHelpers.own_module_bytecode(__MODULE__)
    push_module(original_peers, __MODULE__, bytecode)

    nodes = Enum.map(original_peers, fn {_pid, node, _ordinal} -> node end)

    for {n1, n2} <- unique_pairs(nodes) do
      assert :erpc.call(n1, :net_kernel, :connect_node, [n2]) == true
    end

    bootstrap_ra(original_peers)
    form_placement_cluster(original_peers, nodes)

    [{pid_a, node_a, _}, {pid_b, _node_b, _}, {_pid_c, node_c, _}] = original_peers

    stream_id = "snapshot-recovery-" <> Uniq.UUID.uuid4()

    assigned = :erpc.call(node_a, Riptide.Placement, :assign, [stream_id, [node_a]])

    assert assigned == [node_a]

    assert :erpc.call(node_c, Riptide.Placement, :lookup, [stream_id]) == [node_a]

    # Kill 2-of-3 — genuine quorum loss, not a graceful shutdown.
    stop_peer(pid_a)
    stop_peer(pid_b)

    # Spawn fresh replacement peers for riptide-0/riptide-1 under brand-new
    # node identities (new IPs) but the SAME `HOSTNAME` env var — mirroring
    # a real pod restart under a new IP on the same StatefulSet ordinal /
    # PVC mount.
    replacement_peers = start_peers(@replacements, pa_args)

    on_exit(fn ->
      Enum.each(replacement_peers, fn {pid, _node, _ordinal} -> stop_peer(pid) end)
    end)

    push_module(replacement_peers, __MODULE__, bytecode)

    [{_pid_a2, node_a2, _}, {_pid_b2, node_b2, _}] = replacement_peers

    for node <- [node_a2, node_b2] do
      assert :erpc.call(node, :net_kernel, :connect_node, [node_c]) == true
    end

    bootstrap_ra(replacement_peers)

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
      _ =
        :erpc.call(node, Riptide.RaCluster.Placement, :start_genesis_placement_cluster, [
          fresh_nodes
        ])
    end

    # Membership reconciles to the fresh identities, queried from the one
    # member that was never killed.
    assert eventually(fn ->
             case :erpc.call(node_c, :ra, :members, [{:riptide_placement, node_c}]) do
               {:ok, members, _leader} ->
                 member_nodes = Enum.map(members, fn {_name, n} -> n end)
                 Enum.sort(member_nodes) == Enum.sort([node_a2, node_b2, node_c])

               _ ->
                 false
             end
           end)

    # No data loss: the original assignment, made before the quorum loss,
    # is still there — queried against the reconciled cluster.
    assert :erpc.call(node_c, Riptide.Placement, :lookup, [stream_id]) == [node_a]
  end

  defp start_peers(peer_specs, pa_args) do
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
  end

  defp push_module(peers, module, bytecode) do
    for {_pid, node, _ordinal} <- peers do
      assert {:module, ^module} =
               :erpc.call(node, :code, :load_binary, [
                 module,
                 ~c"placement_snapshot_recovery_test.ex",
                 bytecode
               ])
    end
  end

  defp bootstrap_ra(peers) do
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
  end

  defp form_placement_cluster(peers, nodes) do
    results =
      Enum.map(peers, fn {_pid, node, _ordinal} ->
        :erpc.call(node, Riptide.RaCluster.Placement, :start_genesis_placement_cluster, [nodes])
      end)

    assert Enum.all?(results, &(&1 in [:ok, {:error, :cluster_not_formed}]))
    assert Enum.any?(results, &(&1 == :ok))
  end

  defp stop_peer(pid) do
    :peer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  defp cleanup_data_dirs(peer_specs) do
    Enum.each(peer_specs, fn {_alive_name, ordinal, _host} ->
      File.rm_rf!(Path.join(File.cwd!(), ordinal))
    end)
  end

  # Membership reconciliation isn't instantaneous — it happens as a side
  # effect of `start_genesis_placement_cluster/1`'s own election/replication
  # machinery settling, not synchronously within a single call.
  defp eventually(fun, attempts_left \\ 50) do
    cond do
      fun.() ->
        true

      attempts_left <= 1 ->
        false

      true ->
        Process.sleep(100)
        eventually(fun, attempts_left - 1)
    end
  end
end
