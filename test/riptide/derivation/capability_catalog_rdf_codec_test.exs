defmodule Riptide.Derivation.CapabilityCatalogRDFCodecTest do
  use ExUnit.Case, async: true

  alias Riptide.Derivation.{CapabilityCatalogEntry, CapabilityCatalogRDFCodec}

  defp sample_entry(overrides) do
    Map.merge(
      %CapabilityCatalogEntry{
        name: RDF.iri("urn:riptide:capability:restartPaymentsService"),
        kind: :effect,
        component_hash: String.duplicate("a", 64),
        function: "restart",
        fuel_limit: 10_000_000,
        timeout_ms: 5_000,
        memory_limits: %{
          max_memory_size: nil,
          max_table_elements: nil,
          max_instances: nil,
          max_tables: nil
        }
      },
      overrides
    )
  end

  test "to_rdf/1 + from_rdf/2 round-trips every field, including a fully-populated memory_limits" do
    entry =
      sample_entry(%{
        memory_limits: %{
          max_memory_size: 67_108_864,
          max_table_elements: 1_000,
          max_instances: 4,
          max_tables: 2
        }
      })

    {node, graph} = CapabilityCatalogRDFCodec.to_rdf(entry)

    assert CapabilityCatalogRDFCodec.from_rdf(node, graph) == entry
  end

  test "round-trips :observe kind and a fully-nil memory_limits" do
    entry = sample_entry(%{kind: :observe})

    {node, graph} = CapabilityCatalogRDFCodec.to_rdf(entry)

    assert CapabilityCatalogRDFCodec.from_rdf(node, graph) == entry
  end
end
