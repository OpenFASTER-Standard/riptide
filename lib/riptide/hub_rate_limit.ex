defmodule Riptide.HubRateLimit do
  @moduledoc """
  Rate-limits the Pattern Hub's network-public surface (design spec
  `docs/superpowers/specs/2026-08-29-phase-6h-i-pattern-hub-threat-model-design.md`
  T1/T2/T10; `docs/superpowers/specs/2026-08-29-phase-6h-ii-pattern-hub-deployment-design.md`
  §4). Mirrors `Riptide.NewStreamRateLimit`'s exact shape — same
  `:fix_window_per_key` algorithm, for the same reason (the default
  `:fix_window` anchors every key to the same wall-clock boundary,
  under-counting a burst that straddles it).

  Two independent limiters: `check_read/1` for Hub Discovery/entry-fetch
  (keyed by authenticated subject when present, else caller IP — never
  `tenant_id`, which is free to mint); `check_propose/1` for
  propose-to-Hub (keyed by the proposing Tenant's own id — a per-tenant
  quota, not a shared cross-tenant one, since each Tenant reviews only
  its own queue).
  """

  use Hammer, backend: :ets, algorithm: :fix_window_per_key

  @default_read_limit 60
  @default_read_scale_ms :timer.minutes(1)
  @default_propose_limit 10
  @default_propose_scale_ms :timer.minutes(1)

  @spec check_read(String.t()) :: :allow | :deny
  def check_read(subject_or_ip) do
    limit = Application.get_env(:riptide, :hub_read_rate_limit, @default_read_limit)
    scale_ms = Application.get_env(:riptide, :hub_read_rate_scale_ms, @default_read_scale_ms)

    case hit("hub_read:#{subject_or_ip}", scale_ms, limit) do
      {:allow, _count} -> :allow
      {:deny, _retry_after} -> :deny
    end
  end

  @spec check_propose(String.t()) :: :allow | :deny
  def check_propose(tenant_id) do
    limit = Application.get_env(:riptide, :hub_propose_rate_limit, @default_propose_limit)

    scale_ms =
      Application.get_env(:riptide, :hub_propose_rate_scale_ms, @default_propose_scale_ms)

    case hit("hub_propose:#{tenant_id}", scale_ms, limit) do
      {:allow, _count} -> :allow
      {:deny, _retry_after} -> :deny
    end
  end
end
