defmodule Riptide.Derivation.JobRDFCodec do
  @moduledoc """
  Reifies a `Riptide.Derivation.Job` as RDF triples and reads it back,
  following the exact same reification style `RuleRDFCodec`/
  `CapabilityCatalogRDFCodec` already established. Lighter than either —
  a Job has no nested `body` literal list the way a Rule does.
  """

  alias Riptide.Derivation.Job

  @rdf_type RDF.iri("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
  @riptide_job RDF.iri("urn:riptide:vocab:Job")
  @riptide_job_tenant RDF.iri("urn:riptide:vocab:jobTenant")
  @riptide_job_status RDF.iri("urn:riptide:vocab:jobStatus")
  @riptide_job_capability RDF.iri("urn:riptide:vocab:jobCapability")
  @riptide_job_rule RDF.iri("urn:riptide:vocab:jobRule")
  @riptide_job_args RDF.iri("urn:riptide:vocab:jobArgs")
  @riptide_job_graph RDF.iri("urn:riptide:vocab:jobGraph")
  @riptide_job_result RDF.iri("urn:riptide:vocab:jobResult")
  @riptide_job_error RDF.iri("urn:riptide:vocab:jobError")
  @riptide_job_resource_key RDF.iri("urn:riptide:vocab:jobResourceKey")

  @spec to_rdf(Job.t()) :: {RDF.BlankNode.t(), RDF.Graph.t()}
  def to_rdf(%Job{} = job) do
    node = RDF.BlankNode.new()
    args_list = RDF.List.from(job.args)

    graph =
      RDF.Graph.new()
      |> RDF.Graph.add(args_list.graph)
      |> RDF.Graph.add({node, @rdf_type, @riptide_job})
      |> RDF.Graph.add({node, @riptide_job_tenant, RDF.literal(job.tenant_id)})
      |> RDF.Graph.add({node, @riptide_job_status, RDF.literal(encode_status(job.status))})
      |> add_reference(node, job.reference)
      |> RDF.Graph.add({node, @riptide_job_args, args_list.head})
      |> maybe_add(node, @riptide_job_graph, job.job_graph && RDF.literal(job.job_graph))
      |> maybe_add(node, @riptide_job_result, job.result)
      |> maybe_add(node, @riptide_job_error, job.error && RDF.literal(job.error))
      |> maybe_add(
        node,
        @riptide_job_resource_key,
        job.resource_key && RDF.literal(job.resource_key)
      )

    {node, graph}
  end

  defp add_reference(graph, node, {:capability, iri}),
    do: RDF.Graph.add(graph, {node, @riptide_job_capability, iri})

  defp add_reference(graph, node, {:rule, iri}),
    do: RDF.Graph.add(graph, {node, @riptide_job_rule, iri})

  defp maybe_add(graph, _node, _predicate, nil), do: graph

  defp maybe_add(graph, node, predicate, value),
    do: RDF.Graph.add(graph, {node, predicate, value})

  # Explicit case matching, not Atom.to_string/String.to_existing_atom — see
  # CrosswalkRDFCodec's own decode_match_type/1 for the full reasoning this
  # mirrors exactly.
  defp encode_status(:pending), do: "pending"
  defp encode_status(:done), do: "done"
  defp encode_status(:failed), do: "failed"

  defp decode_status("pending"), do: :pending
  defp decode_status("done"), do: :done
  defp decode_status("failed"), do: :failed

  @spec from_rdf(RDF.Resource.t(), RDF.Graph.t()) :: Job.t()
  def from_rdf(node, graph) do
    description = RDF.Graph.get(graph, node)
    args_head = RDF.Description.first(description, @riptide_job_args)

    %Job{
      tenant_id: description |> RDF.Description.first(@riptide_job_tenant) |> RDF.Literal.value(),
      status:
        description
        |> RDF.Description.first(@riptide_job_status)
        |> RDF.Literal.value()
        |> decode_status(),
      reference: decode_reference(description),
      args: RDF.List.new(args_head, graph) |> RDF.List.values(),
      job_graph: decode_optional_string(description, @riptide_job_graph),
      result: RDF.Description.first(description, @riptide_job_result),
      error: decode_optional_string(description, @riptide_job_error),
      resource_key: decode_optional_string(description, @riptide_job_resource_key)
    }
  end

  defp decode_reference(description) do
    case RDF.Description.first(description, @riptide_job_capability) do
      nil -> {:rule, RDF.Description.first(description, @riptide_job_rule)}
      iri -> {:capability, iri}
    end
  end

  defp decode_optional_string(description, predicate) do
    case RDF.Description.first(description, predicate) do
      nil -> nil
      literal -> RDF.Literal.value(literal)
    end
  end
end
