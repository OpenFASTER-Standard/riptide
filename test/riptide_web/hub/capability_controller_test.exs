defmodule RiptideWeb.Hub.CapabilityControllerTest do
  use ExUnit.Case, async: false
  use Plug.Test

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
    :claimed = Store.Placement.claim_tenant_if_unclaimed(tenant_id, "the-owner")
  end

  test "propose a Capability with embedded bytes, then approve it — it becomes live in the Hub capability catalog" do
    tenant_id = "capability-test-" <> Uniq.UUID.uuid4()
    claim_tenant(tenant_id)

    on_exit(fn ->
      Riptide.RaTestHelpers.cleanup_stream(Catalog.pending_review_stream_id({:tenant, tenant_id}))
    end)

    bytes = :crypto.strong_rand_bytes(512)
    name = "urn:riptide:capability:httpcap-#{System.unique_integer([:positive])}"

    body =
      Jason.encode!(%{
        "name" => name,
        "kind" => "effect",
        "function" => "run",
        "fuel_limit" => 10_000_000,
        "timeout_ms" => 5_000,
        "memory_limits" => %{
          "max_memory_size" => nil,
          "max_table_elements" => nil,
          "max_instances" => nil,
          "max_tables" => nil
        },
        "component_bytes" => Base.encode64(bytes)
      })

    propose_conn =
      :post
      |> conn("/tenants/#{tenant_id}/hub/capabilities", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert propose_conn.status == 200
    node_id = Jason.decode!(propose_conn.resp_body)["node_id"]
    assert is_binary(node_id)

    approve_conn =
      :post
      |> conn("/tenants/#{tenant_id}/hub/capability-reviews/#{node_id}/approve")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert approve_conn.status == 200

    assert {:ok, entries} = Catalog.list_capabilities()
    assert Enum.any?(entries, fn {_n, e} -> e.name == RDF.iri(name) end)
  end

  test "declining a proposed Capability admits nothing" do
    tenant_id = "capability-decline-" <> Uniq.UUID.uuid4()
    claim_tenant(tenant_id)

    on_exit(fn ->
      Riptide.RaTestHelpers.cleanup_stream(Catalog.pending_review_stream_id({:tenant, tenant_id}))
    end)

    name = "urn:riptide:capability:httpcapdecline-#{System.unique_integer([:positive])}"

    body =
      Jason.encode!(%{
        "name" => name,
        "kind" => "effect",
        "function" => "run",
        "fuel_limit" => 10_000_000,
        "timeout_ms" => 5_000,
        "memory_limits" => %{
          "max_memory_size" => nil,
          "max_table_elements" => nil,
          "max_instances" => nil,
          "max_tables" => nil
        },
        "component_bytes" => Base.encode64(:crypto.strong_rand_bytes(64))
      })

    propose_conn =
      :post
      |> conn("/tenants/#{tenant_id}/hub/capabilities", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    node_id = Jason.decode!(propose_conn.resp_body)["node_id"]

    decline_conn =
      :post
      |> conn("/tenants/#{tenant_id}/hub/capability-reviews/#{node_id}/decline")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert decline_conn.status == 200

    assert {:ok, entries} = Catalog.list_capabilities()
    refute Enum.any?(entries, fn {_n, e} -> e.name == RDF.iri(name) end)
  end
end
