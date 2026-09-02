defmodule Riptide.WriteRateLimit do
  @moduledoc """
  Per-tenant write throttle — renamed from `Riptide.HubRateLimit.check_propose/1`, which was already
  the general per-tenant write quota for this whole area of the app (reused by `TenantProposeController`
  and `TaskController` well before this rename, not actually Hub-specific logic) — see design spec
  `docs/superpowers/specs/2026-09-02-phase-6q-tenant-sovereignty-design.md` §4.6.
  """

  use Hammer, backend: :ets, algorithm: :fix_window_per_key

  @default_limit 10
  @default_scale_ms :timer.minutes(1)

  @spec check(String.t()) :: :allow | :deny
  def check(tenant_id) do
    limit = Application.get_env(:riptide, :write_rate_limit, @default_limit)
    scale_ms = Application.get_env(:riptide, :write_rate_scale_ms, @default_scale_ms)

    case hit("write:#{tenant_id}", scale_ms, limit) do
      {:allow, _count} -> :allow
      {:deny, _retry_after} -> :deny
    end
  end
end
