defmodule Riptide.Auth.Verifier.Password do
  @moduledoc """
  `Riptide.Auth.Verifier` implementation for Riptide's own self-issued
  username/password JWTs — mirrors `Riptide.Auth.Verifier.OIDC`'s exact
  shape, delegating to `Riptide.Auth.PasswordTokenConfig` instead of
  `Riptide.Auth.TokenConfig`.
  """
  @behaviour Riptide.Auth.Verifier

  alias Riptide.Auth.PasswordTokenConfig

  @impl true
  def verify(token) when is_binary(token) do
    PasswordTokenConfig.verify_and_validate_required_claims(token)
  rescue
    error -> {:error, error}
  end
end
