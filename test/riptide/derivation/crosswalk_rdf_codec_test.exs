defmodule Riptide.Derivation.CrosswalkRDFCodecTest do
  use ExUnit.Case, async: true

  alias Riptide.Derivation.{Crosswalk, CrosswalkRDFCodec}

  defp rel(name), do: RDF.iri("urn:riptide:relation:" <> name)

  test "a Crosswalk round-trips through to_rdf/1 and from_rdf/2" do
    crosswalk = %Crosswalk{
      subject_predicate: rel("pendingDeploy"),
      object_predicate: rel("deploymentQueued"),
      match_type: :exact_match
    }

    {node, graph} = CrosswalkRDFCodec.to_rdf(crosswalk)
    assert CrosswalkRDFCodec.from_rdf(node, graph) == crosswalk
  end

  test "each SSSOM match_type round-trips correctly" do
    for match_type <- [:exact_match, :close_match, :broad_match, :narrow_match, :related_match] do
      crosswalk = %Crosswalk{
        subject_predicate: rel("a"),
        object_predicate: rel("b"),
        match_type: match_type
      }

      {node, graph} = CrosswalkRDFCodec.to_rdf(crosswalk)
      assert CrosswalkRDFCodec.from_rdf(node, graph).match_type == match_type
    end
  end
end
