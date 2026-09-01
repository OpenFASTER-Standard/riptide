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
    scope = conn.assigns.scope
    current_subject = conn.assigns.current_subject
    path_segments = Map.get(conn.params, "path") || []
    mode = mode_for(conn.method)

    case Riptide.Authz.evaluate(scope, path_segments, current_subject, mode) do
      :allow -> conn
      :deny -> maybe_bootstrap(conn, scope, current_subject, mode)
    end
  rescue
    _ -> service_unavailable(conn)
  catch
    # Riptide.Authz.evaluate/4 (and claim_tenant_if_unclaimed/2 below) can
    # raise/exit if the placement cluster backing the policy store is fully
    # unreachable (Riptide.Placement's own documented raise-on-total-failure
    # behavior) — every authenticated LDP/policy route goes through this
    # plug, so left uncaught this surfaces as a generic Phoenix 500 with no
    # way for a caller/load-balancer to tell "genuinely forbidden" apart
    # from "transient, back off and retry," the same distinction
    # RiptideWeb.HealthController's /health/ready already makes for this
    # exact failure mode.
    :exit, _ -> service_unavailable(conn)
  end

  # Guards against `current_subject["sub"]` being `nil` (bootstrapping the
  # tenant with an `{:agent, nil}` owner policy that would then match any
  # other subject-less token — see `Riptide.Authz`'s own guard on this same
  # shape). `Riptide.Auth.TokenConfig` requires `sub` on every verified
  # token, so this should not be reachable in practice; kept as defense in
  # depth rather than trusting that invariant to hold from this call site
  # alone.
  defp maybe_bootstrap(conn, {:tenant, tenant_id}, %{"sub" => sub}, :write)
       when not is_nil(sub) do
    store = Application.get_env(:riptide, :authz_store, Riptide.Authz.Store.Placement)

    case store.claim_tenant_if_unclaimed(tenant_id, sub) do
      :claimed -> conn
      :already_claimed -> reject(conn)
    end
  end

  # Covers :hub (never reaches Authorize in practice — no write route exists for it) and any
  # future non-tenant scope; keeps this function total instead of relying on that never happening.
  defp maybe_bootstrap(conn, _scope, _current_subject, _mode), do: reject(conn)

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
