defmodule RiptideWeb.CORSTest do
  use ExUnit.Case, async: false
  use Plug.Test

  @opts RiptideWeb.Endpoint.init([])

  test "a normal response includes Access-Control-Allow-Origin" do
    conn =
      :get
      |> conn("/health/live")
      |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 200
    assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
  end

  test "an OPTIONS preflight to an LDP route is answered without reaching the router" do
    # The tenant_id here is deliberately nonexistent/never seeded — proving this
    # succeeds proves the CORS plug halts the response before tenant resolution,
    # auth, or authorization ever run.
    conn =
      :options
      |> conn("/tenants/cors-test-nonexistent-tenant/resources/foo")
      |> put_req_header("access-control-request-method", "PUT")
      |> put_req_header("origin", "https://example.com")
      |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 204
    assert get_resp_header(conn, "access-control-allow-origin") == ["*"]

    assert get_resp_header(conn, "access-control-allow-methods") == [
             "GET,PUT,PATCH,DELETE,POST,OPTIONS"
           ]

    assert get_resp_header(conn, "access-control-allow-headers") == [
             "Authorization,Content-Type,Last-Event-ID"
           ]

    assert get_resp_header(conn, "access-control-max-age") != []
  end

  test "a plain OPTIONS request with no CORS preflight header falls through to the router unaffected" do
    conn =
      :options
      |> conn("/health/live")
      |> RiptideWeb.Endpoint.call(@opts)

    # No route defines OPTIONS — this proves the CORS plug leaves a genuine
    # (non-preflight) OPTIONS request alone rather than swallowing it.
    assert conn.status == 404
  end
end
