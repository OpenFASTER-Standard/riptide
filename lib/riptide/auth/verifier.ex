defmodule Riptide.Auth.Verifier do
  @moduledoc """
  Behaviour for verifying a bearer token and returning its claims. Selected
  via `Application.get_env(:riptide, :auth_verifier, Riptide.Auth.Verifier.OIDC)`
  — the same config-driven swap `Riptide.Tenancy.Resolver` (Phase 4a) and
  `Riptide.RaCluster.default_ordinal_resolver/1` (Phase 3c-i) already use, so
  a different identity mechanism (API keys, WebID-OIDC) can replace this one
  later without touching the pipeline that consumes it.
  """

  @callback verify(token :: String.t()) :: {:ok, claims :: map()} | {:error, term()}
end
