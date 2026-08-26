defmodule RiptideWeb.Plugs.AuthorizeTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias RiptideWeb.Plugs.Authorize

  defmodule FakeStore do
    @behaviour Riptide.Authz.Store

    @impl true
    def list_policies("acme", []),
      do: [%Riptide.Authz.Policy{effect: :allow, modes: [:read], matcher: :public}]

    def list_policies(_tenant_id, _path_prefix), do: []

    @impl true
    def add_policy(_tenant_id, _path_prefix, _policy), do: :ok

    @impl true
    def claim_tenant_if_unclaimed("unclaimed-tenant", _subject), do: :claimed
    def claim_tenant_if_unclaimed(_tenant_id, _subject), do: :already_claimed
  end

  setup do
    original = Application.get_env(:riptide, :authz_store)
    Application.put_env(:riptide, :authz_store, FakeStore)

    on_exit(fn ->
      # `Application.put_env(key, nil)` leaves the key present with value
      # `nil`, which is NOT equivalent to the key being absent:
      # `Application.get_env(:riptide, :authz_store, SomeDefault)`'s default
      # only applies when the key is entirely unset, so if `original` here
      # is `nil` (as it always is in this suite — nothing configures
      # `:authz_store` anywhere), restoring via `put_env` would permanently
      # poison it to `nil` for the rest of the same `mix test` run instead
      # of restoring the "absent, fall back to the real default" state.
      if is_nil(original) do
        Application.delete_env(:riptide, :authz_store)
      else
        Application.put_env(:riptide, :authz_store, original)
      end
    end)

    :ok
  end

  defp conn_for(method, tenant_id, path_segments, current_subject) do
    method
    |> conn("/tenants/#{tenant_id}/resources/" <> Enum.join(path_segments, "/"))
    |> Map.update!(:params, &Map.put(&1, "path", path_segments))
    |> assign(:tenant_id, tenant_id)
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

  test "an authenticated write to an unclaimed tenant bootstraps ownership and is allowed" do
    conn =
      :put
      |> conn_for("unclaimed-tenant", ["docs"], %{"sub" => "user-1"})
      |> Authorize.call(Authorize.init([]))

    refute conn.halted
  end

  test "an anonymous write to an unclaimed tenant is denied, not treated as a claim attempt" do
    conn =
      :put
      |> conn_for("unclaimed-tenant", ["docs"], nil)
      |> Authorize.call(Authorize.init([]))

    assert conn.halted
    assert conn.status == 403
  end

  test "a read (never a write) never bootstraps ownership even when authenticated" do
    conn =
      :get
      |> conn_for("unclaimed-tenant", ["docs"], %{"sub" => "user-1"})
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
