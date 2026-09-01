defmodule RiptideWeb.Plugs.ResolveHubScope do
  @moduledoc """
  Assigns `conn.assigns.scope = :hub` for the `/hub/resources/*path` read route — the Hub-side
  counterpart to `RiptideWeb.Plugs.ResolveTenant` assigning `{:tenant, tenant_id}`. No route param to
  resolve; this plug exists purely so `Authorize`/`RiptideWeb.LDP.ResourceController` see the same
  `conn.assigns.scope` shape regardless of which scope a request is for (design spec
  `docs/superpowers/specs/2026-09-01-phase-6n-hub-resource-lifecycle-design.md` §4.2).
  """
  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts), do: assign(conn, :scope, :hub)
end
