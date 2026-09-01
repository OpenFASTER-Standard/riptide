defmodule RiptideWeb.Plugs.ResolveHubScopeTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias RiptideWeb.Plugs.ResolveHubScope

  test "assigns conn.assigns.scope = :hub unconditionally" do
    conn = conn(:get, "/hub/resources/catalog")
    conn = ResolveHubScope.call(conn, ResolveHubScope.init([]))

    assert conn.assigns.scope == :hub
  end
end
