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

  defp unique_name, do: "signupctl-name-#{System.unique_integer([:positive])}"

  defp signup_body(overrides \\ %{}) do
    Jason.encode!(
      Map.merge(
        %{
          "name" => unique_name(),
          "username" => "alice",
          "password_hash" => String.duplicate("a", 64)
        },
        overrides
      )
    )
  end

  test "valid signup returns 200 with a usable token, sub, and a freshly-minted tenant_id" do
    conn =
      :post
      |> conn("/auth/signup", signup_body())
      |> put_req_header("content-type", "application/json")
      |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert is_binary(body["token"])
    assert is_binary(body["sub"])
    assert is_binary(body["tenant_id"])
  end

  test "signing up against an already-claimed name returns 409" do
    name = unique_name()
    body = signup_body(%{"name" => name})

    first_conn =
      :post
      |> conn("/auth/signup", body)
      |> put_req_header("content-type", "application/json")
      |> RiptideWeb.Endpoint.call(@opts)

    assert first_conn.status == 200

    second_conn =
      :post
      |> conn("/auth/signup", signup_body(%{"name" => name, "username" => "mallory"}))
      |> put_req_header("content-type", "application/json")
      |> RiptideWeb.Endpoint.call(@opts)

    assert second_conn.status == 409
  end

  test "a name containing '/' returns 400 without claiming anything" do
    conn =
      :post
      |> conn("/auth/signup", signup_body(%{"name" => "has/slash"}))
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
