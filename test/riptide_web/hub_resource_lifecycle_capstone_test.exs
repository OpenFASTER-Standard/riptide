defmodule RiptideWeb.HubResourceLifecycleCapstoneTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Riptide.Authz.Store
  alias Riptide.Derivation.Catalog
  alias Riptide.Stream.StreamServer

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

  test "exit criterion: propose -> approve -> live-readable via GET /hub/resources -> propose-with-replaces -> approve -> only the new version live" do
    tenant_id = "hub-lifecycle-capstone-" <> Uniq.UUID.uuid4()
    :claimed = Store.Placement.claim_tenant_if_unclaimed(tenant_id, "the-owner")

    on_exit(fn ->
      Riptide.RaTestHelpers.cleanup_stream(Catalog.pending_review_stream_id({:tenant, tenant_id}))
    end)

    name = "urn:riptide:capability:capstone-qr-#{System.unique_integer([:positive])}"

    body = %{
      "name" => name,
      "kind" => "effect",
      "function" => "generate",
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

    # 1. Propose + approve, exactly as today.
    propose_conn =
      :post
      |> conn("/tenants/#{tenant_id}/hub/capabilities", Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    node_id = Jason.decode!(propose_conn.resp_body)["node_id"]

    approve_conn =
      :post
      |> conn("/tenants/#{tenant_id}/hub/capability-reviews/#{node_id}/approve")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert approve_conn.status == 200

    # 2. Live-readable via the NEW generic Hub surface — this is the actual exit criterion, not
    # just Catalog.list_capabilities/0 (a library call, not a public surface).
    read_conn =
      :get |> conn("/hub/resources/catalog/capabilities") |> RiptideWeb.Endpoint.call(@opts)

    assert read_conn.status == 200
    assert read_conn.resp_body =~ name

    {:ok, entries} = Catalog.list_capabilities()
    {old_node, _entry} = Enum.find(entries, fn {_n, e} -> e.name == RDF.iri(name) end)

    # 3. Propose a replacement, approve it.
    replaces_body = Map.put(body, "replaces", RDF.BlankNode.value(old_node))

    propose_replacement_conn =
      :post
      |> conn("/tenants/#{tenant_id}/hub/capabilities", Jason.encode!(replaces_body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    new_node_id = Jason.decode!(propose_replacement_conn.resp_body)["node_id"]

    approve_replacement_conn =
      :post
      |> conn("/tenants/#{tenant_id}/hub/capability-reviews/#{new_node_id}/approve")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert approve_replacement_conn.status == 200

    # 4. Only the new version is live — full history preserved underneath, never hard-deleted.
    {:ok, entries_after} = Catalog.list_capabilities()
    matching = Enum.filter(entries_after, fn {_n, e} -> e.name == RDF.iri(name) end)
    assert length(matching) == 1

    stream_id = Catalog.capability_stream_id()
    {:ok, all_events} = StreamServer.get_since(stream_id, 0)
    assert length(all_events) >= 2
  end
end
