defmodule Riptide.RDF.Patch do
  @moduledoc """
  An RDF Patch: an explicit add/remove delta against a graph, applied as
  removals-then-additions so a triple can be replaced in one patch.
  """

  @enforce_keys [:additions, :removals]
  defstruct [:additions, :removals]

  @type triple :: {RDF.IRI.t(), RDF.IRI.t(), RDF.Term.t()}
  @type t :: %__MODULE__{additions: [triple()], removals: [triple()]}

  @spec apply(RDF.Graph.t(), t()) :: RDF.Graph.t()
  def apply(%RDF.Graph{} = graph, %__MODULE__{additions: additions, removals: removals}) do
    graph
    |> RDF.Graph.delete(removals)
    |> RDF.Graph.add(additions)
  end

  @spec encode(t()) :: map()
  def encode(%__MODULE__{additions: additions, removals: removals}) do
    %{v: 1, additions: additions, removals: removals}
  end

  @spec decode(map()) :: t()
  def decode(%{v: 1, additions: additions, removals: removals}) do
    %__MODULE__{additions: additions, removals: removals}
  end

  def decode(%{v: unknown}), do: raise("Unknown Patch wire version: #{inspect(unknown)}")
end
