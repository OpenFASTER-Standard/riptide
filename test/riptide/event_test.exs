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
end
