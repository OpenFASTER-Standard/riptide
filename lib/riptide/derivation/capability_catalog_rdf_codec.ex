defmodule Riptide.Derivation.CapabilityCatalogRDFCodec do
  @moduledoc """
  Reifies a `Riptide.Derivation.CapabilityCatalogEntry` as RDF triples and
  reads it back, following the exact same reification style
  `Riptide.Derivation.CrosswalkRDFCodec` already established.
  """

  alias Riptide.Derivation.CapabilityCatalogEntry

  @rdf_type RDF.iri("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
  @riptide_capability_catalog_entry RDF.iri("urn:riptide:vocab:CapabilityCatalogEntry")
  @riptide_name RDF.iri("urn:riptide:vocab:name")
  @riptide_capability_kind RDF.iri("urn:riptide:vocab:capabilityKind")
  @riptide_component_hash RDF.iri("urn:riptide:vocab:componentHash")
  @riptide_capability_function RDF.iri("urn:riptide:vocab:capabilityFunction")
  @riptide_fuel_limit RDF.iri("urn:riptide:vocab:fuelLimit")
  @riptide_timeout_ms RDF.iri("urn:riptide:vocab:timeoutMs")
  @riptide_memory_limits RDF.iri("urn:riptide:vocab:memoryLimits")
  @riptide_max_memory_size RDF.iri("urn:riptide:vocab:maxMemorySize")
  @riptide_max_table_elements RDF.iri("urn:riptide:vocab:maxTableElements")
  @riptide_max_instances RDF.iri("urn:riptide:vocab:maxInstances")
  @riptide_max_tables RDF.iri("urn:riptide:vocab:maxTables")

  @spec to_rdf(CapabilityCatalogEntry.t()) :: {RDF.BlankNode.t(), RDF.Graph.t()}
  def to_rdf(%CapabilityCatalogEntry{} = entry) do
    node = RDF.BlankNode.new()
    {limits_node, limits_graph} = encode_memory_limits(entry.memory_limits)

    graph =
      RDF.Graph.new()
      |> RDF.Graph.add(limits_graph)
      |> RDF.Graph.add({node, @rdf_type, @riptide_capability_catalog_entry})
      |> RDF.Graph.add({node, @riptide_name, entry.name})
      |> RDF.Graph.add({node, @riptide_capability_kind, RDF.literal(encode_kind(entry.kind))})
      |> RDF.Graph.add({node, @riptide_component_hash, RDF.literal(entry.component_hash)})
      |> RDF.Graph.add({node, @riptide_capability_function, RDF.literal(entry.function)})
      |> RDF.Graph.add({node, @riptide_fuel_limit, RDF.literal(entry.fuel_limit)})
      |> RDF.Graph.add({node, @riptide_timeout_ms, RDF.literal(entry.timeout_ms)})
      |> RDF.Graph.add({node, @riptide_memory_limits, limits_node})

    {node, graph}
  end

  # Explicit case matching, not Atom.to_string/String.to_existing_atom: see
  # CrosswalkRDFCodec's own decode_match_type/1 for the full reasoning this
  # mirrors exactly.
  defp encode_kind(:effect), do: "effect"
  defp encode_kind(:observe), do: "observe"

  defp decode_kind("effect"), do: :effect
  defp decode_kind("observe"), do: :observe

  defp encode_memory_limits(limits) do
    node = RDF.BlankNode.new()

    graph =
      RDF.Graph.new()
      |> maybe_add(node, @riptide_max_memory_size, limits.max_memory_size)
      |> maybe_add(node, @riptide_max_table_elements, limits.max_table_elements)
      |> maybe_add(node, @riptide_max_instances, limits.max_instances)
      |> maybe_add(node, @riptide_max_tables, limits.max_tables)

    {node, graph}
  end

  defp maybe_add(graph, _node, _predicate, nil), do: graph

  defp maybe_add(graph, node, predicate, value),
    do: RDF.Graph.add(graph, {node, predicate, RDF.literal(value)})

  @spec from_rdf(RDF.Resource.t(), RDF.Graph.t()) :: CapabilityCatalogEntry.t()
  def from_rdf(node, graph) do
    description = RDF.Graph.get(graph, node)
    limits_node = RDF.Description.first(description, @riptide_memory_limits)

    %CapabilityCatalogEntry{
      name: RDF.Description.first(description, @riptide_name),
      kind:
        description
        |> RDF.Description.first(@riptide_capability_kind)
        |> RDF.Literal.value()
        |> decode_kind(),
      component_hash:
        description |> RDF.Description.first(@riptide_component_hash) |> RDF.Literal.value(),
      function:
        description |> RDF.Description.first(@riptide_capability_function) |> RDF.Literal.value(),
      fuel_limit:
        description |> RDF.Description.first(@riptide_fuel_limit) |> RDF.Literal.value(),
      timeout_ms:
        description |> RDF.Description.first(@riptide_timeout_ms) |> RDF.Literal.value(),
      memory_limits: decode_memory_limits(limits_node, graph)
    }
  end

  # A fully-nil memory_limits (no field set) means encode_memory_limits/1
  # added zero triples for its own sub-node — RDF.Graph.get/2 then returns
  # nil rather than an empty %RDF.Description{}, so that case is handled
  # explicitly here rather than crashing in RDF.Description.first/2.
  defp decode_memory_limits(node, graph) do
    case RDF.Graph.get(graph, node) do
      nil ->
        %{max_memory_size: nil, max_table_elements: nil, max_instances: nil, max_tables: nil}

      description ->
        %{
          max_memory_size: decode_optional_int(description, @riptide_max_memory_size),
          max_table_elements: decode_optional_int(description, @riptide_max_table_elements),
          max_instances: decode_optional_int(description, @riptide_max_instances),
          max_tables: decode_optional_int(description, @riptide_max_tables)
        }
    end
  end

  defp decode_optional_int(description, predicate) do
    case RDF.Description.first(description, predicate) do
      nil -> nil
      literal -> RDF.Literal.value(literal)
    end
  end
end
