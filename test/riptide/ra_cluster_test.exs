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
    case :ra_system.start_default() do
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

  test "server_id/1 never turns an arbitrary stream_id into an unbounded atom", %{
    stream_id: stream_id
  } do
    {name, _node} = RaCluster.server_id(stream_id)
    assert is_atom(name)
    assert String.starts_with?(Atom.to_string(name), "riptide_")
    assert RaCluster.server_id(stream_id) == RaCluster.server_id(stream_id)
  end
end
