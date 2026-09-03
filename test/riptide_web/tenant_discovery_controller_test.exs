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

  test "GET /tenants/:tenant_id/discovery/search response carries each entry's real, addressable node id as a literal" do
    tenant_id = "tenant-discovery-nodeid-" <> Uniq.UUID.uuid4()
    predicate_name = "tenantdiscoverynodeid#{System.unique_integer([:positive])}"
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
    {:ok, entries} = Catalog.list_entries({:tenant, tenant_id})
    predicate = RDF.iri("urn:riptide:relation:#{predicate_name}")
    {node, _rule} = Enum.find(entries, fn {_n, r} -> r.head.predicate == predicate end)
    real_node_id = RDF.BlankNode.value(node)

    conn =
      :get
      |> conn("/tenants/#{tenant_id}/discovery/search?q=#{predicate_name}")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 200
    # A real HTTP client has no way to recover a blank node's own label across an independent
    # parse of this response (RDF gives blank nodes no identity outside one document, and this
    # response's own top-level Rule node has zero inbound references, so Riptide.RDF.TurtleCodec's
    # underlying writer renders it as anonymous `[...]` syntax with no label at all — confirmed
    # live). Without a literal carrying the real node_id, nothing in this response could ever be
    # passed to POST /install's own node_id param, which requires an exact
    # RDF.BlankNode.value/1 match against Catalog.list_entries/1.
    {:ok, graph} = RDF.Turtle.read_string(conn.resp_body)

    node_id_quad =
      Enum.find(RDF.Graph.triples(graph), fn {_s, p, _o} ->
        p == RDF.iri("urn:riptide:vocab:nodeId")
      end)

    assert node_id_quad != nil
    {_s, _p, literal} = node_id_quad
    assert RDF.Literal.value(literal) == real_node_id
  end

  test "GET /tenants/:tenant_id/entries/:node_id fetches a specific entry by its blank-node id" do
    tenant_id = "discovery-show-" <> Uniq.UUID.uuid4()
    predicate_name = "discoveryshow#{System.unique_integer([:positive])}"
    claim_tenant(tenant_id)

    on_exit(fn ->
      Riptide.RaTestHelpers.cleanup_stream(Catalog.catalog_stream_id({:tenant, tenant_id}))
    end)

    predicate = RDF.iri("urn:riptide:relation:#{predicate_name}")

    rule = %Riptide.Derivation.Rule{
      signature: %Riptide.Derivation.Signature{
        name: predicate,
        parameters: [],
        reads: [],
        produces: [predicate]
      },
      head: %Riptide.Derivation.Literal.FactPattern{
        predicate: predicate,
        args: [RDF.iri("urn:test:subject"), RDF.literal("done")]
      },
      body: []
    }

    :ok = Catalog.admit_entry({:tenant, tenant_id}, rule, nil)
    {:ok, entries} = Catalog.list_entries({:tenant, tenant_id})
    {node, ^rule} = Enum.find(entries, fn {_n, r} -> r == rule end)
    node_id = RDF.BlankNode.value(node)

    conn =
      :get
      |> conn("/tenants/#{tenant_id}/entries/#{node_id}")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 200
    assert conn.resp_body =~ predicate_name
  end

  test "GET /tenants/:tenant_id/entries/:node_id returns 404 for an id that was never admitted" do
    tenant_id = "discovery-show-missing-" <> Uniq.UUID.uuid4()
    claim_tenant(tenant_id)

    conn =
      :get
      |> conn("/tenants/#{tenant_id}/entries/nonexistent")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 404
  end
end
