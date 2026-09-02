defmodule RiptideWeb.TenantProposeControllerTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Riptide.Authz.Store
  alias Riptide.Derivation.{Catalog, Job}

  @opts RiptideWeb.Endpoint.init([])

  defmodule StubVerifier do
    @behaviour Riptide.Auth.Verifier
    @impl true
    def verify("owner-token"), do: {:ok, %{"sub" => "the-owner"}}
    def verify(_token), do: {:error, :invalid_token}
  end

  setup do
    Riptide.AppEnvTestHelpers.put_env(:riptide, :auth_verifier, StubVerifier)
    :ok
  end

  defp claim_tenant(tenant_id) do
    :ok =
      Store.TenantFacts.add_policy(tenant_id, [], %Riptide.Authz.Policy{
        effect: :allow,
        modes: [:read, :write],
        matcher: {:agent, "the-owner"}
      })
  end

  defp trace_for(subject, predicate_name) do
    %Riptide.Derivation.Rule{
      signature: %Riptide.Derivation.Signature{
        name: RDF.iri("urn:riptide:relation:#{predicate_name}"),
        parameters: [],
        reads: [RDF.iri("urn:riptide:relation:seed")],
        produces: [RDF.iri("urn:riptide:relation:#{predicate_name}")]
      },
      head: %Riptide.Derivation.Literal.FactPattern{
        predicate: RDF.iri("urn:riptide:relation:#{predicate_name}"),
        args: [RDF.iri(subject), RDF.literal("done")]
      },
      body: [
        %Riptide.Derivation.Literal.FactPattern{
          predicate: RDF.iri("urn:riptide:relation:seed"),
          args: [RDF.iri(subject), RDF.literal("v1")]
        }
      ]
    }
  end

  test "proposing two Job node references anti-unifies their traces and queues a review" do
    tenant_id = "tenant-propose-test-" <> Uniq.UUID.uuid4()
    predicate_name = "tenantpropose#{System.unique_integer([:positive])}"
    claim_tenant(tenant_id)

    on_exit(fn ->
      Riptide.RaTestHelpers.cleanup_stream(Catalog.job_stream_id(tenant_id))
      Riptide.RaTestHelpers.cleanup_stream(Catalog.pending_review_stream_id({:tenant, tenant_id}))
    end)

    job1 = %Job{
      tenant_id: tenant_id,
      status: :done,
      reference: {:rule, RDF.iri("urn:riptide:relation:#{predicate_name}")},
      args: [],
      job_graph: nil,
      result: nil,
      error: nil,
      resolved_via: :llm_fallback,
      original_description: "first",
      trace: trace_for("urn:test:alice", predicate_name)
    }

    job2 = %Job{
      job1
      | original_description: "second",
        trace: trace_for("urn:test:bob", predicate_name)
    }

    {:ok, job1_node} = Catalog.write_job(tenant_id, job1)
    {:ok, job2_node} = Catalog.write_job(tenant_id, job2)

    # DedupGate.propose/5 only queues a candidate that passes fidelity
    # checking, which re-verifies each trace's own body literals against
    # the submitted facts graph — both traces' bodies read `seed(<subject>,
    # "v1")`, so both grounding facts must be present or the outcome is
    # {:fidelity_failed, _}, not {:queued, _, _} (confirmed against
    # DedupGate.propose/5 and GeneralizationFidelity.check/3 directly).
    body =
      Jason.encode!(%{
        "job1" => RDF.BlankNode.value(job1_node),
        "job2" => RDF.BlankNode.value(job2_node),
        "facts" => [
          %{
            "subject" => "urn:test:alice",
            "predicate" => "urn:riptide:relation:seed",
            "object" => "v1"
          },
          %{
            "subject" => "urn:test:bob",
            "predicate" => "urn:riptide:relation:seed",
            "object" => "v1"
          }
        ]
      })

    conn =
      :post
      |> conn("/tenants/#{tenant_id}/propose", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 200
    response = Jason.decode!(conn.resp_body)
    assert response["outcome"] == "queued"

    assert {:ok, [{_node, _pending}]} = Catalog.list_pending_reviews({:tenant, tenant_id})
  end

  test "proposing a Job with no recorded trace (Discovery-resolved) returns 422" do
    tenant_id = "tenant-propose-no-trace-" <> Uniq.UUID.uuid4()
    claim_tenant(tenant_id)

    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(Catalog.job_stream_id(tenant_id)) end)

    job = %Job{
      tenant_id: tenant_id,
      status: :done,
      reference: {:rule, RDF.iri("urn:riptide:relation:whatever")},
      args: [],
      job_graph: nil,
      result: nil,
      error: nil,
      resolved_via: :discovery,
      trace: nil
    }

    {:ok, job1_node} = Catalog.write_job(tenant_id, job)
    {:ok, job2_node} = Catalog.write_job(tenant_id, job)

    body =
      Jason.encode!(%{
        "job1" => RDF.BlankNode.value(job1_node),
        "job2" => RDF.BlankNode.value(job2_node)
      })

    conn =
      :post
      |> conn("/tenants/#{tenant_id}/propose", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 422
    assert Jason.decode!(conn.resp_body)["error"] == "job_has_no_trace"
  end
end
