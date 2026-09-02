defmodule RiptideWeb.Plugs.Authorize do
  @moduledoc """
  Enforces `Riptide.Authz.evaluate/4`'s decision on every tenant-scoped LDP route — mirrors
  `RiptideWeb.Plugs.ResolveTenant`/`Authenticate`'s shape. Halts with `403` on deny.

  There is no bootstrap-on-first-write fallback (removed in Phase 6q, design spec
  `docs/superpowers/specs/2026-09-02-phase-6q-tenant-sovereignty-design.md` §4.4): `tenant_id` is now
  an opaque, self-generated UUID nobody could ever guess or write to before it exists — a tenant only
  ever comes into being via the explicit `Riptide.Accounts.sign_up/3` sequence, so there is no
  "unclaimed tenant someone stumbles onto" case left to handle here.
  """
  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    scope = conn.assigns.scope
    current_subject = conn.assigns.current_subject
    path_segments = Map.get(conn.params, "path") || []
    mode = mode_for(conn.method)

    case Riptide.Authz.evaluate(scope, path_segments, current_subject, mode) do
      :allow -> conn
      :deny -> reject(conn)
    end
  rescue
    _ -> service_unavailable(conn)
  catch
    # Riptide.Authz.evaluate/4 can raise/exit if the placement cluster backing the policy store is
    # fully unreachable (Riptide.Placement's own documented raise-on-total-failure behavior) — every
    # authenticated LDP/policy route goes through this plug, so left uncaught this surfaces as a
    # generic Phoenix 500 with no way for a caller/load-balancer to tell "genuinely forbidden" apart
    # from "transient, back off and retry," the same distinction RiptideWeb.HealthController's
    # /health/ready already makes for this exact failure mode.
    :exit, _ -> service_unavailable(conn)
  end

  defp mode_for("GET"), do: :read
  defp mode_for(_other), do: :write

  defp reject(conn) do
    conn
    |> send_resp(403, "")
    |> halt()
  end

  defp service_unavailable(conn) do
    conn
    |> send_resp(503, "")
    |> halt()
  end
end
