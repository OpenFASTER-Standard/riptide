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

  @impl true
  def init_opts(opts) do
    Keyword.put_new(opts, :jwks_url, Application.get_env(:riptide, :oidc_jwks_url))
  end
end
