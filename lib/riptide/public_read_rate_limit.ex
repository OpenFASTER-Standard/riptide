defmodule Riptide.PublicReadRateLimit do
  @moduledoc """
  Subject/IP-keyed abuse protection for reads that resolve via a `:public` Authz policy match rather
  than tenant ownership — the direct successor to `Riptide.HubRateLimit.check_read/1`, retargeted from
  "this request hit `:hub` scope" to "this request's Authz decision matched a `:public` policy," since
  `:hub` no longer exists as a distinct scope (design spec
  `docs/superpowers/specs/2026-09-02-phase-6q-tenant-sovereignty-design.md` §4.6). Ordinary
  tenant-owned reads (matched via `{:agent, subject}`/`:authenticated`) never hit this limiter, exactly
  as they never hit `HubRateLimit` before.
  """

  use Hammer, backend: :ets, algorithm: :fix_window_per_key

  @default_limit 60
  @default_scale_ms :timer.minutes(1)

  @spec check(String.t()) :: :allow | :deny
  def check(subject_or_ip) do
    limit = Application.get_env(:riptide, :public_read_rate_limit, @default_limit)
    scale_ms = Application.get_env(:riptide, :public_read_rate_scale_ms, @default_scale_ms)

    case hit("public_read:#{subject_or_ip}", scale_ms, limit) do
      {:allow, _count} -> :allow
      {:deny, _retry_after} -> :deny
    end
  end
end
