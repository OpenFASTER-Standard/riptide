defmodule RiptideWeb.HealthTest do
  use ExUnit.Case, async: false
  use Plug.Test

  @opts RiptideWeb.Endpoint.init([])

  describe "GET /health/live" do
    test "returns 200 ok unconditionally" do
      conn =
        :get
        |> conn("/health/live")
        |> RiptideWeb.Endpoint.call(@opts)

      assert conn.status == 200
      assert conn.resp_body == "ok"
    end
  end

  describe "GET /health/ready" do
    test "returns 200 ok when the placement cluster is reachable" do
      conn =
        :get
        |> conn("/health/ready")
        |> RiptideWeb.Endpoint.call(@opts)

      assert conn.status == 200
      assert conn.resp_body == "ok"
    end

    # :placement_members_override is global Application state that every
    # other test touching Riptide.Placement also reads — this test module is
    # async: false specifically so this override never races a concurrently-
    # running async test.
    test "returns 503 when the placement cluster is unreachable" do
      original = Application.get_env(:riptide, :placement_members_override)
      Application.put_env(:riptide, :placement_members_override, [:nonexistent@nohost])
      on_exit(fn -> Application.put_env(:riptide, :placement_members_override, original) end)

      conn =
        :get
        |> conn("/health/ready")
        |> RiptideWeb.Endpoint.call(@opts)

      assert conn.status == 503
    end
  end
end
