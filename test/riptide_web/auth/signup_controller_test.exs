defmodule RiptideWeb.Auth.SignupControllerTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @opts RiptideWeb.Endpoint.init([])

  setup do
    Riptide.AppEnvTestHelpers.put_env(
      :riptide,
      :password_auth_signing_key,
      "test-signing-key-fixture"
    )

    Riptide.AppEnvTestHelpers.put_env(:riptide, :password_auth_signup_rate_limit, 1_000)
    :ok
  end

  defp unique_tenant, do: "signupctl-tenant-#{System.unique_integer([:positive])}"

  defp signup_body(overrides \\ %{}) do
    Jason.encode!(
      Map.merge(
        %{
          "tenant_id" => unique_tenant(),
          "username" => "alice",
          "password_hash" => String.duplicate("a", 64)
        },
        overrides
      )
    )
  end

  test "valid signup returns 200 with a usable token" do
    conn =
      :post
      |> conn("/auth/signup", signup_body())
      |> put_req_header("content-type", "application/json")
      |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert is_binary(body["token"])
    assert is_binary(body["sub"])
  end

  test "signing up against an already-claimed tenant_id returns 409" do
    tenant_id = unique_tenant()
    body = signup_body(%{"tenant_id" => tenant_id})

    first_conn =
      :post
      |> conn("/auth/signup", body)
      |> put_req_header("content-type", "application/json")
      |> RiptideWeb.Endpoint.call(@opts)

    assert first_conn.status == 200

    second_conn =
      :post
      |> conn("/auth/signup", signup_body(%{"tenant_id" => tenant_id, "username" => "mallory"}))
      |> put_req_header("content-type", "application/json")
      |> RiptideWeb.Endpoint.call(@opts)

    assert second_conn.status == 409
  end

  test "a tenant_id containing '/' returns 400 without claiming anything" do
    conn =
      :post
      |> conn("/auth/signup", signup_body(%{"tenant_id" => "has/slash"}))
      |> put_req_header("content-type", "application/json")
      |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 400
  end

  test "a username containing '/' returns 400" do
    conn =
      :post
      |> conn("/auth/signup", signup_body(%{"username" => "has/slash"}))
      |> put_req_header("content-type", "application/json")
      |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 400
  end

  test "signup is rate-limited" do
    Riptide.AppEnvTestHelpers.put_env(:riptide, :password_auth_signup_rate_limit, 0)

    conn =
      :post
      |> conn("/auth/signup", signup_body())
      |> put_req_header("content-type", "application/json")
      |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 429
  end
end
