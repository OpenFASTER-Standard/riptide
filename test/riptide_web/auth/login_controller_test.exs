defmodule RiptideWeb.Auth.LoginControllerTest do
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
    Riptide.AppEnvTestHelpers.put_env(:riptide, :password_auth_login_rate_limit, 1_000)
    :ok
  end

  defp unique_tenant, do: "loginctl-tenant-#{System.unique_integer([:positive])}"

  defp sign_up!(tenant_id, username, password_hash) do
    body =
      Jason.encode!(%{
        "tenant_id" => tenant_id,
        "username" => username,
        "password_hash" => password_hash
      })

    conn =
      :post
      |> conn("/auth/signup", body)
      |> put_req_header("content-type", "application/json")
      |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 200
    :ok
  end

  defp login_conn(tenant_id, username, password_hash) do
    body =
      Jason.encode!(%{
        "tenant_id" => tenant_id,
        "username" => username,
        "password_hash" => password_hash
      })

    :post
    |> conn("/auth/login", body)
    |> put_req_header("content-type", "application/json")
    |> RiptideWeb.Endpoint.call(@opts)
  end

  test "correct credentials return 200 with a usable token" do
    tenant_id = unique_tenant()
    password_hash = String.duplicate("b", 64)
    :ok = sign_up!(tenant_id, "alice", password_hash)

    conn = login_conn(tenant_id, "alice", password_hash)

    assert conn.status == 200
    assert is_binary(Jason.decode!(conn.resp_body)["token"])
  end

  test "wrong password, wrong username, and a nonexistent tenant all return the same 401 shape" do
    tenant_id = unique_tenant()
    password_hash = String.duplicate("b", 64)
    :ok = sign_up!(tenant_id, "alice", password_hash)

    wrong_password = login_conn(tenant_id, "alice", String.duplicate("c", 64))
    wrong_username = login_conn(tenant_id, "nobody", password_hash)
    wrong_tenant = login_conn(unique_tenant(), "alice", password_hash)

    assert wrong_password.status == 401
    assert wrong_username.status == 401
    assert wrong_tenant.status == 401
    assert wrong_password.resp_body == wrong_username.resp_body
    assert wrong_username.resp_body == wrong_tenant.resp_body
  end

  test "login is rate-limited" do
    Riptide.AppEnvTestHelpers.put_env(:riptide, :password_auth_login_rate_limit, 0)

    conn = login_conn(unique_tenant(), "alice", String.duplicate("b", 64))

    assert conn.status == 429
  end
end
