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
  separate module's `verify_and_validate_required_claims/1` avoids the name
  clash entirely.

  `iss`/`aud` are read from `Application` config inside the validate
  functions themselves (called at verification time, not compiled in), so
  different deployments/tests can configure a different expected
  issuer/audience without recompiling.

  ## Required claims

  Joken's own validation loop (`Joken.reduce_validations/3`) iterates over
  the *token's own* decoded claims and only runs a claim's validator when
  that claim is actually present — it never enforces that a configured
  claim key show up in the token at all. Left alone, this means a validly
  signed token that simply omits `exp`, `iss`, or `aud` would skip that
  claim's check entirely and be accepted. `verify_and_validate_required_claims/1`
  closes that gap by requiring all three to be present *and non-null*, on
  top of whatever `verify_and_validate/1` (Joken.Config's own generated
  function) already checks for claims that are present.

  The non-null part matters on its own: a token with an explicit `"exp":
  null` (present, not omitted) still passes Joken's own default `exp`
  validator (`&(&1 > current_time())`) — `nil > <integer>` evaluates `true`
  under Erlang/Elixir term ordering (atoms sort above numbers), so a null
  `exp` reads as "never expires" instead of failing outright. `iss`/`aud`'s
  own validators here are equality/membership checks, so a null value
  already fails those correctly (`nil == "some-issuer"` is `false`) — `exp`
  is the only one of the three with this specific gap, but the presence
  check below treats all three claims uniformly (require present and
  non-null) rather than special-casing just `exp`.
  """
  use Joken.Config

  add_hook(JokenJwks, strategy: Riptide.Auth.JwksStrategy)

  @required_claims ~w(exp iss aud)

  @impl Joken.Config
  def token_config do
    default_claims(skip: [:iss, :aud])
    |> add_claim("iss", nil, &valid_issuer?/1)
    |> add_claim("aud", nil, &valid_audience?/1)
  end

  @doc """
  Same as the generated `verify_and_validate/1`, plus an explicit
  present-and-non-null check for `exp`/`iss`/`aud` — see the "Required
  claims" section above for why that check can't just live inside
  `token_config/0`'s claim validators.
  """
  @spec verify_and_validate_required_claims(Joken.bearer_token()) ::
          {:ok, Joken.claims()} | {:error, Joken.error_reason()}
  def verify_and_validate_required_claims(bearer_token) do
    with {:ok, claims} <- verify_and_validate(bearer_token) do
      require_claims(claims)
    end
  end

  defp require_claims(claims) do
    case Enum.filter(@required_claims, &is_nil(Map.get(claims, &1))) do
      [] -> {:ok, claims}
      missing -> {:error, {:missing_claims, missing}}
    end
  end

  defp valid_issuer?(iss), do: iss == Application.get_env(:riptide, :oidc_issuer)

  defp valid_audience?(aud) do
    expected = Application.get_env(:riptide, :oidc_audience)
    aud == expected or (is_list(aud) and expected in aud)
  end
end
