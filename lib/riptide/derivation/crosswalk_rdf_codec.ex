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
        {node, @riptide_match_type, RDF.literal(Atom.to_string(crosswalk.match_type))}
      )

    {node, graph}
  end

  @spec from_rdf(RDF.Resource.t(), RDF.Graph.t()) :: Crosswalk.t()
  def from_rdf(node, graph) do
    description = RDF.Graph.get(graph, node)

    # Safe: the 5 SSSOM match-type strings are the only values `to_rdf/1`
    # ever writes, and all 5 atoms already exist in the atom table from
    # this module's own `@type match_type` usage — never derived from
    # untrusted input (mirrors PendingReview.from_rdf/2's identical
    # `String.to_existing_atom/1` safety argument).
    match_type =
      description
      |> RDF.Description.first(@riptide_match_type)
      |> RDF.Literal.value()
      |> String.to_existing_atom()

    %Crosswalk{
      subject_predicate: RDF.Description.first(description, @riptide_subject_predicate),
      object_predicate: RDF.Description.first(description, @riptide_object_predicate),
      match_type: match_type
    }
  end
end
