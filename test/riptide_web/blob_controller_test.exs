defmodule RiptideWeb.BlobControllerTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

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

  defp tenant_id, do: "blob-http-test-" <> Uniq.UUID.uuid4()

  test "PUT then GET round-trips the exact bytes" do
    tenant_id = tenant_id()
    bytes = :crypto.strong_rand_bytes(2048)

    put_conn =
      :put
      |> conn("/tenants/#{tenant_id}/blobs", bytes)
      |> put_req_header("content-type", "application/octet-stream")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert put_conn.status == 200
    assert %{"hash" => hash} = Jason.decode!(put_conn.resp_body)

    get_conn =
      :get
      |> conn("/tenants/#{tenant_id}/blobs/#{hash}")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert get_conn.status == 200
    assert get_conn.resp_body == bytes
  end

  test "GET for an unknown hash returns 404" do
    conn =
      :get
      |> conn("/tenants/#{tenant_id()}/blobs/#{String.duplicate("0", 64)}")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 404
  end

  test "PUT without a valid token is rejected" do
    conn =
      :put
      |> conn("/tenants/#{tenant_id()}/blobs", "some bytes")
      |> put_req_header("content-type", "application/octet-stream")
      |> put_req_header("authorization", "Bearer not-a-real-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 401
  end

  test "PUT without any Authorization header is rejected" do
    conn =
      :put
      |> conn("/tenants/#{tenant_id()}/blobs", "some bytes")
      |> put_req_header("content-type", "application/octet-stream")
      |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 401
  end

  test "GET without any Authorization header is rejected" do
    conn =
      :get
      |> conn("/tenants/#{tenant_id()}/blobs/#{String.duplicate("0", 64)}")
      |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 401
  end

  test "PUT with large body over 8MB round-trips correctly" do
    tenant_id = tenant_id()
    bytes = :crypto.strong_rand_bytes(9 * 1024 * 1024)

    put_conn =
      :put
      |> conn("/tenants/#{tenant_id}/blobs", bytes)
      |> put_req_header("content-type", "application/octet-stream")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert put_conn.status == 200
    assert %{"hash" => hash} = Jason.decode!(put_conn.resp_body)

    get_conn =
      :get
      |> conn("/tenants/#{tenant_id}/blobs/#{hash}")
      |> put_req_header("authorization", "Bearer owner-token")
      |> RiptideWeb.Endpoint.call(@opts)

    assert get_conn.status == 200
    assert get_conn.resp_body == bytes
  end
end
