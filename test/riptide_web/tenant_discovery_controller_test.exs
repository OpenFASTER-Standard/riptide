defmodule RiptideWeb.TenantDiscoveryControllerTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Riptide.Authz.Store
  alias Riptide.Derivation.Catalog

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

  test "GET /tenants/:tenant_id/discovery/search finds an admitted Tenant-scope CatalogEntry" do
    tenant_id = "tenant-discovery-test-" <> Uniq.UUID.uuid4()
    predicate_name = "tenantdiscovery#{System.unique_integer([:positive])}"
    claim_tenant(tenant_id)

    on_exit(fn ->
      Riptide.RaTestHelpers.cleanup_stream(Catalog.catalog_stream_id({:tenant, tenant_id}))
    end)

    rule = %Riptide.Derivation.Rule{
      signature: %Riptide.Derivation.Signature{
        name: RDF.iri("urn:riptide:relation:#{predicate_name}"),
        parameters: [],
        reads: [],
        produces: []
      },
      head: %Riptide.Derivation.Literal.FactPattern{
        predicate: RDF.iri("urn:riptide:relation:#{predicate_name}"),
        args: [RDF.iri("urn:test:subject"), RDF.literal("done")]
      },
      body: []
    }

    :ok = Catalog.admit_entry({:tenant, tenant_id}, rule, nil)

    conn =
      :get
      |> conn("/tenants/#{tenant_id}/discovery/search?q=#{predicate_name}")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 200
    assert conn.resp_body =~ predicate_name
  end
end
