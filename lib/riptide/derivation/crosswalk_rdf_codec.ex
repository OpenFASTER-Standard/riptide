defmodule Riptide.Derivation.CrosswalkRDFCodec do
  @moduledoc """
  Reifies a `Riptide.Derivation.Crosswalk` as RDF triples and reads it
  back, following the exact same reification style
  `Riptide.Derivation.RuleRDFCodec` already established.
  """

  alias Riptide.Derivation.Crosswalk

  @rdf_type RDF.iri("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
  @riptide_crosswalk RDF.iri("urn:riptide:vocab:Crosswalk")
  @riptide_subject_predicate RDF.iri("urn:riptide:vocab:subjectPredicate")
  @riptide_object_predicate RDF.iri("urn:riptide:vocab:objectPredicate")
  @riptide_match_type RDF.iri("urn:riptide:vocab:matchType")

  @spec to_rdf(Crosswalk.t()) :: {RDF.BlankNode.t(), RDF.Graph.t()}
  def to_rdf(%Crosswalk{} = crosswalk) do
    node = RDF.BlankNode.new()

    graph =
      RDF.Graph.new()
      |> RDF.Graph.add({node, @rdf_type, @riptide_crosswalk})
      |> RDF.Graph.add({node, @riptide_subject_predicate, crosswalk.subject_predicate})
      |> RDF.Graph.add({node, @riptide_object_predicate, crosswalk.object_predicate})
      |> RDF.Graph.add(
        {node, @riptide_match_type, RDF.literal(encode_match_type(crosswalk.match_type))}
      )

    {node, graph}
  end

  # Explicit case matching, not Atom.to_string/String.to_existing_atom: the
  # 5 match-type atoms otherwise appear nowhere as literals in `lib/` (only
  # in `Crosswalk`'s own `@type`, which typespecs don't reliably intern at
  # runtime) — a process that never happens to load a test file mentioning
  # them would hit `String.to_existing_atom/1: not an already existing atom`
  # on the very first decode. Writing the atoms as literals directly in this
  # module's own compiled code guarantees they exist whenever this module
  # does.
  defp encode_match_type(:exact_match), do: "exact_match"
  defp encode_match_type(:close_match), do: "close_match"
  defp encode_match_type(:broad_match), do: "broad_match"
  defp encode_match_type(:narrow_match), do: "narrow_match"
  defp encode_match_type(:related_match), do: "related_match"

  defp decode_match_type("exact_match"), do: :exact_match
  defp decode_match_type("close_match"), do: :close_match
  defp decode_match_type("broad_match"), do: :broad_match
  defp decode_match_type("narrow_match"), do: :narrow_match
  defp decode_match_type("related_match"), do: :related_match

  @spec from_rdf(RDF.Resource.t(), RDF.Graph.t()) :: Crosswalk.t()
  def from_rdf(node, graph) do
    description = RDF.Graph.get(graph, node)

    match_type =
      description
      |> RDF.Description.first(@riptide_match_type)
      |> RDF.Literal.value()
      |> decode_match_type()

    %Crosswalk{
      subject_predicate: RDF.Description.first(description, @riptide_subject_predicate),
      object_predicate: RDF.Description.first(description, @riptide_object_predicate),
      match_type: match_type
    }
  end
end
