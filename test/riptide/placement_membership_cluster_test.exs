defmodule Riptide.PlacementMembershipClusterTest do
  use ExUnit.Case, async: false

  import Riptide.MultiNodeTestHelpers, only: [unique_pairs: 1]

  @moduletag timeout: 60_000

  @peers [
    {:pm0, ~c"127.0.0.20"},
    {:pm1, ~c"127.0.0.21"},
    {:pm2, ~c"127.0.0.22"},
    {:pm3, ~c"127.0.0.23"},
    {:pm4, ~c"127.0.0.24"}
  ]

  setup_all do
    unless Node.alive?() do
      {:ok, _pid} = Node.start(:"placement_membership_cluster_origin@127.0.0.1", :longnames)
    end

    :ok
  end

  test "5 simultaneously-booting nodes with target size 3 converge on exactly one 3-member cluster" do
    {peers, nodes} = spawn_and_connect(5)

    for {_pid, node} <- peers do
      :erpc.call(node, Application, :put_env, [:riptide, :placement_target_size, 3])
    end

    tasks =
      for {_pid, node} <- peers do
        Task.async(fn ->
          :erpc.call(node, Riptide.PlacementMembership, :bootstrap_once, [])
        end)
      end

    Task.await_many(tasks, 15_000)

    # Let the reconcile loop settle: at least one node's genesis attempt
    # should have won, and every node should agree on the same membership
    # once queried directly against a real member.
    members = wait_for_stable_membership(nodes)

    assert length(members) == 3
    assert Enum.all?(members, &(&1 in nodes))
  end

  test "grows from 3 to 5 members when target size is raised with more live nodes present" do
    {peers, nodes} = spawn_and_connect(5)
    [first_three, remaining_two] = [Enum.take(nodes, 3), Enum.drop(nodes, 3)]

    for {_pid, node} <- peers do
      :erpc.call(node, Application, :put_env, [:riptide, :placement_target_size, 3])
    end

    assert :erpc.call(
             hd(first_three),
             Riptide.RaCluster.Placement,
             :start_genesis_placement_cluster,
             [
               first_three
             ]
           ) == :ok

    for {_pid, node} <- peers do
      :erpc.call(node, Application, :put_env, [:riptide, :placement_target_size, 5])
    end

    tasks =
      for node <- remaining_two do
        Task.async(fn -> :erpc.call(node, Riptide.PlacementMembership, :bootstrap_once, []) end)
      end

    Task.await_many(tasks, 15_000)

    members = wait_for_stable_membership(nodes, 5)
    assert length(members) == 5
  end

  test "shrinks from 5 to 3 members when target size is lowered" do
    {peers, nodes} = spawn_and_connect(5)

    for {_pid, node} <- peers do
      :erpc.call(node, Application, :put_env, [:riptide, :placement_target_size, 5])
    end

    assert :erpc.call(hd(nodes), Riptide.RaCluster.Placement, :start_genesis_placement_cluster, [
             nodes
           ]) ==
             :ok

    for {_pid, node} <- peers do
      :erpc.call(node, Application, :put_env, [:riptide, :placement_target_size, 3])
    end

    # Shrinking is leader-only and one member per reconcile tick (Ra permits
    # only one membership change in flight at a time) — drive it directly on
    # whichever node is currently the real Raft leader, twice, mirroring two
    # real reconcile-loop ticks.
    leader_node = find_leader(nodes)
    :erpc.call(leader_node, Riptide.PlacementMembership, :bootstrap_once, [])

    poll_until(fn ->
      case :erpc.call(leader_node, Riptide.RaCluster.Placement, :local_placement_members, []) do
        {:ok, members} when length(members) == 4 -> members
        _ -> nil
      end
    end)

    new_leader_node = find_leader(nodes)
    :erpc.call(new_leader_node, Riptide.PlacementMembership, :bootstrap_once, [])

    members =
      poll_until(fn ->
        case :erpc.call(
               new_leader_node,
               Riptide.RaCluster.Placement,
               :local_placement_members,
               []
             ) do
          {:ok, members} when length(members) == 3 -> members
          _ -> nil
        end
      end)

    assert length(members) == 3
  end

  test "graceful drain: a member proactively leaves when its supervised process is asked to stop" do
    {peers, nodes} = spawn_and_connect(4)
    [leaving_peer | _] = peers

    for {_pid, node} <- peers do
      :erpc.call(node, Application, :put_env, [:riptide, :placement_target_size, 3])
    end

    member_nodes = Enum.take(nodes, 3)

    assert :erpc.call(
             hd(member_nodes),
             Riptide.RaCluster.Placement,
             :start_genesis_placement_cluster,
             [
               member_nodes
             ]
           ) == :ok

    {_pid, leaving_node} = leaving_peer

    membership_before =
      :erpc.call(leaving_node, Riptide.RaCluster.Placement, :local_placement_members, [])

    if membership_before == :error do
      # This peer never won genesis (only 3 of the 4 real members are
      # actual placement members) — retarget the test onto one that is.
      :ok
    end

    # Find whichever of the 4 peers actually IS a member, then stop its
    # Riptide.PlacementMembership process the same way a normal supervised
    # shutdown would (not a raw kill) — this exercises the real terminate/2
    # callback, not just a crash.
    actual_member_node =
      Enum.find(nodes, fn n ->
        match?({:ok, _}, :erpc.call(n, Riptide.RaCluster.Placement, :local_placement_members, []))
      end)

    {:ok, before_members} =
      :erpc.call(actual_member_node, Riptide.RaCluster.Placement, :local_placement_members, [])

    assert length(before_members) == 3

    pid = :erpc.call(actual_member_node, Process, :whereis, [Riptide.PlacementMembership])
    assert :erpc.call(actual_member_node, GenServer, :stop, [pid, :shutdown, 8_000]) == :ok

    other_member_node = Enum.find(before_members, &(&1 != actual_member_node))

    members =
      poll_until(fn ->
        case :erpc.call(
               other_member_node,
               Riptide.RaCluster.Placement,
               :local_placement_members,
               []
             ) do
          {:ok, members} when length(members) == 2 -> members
          _ -> nil
        end
      end)

    refute actual_member_node in members
  end

  test "dead-member replacement: killing one member converges back to target size with the same size" do
    {peers, _nodes} = spawn_and_connect(4)
    [members_peers, spare_peer] = [Enum.take(peers, 3), Enum.at(peers, 3)]
    member_nodes = Enum.map(members_peers, fn {_pid, node} -> node end)
    {spare_pid, spare_node} = spare_peer

    for {_pid, node} <- peers do
      :erpc.call(node, Application, :put_env, [:riptide, :placement_target_size, 3])
    end

    assert :erpc.call(
             hd(member_nodes),
             Riptide.RaCluster.Placement,
             :start_genesis_placement_cluster,
             [
               member_nodes
             ]
           ) == :ok

    {dead_pid, dead_node} = hd(members_peers)
    :peer.stop(dead_pid)

    # Drive reconciliation manually on a survivor (the leader) and on the
    # spare node (the join candidate) — mirrors what the real periodic timer
    # does, without waiting a full @reconcile_interval_ms in the test.
    [_dead | survivors] = members_peers
    {survivor_pid, survivor_node} = hd(survivors)
    :erpc.call(survivor_node, Riptide.PlacementMembership, :bootstrap_once, [])

    # A plain size-3 check isn't enough to detect real convergence here:
    # the ORIGINAL cluster (with the now-dead node still counted) is already
    # size 3 the instant it forms, and stays exactly size 3 in the steady
    # state too (dead node removed, spare node joined) — so a poll that only
    # checks length would report "converged" on its very first read, before
    # any repair has actually happened. Require the dead node's absence too.
    members =
      poll_until(
        fn ->
          case :erpc.call(survivor_node, Riptide.RaCluster.Placement, :probe_placement_members, [
                 [survivor_node, spare_node]
               ]) do
            {:ok, members} ->
              if length(members) == 3 and dead_node not in members, do: members

            _ ->
              nil
          end
        end,
        20_000
      )

    assert length(members) == 3
    refute dead_node in members
    assert Process.alive?(survivor_pid)
    assert Process.alive?(spare_pid)
  end

  defp spawn_and_connect(count) do
    pa_args = Enum.flat_map(:code.get_path(), fn p -> [~c"-pa", p] end)
    specs = Enum.take(@peers, count)

    peers =
      for {alive_name, host} <- specs do
        {:ok, pid, node} =
          :peer.start_link(%{name: alive_name, host: host, longnames: true, args: pa_args})

        {pid, node}
      end

    on_exit(fn ->
      Enum.each(peers, fn {pid, _node} -> stop_alive_peer(pid) end)

      # Keyed on the full node name, not `alive_name` — `RaCluster.data_dir/0`
      # derives its on-disk directory from `HOSTNAME`, which is set below to
      # `Atom.to_string(node)` (e.g. "pm0@127.0.0.20"), not the bare peer
      # alias ("pm0"). Cleaning up the wrong directory leaves real Ra data on
      # disk for the next test in this file to collide with, since @peers'
      # names/hosts are reused across every test in this module.
      Enum.each(peers, fn {_pid, node} ->
        File.rm_rf!(Path.join(File.cwd!(), Atom.to_string(node)))
      end)
    end)

    push_module_to_peers(peers)
    nodes = Enum.map(peers, fn {_pid, node} -> node end)

    for {n1, n2} <- unique_pairs(nodes) do
      assert :erpc.call(n1, :net_kernel, :connect_node, [n2]) == true
    end

    for {_pid, node} <- peers do
      {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:ra])
      :erpc.call(node, System, :put_env, ["HOSTNAME", Atom.to_string(node)])

      case :erpc.call(node, :ra_system, :start, [
             :erpc.call(node, Riptide.RaCluster, :system_config, [])
           ]) do
        {:ok, _pid} -> :ok
        {:ok, _pid, _info} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    # These bare :peer nodes never boot Riptide.Application, so neither
    # Phoenix.PubSub (which attempt_genesis/reconcile_as_leader's
    # broadcast_members/1 needs) nor Riptide.PlacementMembership's own ETS
    # cache table exist there yet. Bootstrap PubSub explicitly (mirroring
    # test/riptide/stream/stream_placement_cluster_test.exs's exact pattern
    # for the same class of problem), then start the REAL
    # Riptide.PlacementMembership GenServer (unlinked) on every peer — its
    # own init/1 creates the ETS table and subscribes to PubSub as a side
    # effect, and having a genuinely running, supervised-shaped process
    # (not just bare function calls) is what lets the graceful-drain test
    # below exercise a real terminate/2 via GenServer.stop/3. The tests'
    # own direct bootstrap_once/0 calls remain safe to make afterward —
    # they're idempotent, the same operation the GenServer's own :bootstrap
    # message already performs, just driven synchronously instead of
    # waiting on that message or the periodic reconcile timer.
    for {_pid, node} <- peers do
      {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:phoenix_pubsub])

      {:ok, _pid} =
        start_unlinked(node, Phoenix.PubSub.Supervisor, :start_link, [[name: Riptide.PubSub]])

      {:ok, _pid} = start_unlinked(node, Riptide.PlacementMembership, :start_link, [[]])
    end

    {peers, nodes}
  end

  defp stop_alive_peer(pid) do
    if Process.alive?(pid), do: safe_stop_peer(pid)
  end

  defp safe_stop_peer(pid) do
    :peer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  defp push_module_to_peers(peers) do
    bytecode = Riptide.MultiNodeTestHelpers.own_module_bytecode(__MODULE__)

    for {_pid, node} <- peers do
      assert {:module, __MODULE__} =
               :erpc.call(node, :code, :load_binary, [
                 __MODULE__,
                 ~c"placement_membership_cluster_test.ex",
                 bytecode
               ])
    end
  end

  # Starts `apply(mod, fun, args)` on `node` without linking whatever it
  # starts to the transient process `:erpc.call/4` uses to dispatch the call
  # — a direct `:erpc.call` of a `start_link`-shaped function would die the
  # instant erpc's own dispatch process exits, taking the newly-started
  # process down with it (confirmed empirically in
  # test/riptide/stream/stream_placement_cluster_test.exs, Task 9). Mirrors
  # that same file's `start_unlinked/4` exactly.
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

  defp find_leader(nodes) do
    Enum.find(nodes, fn n ->
      :erpc.call(n, Riptide.RaCluster.Placement, :placement_leader?, [])
    end)
  end

  defp poll_until(fun, timeout_ms \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_poll_until(fun, deadline)
  end

  defp do_poll_until(fun, deadline) do
    case fun.() do
      nil ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("Condition never became true within the timeout")
        else
          Process.sleep(200)
          do_poll_until(fun, deadline)
        end

      result ->
        result
    end
  end

  defp wait_for_stable_membership(candidate_nodes, expected_size \\ nil, timeout_ms \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_membership(candidate_nodes, expected_size, deadline)
  end

  defp poll_membership(candidate_nodes, expected_size, deadline) do
    case :erpc.call(hd(candidate_nodes), Riptide.RaCluster.Placement, :probe_placement_members, [
           candidate_nodes
         ]) do
      {:ok, members} when expected_size == nil or length(members) == expected_size ->
        members

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("Placement membership never stabilized within the timeout")
        else
          Process.sleep(200)
          poll_membership(candidate_nodes, expected_size, deadline)
        end
    end
  end
end
