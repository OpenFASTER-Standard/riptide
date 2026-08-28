defmodule Riptide.RaClusterReplaceMemberTest do
  use ExUnit.Case, async: false

  import Riptide.MultiNodeTestHelpers, only: [unique_pairs: 1]

  @moduletag timeout: 60_000

  alias Riptide.Test.EchoMachine

  @peers [
    {:repl_a, "repl-a", ~c"127.0.0.40"},
    {:repl_b, "repl-b", ~c"127.0.0.41"},
    {:repl_c, "repl-c", ~c"127.0.0.42"}
  ]

  @replacement {:repl_d, "repl-d", ~c"127.0.0.43"}

  @peers2 [
    {:repl2_a, "repl2-a", ~c"127.0.0.44"},
    {:repl2_b, "repl2-b", ~c"127.0.0.45"},
    {:repl2_c, "repl2-c", ~c"127.0.0.46"}
  ]

  @replacement2 {:repl2_d, "repl2-d", ~c"127.0.0.47"}

  setup_all do
    unless Node.alive?() do
      {:ok, _pid} = Node.start(:"ra_cluster_replace_member_origin@127.0.0.1", :longnames)
    end

    :ok
  end

  test "replace_member/5 evicts a dead real member and joins a fresh real replacement, preserving data" do
    peers = bootstrap_peers(@peers ++ [@replacement])
    [{_pid_a, node_a, _}, {_pid_b, node_b, _}, {_pid_c, node_c, _}, {_pid_d, node_d, _}] = peers
    original_nodes = [node_a, node_b, node_c]

    uid = "replace-member-real-" <> Uniq.UUID.uuid4()
    machine = {:module, EchoMachine, %{}}

    assert {:ok, _server_ids} =
             :erpc.call(node_a, Riptide.RaCluster, :start_or_join_replicated, [
               uid,
               original_nodes,
               machine
             ])

    name = String.to_atom(uid)

    # Write real data before the repair, to prove it survives.
    :erpc.call(node_a, Riptide.RaCluster, :process_command, [{name, node_a}, {:add, "a"}])

    # Kill node_c for real — the member being replaced.
    stop_peer_for(peers, node_c)

    survivor_nodes = [node_a, node_b]

    # If node_c happened to be the leader, the survivors must elect a new one
    # before any membership change is possible; and even once a leader is
    # settled, `replace_member/5`'s own `remove_member` call can briefly race
    # its own preceding `add_member` change. Both are real, transient `:ra`
    # conditions (`replace_member/5` retries internally — see its own
    # `retry_cluster_change/2` for the full explanation), not something this
    # test needs to work around itself.
    assert :ok =
             :erpc.call(node_a, Riptide.RaCluster, :replace_member, [
               uid,
               survivor_nodes,
               node_c,
               node_d,
               machine
             ])

    assert eventually(fn ->
             case :erpc.call(node_a, :ra, :members, [{name, node_a}]) do
               {:ok, members, _leader} ->
                 member_nodes = Enum.map(members, fn {_name, n} -> n end)
                 Enum.sort(member_nodes) == Enum.sort([node_a, node_b, node_d])

               _ ->
                 false
             end
           end)

    assert :erpc.call(node_d, Riptide.RaCluster, :server_alive?, [name])
    refute :erpc.call(node_a, Riptide.RaCluster, :member_alive?, [{name, node_c}])

    # No data loss: the write made before the repair is still there,
    # readable through the NEW member.
    assert :erpc.call(node_d, Riptide.RaCluster, :local_query, [{name, node_d}, & &1]) == ["a"]
  end

  test "replace_member/5 self-corrects when a prior attempt already added and started the replacement" do
    # Reproduces finding 3(b) from the Phase 3d-ii final review: a repair
    # attempt can crash after `add_member` and `start_server` both succeed
    # but before `remove_member` runs (e.g. the node running the repair
    # crashes right there). The very next `replace_member/5` retry must
    # still converge on a fully repaired cluster instead of failing outright
    # on `:ra.add_member/2`'s now-genuine `{:error, :already_member}` (and
    # `:ra.start_server/5`'s equivalent "already there") for a `new_node`
    # that's already fully joined.
    peers = bootstrap_peers(@peers2 ++ [@replacement2])
    [{_pid_a, node_a, _}, {_pid_b, node_b, _}, {_pid_c, node_c, _}, {_pid_d, node_d, _}] = peers
    original_nodes = [node_a, node_b, node_c]

    uid = "replace-member-self-correct-" <> Uniq.UUID.uuid4()
    machine = {:module, EchoMachine, %{}}

    assert {:ok, _server_ids} =
             :erpc.call(node_a, Riptide.RaCluster, :start_or_join_replicated, [
               uid,
               original_nodes,
               machine
             ])

    name = String.to_atom(uid)
    :erpc.call(node_a, Riptide.RaCluster, :process_command, [{name, node_a}, {:add, "a"}])

    stop_peer_for(peers, node_c)
    survivor_ids = [{name, node_a}, {name, node_b}]
    cluster_name = uid <> "_cluster"

    # Simulate a prior attempt that got all the way through `add_member` and
    # `start_server` — exactly what `replace_member/5` itself does for these
    # same two steps — but crashed before ever calling `remove_member`.
    # Retries past `:cluster_change_not_permitted` the same way
    # `replace_member/5`'s own `retry_cluster_change/2` does (node_c dying
    # may force a fresh leader election among the 2 survivors first).
    assert eventually(fn ->
             match?(
               {:ok, _reply, _leader},
               :erpc.call(node_a, :ra, :add_member, [survivor_ids, {name, node_d}])
             )
           end)

    assert :ok =
             :erpc.call(node_d, :ra, :start_server, [
               :default,
               cluster_name,
               {name, node_d},
               machine,
               survivor_ids
             ])

    # Wait for node_d to be fully caught up and voting before treating the
    # "prior attempt" as done — otherwise the repair below would have to
    # commit `remove_member` with only 2 of the (still 4-member, since
    # node_c hasn't been evicted yet) config's members able to ack, which
    # can't reach quorum until node_d's freshly-started server finishes
    # catching up and becomes a real voter.
    assert eventually(fn ->
             :erpc.call(node_d, Riptide.RaCluster, :server_alive?, [name]) and
               :erpc.call(node_d, Riptide.RaCluster, :local_query, [{name, node_d}, & &1]) ==
                 ["a"]
           end)

    # The real repair call, run as if for the first time — its own internal
    # `add_member`/`start_server` now both hit "already there" outcomes and
    # must self-correct past them rather than failing the whole call, then
    # succeed at `remove_member` (node_d is already a caught-up voter, so
    # this commits fast).
    assert :ok =
             :erpc.call(node_a, Riptide.RaCluster, :replace_member, [
               uid,
               [node_a, node_b],
               node_c,
               node_d,
               machine
             ])

    assert eventually(fn ->
             case :erpc.call(node_a, :ra, :members, [{name, node_a}]) do
               {:ok, members, _leader} ->
                 member_nodes = Enum.map(members, fn {_name, n} -> n end)
                 Enum.sort(member_nodes) == Enum.sort([node_a, node_b, node_d])

               _ ->
                 false
             end
           end)

    assert :erpc.call(node_d, Riptide.RaCluster, :server_alive?, [name])
    refute :erpc.call(node_a, Riptide.RaCluster, :member_alive?, [{name, node_c}])
    assert :erpc.call(node_d, Riptide.RaCluster, :local_query, [{name, node_d}, & &1]) == ["a"]
  end

  # Shared bootstrap for both tests above: spins up real `:peer` nodes for
  # `specs`, connects them, starts `:ra` and its `:default` system on each,
  # and registers cleanup — everything short of forming any particular
  # cluster, which each test does itself against its own uid.
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
                 ~c"ra_cluster_replace_member_test.ex",
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

    # Every peer's own local `:default` Ra system must be started BEFORE any
    # of them attempts to form or grow a cluster — `start_or_join_replicated/3`
    # and `replace_member/5` both call `:ra.start_cluster/2`/`:ra.start_server/5`,
    # which reach out over RPC to start (or add) servers on the OTHER member
    # nodes too, not just the local one. `start_or_join_replicated/3`'s own
    # `ensure_system_started/0` call only starts the system on whichever node
    # the erpc call itself lands on (node_a below) — it has no way to reach
    # the other peers' local systems. Matches the exact same prerequisite this
    # codebase's other real multi-node tests already establish (see
    # `ra_cluster_replicated_formation_test.exs` and
    # `placement_cluster_test.exs`'s `bootstrap_ra_on_peers/1`); without this,
    # every remote member's start fails with `{:error, :system_not_started}`.
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
