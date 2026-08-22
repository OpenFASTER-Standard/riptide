defmodule Riptide.EventTest do
  use ExUnit.Case, async: true

  test "new/3 builds an event with sequence unset" do
    graph = RDF.Graph.new()
    event = Riptide.Event.new("https://pod.example/alice/profile", graph)

    assert event.stream_id == "https://pod.example/alice/profile"
    assert event.payload == graph
    assert event.is_snapshot? == false
    assert event.sequence == nil
  end

  test "new/3 accepts an explicit is_snapshot? flag" do
    event = Riptide.Event.new("stream-1", RDF.Graph.new(), true)

    assert event.is_snapshot? == true
  end

  test "with_sequence/2 assigns a sequence number" do
    event = Riptide.Event.new("stream-1", RDF.Graph.new())
    updated = Riptide.Event.with_sequence(event, 42)

    assert updated.sequence == 42
  end

  test "with_sequence/2 rejects non-positive integers" do
    event = Riptide.Event.new("stream-1", RDF.Graph.new())

    assert_raise FunctionClauseError, fn ->
      Riptide.Event.with_sequence(event, 0)
    end
  end
end
