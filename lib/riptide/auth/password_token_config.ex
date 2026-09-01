defmodule Riptide.Auth.PasswordTokenConfig do
  @moduledoc """
  `Joken.Config` token configuration for Riptide's own self-issued
  username/password JWTs (design spec
  `docs/superpowers/specs/2026-09-01-phase-6o-username-password-auth-design.md`
  §4.5) — mirrors `Riptide.Auth.TokenConfig`'s own shape, but signs and
  verifies against a single shared secret (`Application.fetch_env!(:riptide,
  :password_auth_signing_key)`) rather than fetching a signer from an
  external JWKS endpoint: there is no external party for a self-issued token,
  so the signer and verifier are always the same deployment.

  `iss`/`aud` are fixed, self-referential literals (not app-config-driven
  the way OIDC's are) — there is no external issuer to match against, only
  "did this Riptide instance itself issue this token."
  """
  use Joken.Config

  @issuer "riptide-password-auth"
  @audience "riptide-password-auth"
  @required_claims ~w(exp iss aud sub)

  @impl Joken.Config
  def token_config do
    default_claims(skip: [:iss, :aud])
    |> add_claim("iss", fn -> @issuer end, &(&1 == @issuer))
    |> add_claim("aud", fn -> @audience end, &(&1 == @audience))
  end

  @spec sign(String.t()) :: {:ok, String.t()} | {:error, term()}
  def sign(sub) when is_binary(sub) do
    case generate_and_sign(%{"sub" => sub}, signer()) do
      {:ok, token, _claims} -> {:ok, token}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Same as the generated `verify_and_validate/2`, plus an explicit
  present-and-non-null check for `exp`/`iss`/`aud`/`sub` — mirrors
  `Riptide.Auth.TokenConfig.verify_and_validate_required_claims/1`'s own
  reasoning exactly (a validly-signed token that simply omits one of these
  would otherwise skip that claim's check entirely).
  """
  @spec verify_and_validate_required_claims(Joken.bearer_token()) ::
          {:ok, Joken.claims()} | {:error, Joken.error_reason()}
  def verify_and_validate_required_claims(bearer_token) do
    with {:ok, claims} <- verify_and_validate(bearer_token, signer()) do
      require_claims(claims)
    end
  end

  defp require_claims(claims) do
    case Enum.filter(@required_claims, &is_nil(Map.get(claims, &1))) do
      [] -> {:ok, claims}
      missing -> {:error, {:missing_claims, missing}}
    end
  end

  defp signer do
    Joken.Signer.create("HS256", Application.fetch_env!(:riptide, :password_auth_signing_key))
  end
end
