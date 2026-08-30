defmodule RiptideWeb.Hub.InstallControllerTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias Riptide.Authz.Store
  alias Riptide.Derivation.{Catalog, Parser}

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

  test "install a Hub entry into a Tenant, then approve — it becomes live in the Tenant's own Catalog" do
    tenant_id = "install-test-" <> Uniq.UUID.uuid4()
    predicate_name = "installhttp#{System.unique_integer([:positive])}"
    claim_tenant(tenant_id)

    on_exit(fn ->
      Riptide.RaTestHelpers.cleanup_stream(Catalog.catalog_stream_id({:tenant, tenant_id}))
      Riptide.RaTestHelpers.cleanup_stream(Catalog.pending_review_stream_id({:tenant, tenant_id}))
    end)

    hub_rule_text =
      "#{predicate_name}(<urn:test:alice>, \"hi\") :- pendingDeploy(<urn:test:alice>, \"v1\")."

    {:ok, hub_rule} = Parser.decode(hub_rule_text)
    :ok = Catalog.admit_entry(:hub, hub_rule, nil)
    {:ok, hub_entries} = Catalog.list_entries(:hub)
    {hub_node, ^hub_rule} = Enum.find(hub_entries, fn {_n, r} -> r == hub_rule end)
    hub_node_id = RDF.BlankNode.value(hub_node)

    body = Jason.encode!(%{"hub_node_id" => hub_node_id})

    install_conn =
      :post
      |> conn("/tenants/#{tenant_id}/hub/install", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert install_conn.status == 200
    review_node_id = Jason.decode!(install_conn.resp_body)["node_id"]

    approve_conn =
      :post
      |> conn("/tenants/#{tenant_id}/hub/install-reviews/#{review_node_id}/approve")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert approve_conn.status == 200

    predicate = RDF.iri("urn:riptide:relation:" <> predicate_name)
    assert {:ok, entries} = Catalog.list_entries({:tenant, tenant_id})
    assert Enum.any?(entries, fn {_n, r} -> r.head.predicate == predicate end)
  end
end
