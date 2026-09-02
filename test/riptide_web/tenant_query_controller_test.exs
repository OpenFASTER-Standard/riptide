defmodule RiptideWeb.TenantQueryControllerTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Riptide.Authz.Store
  alias Riptide.Derivation.{Catalog, Rule, Signature}
  alias Riptide.Derivation.Literal.FactPattern

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
    :claimed = Store.Placement.claim_tenant_if_unclaimed(tenant_id, "the-owner")
  end

  defp rel(name), do: RDF.iri("urn:riptide:relation:" <> name)
  defp t(name), do: RDF.iri("urn:test:" <> name)

  test "evaluates the Tenant's own admitted rule against a named starting resource" do
    tenant_id = "query-ctl-" <> Uniq.UUID.uuid4()
    claim_tenant(tenant_id)

    on_exit(fn ->
      Riptide.RaTestHelpers.cleanup_stream(Catalog.catalog_stream_id({:tenant, tenant_id}))
    end)

    # Deliberately a single ground implication (no Vars, no multi-hop chaining) — this test's
    # only job is proving the HTTP endpoint correctly wires Catalog rules + a named starting
    # resource + QueryInterpreter.evaluate/3 together; QueryInterpreter's own multi-hop
    # fixpoint/recursion algorithm already has its own dedicated coverage from 6c-ii and doesn't
    # need re-proving here.
    base_rule = %Rule{
      signature: %Signature{
        name: rel("unlocks"),
        parameters: [],
        reads: [rel("unlocks")],
        produces: [rel("unlocks")]
      },
      head: %FactPattern{predicate: rel("unlocks"), args: [t("a"), t("c")]},
      body: [%FactPattern{predicate: rel("unlocks"), args: [t("a"), t("b")]}]
    }

    :ok = Catalog.admit_entry({:tenant, tenant_id}, base_rule, nil)

    starting_body = "<urn:test:a> <urn:riptide:relation:unlocks> <urn:test:b> ."

    write_conn =
      :put
      |> conn("/tenants/#{tenant_id}/resources/characters/alice", starting_body)
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert write_conn.status == 201

    query_body = Jason.encode!(%{"starting_resource_path" => ["characters", "alice"]})

    query_conn =
      :post
      |> conn("/tenants/#{tenant_id}/query", query_body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert query_conn.status == 200
    assert query_conn.resp_body =~ "urn:test:c"
  end

  test "a starting_resource_path that's never been written evaluates against an empty starting graph, not 404" do
    tenant_id = "query-ctl-" <> Uniq.UUID.uuid4()
    claim_tenant(tenant_id)

    query_body = Jason.encode!(%{"starting_resource_path" => ["characters", "nobody"]})

    conn =
      :post
      |> conn("/tenants/#{tenant_id}/query", query_body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 200
  end

  test "a missing starting_resource_path returns 400" do
    tenant_id = "query-ctl-" <> Uniq.UUID.uuid4()
    claim_tenant(tenant_id)

    conn =
      :post
      |> conn("/tenants/#{tenant_id}/query", Jason.encode!(%{}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 400
  end

  test "an empty starting_resource_path returns 400" do
    tenant_id = "query-ctl-" <> Uniq.UUID.uuid4()
    claim_tenant(tenant_id)

    conn =
      :post
      |> conn("/tenants/#{tenant_id}/query", Jason.encode!(%{"starting_resource_path" => []}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 400
  end
end
