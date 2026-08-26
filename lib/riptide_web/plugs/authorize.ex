defmodule RiptideWeb.Plugs.Authorize do
  @moduledoc """
  Enforces `Riptide.Authz.evaluate/4`'s decision on every tenant-scoped LDP
  route — mirrors `RiptideWeb.Plugs.ResolveTenant`/`Authenticate`'s shape.
  Halts with `403` on deny.

  On an otherwise-denied *authenticated write*, first checks whether the
  tenant is still unclaimed (see the Phase 4c design spec §6):
  `Riptide.Authz.Store.claim_tenant_if_unclaimed/2` is a single atomic Ra
  command, not a separate check-then-add pair of calls, so a race between
  two different agents both attempting to be "first write" to the same
  brand-new tenant resolves to exactly one owner. Anonymous requests and
  reads never reach this path — they're just denied.
  """
  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    tenant_id = conn.assigns.tenant_id
    current_subject = conn.assigns.current_subject
    path_segments = Map.get(conn.params, "path") || []
    mode = mode_for(conn.method)

    case Riptide.Authz.evaluate(tenant_id, path_segments, current_subject, mode) do
      :allow -> conn
      :deny -> maybe_bootstrap(conn, tenant_id, current_subject, mode)
    end
  end

  defp maybe_bootstrap(conn, tenant_id, current_subject, :write)
       when not is_nil(current_subject) do
    store = Application.get_env(:riptide, :authz_store, Riptide.Authz.Store.Placement)

    case store.claim_tenant_if_unclaimed(tenant_id, current_subject["sub"]) do
      :claimed -> conn
      :already_claimed -> reject(conn)
    end
  end

  defp maybe_bootstrap(conn, _tenant_id, _current_subject, _mode), do: reject(conn)

  defp mode_for("GET"), do: :read
  defp mode_for(_other), do: :write

  defp reject(conn) do
    conn
    |> send_resp(403, "")
    |> halt()
  end
end
