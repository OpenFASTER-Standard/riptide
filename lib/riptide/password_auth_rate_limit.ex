defmodule Riptide.PasswordAuthRateLimit do
  @moduledoc """
  Rate-limits `POST /auth/signup`/`POST /auth/login` (design spec
  `docs/superpowers/specs/2026-09-01-phase-6o-username-password-auth-design.md`
  §4.6) — mirrors `Riptide.HubRateLimit`'s exact shape (`Hammer`,
  `:fix_window_per_key`, same window-boundary-undercounting reasoning).
  Both routes are deliberately anonymous (no subject exists yet at this
  point in the request, by definition), so both limiters are keyed by
  caller IP, never a tenant_id or username (either of which is free to
  mint and would make the limit trivially bypassable).

  Two independent limiters: `check_login/1` gets the tighter default (brute-
  force protection against a known account); `check_signup/1`'s own limit
  exists primarily against automated account-creation spam.
  """

  use Hammer, backend: :ets, algorithm: :fix_window_per_key

  @default_signup_limit 10
  @default_signup_scale_ms :timer.minutes(1)
  @default_login_limit 20
  @default_login_scale_ms :timer.minutes(1)

  @spec check_signup(String.t()) :: :allow | :deny
  def check_signup(ip) do
    limit = Application.get_env(:riptide, :password_auth_signup_rate_limit, @default_signup_limit)

    scale_ms =
      Application.get_env(
        :riptide,
        :password_auth_signup_rate_scale_ms,
        @default_signup_scale_ms
      )

    case hit("password_auth_signup:#{ip}", scale_ms, limit) do
      {:allow, _count} -> :allow
      {:deny, _retry_after} -> :deny
    end
  end

  @spec check_login(String.t()) :: :allow | :deny
  def check_login(ip) do
    limit = Application.get_env(:riptide, :password_auth_login_rate_limit, @default_login_limit)

    scale_ms =
      Application.get_env(:riptide, :password_auth_login_rate_scale_ms, @default_login_scale_ms)

    case hit("password_auth_login:#{ip}", scale_ms, limit) do
      {:allow, _count} -> :allow
      {:deny, _retry_after} -> :deny
    end
  end
end
