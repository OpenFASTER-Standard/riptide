defmodule Riptide.Stream.StreamSupervisorTest do
  use ExUnit.Case, async: true

  alias Riptide.Stream.StreamSupervisor

  test "get_or_start/1 starts a new process for an unseen stream id" do
    stream_id = "stream-#{System.unique_integer([:positive])}"

    pid = StreamSupervisor.get_or_start(stream_id)

    assert Process.alive?(pid)
  end

  test "get_or_start/1 returns the same pid for the same stream id" do
    stream_id = "stream-#{System.unique_integer([:positive])}"

    first = StreamSupervisor.get_or_start(stream_id)
    second = StreamSupervisor.get_or_start(stream_id)

    assert first == second
  end

  test "get_or_start/1 isolates state between different streams" do
    stream_a = "stream-#{System.unique_integer([:positive])}"
    stream_b = "stream-#{System.unique_integer([:positive])}"
    StreamSupervisor.get_or_start(stream_a)
    StreamSupervisor.get_or_start(stream_b)

    Riptide.Stream.StreamServer.append(stream_a, Riptide.Event.new(stream_a, RDF.Graph.new()))

    {:ok, events_b} = Riptide.Stream.StreamServer.get_since(stream_b, 0)
    assert events_b == []
  end
end
