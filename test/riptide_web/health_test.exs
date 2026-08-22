defmodule RiptideWeb.HealthTest do
  use ExUnit.Case, async: true
  use Plug.Test

  @opts RiptideWeb.Endpoint.init([])

  test "GET /health returns 200 ok" do
    conn =
      :get
      |> conn("/health")
      |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 200
    assert conn.resp_body == "ok"
  end
end
