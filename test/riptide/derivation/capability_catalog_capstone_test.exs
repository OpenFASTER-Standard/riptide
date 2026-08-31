defmodule Riptide.Derivation.CapabilityCatalogCapstoneTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias Riptide.Authz.{Policy, Store}
  alias Riptide.Capability
  alias Riptide.Derivation.{CapabilityCatalog, Catalog}

  @opts RiptideWeb.Endpoint.init([])

  defmodule StubVerifier do
    @behaviour Riptide.Auth.Verifier

    @impl true
    def verify("owner-token"), do: {:ok, %{"sub" => "the-owner"}}
    def verify(_token), do: {:error, :invalid_token}
  end

  defmodule FakeStore do
    @behaviour Riptide.Authz.Store

    @impl true
    def list_policies(tenant_id, path_prefix) do
      Agent.get(__MODULE__, &Map.get(&1, {tenant_id, path_prefix}, []))
    end

    @impl true
    def add_policy(_tenant_id, _path_prefix, _policy), do: :ok

    @impl true
    def claim_tenant_if_unclaimed(_tenant_id, _subject), do: :already_claimed

    def start(policies_by_prefix) do
      case Agent.start_link(fn -> policies_by_prefix end, name: __MODULE__) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end
    end
  end

  setup do
    Riptide.AppEnvTestHelpers.put_env(:riptide, :auth_verifier, StubVerifier)
    dir = Path.join(System.tmp_dir!(), "cap_capstone_#{System.unique_integer([:positive])}")
    Riptide.AppEnvTestHelpers.put_env(:riptide, :blob_data_dir, dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    :ok
  end

  test "exit criterion: register via real HTTP, approve, resolve and invoke by IRI alone" do
    tenant_id = "capstone-" <> Uniq.UUID.uuid4()
    :claimed = Store.Placement.claim_tenant_if_unclaimed(tenant_id, "the-owner")

    on_exit(fn ->
      Riptide.RaTestHelpers.cleanup_stream(Catalog.pending_review_stream_id({:tenant, tenant_id}))
    end)

    name = "urn:riptide:capability:capstone-greet-#{System.unique_integer([:positive])}"
    component_bytes = File.read!("test/fixtures/riptide_capability/fixture.wasm")

    body =
      Jason.encode!(%{
        "name" => name,
        "kind" => "effect",
        "function" => "greet",
        "fuel_limit" => 100_000_000,
        "timeout_ms" => 5_000,
        "memory_limits" => %{
          "max_memory_size" => nil,
          "max_table_elements" => nil,
          "max_instances" => nil,
          "max_tables" => nil
        },
        "component_bytes" => Base.encode64(component_bytes)
      })

    propose_conn =
      :post
      |> conn("/tenants/#{tenant_id}/hub/capabilities", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert propose_conn.status == 200
    node_id = Jason.decode!(propose_conn.resp_body)["node_id"]

    approve_conn =
      :post
      |> conn("/tenants/#{tenant_id}/hub/capability-reviews/#{node_id}/approve")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert approve_conn.status == 200

    # Resolution and invocation — never a hand-built %Definition{} anywhere
    # below this line.
    Riptide.AppEnvTestHelpers.put_env(:riptide, :authz_store, FakeStore)

    local_name = String.trim_leading(name, "urn:riptide:capability:")

    FakeStore.start(%{
      {"acme", ["capabilities", local_name]} => [
        %Policy{effect: :allow, modes: [:invoke], matcher: :public}
      ]
    })

    assert {:ok, entry} = CapabilityCatalog.find_by_name(RDF.iri(name))
    assert {:ok, definition} = CapabilityCatalog.materialize(entry)
    assert {:ok, result} = Capability.invoke(definition, "acme", nil, ["World"])
    assert result == "\"Hello, World!\""
  end
end
