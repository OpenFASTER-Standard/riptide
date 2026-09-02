defmodule RiptideWeb.TenantCapabilityControllerTest do
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

  test "propose a Capability with embedded bytes, then approve it — it becomes live in the tenant's own capability catalog" do
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
      |> conn("/tenants/#{tenant_id}/capabilities", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert propose_conn.status == 200
    node_id = Jason.decode!(propose_conn.resp_body)["node_id"]
    assert is_binary(node_id)

    approve_conn =
      :post
      |> conn("/tenants/#{tenant_id}/capability-reviews/#{node_id}/approve")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert approve_conn.status == 200

    assert {:ok, entries} = Catalog.list_capabilities({:tenant, tenant_id})
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
      |> conn("/tenants/#{tenant_id}/capabilities", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    node_id = Jason.decode!(propose_conn.resp_body)["node_id"]

    decline_conn =
      :post
      |> conn("/tenants/#{tenant_id}/capability-reviews/#{node_id}/decline")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert decline_conn.status == 200

    assert {:ok, entries} = Catalog.list_capabilities({:tenant, tenant_id})
    refute Enum.any?(entries, fn {_n, e} -> e.name == RDF.iri(name) end)
  end

  test "proposing a Capability with replaces: admits the new version and supersedes the old one" do
    tenant_id = "capability-replaces-" <> Uniq.UUID.uuid4()
    claim_tenant(tenant_id)

    on_exit(fn ->
      Riptide.RaTestHelpers.cleanup_stream(Catalog.pending_review_stream_id({:tenant, tenant_id}))
    end)

    name = "urn:riptide:capability:httpcapreplaces-#{System.unique_integer([:positive])}"

    base_body = %{
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
    }

    propose_conn =
      :post
      |> conn("/tenants/#{tenant_id}/capabilities", Jason.encode!(base_body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    old_node_id = Jason.decode!(propose_conn.resp_body)["node_id"]

    approve_conn =
      :post
      |> conn("/tenants/#{tenant_id}/capability-reviews/#{old_node_id}/approve")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert approve_conn.status == 200

    {:ok, entries_before} = Catalog.list_capabilities({:tenant, tenant_id})

    {old_tenant_node, _entry} =
      Enum.find(entries_before, fn {_n, e} -> e.name == RDF.iri(name) end)

    replaces_body = Map.put(base_body, "replaces", RDF.BlankNode.value(old_tenant_node))

    propose_replacement_conn =
      :post
      |> conn("/tenants/#{tenant_id}/capabilities", Jason.encode!(replaces_body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    new_node_id = Jason.decode!(propose_replacement_conn.resp_body)["node_id"]

    approve_replacement_conn =
      :post
      |> conn("/tenants/#{tenant_id}/capability-reviews/#{new_node_id}/approve")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert approve_replacement_conn.status == 200

    {:ok, entries_after} = Catalog.list_capabilities({:tenant, tenant_id})
    matching = Enum.filter(entries_after, fn {_n, e} -> e.name == RDF.iri(name) end)
    assert length(matching) == 1
  end
end
