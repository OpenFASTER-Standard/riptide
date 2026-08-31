defmodule Riptide.Derivation.CatalogJobTest do
  use ExUnit.Case, async: false

  alias Riptide.Derivation.{Catalog, Job}

  defp unique_tenant, do: "job-acme-#{System.unique_integer([:positive])}"

  defp sample_job(tenant_id) do
    %Job{
      tenant_id: tenant_id,
      status: :pending,
      reference: {:capability, RDF.iri("urn:riptide:capability:catalog-job-test")},
      args: [RDF.literal("World")],
      job_graph: nil,
      result: nil,
      error: nil
    }
  end

  test "write_job/2 + list_jobs/1 round-trip" do
    tenant_id = unique_tenant()
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(Catalog.job_stream_id(tenant_id)) end)

    job = sample_job(tenant_id)
    assert {:ok, node} = Catalog.write_job(tenant_id, job)

    assert {:ok, jobs} = Catalog.list_jobs(Catalog.job_stream_id(tenant_id))
    assert Enum.any?(jobs, fn {n, j} -> n == node and j == job end)
  end

  test "mark_job_done/3 transitions status and records the result" do
    tenant_id = unique_tenant()
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(Catalog.job_stream_id(tenant_id)) end)

    job = sample_job(tenant_id)
    {:ok, node} = Catalog.write_job(tenant_id, job)
    stream_id = Catalog.job_stream_id(tenant_id)

    assert :ok = Catalog.mark_job_done(stream_id, node, RDF.literal("\"Hello, World!\""))

    {:ok, jobs} = Catalog.list_jobs(stream_id)
    {^node, updated} = Enum.find(jobs, fn {n, _j} -> n == node end)
    assert updated.status == :done
    assert updated.result == RDF.literal("\"Hello, World!\"")
  end

  test "mark_job_failed/3 transitions status and records the error" do
    tenant_id = unique_tenant()
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(Catalog.job_stream_id(tenant_id)) end)

    job = sample_job(tenant_id)
    {:ok, node} = Catalog.write_job(tenant_id, job)
    stream_id = Catalog.job_stream_id(tenant_id)

    assert :ok = Catalog.mark_job_failed(stream_id, node, "unauthorized")

    {:ok, jobs} = Catalog.list_jobs(stream_id)
    {^node, updated} = Enum.find(jobs, fn {n, _j} -> n == node end)
    assert updated.status == :failed
    assert updated.error == "unauthorized"
  end
end
