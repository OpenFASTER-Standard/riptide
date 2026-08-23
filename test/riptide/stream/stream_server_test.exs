defmodule Riptide.Stream.StreamServerTest do
  use ExUnit.Case, async: true

  alias Riptide.Event
  alias Riptide.Stream.StreamServer

  setup do
    stream_id = "stream-#{System.unique_integer([:positive])}"
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id) end)
    {:ok, _pid} = StreamServer.start_link(stream_id)
    {:ok, stream_id: stream_id}
  end

  test "append/2 assigns sequence numbers starting at 1", %{stream_id: stream_id} do
    event = Event.new(stream_id, RDF.Graph.new())

    appended = StreamServer.append(stream_id, event)

    assert appended.sequence == 1
  end

  test "append/2 assigns strictly increasing sequence numbers", %{stream_id: stream_id} do
    first = StreamServer.append(stream_id, Event.new(stream_id, RDF.Graph.new()))
    second = StreamServer.append(stream_id, Event.new(stream_id, RDF.Graph.new()))

    assert first.sequence == 1
    assert second.sequence == 2
  end

  test "get_since/2 with nil cursor returns no historical events (live-tail semantics)", %{
    stream_id: stream_id
  } do
    StreamServer.append(stream_id, Event.new(stream_id, RDF.Graph.new()))

    assert {:ok, []} = StreamServer.get_since(stream_id, nil)
  end

  test "get_since/2 returns events after the given cursor, in order", %{stream_id: stream_id} do
    StreamServer.append(stream_id, Event.new(stream_id, RDF.Graph.new()))
    StreamServer.append(stream_id, Event.new(stream_id, RDF.Graph.new()))
    StreamServer.append(stream_id, Event.new(stream_id, RDF.Graph.new()))

    {:ok, events} = StreamServer.get_since(stream_id, 1)

    assert Enum.map(events, & &1.sequence) == [2, 3]
  end

  test "a stream started with a retention limit trims old events", %{stream_id: _unused} do
    stream_id = "stream-retention-#{System.unique_integer([:positive])}"
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id) end)
    {:ok, _pid} = StreamServer.start_link({stream_id, retention: 2})

    StreamServer.append(stream_id, Event.new(stream_id, RDF.Graph.new()))
    StreamServer.append(stream_id, Event.new(stream_id, RDF.Graph.new()))
    StreamServer.append(stream_id, Event.new(stream_id, RDF.Graph.new()))

    assert {:gap, 2} = StreamServer.get_since(stream_id, 0)
    assert {:ok, [%{sequence: 3}]} = StreamServer.get_since(stream_id, 2)
  end

  test "events and sequence numbers survive killing and restarting the Ra process" do
    stream_id = "stream-" <> Uniq.UUID.uuid4()
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id) end)

    {:ok, pid} = StreamServer.start_link(stream_id)
    StreamServer.append(stream_id, Event.new(stream_id, RDF.Graph.new()))
    StreamServer.append(stream_id, Event.new(stream_id, RDF.Graph.new()))

    Process.exit(pid, :kill)
    refute Process.alive?(pid)

    {:ok, _pid} = StreamServer.start_link(stream_id)

    assert {:ok, [%{sequence: 1}, %{sequence: 2}]} = StreamServer.get_since(stream_id, 0)

    third = StreamServer.append(stream_id, Event.new(stream_id, RDF.Graph.new()))
    assert third.sequence == 3
  end
end
