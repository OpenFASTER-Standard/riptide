defmodule RiptideWeb.TenantSovereigntyCapstoneTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Riptide.Authz.{Policy, Store}
  alias Riptide.{BlobStore, Capability}
  alias Riptide.Derivation.{CapabilityCatalog, Catalog}

  @opts RiptideWeb.Endpoint.init([])

  defp sha256_hex(s), do: :crypto.hash(:sha256, s) |> Base.encode16(case: :lower)
  defp unique_name(prefix), do: prefix <> "-" <> Uniq.UUID.uuid4()

  defp signup!(name, username) do
    body =
      Jason.encode!(%{
        "name" => name,
        "username" => username,
        "password_hash" => sha256_hex("pw")
      })

    conn =
      :post
      |> conn("/auth/signup", body)
      |> put_req_header("content-type", "application/json")
      |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 200
    Jason.decode!(conn.resp_body)
  end

  test "exit criterion: install copies a Capability's blob bytes, invocation keeps working after the source tenant's own copy is deleted" do
    %{"token" => alice_token, "tenant_id" => guild_a} = signup!(unique_name("guild-a"), "alice")
    %{"token" => bob_token, "tenant_id" => guild_b} = signup!(unique_name("guild-b"), "bob")

    wasm_bytes = File.read!("test/fixtures/riptide_capability/fixture.wasm")

    cap_name = "urn:riptide:capability:capstone6q-#{Uniq.UUID.uuid4()}"

    propose_body =
      Jason.encode!(%{
        "name" => cap_name,
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
        "component_bytes" => Base.encode64(wasm_bytes)
      })

    propose_conn =
      :post
      |> conn("/tenants/#{guild_a}/capabilities", propose_body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{alice_token}")
      |> RiptideWeb.Endpoint.call(@opts)

    assert propose_conn.status == 200
    %{"node_id" => cap_node_id} = Jason.decode!(propose_conn.resp_body)

    approve_conn =
      :post
      |> conn("/tenants/#{guild_a}/capability-reviews/#{cap_node_id}/approve", "")
      |> put_req_header("authorization", "Bearer #{alice_token}")
      |> RiptideWeb.Endpoint.call(@opts)

    assert approve_conn.status == 200

    # Capabilities aren't Rules, so use list_capabilities directly to find the admitted entry's own
    # node id (distinct from the review node id) to install by.
    {:ok, capabilities} = Catalog.list_capabilities({:tenant, guild_a})
    assert [{cap_entry_node, _entry}] = capabilities

    # Grant :public read so Guild B (a different tenant) can discover it:
    grant_body = Jason.encode!(%{"effect" => "allow", "modes" => ["read"], "matcher" => "public"})

    grant_conn =
      :post
      |> conn("/tenants/#{guild_a}/policies", grant_body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{alice_token}")
      |> RiptideWeb.Endpoint.call(@opts)

    assert grant_conn.status == 201

    # Guild B installs it via the dedicated Capability copy-on-install endpoint.
    install_conn =
      :post
      |> conn(
        "/tenants/#{guild_b}/install-capability",
        Jason.encode!(%{
          "source_tenant_id" => guild_a,
          "node_id" => RDF.BlankNode.value(cap_entry_node)
        })
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{bob_token}")
      |> RiptideWeb.Endpoint.call(@opts)

    assert install_conn.status == 200
    %{"node_id" => install_review_node} = Jason.decode!(install_conn.resp_body)

    install_approve_conn =
      :post
      |> conn("/tenants/#{guild_b}/capability-reviews/#{install_review_node}/approve", "")
      |> put_req_header("authorization", "Bearer #{bob_token}")
      |> RiptideWeb.Endpoint.call(@opts)

    assert install_approve_conn.status == 200

    {:ok, [{_node, installed_entry}]} = Catalog.list_capabilities({:tenant, guild_b})

    # Guild B grants itself (:public, for simplicity) invoke rights on its own newly-installed copy.
    # RiptideWeb.Authz.PolicyController's HTTP surface only supports read/write modes scoped to the
    # tenant root — :invoke, path-scoped grants have no HTTP endpoint yet, so this goes straight
    # through the store, matching the exact pattern
    # test/riptide_web/demo_backend_additions_capstone_test.exs's own capability-invocation setup
    # already establishes.
    local_name = String.trim_leading(cap_name, "urn:riptide:capability:")

    :ok =
      Store.TenantFacts.add_policy(
        guild_b,
        ["capabilities", local_name],
        %Policy{
          effect: :allow,
          modes: [:invoke],
          matcher: :public
        }
      )

    # Guild B's own copy is invocable right now:
    {:ok, definition} = CapabilityCatalog.materialize(guild_b, installed_entry)
    assert {:ok, _result} = Capability.invoke(definition, guild_b, nil, ["World"])

    # The real proof of independence: delete Guild A's own original blob entirely, confirm Guild B's
    # own copy — a different hash if content-addressing ever diverges, but here identical bytes so the
    # SAME hash under a DIFFERENT tenant-scoped path — still works, since it was actually copied, not
    # referenced.
    original_path = BlobStore.path_for(guild_a, installed_entry.component_hash)
    File.rm!(original_path)
    refute File.exists?(original_path)

    {:ok, definition_after_deletion} = CapabilityCatalog.materialize(guild_b, installed_entry)

    assert {:ok, _result} = Capability.invoke(definition_after_deletion, guild_b, nil, ["World"])
  end
end
