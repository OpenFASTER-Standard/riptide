defmodule RiptideWeb.UsernamePasswordAuthCapstoneTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Riptide.Accounts.Account
  alias Riptide.Accounts.RDFCodec, as: AccountRDFCodec
  alias Riptide.RDF.TurtleCodec

  @opts RiptideWeb.Endpoint.init([])

  setup do
    Riptide.AppEnvTestHelpers.put_env(
      :riptide,
      :password_auth_signing_key,
      "test-signing-key-fixture"
    )

    Riptide.AppEnvTestHelpers.put_env(:riptide, :password_auth_signup_rate_limit, 1_000)
    Riptide.AppEnvTestHelpers.put_env(:riptide, :password_auth_login_rate_limit, 1_000)
    :ok
  end

  test "signup -> invite a teammate via the existing generic write route -> both log in independently -> both tokens work through the existing Authenticate/Authorize pipeline" do
    tenant_id = "capstone-tenant-#{System.unique_integer([:positive])}"

    # 1. Alice signs up, creating the Tenant and her own account together.
    signup_body =
      Jason.encode!(%{
        "tenant_id" => tenant_id,
        "username" => "alice",
        "password_hash" => String.duplicate("a", 64)
      })

    signup_conn =
      :post
      |> conn("/auth/signup", signup_body)
      |> put_req_header("content-type", "application/json")
      |> RiptideWeb.Endpoint.call(@opts)

    assert signup_conn.status == 200
    alice_token = Jason.decode!(signup_conn.resp_body)["token"]

    # 2. Alice invites Bob by writing a second account fact directly, using her own
    # token via the EXISTING generic write route (PUT, not POST — a client-named
    # path segment, not an auto-generated one) — zero new server code for this step.
    bob_account = %Account{
      username: "bob",
      password_hash_sha256: String.duplicate("b", 64),
      sub: Uniq.UUID.uuid4()
    }

    {_node, bob_graph} = AccountRDFCodec.to_rdf(bob_account)
    {:ok, bob_turtle} = TurtleCodec.encode(bob_graph)

    invite_conn =
      :put
      |> conn("/tenants/#{tenant_id}/resources/accounts/bob", bob_turtle)
      |> put_req_header("authorization", "Bearer #{alice_token}")
      |> RiptideWeb.Endpoint.call(@opts)

    assert invite_conn.status == 201

    # 2b. Having an account (a login) is a separate thing from being authorized to
    # read/write Guild-A's own resources — Bob's account alone grants him nothing
    # there yet. Alice, as the tenant's owner, grants Bob's own subject a policy via
    # the EXISTING, already-built policy endpoint (Phase 4c) — no new code for this
    # either.
    grant_policy_body =
      Jason.encode!(%{
        "effect" => "allow",
        "modes" => ["read", "write"],
        "matcher" => %{"agent" => bob_account.sub}
      })

    grant_policy_conn =
      :post
      |> conn("/tenants/#{tenant_id}/policies", grant_policy_body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{alice_token}")
      |> RiptideWeb.Endpoint.call(@opts)

    assert grant_policy_conn.status == 201

    # 3. Bob logs in independently.
    bob_login_body =
      Jason.encode!(%{
        "tenant_id" => tenant_id,
        "username" => "bob",
        "password_hash" => String.duplicate("b", 64)
      })

    bob_login_conn =
      :post
      |> conn("/auth/login", bob_login_body)
      |> put_req_header("content-type", "application/json")
      |> RiptideWeb.Endpoint.call(@opts)

    assert bob_login_conn.status == 200
    bob_token = Jason.decode!(bob_login_conn.resp_body)["token"]

    # 4. Both tokens independently pass through the EXISTING Authenticate/Authorize
    # pipeline for an ordinary Tenant-scoped resource read — nothing downstream of
    # authentication needed to change at all.
    alice_read_conn =
      :get
      |> conn("/tenants/#{tenant_id}/resources/accounts/bob")
      |> put_req_header("authorization", "Bearer #{alice_token}")
      |> RiptideWeb.Endpoint.call(@opts)

    bob_read_conn =
      :get
      |> conn("/tenants/#{tenant_id}/resources/accounts/bob")
      |> put_req_header("authorization", "Bearer #{bob_token}")
      |> RiptideWeb.Endpoint.call(@opts)

    assert alice_read_conn.status == 200
    assert bob_read_conn.status == 200
  end
end
