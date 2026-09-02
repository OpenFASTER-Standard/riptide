defmodule RiptideWeb.Plugs.AuthorizeTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias RiptideWeb.Plugs.Authorize

  defmodule FakeStore do
    @behaviour Riptide.Authz.Store

    @impl true
    def list_policies("acme", []),
      do: [%Riptide.Authz.Policy{effect: :allow, modes: [:read], matcher: :public}]

    def list_policies(_tenant_id, _path_prefix), do: []

    @impl true
    def add_policy(_tenant_id, _path_prefix, _policy), do: :ok
  end

  setup do
    Riptide.AppEnvTestHelpers.put_env(:riptide, :authz_store, FakeStore)
    :ok
  end

  defp conn_for(method, tenant_id, path_segments, current_subject) do
    method
    |> conn("/tenants/#{tenant_id}/resources/" <> Enum.join(path_segments, "/"))
    |> Map.update!(:params, &Map.put(&1, "path", path_segments))
    |> assign(:tenant_id, tenant_id)
    |> assign(:scope, {:tenant, tenant_id})
    |> assign(:current_subject, current_subject)
  end

  test "allows a GET matching a public policy, for an anonymous request" do
    conn =
      :get
      |> conn_for("acme", ["docs"], nil)
      |> Authorize.call(Authorize.init([]))

    refute conn.halted
  end

  test "denies a POST/PUT/PATCH/DELETE with no matching write policy" do
    for method <- [:post, :put, :patch, :delete] do
      conn =
        method
        |> conn_for("acme", ["docs"], %{"sub" => "someone"})
        |> Authorize.call(Authorize.init([]))

      assert conn.halted
      assert conn.status == 403
    end
  end

  test "denies a GET with no matching policy at all" do
    conn =
      :get
      |> conn_for("no-such-tenant", ["docs"], nil)
      |> Authorize.call(Authorize.init([]))

    assert conn.halted
    assert conn.status == 403
  end

  test "an authenticated write with no matching policy is denied — no bootstrap fallback" do
    conn =
      :put
      |> conn_for("no-such-tenant", ["docs"], %{"sub" => "user-1"})
      |> Authorize.call(Authorize.init([]))

    assert conn.halted
    assert conn.status == 403
  end

  test "an authenticated write to an already-claimed tenant with no matching policy is denied" do
    conn =
      :put
      |> conn_for("already-claimed-tenant", ["docs"], %{"sub" => "someone"})
      |> Authorize.call(Authorize.init([]))

    assert conn.halted
    assert conn.status == 403
  end
end
