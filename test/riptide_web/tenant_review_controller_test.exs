defmodule RiptideWeb.TenantReviewControllerTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Riptide.Authz.Store
  alias Riptide.Derivation.{Catalog, DedupGate}

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

  test "approving a Tenant-scope pending review admits it into the Tenant's own Catalog" do
    tenant_id = "tenant-review-test-" <> Uniq.UUID.uuid4()
    claim_tenant(tenant_id)

    on_exit(fn ->
      Riptide.RaTestHelpers.cleanup_stream(Catalog.pending_review_stream_id({:tenant, tenant_id}))
      Riptide.RaTestHelpers.cleanup_stream(Catalog.catalog_stream_id({:tenant, tenant_id}))
    end)

    rule = %Riptide.Derivation.Rule{
      signature: %Riptide.Derivation.Signature{
        name: RDF.iri("urn:riptide:relation:tenantreview#{System.unique_integer([:positive])}"),
        parameters: [],
        reads: [],
        produces: []
      },
      head: %Riptide.Derivation.Literal.FactPattern{
        predicate: RDF.iri("urn:riptide:relation:tenantreviewhead"),
        args: [RDF.iri("urn:test:subject"), RDF.literal("done")]
      },
      body: []
    }

    pending = %DedupGate.PendingReview{
      kind: :admit,
      candidate: rule,
      fidelity_evidence: [],
      replaces: nil
    }

    {:ok, node} = Catalog.queue_pending_review({:tenant, tenant_id}, pending)

    conn =
      :post
      |> conn("/tenants/#{tenant_id}/pending-reviews/#{RDF.BlankNode.value(node)}/approve")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 200
    assert {:ok, [{_node, _entry}]} = Catalog.list_entries({:tenant, tenant_id})
  end

  test "declining a Tenant-scope pending review does not admit it" do
    tenant_id = "tenant-review-decline-test-" <> Uniq.UUID.uuid4()
    claim_tenant(tenant_id)

    on_exit(fn ->
      Riptide.RaTestHelpers.cleanup_stream(Catalog.pending_review_stream_id({:tenant, tenant_id}))
    end)

    rule = %Riptide.Derivation.Rule{
      signature: %Riptide.Derivation.Signature{
        name: RDF.iri("urn:riptide:relation:tenantdecline#{System.unique_integer([:positive])}"),
        parameters: [],
        reads: [],
        produces: []
      },
      head: %Riptide.Derivation.Literal.FactPattern{
        predicate: RDF.iri("urn:riptide:relation:tenantdeclinehead"),
        args: [RDF.iri("urn:test:subject"), RDF.literal("done")]
      },
      body: []
    }

    pending = %DedupGate.PendingReview{
      kind: :admit,
      candidate: rule,
      fidelity_evidence: [],
      replaces: nil
    }

    {:ok, node} = Catalog.queue_pending_review({:tenant, tenant_id}, pending)

    conn =
      :post
      |> conn("/tenants/#{tenant_id}/pending-reviews/#{RDF.BlankNode.value(node)}/decline")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 200
    assert {:ok, []} = Catalog.list_entries({:tenant, tenant_id})
  end
end
