defmodule Riptide.Auth.JwksStrategy do
  @moduledoc """
  `JokenJwks.DefaultStrategyTemplate` instance backing `Riptide.Auth.TokenConfig`
  — fetches and caches signers from the configured OIDC provider's JWKS
  endpoint, re-fetching on a time window whenever an unrecognized `kid` is
  seen (the template's own built-in behavior). Runs on every node that can
  serve a request (see `Riptide.Application`), not gated to the 3 placement
  ordinals the way `Riptide.Stream.ReplicaHealer` is: fetching a public JWKS
  document is a side-effect-free GET, so unlike replica repair there's no
  need for single-leader coordination — every node just fetches and caches
  independently.
  """
  use JokenJwks.DefaultStrategyTemplate

  # Without an explicit timeout, `Tesla.Adapter.Httpc` (this project's
  # configured adapter — see config/config.exs) defaults `:httpc`'s own
  # `timeout`/`connect_timeout` to `:infinity`. `fetch_signers/2` runs
  # synchronously inside this GenServer's own `handle_info(:check_fetch, ...)`
  # callback, and the NEXT check is only scheduled after that call returns —
  # so a JWKS endpoint that accepts the TCP connection but never responds (a
  # flaky or attacker-influenced IdP) would otherwise wedge this process
  # forever: no future re-fetch ever fires, and any JWT with a new/rotated
  # `kid` becomes permanently unverifiable on this node until it restarts.
  @http_timeout_ms 5_000

  def init_opts(opts) do
    opts
    |> Keyword.put_new(:jwks_url, Application.get_env(:riptide, :oidc_jwks_url))
    |> Keyword.put_new(:http_middlewares, [
      {Tesla.Middleware.Timeout, timeout: @http_timeout_ms}
    ])
  end
end
