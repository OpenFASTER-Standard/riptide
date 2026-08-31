defmodule Riptide.PlacementClusterTest do
  use ExUnit.Case, async: false

  import Riptide.MultiNodeTestHelpers, only: [unique_pairs: 1]

  @moduletag timeout: 60_000

  @peers [
    {:riptide0, "riptide-0", ~c"127.0.0.1"},
    {:riptide1, "riptide-1", ~c"127.0.0.2"},
    {:riptide2, "riptide-2", ~c"127.0.0.3"}
  ]

  setup_all do
    unless Node.alive?() do
      {:ok, _pid} = Node.start(:"placement_cluster_origin@127.0.0.1", :longnames)
    end

    :ok
  end

  test "the placement metadata cluster bootstraps across 3 real nodes and agrees on assignments" do
    {peers, nodes} = bootstrap()

    {_pid, entry_node, _ordinal} = hd(peers)
    stream_id = "placement-test-" <> Uniq.UUID.uuid4()
    proposed = Enum.take(nodes, 2)

    assigned =
      :erpc.call(entry_node, Riptide.Placement, :assign, [stream_id, proposed])

    assert Enum.sort(assigned) == Enum.sort(proposed)

    # Every member — not just the one that received the assign call — must
    # agree on the same assignment, proving the value actually replicated
    # through the metadata cluster's own Raft consensus rather than just
    # being remembered by whichever node handled the write.
    for {_pid, node, _ordinal} <- peers do
      looked_up = :erpc.call(node, Riptide.Placement, :lookup, [stream_id])
      assert Enum.sort(looked_up) == Enum.sort(proposed)
    end

    # Idempotency holds across real nodes too: a second, different proposal
    # for the same stream_id from a *different* node must not overwrite the
    # first winning assignment.
    {_pid, other_node, _ordinal} = Enum.at(peers, 1)
    different_proposal = Enum.take(Enum.reverse(nodes), 2)

    reassigned =
      :erpc.call(other_node, Riptide.Placement, :assign, [
        stream_id,
        different_proposal
      ])

    assert Enum.sort(reassigned) == Enum.sort(proposed)
  end

  # Regression test for Phase 3d-i's HA-proof spike finding 2: `assign/2,3`
  # and `lookup/1,2` used to always address the metadata cluster via ONLY
  # `RaCluster.placement_ordinals() |> hd()` ("riptide-0"), with no
  # fallback — making that one specific ordinal a de-facto single point of
  # failure for the entire placement layer even though the underlying
  # 3-member Raft cluster stayed perfectly healthy on its other 2 members.
  # Stopping riptide-0's peer here reproduces exactly that: the cluster
  # keeps a live 2-of-3 quorum, but the *client's own addressing*, not
  # consensus, was the thing that used to break.
  test "assign/2 and lookup/2 fall back to a surviving ordinal when riptide-0 is unreachable" do
    {peers, nodes} = bootstrap()

    [{pid0, node0, _ord0}, {_pid1, node1, _ord1} = peer1, {_pid2, node2, _ord2} = peer2] = peers
    surviving_peers = [peer1, peer2]

    stop_peer(pid0)

    {_pid, entry_node, _ordinal} = peer1
    stream_id = "placement-fallback-test-" <> Uniq.UUID.uuid4()
    proposed = Enum.take(nodes, 2)

    assigned =
      :erpc.call(entry_node, Riptide.Placement, :assign, [stream_id, proposed])

    assert Enum.sort(assigned) == Enum.sort(proposed)

    for {_pid, node, _ordinal} <- surviving_peers do
      looked_up = :erpc.call(node, Riptide.Placement, :lookup, [stream_id])
      assert Enum.sort(looked_up) == Enum.sort(proposed)
    end

    refute node0 in [node1, node2]
  end

  defp bootstrap do
    pa_args = Enum.flat_map(:code.get_path(), fn p -> [~c"-pa", p] end)
    peers = spawn_peers(pa_args)

    on_exit(fn -> cleanup_peers(peers) end)

    push_module_to_peers(peers)

    nodes = Enum.map(peers, fn {_pid, node, _ordinal} -> node end)

    for {n1, n2} <- unique_pairs(nodes) do
      assert :erpc.call(n1, :net_kernel, :connect_node, [n2]) == true
    end

    bootstrap_ra_on_peers(peers)
    form_placement_cluster(peers, nodes)

    {peers, nodes}
  end

  defp spawn_peers(pa_args) do
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
  end

  defp cleanup_peers(peers) do
    Enum.each(peers, fn {pid, _node, _ordinal} -> stop_peer(pid) end)

    # NEW GOTCHA (found empirically while implementing this test, beyond
    # the brief's own list): `:peer`-spawned nodes don't load this
    # project's Mix config at all (they're bare `erl` processes booted
    # with just `-pa <code path>`, no `-config`/release env) — so
    # `RaCluster.data_dir/0`'s `Application.get_env(:ra, :data_dir,
    # File.cwd!())` falls through to the `File.cwd!()` default on every
    # peer, NOT `config/test.exs`'s `priv/ra_data_test`. Each peer
    # inherits this test-runner's own cwd (the repo root), so `:ra`
    # durably persists the placement cluster's real on-disk state
    # directly under `<repo_root>/riptide-0`, `riptide-1`, `riptide-2` —
    # confirmed by inspecting the filesystem after a run. Left alone, a
    # second run recovers that stale state at `:ra_system` boot before
    # this test's own bootstrap logic gets a chance to run, corrupting
    # the very thing under test (observed: every member showing up
    # "already started" immediately, before any real interaction).
    # Clean it up here so the test is idempotent across repeated runs.
    Enum.each(@peers, fn {_alive_name, ordinal, _host} ->
      File.rm_rf!(Path.join(File.cwd!(), ordinal))
    end)
  end

  defp stop_peer(pid) do
    if Process.alive?(pid), do: do_stop_peer(pid)
  end

  defp do_stop_peer(pid) do
    :peer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  defp push_module_to_peers(peers) do
    # ExUnit compiles test/ files purely in-memory (only "lib" and
    # "test/support" are in `elixirc_paths`, per mix.exs) — no .beam for this
    # module ever lands on disk, so peers spawned with `-pa <code path>`
    # never see it, even though the full path list is passed. Confirmed
    # empirically: passing a closure defined in this module as an
    # `:erpc.call/4` argument fails with `{:exception, :undef, ...}` on the
    # remote node when the closure is invoked there. Fix: push this
    # already-loaded module's own bytecode (see
    # `MultiNodeTestHelpers.own_module_bytecode/1`) to each peer via
    # `:code.load_binary/3` before relying on any closure from this module
    # crossing the wire — this is the documented fallback's underlying fix
    # (plain data alone isn't the issue; the module's absence is), applied
    # without needing to restructure the resolver into non-closure data.
    bytecode = Riptide.MultiNodeTestHelpers.own_module_bytecode(__MODULE__)

    for {_pid, node, _ordinal} <- peers do
      assert {:module, __MODULE__} =
               :erpc.call(node, :code, :load_binary, [
                 __MODULE__,
                 ~c"placement_cluster_test.ex",
                 bytecode
               ])
    end
  end

  # `:ra` must be started as an OTP application on EVERY member before ANY
  # of them attempts to form the cluster — `start_genesis_placement_cluster/1`
  # calls `:ra.start_cluster/2`, which reaches out over RPC to start the
  # *other* members too, not just the local one. Confirmed empirically:
  # interleaving "start :ra, then immediately attempt to form" per node (as
  # a single combined loop) races the still-not-started siblings and fails
  # with `{:error, :system_not_started}` on every remote member the caller
  # gets to before its own turn comes up — surfacing as
  # `{:error, :cluster_not_formed}` from `start_genesis_placement_cluster/1`
  # itself. Splitting into two passes avoids the race.
  #
  # `start_genesis_placement_cluster/1` only starts the *local* `:default`
  # Ra system (via its own private `ensure_system_started/0`) on whichever
  # node calls it — but internally it calls `:ra.start_cluster/2`, which
  # tries to start EVERY member's server, including the ones on the *other*
  # two nodes, over RPC. Confirmed empirically: without this, calling
  # `start_genesis_placement_cluster/1` on each node in turn fails with
  # `{:error, :cluster_not_formed}` every time — `:ra`'s own logs show
  # `{:error, :system_not_started}` for whichever sibling members haven't
  # yet run `start_genesis_placement_cluster/1` themselves (so never
  # started their own local system), which is every sibling except
  # whichever one is on its own turn. Pre-start every node's local
  # `:default` system directly (mirroring `RaCluster`'s own private
  # `ensure_system_started/0`, via its public `system_config/0`) before any
  # node attempts cluster formation, so no member is ever "not started yet"
  # when another member's `:ra.start_cluster/2` call tries to reach it.
  defp bootstrap_ra_on_peers(peers) do
    for {_pid, node, _ordinal} <- peers do
      {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:ra])
    end

    for {_pid, node, _ordinal} <- peers do
      start_ra_system(node)
    end
  end

  defp start_ra_system(node) do
    case :erpc.call(node, :ra_system, :start, [
           :erpc.call(node, Riptide.RaCluster, :system_config, [])
         ]) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  # NEW GOTCHA (found empirically while implementing this test, beyond the
  # brief's own list): `start_genesis_placement_cluster/1`'s moduledoc
  # comment in `ra_cluster.ex` claims it's "safe to call redundantly from
  # multiple ordinals concurrently" because `:ra.start_cluster/2` tolerates
  # `{:error, {:already_started, _pid}}` per member internally — but that
  # only covers a *remote* member that's already running. Calling it a
  # second time on a node whose *own local* member is already up (because
  # an earlier winning call already started every member, this one
  # included, via RPC) hits a local `ra_server_sup` child-start conflict
  # that `:ra.start_cluster/2` does NOT treat as equivalent to success —
  # it reports the whole call as `{:error, :cluster_not_formed}`, same as
  # a genuine failure-to-form. Confirmed real, not a timing fluke: happens
  # identically whether the 3 calls are made sequentially (after the
  # cluster's already fully formed by the first) or concurrently via
  # `Task.async` (racing each other). So at most one of the 3 calls can
  # ever observe `:ok` — the redundant callers observing an error is
  # expected, not proof the cluster failed to form. What actually matters,
  # and what this asserts, is that (a) at least one ordinal's attempt
  # genuinely forms the cluster fresh, and (b) the cluster that results is
  # for real — proven below by successful, replicated assign/lookup calls
  # across all 3 members, not by this step's return values alone.
  defp form_placement_cluster(peers, nodes) do
    results =
      Enum.map(peers, fn {_pid, node, _ordinal} ->
        :erpc.call(node, Riptide.RaCluster.Placement, :start_genesis_placement_cluster, [nodes])
      end)

    assert Enum.all?(results, &(&1 in [:ok, {:error, :cluster_not_formed}]))
    assert Enum.any?(results, &(&1 == :ok))
  end
end
