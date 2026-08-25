defmodule Riptide.RaClusterReplicatedFormationTest do
  use ExUnit.Case, async: false

  @moduletag timeout: 60_000

  alias Riptide.Test.EchoMachine

  @peers [
    {:sojr_a, "sojr-a", ~c"127.0.0.11"},
    {:sojr_b, "sojr-b", ~c"127.0.0.12"},
    {:sojr_c, "sojr-c", ~c"127.0.0.13"}
  ]

  setup_all do
    unless Node.alive?() do
      {:ok, _pid} = Node.start(:"ra_cluster_replicated_formation_origin@127.0.0.1", :longnames)
    end

    :ok
  end

  # Reproduces Phase 3d-i's HA-proof spike finding 1 directly, at the exact
  # layer where the bug lived: `start_or_join_replicated/3` blindly trusting
  # `:ra.start_cluster/2`'s `{:ok, Started, NotStarted}` reply even when
  # `NotStarted` is non-empty. With RF=3, 2-of-3 members starting is already
  # a quorum — `:ra.start_cluster/2` succeeds and reports the 3rd in
  # `NotStarted` rather than failing outright, which is exactly what made
  # the old code's blanket `{:ok, member_ids}` dangerous: the returned
  # server_ids looked completely healthy even though one replica silently
  # never started. Node C here stands in for a fleet node whose `:ra` OTP
  # application is running (an ordinary dependency of `:riptide`, always up)
  # but whose local `:default` Ra *system* hasn't been started yet — exactly
  # the gap `Riptide.Application.start/2` now closes proactively in
  # production; this test proves the lower-level `RaCluster` fix holds even
  # without that boot-time call, since a momentary reason for a member to be
  # unreachable (network blip, mid-crash restart) can never be fully ruled
  # out by a single boot-time call anyway.
  test "a 2-of-3 quorum with the 3rd member's local Ra system not yet started is not silently accepted as fully replicated" do
    pa_args = Enum.flat_map(:code.get_path(), fn p -> [~c"-pa", p] end)

    peers =
      for {alive_name, ordinal, host} <- @peers do
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

      Enum.each(@peers, fn {_alive_name, ordinal, _host} ->
        File.rm_rf!(Path.join(File.cwd!(), ordinal))
      end)
    end)

    [{module, bytecode}] = Code.compile_file(__ENV__.file)

    for {_pid, node, _ordinal} <- peers do
      assert {:module, ^module} =
               :erpc.call(node, :code, :load_binary, [
                 module,
                 ~c"ra_cluster_replicated_formation_test.ex",
                 bytecode
               ])
    end

    [{_pid_a, node_a, _}, {_pid_b, node_b, _}, {_pid_c, node_c, _}] = peers

    for {n1, n2} <- [{node_a, node_b}, {node_a, node_c}, {node_b, node_c}] do
      assert :erpc.call(n1, :net_kernel, :connect_node, [n2]) == true
    end

    # `:ra` the OTP application is started on all 3, mirroring how it's
    # always running as an ordinary dependency of `:riptide` in production —
    # only the `:default` Ra *system* is what's deliberately left unstarted
    # on node_c, reproducing the actual gap.
    for {_pid, node, _ordinal} <- peers do
      {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:ra])
    end

    for node <- [node_a, node_b] do
      {:ok, _} =
        :erpc.call(node, :ra_system, :start, [
          :erpc.call(node, Riptide.RaCluster, :system_config, [])
        ])
    end

    uid = "sojr-race-" <> Uniq.UUID.uuid4()
    machine = {:module, EchoMachine, %{}}
    member_nodes = [node_a, node_b, node_c]

    # Old behavior: 2-of-3 (a and b) reach quorum, `:ra.start_cluster/2`
    # returns `{:ok, [a's id, b's id], [c's id]}`, and the pre-fix code
    # returned `{:ok, member_ids}` for all 3 anyway — silently under-
    # replicating. The fix must surface this as retriable instead.
    assert :erpc.call(node_a, Riptide.RaCluster, :start_or_join_replicated, [
             uid,
             member_nodes,
             machine
           ]) == {:error, :cluster_not_formed}

    refute :erpc.call(node_c, Riptide.RaCluster, :server_alive?, [String.to_atom(uid)])

    # Node C catches up — mirrors what `Riptide.Application.start/2` now
    # does proactively at boot in production — and a retry (exactly what
    # `Riptide.Stream.Placement`'s own bounded-retry loop would do) succeeds
    # for real, with all 3 members genuinely running.
    {:ok, _} =
      :erpc.call(node_c, :ra_system, :start, [
        :erpc.call(node_c, Riptide.RaCluster, :system_config, [])
      ])

    assert {:ok, server_ids} =
             :erpc.call(node_a, Riptide.RaCluster, :start_or_join_replicated, [
               uid,
               member_nodes,
               machine
             ])

    assert length(server_ids) == 3
    assigned_nodes = Enum.map(server_ids, fn {_name, n} -> n end)
    assert Enum.sort(assigned_nodes) == Enum.sort(member_nodes)
    assert :erpc.call(node_c, Riptide.RaCluster, :server_alive?, [String.to_atom(uid)])
  end
end
