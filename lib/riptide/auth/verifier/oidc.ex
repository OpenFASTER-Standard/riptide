defmodule Riptide.Auth.Verifier.OIDC do
  @moduledoc """
  Standard OIDC/JWT `Riptide.Auth.Verifier` implementation: verifies a
  token's signature against the configured provider's JWKS endpoint and its
  `exp`/`iss`/`aud` claims, via `Riptide.Auth.TokenConfig`. This is the
  configured default (`Application.get_env(:riptide, :auth_verifier,
  Riptide.Auth.Verifier.OIDC)`) but any module implementing
  `Riptide.Auth.Verifier` can replace it.
  """
  @behaviour Riptide.Auth.Verifier

  alias Riptide.Auth.TokenConfig

  @impl true
  def verify(token) when is_binary(token) do
    TokenConfig.verify_and_validate_required_claims(token)
  rescue
    error -> {:error, error}
  end
end
