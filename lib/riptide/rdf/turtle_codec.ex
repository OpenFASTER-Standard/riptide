defmodule Riptide.RDF.TurtleCodec do
  @moduledoc """
  Thin wrapper around RDF.Turtle so the rest of Riptide depends on this
  module's stable {:ok, _} | {:error, _} contract rather than the rdf
  library's own (bang vs non-bang) function-naming conventions directly.
  """

  @spec decode(String.t()) :: {:ok, RDF.Graph.t()} | {:error, term()}
  def decode(turtle_string) when is_binary(turtle_string) do
    case RDF.Turtle.read_string(turtle_string) do
      {:ok, graph} -> {:ok, graph}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec encode(RDF.Graph.t()) :: {:ok, String.t()} | {:error, term()}
  def encode(%RDF.Graph{} = graph) do
    case RDF.Turtle.write_string(graph) do
      {:ok, turtle} -> {:ok, turtle}
      {:error, reason} -> {:error, reason}
    end
  end
end
