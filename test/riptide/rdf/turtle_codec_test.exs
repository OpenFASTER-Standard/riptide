defmodule Riptide.RDF.TurtleCodecTest do
  use ExUnit.Case, async: true

  alias Riptide.RDF.TurtleCodec

  test "decode/1 parses valid Turtle into an RDF.Graph" do
    turtle = """
    @prefix ex: <https://pod.example/> .
    ex:alice ex:name "Alice" .
    """

    assert {:ok, graph} = TurtleCodec.decode(turtle)

    assert RDF.Graph.include?(
             graph,
             {RDF.iri("https://pod.example/alice"), RDF.iri("https://pod.example/name"),
              RDF.literal("Alice")}
           )
  end

  test "decode/1 returns an error for invalid Turtle" do
    assert {:error, _reason} = TurtleCodec.decode("this is not turtle {{{")
  end

  test "encode/1 round-trips a graph back to parseable Turtle" do
    {:ok, graph} =
      TurtleCodec.decode("""
      @prefix ex: <https://pod.example/> .
      ex:alice ex:name "Alice" .
      """)

    assert {:ok, turtle} = TurtleCodec.encode(graph)
    assert {:ok, round_tripped} = TurtleCodec.decode(turtle)
    assert RDF.Graph.equal?(graph, round_tripped)
  end
end
