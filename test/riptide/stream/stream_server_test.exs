defmodule Riptide.Stream.StreamServerTest do
  use ExUnit.Case, async: true

  alias Riptide.Event
  alias Riptide.RaCluster
  alias Riptide.Stream.{RaMachine, StreamServer}

  setup do
    stream_id = "stream-#{System.unique_integer([:positive])}"
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id) end)
    {:ok, _pid} = StreamServer.start_link(stream_id)
    {:ok, stream_id: stream_id}
  end

  test "append/2 assigns sequence numbers starting at 1", %{stream_id: stream_id} do
    event = Event.new(stream_id, :replace, RDF.Graph.new())

    appended = StreamServer.append(stream_id, event)

    assert appended.sequence == 1
  end

  test "append/2 assigns strictly increasing sequence numbers", %{stream_id: stream_id} do
    first = StreamServer.append(stream_id, Event.new(stream_id, :replace, RDF.Graph.new()))
    second = StreamServer.append(stream_id, Event.new(stream_id, :replace, RDF.Graph.new()))

    assert first.sequence == 1
    assert second.sequence == 2
  end

  test "get_since/2 with nil cursor returns no historical events (live-tail semantics)", %{
    stream_id: stream_id
  } do
    StreamServer.append(stream_id, Event.new(stream_id, :replace, RDF.Graph.new()))

    assert {:ok, []} = StreamServer.get_since(stream_id, nil)
  end

  test "get_since/2 returns events after the given cursor, in order", %{stream_id: stream_id} do
    StreamServer.append(stream_id, Event.new(stream_id, :replace, RDF.Graph.new()))
    StreamServer.append(stream_id, Event.new(stream_id, :replace, RDF.Graph.new()))
    StreamServer.append(stream_id, Event.new(stream_id, :replace, RDF.Graph.new()))

    {:ok, events} = StreamServer.get_since(stream_id, 1)

    assert Enum.map(events, & &1.sequence) == [2, 3]
  end

  test "a stream started with a retention limit trims old events", %{stream_id: _unused} do
    stream_id = "stream-retention-#{System.unique_integer([:positive])}"
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id) end)
    {:ok, _pid} = StreamServer.start_link({stream_id, retention: 2})

    StreamServer.append(stream_id, Event.new(stream_id, :replace, RDF.Graph.new()))
    StreamServer.append(stream_id, Event.new(stream_id, :replace, RDF.Graph.new()))
    StreamServer.append(stream_id, Event.new(stream_id, :replace, RDF.Graph.new()))

    assert {:gap, 2} = StreamServer.get_since(stream_id, 0)
    assert {:ok, [%{sequence: 3}]} = StreamServer.get_since(stream_id, 2)
  end

  test "events and sequence numbers survive killing and restarting the Ra process" do
    stream_id = "stream-" <> Uniq.UUID.uuid4()
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id) end)

    {:ok, pid} = StreamServer.start_link(stream_id)
    StreamServer.append(stream_id, Event.new(stream_id, :replace, RDF.Graph.new()))
    StreamServer.append(stream_id, Event.new(stream_id, :replace, RDF.Graph.new()))

    Process.exit(pid, :kill)
    refute Process.alive?(pid)

    {:ok, _pid} = StreamServer.start_link(stream_id)

    # What this test proves: the two acknowledged appends were durably
    # committed to Ra's on-disk WAL (fsync happens as part of the commit path,
    # *before* the append is acknowledged — verified in the final-fix-wave
    # investigation report) and survive the Ra server process being killed.
    #
    # It deliberately asserts durability via a linearizable `consistent_query`,
    # NOT via `StreamServer.get_since/2`. `get_since/2` uses `:ra.local_query`,
    # a fast but *possibly stale* read of the local server's already-applied
    # state. Immediately after a restart the recovered server has its full
    # durable log on disk but re-applies it asynchronously, so for a few
    # milliseconds a `local_query` can observe a state caught up to only the
    # first of the two committed entries. That is a read-freshness window, not
    # data loss — the second event is on disk and committed the whole time.
    # Under full-suite scheduler contention that window widened enough that the
    # original immediate-`local_query` assertion here flaked ~1-in-12 runs
    # (right side `{:ok, [%{sequence: 1}]}`, never empty, never a gap). A
    # `consistent_query` only answers after the server has applied everything
    # committed as of the query, so it deterministically observes the fully
    # recovered log.
    server_id = RaCluster.server_id(stream_id)

    assert {:ok, [%{sequence: 1}, %{sequence: 2}]} =
             RaCluster.consistent_query(server_id, &RaMachine.get_since(&1, 0))

    # The consistent read above forced the server fully caught up, so the
    # ordinary local_query read path now deterministically sees both events too.
    assert {:ok, [%{sequence: 1}, %{sequence: 2}]} = StreamServer.get_since(stream_id, 0)

    third = StreamServer.append(stream_id, Event.new(stream_id, :replace, RDF.Graph.new()))
    assert third.sequence == 3
  end
end
