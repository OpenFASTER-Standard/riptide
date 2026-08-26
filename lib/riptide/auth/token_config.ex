defmodule Riptide.Auth.TokenConfig do
  @moduledoc """
  `Joken.Config` token configuration backing `Riptide.Auth.Verifier.OIDC`:
  signature verification via `Riptide.Auth.JwksStrategy` (a `JokenJwks` hook),
  plus `exp` (from Joken's own generated defaults) and `iss`/`aud` claim
  checks against `Application.get_env(:riptide, :oidc_issuer/:oidc_audience)`.

  Kept as a separate module from `Riptide.Auth.Verifier.OIDC` rather than
  having the latter itself `use Joken.Config`: that macro generates its own
  `verify/1` (a default-argument shortcut for its generated `verify/2`),
  which would silently collide with — and only partially satisfy — the
  `Riptide.Auth.Verifier` behaviour's own `verify/1` callback (Joken's
  generated `verify/1` only checks the signature, not `exp`/`iss`/`aud`;
  `Riptide.Auth.Verifier.OIDC.verify/1` needs to do both). Delegating to this
  separate module's `verify_and_validate/1` avoids the name clash entirely.

  `iss`/`aud` are read from `Application` config inside the validate
  functions themselves (called at verification time, not compiled in), so
  different deployments/tests can configure a different expected
  issuer/audience without recompiling.
  """
  use Joken.Config

  add_hook(JokenJwks, strategy: Riptide.Auth.JwksStrategy)

  @impl Joken.Config
  def token_config do
    default_claims(skip: [:iss, :aud])
    |> add_claim("iss", nil, &valid_issuer?/1)
    |> add_claim("aud", nil, &valid_audience?/1)
  end

  defp valid_issuer?(iss), do: iss == Application.get_env(:riptide, :oidc_issuer)

  defp valid_audience?(aud) do
    expected = Application.get_env(:riptide, :oidc_audience)
    aud == expected or (is_list(aud) and expected in aud)
  end
end
