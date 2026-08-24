defmodule Riptide.EventTest do
  use ExUnit.Case, async: true

  alias Riptide.Event
  alias Riptide.RDF.Patch

  test "new/3 builds a :replace event carrying a full graph" do
    graph = RDF.Graph.new()
    event = Event.new("s", :replace, graph)

    assert event.operation == :replace
    assert event.payload == graph
    assert event.sequence == nil
  end

  test "new/3 builds a :delete event" do
    event = Event.new("s", :delete, RDF.Graph.new())
    assert event.operation == :delete
  end

  test "new/3 builds a :patch event carrying a Patch" do
    patch = %Patch{additions: [], removals: []}
    event = Event.new("s", :patch, patch)

    assert event.operation == :patch
    assert event.payload == patch
  end

  test "with_sequence/2 assigns a sequence" do
    event = Event.new("s", :replace, RDF.Graph.new()) |> Event.with_sequence(5)
    assert event.sequence == 5
  end

  test "with_sequence/2 rejects non-positive sequences" do
    assert_raise FunctionClauseError, fn ->
      Event.new("s", :replace, RDF.Graph.new()) |> Event.with_sequence(0)
    end
  end

  describe "wire_snapshot?/1 and wire_payload/1" do
    test ":replace is a wire snapshot carrying its full graph" do
      graph = RDF.Graph.new() |> RDF.Graph.add({RDF.iri("s"), RDF.iri("p"), RDF.iri("o")})
      event = Event.new("s", :replace, graph)

      assert Event.wire_snapshot?(event) == true
      assert Event.wire_payload(event) == graph
    end

    test ":delete is a wire snapshot carrying an empty graph" do
      event = Event.new("s", :delete, RDF.Graph.new())

      assert Event.wire_snapshot?(event) == true
      assert RDF.Graph.triples(Event.wire_payload(event)) == []
    end

    test ":patch is not a wire snapshot; wire payload is additions-only" do
      triple = {RDF.iri("s"), RDF.iri("p"), RDF.iri("o")}
      patch = %Patch{additions: [triple], removals: [{RDF.iri("s"), RDF.iri("p"), RDF.iri("o2")}]}
      event = Event.new("s", :patch, patch)

      assert Event.wire_snapshot?(event) == false
      assert RDF.Graph.triples(Event.wire_payload(event)) == [triple]
    end
  end

  describe "encode/1 and decode/1" do
    test "round-trips a :replace event" do
      graph = RDF.Graph.new() |> RDF.Graph.add({RDF.iri("s"), RDF.iri("p"), RDF.iri("o")})
      event = Event.new("stream-1", :replace, graph)

      assert Event.decode(Event.encode(event)) == event
    end

    test "round-trips a :delete event" do
      event = Event.new("stream-1", :delete, RDF.Graph.new())

      assert Event.decode(Event.encode(event)) == event
    end

    test "round-trips a :patch event, including the nested Patch" do
      patch = %Patch{additions: [{RDF.iri("s"), RDF.iri("p"), RDF.iri("o")}], removals: []}
      event = Event.new("stream-1", :patch, patch)

      assert Event.decode(Event.encode(event)) == event
    end

    test "round-trips a stamped event's sequence number" do
      event = Event.new("stream-1", :replace, RDF.Graph.new()) |> Event.with_sequence(7)

      assert Event.decode(Event.encode(event)) == event
    end

    test "encode/1 produces a version-tagged map" do
      event = Event.new("stream-1", :replace, RDF.Graph.new())
      wire = Event.encode(event)

      assert wire.v == 1
      assert wire.operation == :replace
      assert wire.stream_id == "stream-1"
    end

    test "decode/1 raises a clear error on an unrecognized version" do
      assert_raise RuntimeError, ~r/Unknown Event wire version: 99/, fn ->
        Event.decode(%{
          v: 99,
          sequence: nil,
          stream_id: "s",
          operation: :replace,
          payload: RDF.Graph.new()
        })
      end
    end
  end
end
