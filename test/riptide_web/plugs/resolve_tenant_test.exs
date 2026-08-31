defmodule RiptideWeb.Plugs.ResolveTenantTest do
  use ExUnit.Case, async: false
  import Plug.Test

  alias RiptideWeb.Plugs.ResolveTenant

  setup do
    Riptide.AppEnvTestHelpers.ensure_restored(:riptide, :tenancy_resolver)
    :ok
  end

  test "assigns tenant_id on success, using the default PathSegment resolver" do
    conn =
      %{conn(:get, "/tenants/acme/resources/foo") | params: %{"tenant_id" => "acme"}}
      |> ResolveTenant.call(ResolveTenant.init([]))

    assert conn.assigns.tenant_id == "acme"
    refute conn.halted
  end

  test "halts with 400 when no tenant_id can be resolved" do
    conn =
      :get
      |> conn("/resources/foo")
      |> ResolveTenant.call(ResolveTenant.init([]))

    assert conn.halted
    assert conn.status == 400
  end

  test "uses whichever resolver is configured, not always PathSegment" do
    Application.put_env(:riptide, :tenancy_resolver, Riptide.Tenancy.Resolver.Subdomain)

    conn =
      %{conn(:get, "/resources/foo") | host: "acme.riptide.example"}
      |> ResolveTenant.call(ResolveTenant.init([]))

    assert conn.assigns.tenant_id == "acme"
    refute conn.halted
  end

  test "halts with 400 when a resolved tenant_id contains a literal slash" do
    # Simulates what a resolver would hand back once a `%2F`-encoded slash
    # in the raw request path has already been decoded by Phoenix's router
    # (see the moduledoc) — the plug must reject this rather than assign it,
    # since an unrejected slash would let this tenant_id's stream_id string
    # collide with a different, legitimate tenant's.
    conn =
      %{conn(:get, "/tenants/a/resources/foo") | params: %{"tenant_id" => "a/resources/foo"}}
      |> ResolveTenant.call(ResolveTenant.init([]))

    assert conn.halted
    assert conn.status == 400
    refute Map.has_key?(conn.assigns, :tenant_id)
  end

  test "sets tenant_id in Logger metadata on success" do
    %{conn(:get, "/tenants/acme/resources/foo") | params: %{"tenant_id" => "acme"}}
    |> ResolveTenant.call(ResolveTenant.init([]))

    assert Logger.metadata()[:tenant_id] == "acme"
  end
end
