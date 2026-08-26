defmodule RiptideWeb.Authz.PolicyControllerTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias Riptide.Authz.Store
  alias RiptideWeb.LDP.ResourceController

  @opts RiptideWeb.Endpoint.init([])

  defmodule StubVerifier do
    @behaviour Riptide.Auth.Verifier

    @impl true
    def verify("owner-token"), do: {:ok, %{"sub" => "the-owner"}}
    def verify("other-token"), do: {:ok, %{"sub" => "someone-else"}}
    def verify("friend-token"), do: {:ok, %{"sub" => "friend-1"}}
    def verify(_token), do: {:error, :invalid_token}
  end

  setup do
    original = Application.get_env(:riptide, :auth_verifier)
    Application.put_env(:riptide, :auth_verifier, StubVerifier)
    on_exit(fn -> Application.put_env(:riptide, :auth_verifier, original) end)
    :ok
  end

  defp claim_tenant(tenant_id) do
    :claimed = Store.Placement.claim_tenant_if_unclaimed(tenant_id, "the-owner")
  end

  test "the owner can add a policy and then list it back" do
    tenant_id = "policy-api-test-" <> Uniq.UUID.uuid4()
    claim_tenant(tenant_id)

    body =
      Jason.encode!(%{
        "effect" => "allow",
        "modes" => ["read"],
        "matcher" => "public"
      })

    post_conn =
      :post
      |> conn("/tenants/#{tenant_id}/policies", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert post_conn.status == 201

    get_conn =
      :get
      |> conn("/tenants/#{tenant_id}/policies")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert get_conn.status == 200

    [owner_policy, added_policy] = Jason.decode!(get_conn.resp_body)
    assert owner_policy["matcher"] == %{"agent" => "the-owner"}
    assert added_policy == %{"effect" => "allow", "modes" => ["read"], "matcher" => "public"}
  end

  test "a non-owner cannot add or list policies for someone else's tenant" do
    tenant_id = "policy-api-test-" <> Uniq.UUID.uuid4()
    claim_tenant(tenant_id)

    body = Jason.encode!(%{"effect" => "allow", "modes" => ["read"], "matcher" => "public"})

    post_conn =
      :post
      |> conn("/tenants/#{tenant_id}/policies", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer other-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert post_conn.status == 403

    get_conn =
      :get
      |> conn("/tenants/#{tenant_id}/policies")
      |> put_req_header("authorization", "Bearer other-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert get_conn.status == 403
  end

  test "adding a policy with an unrecognized effect returns 400" do
    tenant_id = "policy-api-test-" <> Uniq.UUID.uuid4()
    claim_tenant(tenant_id)

    body = Jason.encode!(%{"effect" => "maybe", "modes" => ["read"], "matcher" => "public"})

    conn =
      :post
      |> conn("/tenants/#{tenant_id}/policies", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 400
  end

  test "an agent matcher round-trips as a nested map" do
    tenant_id = "policy-api-test-" <> Uniq.UUID.uuid4()
    claim_tenant(tenant_id)

    body =
      Jason.encode!(%{
        "effect" => "allow",
        "modes" => ["read", "write"],
        "matcher" => %{"agent" => "friend-1"}
      })

    :post
    |> conn("/tenants/#{tenant_id}/policies", body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer owner-token")
    |> RiptideWeb.Endpoint.call(@opts)

    get_conn =
      :get
      |> conn("/tenants/#{tenant_id}/policies")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    [_owner_policy, added_policy] = Jason.decode!(get_conn.resp_body)
    assert added_policy["matcher"] == %{"agent" => "friend-1"}
    assert added_policy["modes"] == ["read", "write"]
  end

  # This is the capstone scenario the whole design's matcher expressiveness
  # exists for (see the Phase 4c design spec §1/§8): an owner shares access
  # with a specific, previously-unenumerated agent, and that agent's access
  # actually works against a real LDP resource afterward — not just that the
  # policy API itself accepts and echoes back the grant.
  test "a policy granted through this API actually enables that agent's real resource access" do
    tenant_id = "policy-api-e2e-" <> Uniq.UUID.uuid4()
    resource_path = "/tenants/#{tenant_id}/resources/shared-doc"

    on_exit(fn ->
      Riptide.RaTestHelpers.cleanup_stream(
        ResourceController.stream_id_for(tenant_id, ["shared-doc"])
      )
    end)

    claim_tenant(tenant_id)

    friend_get_before_grant =
      :get
      |> conn(resource_path)
      |> put_req_header("authorization", "Bearer friend-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert friend_get_before_grant.status == 403

    :put
    |> conn(resource_path, "<https://pod.example/x> <https://pod.example/y> \"shared\" .\n")
    |> put_req_header("content-type", "text/turtle")
    |> put_req_header("authorization", "Bearer owner-token")
    |> RiptideWeb.Endpoint.call(@opts)

    grant_body =
      Jason.encode!(%{
        "effect" => "allow",
        "modes" => ["read"],
        "matcher" => %{"agent" => "friend-1"}
      })

    grant_conn =
      :post
      |> conn("/tenants/#{tenant_id}/policies", grant_body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert grant_conn.status == 201

    friend_get_after_grant =
      :get
      |> conn(resource_path)
      |> put_req_header("authorization", "Bearer friend-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert friend_get_after_grant.status == 200
    assert friend_get_after_grant.resp_body =~ "\"shared\""

    friend_put_still_denied =
      :put
      |> conn(
        resource_path,
        "<https://pod.example/x> <https://pod.example/y> \"overwritten\" .\n"
      )
      |> put_req_header("content-type", "text/turtle")
      |> put_req_header("authorization", "Bearer friend-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert friend_put_still_denied.status == 403
  end
end
