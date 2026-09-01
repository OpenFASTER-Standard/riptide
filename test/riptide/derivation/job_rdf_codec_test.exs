defmodule Riptide.Derivation.JobRDFCodecTest do
  use ExUnit.Case, async: true

  alias Riptide.Derivation.{Job, JobRDFCodec}

  defp sample_job(overrides) do
    Map.merge(
      %Job{
        tenant_id: "acme",
        status: :pending,
        reference: {:capability, RDF.iri("urn:riptide:capability:restart-payments-service")},
        args: [RDF.literal("World")],
        job_graph: nil,
        result: nil,
        error: nil
      },
      overrides
    )
  end

  test "round-trips a pending jobCapability Job with no job_graph" do
    job = sample_job(%{})

    {node, graph} = JobRDFCodec.to_rdf(job)

    assert JobRDFCodec.from_rdf(node, graph) == job
  end

  test "round-trips a pending jobRule Job with a job_graph" do
    job =
      sample_job(%{
        reference: {:rule, RDF.iri("urn:riptide:relation:someRule")},
        job_graph: "https://riptide.example/tenants/acme/catalog",
        args: [RDF.literal("Alice")]
      })

    {node, graph} = JobRDFCodec.to_rdf(job)

    assert JobRDFCodec.from_rdf(node, graph) == job
  end

  test "round-trips a done Job with a result" do
    job = sample_job(%{status: :done, result: RDF.literal("\"Hello, World!\"")})

    {node, graph} = JobRDFCodec.to_rdf(job)

    assert JobRDFCodec.from_rdf(node, graph) == job
  end

  test "round-trips a failed Job with an error" do
    job = sample_job(%{status: :failed, error: "unauthorized"})

    {node, graph} = JobRDFCodec.to_rdf(job)

    assert JobRDFCodec.from_rdf(node, graph) == job
  end

  test "round-trips multiple args in order" do
    job = sample_job(%{args: [RDF.literal("a"), RDF.literal("b"), RDF.literal("c")]})

    {node, graph} = JobRDFCodec.to_rdf(job)

    assert JobRDFCodec.from_rdf(node, graph) == job
  end

  test "round-trips a Job with a resource_key set" do
    job = sample_job(%{resource_key: "restart-payments-service"})

    {node, graph} = JobRDFCodec.to_rdf(job)

    assert JobRDFCodec.from_rdf(node, graph) == job
  end
end
