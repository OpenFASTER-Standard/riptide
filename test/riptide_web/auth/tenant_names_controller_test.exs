defmodule RiptideWeb.Auth.TenantNamesControllerTest do
  use ExUnit.Case, async: false
  import Plug.Test

  @opts RiptideWeb.Endpoint.init([])

  defp unique_name, do: "tenant-names-" <> Uniq.UUID.uuid4()

  test "resolves a claimed name to its tenant_id" do
    name = unique_name()
    :claimed = Riptide.Placement.claim_name(name, "some-tenant-uuid")

    conn = :get |> conn("/tenant-names/#{name}") |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"tenant_id" => "some-tenant-uuid"}
  end

  test "a name that was never claimed returns 404" do
    conn = :get |> conn("/tenant-names/#{unique_name()}") |> RiptideWeb.Endpoint.call(@opts)
    assert conn.status == 404
  end
end
