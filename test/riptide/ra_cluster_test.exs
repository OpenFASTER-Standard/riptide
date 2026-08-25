defmodule Riptide.RaClusterTest do
  use ExUnit.Case, async: true

  alias Riptide.Event
  alias Riptide.RaCluster
  alias Riptide.Stream.RaMachine
  alias Riptide.Test.EchoMachine

  setup do
    stream_id = "ra-spike-" <> Uniq.UUID.uuid4()
    on_exit(fn -> RaCluster.force_delete(stream_id) end)
    %{stream_id: stream_id}
  end

  test "data survives stopping and restarting the Ra server", %{stream_id: stream_id} do
    machine = {:module, EchoMachine, %{}}
    server_id = RaCluster.start_or_restart(stream_id, machine)

    assert RaCluster.process_command(server_id, {:add, "a"}) == ["a"]
    assert RaCluster.process_command(server_id, {:add, "b"}) == ["b", "a"]
    assert RaCluster.local_query(server_id, & &1) == ["b", "a"]

    {name, _node} = server_id
    pid = Process.whereis(name)
    assert is_pid(pid)
    Process.exit(pid, :kill)
    refute Process.alive?(pid)

    restarted_id = RaCluster.start_or_restart(stream_id, machine)
    assert restarted_id == server_id

    # Assert durability with a linearizable read. `local_query` reads
    # possibly-stale local state and, right after a restart, can race the
    # recovered server's asynchronous log re-application (see
    # `RaCluster.consistent_query/2` and the crash-recovery test in
    # `StreamServerTest`). The data is durable on disk the whole time; the
    # consistent read just observes the fully-recovered state deterministically.
    assert RaCluster.consistent_query(restarted_id, & &1) == ["b", "a"]
  end

  test "Ra truncates its on-disk log once retention trimming releases a cursor" do
    # Proves the release_cursor effect RaMachine emits on retention trimming
    # actually makes Ra snapshot and truncate its raft log (design doc §3.2 /
    # final-fix-wave Important #3), rather than the log growing without bound.
    #
    # We start a real Ra cluster directly (not via StreamServer) so we can pin
    # `min_snapshot_interval` small — Ra's default is 4096 entries, which would
    # need thousands of appends to trigger. RaMachine is unchanged; only the
    # Ra-side snapshot cadence differs from production.
    stream_id = "compaction-" <> Uniq.UUID.uuid4()
    uid = RaCluster.uid_for(stream_id)
    name = String.to_atom(uid)
    server_id = {name, node()}
    on_exit(fn -> :ra.force_delete_server(:default, server_id) end)

    # Idempotent: another test may already have started the default system.
    # Must build the exact same config `RaCluster.ensure_system_started/0`
    # does — via the shared `RaCluster.system_config/0` — rather than calling
    # `:ra_system.start_default/0` (which uses the OLD node()-derived
    # directory) or hand-rolling an equivalent-looking config here. See
    # `RaCluster.system_config/0`'s doc for why even a merely-equivalent
    # config is unsafe: this was a confirmed cross-test-file flaky failure in
    # `ra_cluster_cold_restart_test.exs` before all call sites shared this one
    # function.
    config_override = RaCluster.system_config()

    case :ra_system.start(config_override) do
      {:ok, _} -> :ok
      {:ok, _, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    config = %{
      id: server_id,
      uid: uid,
      cluster_name: uid <> "_cluster",
      log_init_args: %{uid: uid, min_snapshot_interval: 8},
      initial_members: [server_id],
      machine: {:module, RaMachine, %{retention: 3}}
    }

    {:ok, [^server_id], []} = :ra.start_cluster(:default, [config])

    # Enough appends that, with retention 3, trimming fires repeatedly and the
    # accumulated log comfortably exceeds min_snapshot_interval (8).
    for _ <- 1..50 do
      {:ok, %Event{}, _leader} =
        :ra.process_command(
          server_id,
          {:append, Event.encode(Event.new(stream_id, :replace, RDF.Graph.new()))}
        )
    end

    # Snapshotting is asynchronous, so poll (bounded) for it to land. A
    # snapshot_index > 0 means Ra took a snapshot and truncated its log up to
    # that index — i.e. the persisted log is bounded, not growing forever.
    snapshot_index = await_snapshot(server_id, 40)
    assert snapshot_index > 0

    # And the retained window is still correct after compaction: only the last
    # `retention` (3) events remain queryable; older sequences read as a gap.
    assert {:gap, _} = RaCluster.consistent_query(server_id, &RaMachine.get_since(&1, 0))

    assert {:ok, [%{sequence: 48}, %{sequence: 49}, %{sequence: 50}]} =
             RaCluster.consistent_query(server_id, &RaMachine.get_since(&1, 47))
  end

  defp await_snapshot(_server_id, 0), do: 0

  defp await_snapshot(server_id, attempts) do
    idx = Map.get(:ra.key_metrics(server_id), :snapshot_index, 0)

    if idx > 0 do
      idx
    else
      Process.sleep(25)
      await_snapshot(server_id, attempts - 1)
    end
  end

  describe "placement_ordinals/0 and placement_server_id/1,2" do
    test "placement_ordinals/0 returns exactly the 3 fixed ordinals" do
      assert RaCluster.placement_ordinals() == ["riptide-0", "riptide-1", "riptide-2"]
    end

    test "placement_server_id/2 combines the placement cluster name with the resolver's result" do
      resolve_fun = fn "riptide-1" -> :"riptide@10.0.0.5" end

      assert RaCluster.placement_server_id("riptide-1", resolve_fun) ==
               {:riptide_placement, :"riptide@10.0.0.5"}
    end
  end

  describe "ensure_placement_cluster_started/2" do
    test "retries the attempt function until it succeeds" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      attempt_fun = fn ->
        count = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
        if count < 2, do: {:error, :cluster_not_formed}, else: :ok
      end

      assert RaCluster.ensure_placement_cluster_started(1, attempt_fun) == :ok
      assert Agent.get(counter, & &1) == 3
    end

    test "succeeds immediately if the first attempt succeeds" do
      attempt_fun = fn -> :ok end
      assert RaCluster.ensure_placement_cluster_started(1, attempt_fun) == :ok
    end
  end

  describe "placement_leader?/0" do
    test "returns true for this node's own already-running (collapsed) placement cluster" do
      assert RaCluster.placement_leader?()
    end
  end

  describe "attempt_start_placement_cluster/1" do
    test "a resolver that raises (e.g. default_ordinal_resolver/1 on an unresolvable DNS name) yields a retriable error instead of an uncaught exception" do
      # Mirrors exactly how `default_ordinal_resolver/1` fails for real: a
      # hard match against `:inet.gethostbyname/1`'s result raises `MatchError`
      # when a sibling ordinal's DNS record doesn't exist yet (e.g. during
      # normal StatefulSet startup, before all pods are up).
      resolve_fun = fn
        "riptide-1" -> raise MatchError, term: {:error, :nxdomain}
        ordinal -> String.to_atom("riptide@#{ordinal}")
      end

      assert RaCluster.attempt_start_placement_cluster(resolve_fun) ==
               {:error, :cluster_not_formed}
    end

    test "a redundant call after the local member is already fully started returns :ok, not {:error, :cluster_not_formed}" do
      # Reproduces the confirmed bug (found by a real multi-node `:peer`-based
      # integration test, see `placement_cluster_test.exs`) with a real
      # `:ra.start_cluster/2` call, no mocking of `:ra` itself — `:ra` doesn't
      # require its members to be on distinct physical (or even distinct
      # Erlang) nodes to exercise this exact bug, since the bug is entirely
      # about `:ra.start_cluster/3`'s own per-call bookkeeping (its `Started`
      # list only tracks servers *this call* newly started, not servers that
      # are merely alive — confirmed directly against
      # `deps/ra/src/ra.erl:427-465`). A resolver that maps every one of the 3
      # fixed ordinals to this same test node collapses all 3 configs to the
      # same real `{:riptide_placement, node()}` id, so the *first* call
      # genuinely starts one real local member (the other two configs lose
      # the race for the same id/uid and are reported as not-started, which
      # is fine — `:ra.start_cluster/2` only needs at least one real `ok`
      # start to succeed) and returns `:ok`. The *second*, redundant call
      # replays the exact real-world failure: every one of its (here, 3
      # identical) per-member `:ra.start_server/2` attempts now hits the
      # already-running member and returns `{:error, {:already_started,
      # pid}}`, so `:ra`'s own `Started` list is empty and it reports
      # `{:error, :cluster_not_formed}` for the whole call — even though the
      # local member is completely healthy. Without the fix in
      # `attempt_start_placement_cluster/1`, this second call would surface
      # that raw `:ra` error instead of self-correcting.
      resolve_fun = fn _ordinal -> node() end

      # NEW GOTCHA (found empirically during the phase-3c-ii side-fix that
      # gave test_helper.exs a stable node() identity): deliberately no
      # `on_exit(fn -> :ra.force_delete_server(:default, {:riptide_placement,
      # node()}) end)` here, even though every other test in this file that
      # starts a throwaway Ra server cleans it up that way. `{:riptide_placement,
      # node()}` is NOT a throwaway server this test owns — it's the exact
      # same address (fixed cluster name + this node's own, now-stable,
      # identity) as the ONE shared, suite-wide placement cluster
      # `test_helper.exs` bootstraps once before any test runs, which every
      # other test touching `Riptide.Placement`/`Riptide.Stream.Placement`
      # depends on for the rest of the `mix test` process's lifetime. Before
      # test_helper.exs's node()-identity fix, this collided with `:nonode@nohost`
      # only when this test happened to run before any `:peer`-based file
      # flipped node() — easy to miss since the resulting failure looked
      # identical to that other, more consistently-triggered bug. Now that
      # node() is stable for the whole suite, this test always collides with
      # the shared instance, so force-deleting it here would silently take
      # down every later test that needs it — confirmed empirically: with the
      # force_delete restored, `mix test test/riptide/ra_cluster_test.exs
      # test/riptide/stream/stream_server_test.exs --seed 0` fails a later,
      # unrelated `StreamServerTest` test with "Ra consistent query failed for
      # {:riptide_placement, :"test_helper_origin@127.0.0.1"}: :noproc" —
      # removing just this on_exit makes that same run pass. This test's own
      # assertions never depend on the server being gone afterward, only on
      # it being alive and correctly responding while the test runs, so
      # leaving the shared instance alone costs this test nothing.
      assert RaCluster.attempt_start_placement_cluster(resolve_fun) == :ok

      pid = Process.whereis(:riptide_placement)
      assert is_pid(pid)
      assert Process.alive?(pid)

      assert RaCluster.attempt_start_placement_cluster(resolve_fun) == :ok
    end
  end

  test "server_id/1 never turns an arbitrary stream_id into an unbounded atom", %{
    stream_id: stream_id
  } do
    {name, _node} = RaCluster.server_id(stream_id)
    assert is_atom(name)
    assert String.starts_with?(Atom.to_string(name), "riptide_")
    assert RaCluster.server_id(stream_id) == RaCluster.server_id(stream_id)
  end

  test "the started Ra system's data_dir and wal_data_dir are HOSTNAME-derived, not node()-derived",
       %{stream_id: stream_id} do
    machine = {:module, EchoMachine, %{}}
    RaCluster.start_or_restart(stream_id, machine)

    config = :ra_system.fetch(:default)
    expected = RaCluster.data_dir()

    assert config.data_dir == expected
    assert config.wal_data_dir == expected
  end

  describe "start_or_join_replicated/3" do
    test "forms a real cluster and returns one server_id per member_node" do
      uid = "sojr-" <> Uniq.UUID.uuid4()
      name = String.to_atom(uid)
      on_exit(fn -> :ra.force_delete_server(:default, {name, node()}) end)

      # A single real node repeated 3x collapses to one real member, exactly
      # the same "collapsed" pattern Phase 3c-i's own redundant-call
      # regression test already uses to exercise multi-member config-building
      # without needing real distinct nodes — real distinctness is proven
      # separately by the :peer-based integration test (Task 6).
      assert {:ok, server_ids} =
               RaCluster.start_or_join_replicated(
                 uid,
                 [node(), node(), node()],
                 {:module, EchoMachine, %{}}
               )

      assert length(server_ids) == 3
      assert Enum.uniq(server_ids) == [{name, node()}]

      pid = Process.whereis(name)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "self-corrects on a redundant call once the local member is already running" do
      uid = "sojr-redundant-" <> Uniq.UUID.uuid4()
      name = String.to_atom(uid)
      on_exit(fn -> :ra.force_delete_server(:default, {name, node()}) end)
      machine = {:module, EchoMachine, %{}}

      assert {:ok, first_ids} = RaCluster.start_or_join_replicated(uid, [node(), node()], machine)

      assert {:ok, second_ids} =
               RaCluster.start_or_join_replicated(uid, [node(), node()], machine)

      assert first_ids == second_ids
    end

    test "returns {:error, :cluster_not_formed} when this node isn't among member_nodes and they're unreachable" do
      uid = "sojr-unreachable-" <> Uniq.UUID.uuid4()
      machine = {:module, EchoMachine, %{}}

      assert RaCluster.start_or_join_replicated(uid, [:nonexistent@nowhere], machine) ==
               {:error, :cluster_not_formed}
    end
  end

  describe "replace_member/5" do
    test "replaces a member with a fresh one, collapsed onto a single real node" do
      uid = "replace-member-" <> Uniq.UUID.uuid4()
      name = String.to_atom(uid)
      machine = {:module, EchoMachine, %{}}
      on_exit(fn -> :ra.force_delete_server(:default, {name, node()}) end)

      assert {:ok, _server_ids} =
               RaCluster.start_or_join_replicated(uid, [node()], machine)

      # A single real node standing in for both "the dead node" and "the
      # replacement" is nonsensical for a real repair, but proves the
      # function's own call sequence (add_member, start_server, remove_member)
      # doesn't blow up against a real, already-running single-member
      # cluster — real distinctness is proven separately by Step 5's
      # `:peer`-based test.
      assert RaCluster.replace_member(uid, [node()], :"dead@nowhere", node(), machine) ==
               {:error, :already_member}
    end
  end
end
