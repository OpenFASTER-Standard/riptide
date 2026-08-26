defmodule Riptide.Auth.Verifier.OIDCTest do
  use ExUnit.Case, async: false

  alias Riptide.Auth.{JwksStrategy, Verifier}

  @kid "test-signing-key"
  @issuer "https://issuer.test.example"
  @audience "riptide-test-audience"

  setup do
    original_issuer = Application.get_env(:riptide, :oidc_issuer)
    original_audience = Application.get_env(:riptide, :oidc_audience)
    Application.put_env(:riptide, :oidc_issuer, @issuer)
    Application.put_env(:riptide, :oidc_audience, @audience)

    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    {_, public_jwk_map} = JOSE.JWK.to_public_map(jwk)
    signer = Joken.Signer.create("RS256", jwk_map(jwk), %{"kid" => @kid})

    jwks_body = %{
      "keys" => [Map.merge(public_jwk_map, %{"kid" => @kid, "use" => "sig", "alg" => "RS256"})]
    }

    Tesla.Mock.mock_global(fn
      %{method: :get, url: "https://issuer.test.example/jwks"} ->
        Tesla.Mock.json(jwks_body)
    end)

    start_supervised!(
      {JwksStrategy,
       jwks_url: "https://issuer.test.example/jwks",
       http_adapter: Tesla.Mock,
       first_fetch_sync: true}
    )

    on_exit(fn ->
      Application.put_env(:riptide, :oidc_issuer, original_issuer)
      Application.put_env(:riptide, :oidc_audience, original_audience)
    end)

    %{signer: signer}
  end

  # `Joken.Signer.create/3` (joken 2.6.2 + jose 1.11.10, as locked in mix.lock)
  # requires a plain JWK JSON map for RS* algorithms, not the raw `%JOSE.JWK{}`
  # struct `JOSE.JWK.generate_key/1` returns — passing the struct directly
  # raises a `FunctionClauseError` deep in `JOSE.JWK.from_record/1`.
  defp jwk_map(jwk) do
    {_, map} = JOSE.JWK.to_map(jwk)
    map
  end

  defp token(claims, signer) do
    default_claims = %{
      "iss" => @issuer,
      "aud" => @audience,
      "exp" => System.system_time(:second) + 3600
    }

    Joken.generate_and_sign!(%{}, Map.merge(default_claims, claims), signer)
  end

  # Builds a validly-signed token that omits `claim_key` entirely (rather than
  # just overriding its value), to exercise the presence requirement added in
  # `Riptide.Auth.TokenConfig.verify_and_validate_required_claims/1` — Joken's
  # own validators only run for claims the token actually includes, so a
  # token that just doesn't have `exp`/`iss`/`aud` at all would otherwise
  # skip that claim's check completely.
  defp token_missing(claim_key, signer) do
    default_claims = %{
      "iss" => @issuer,
      "aud" => @audience,
      "exp" => System.system_time(:second) + 3600,
      "sub" => "user-1"
    }

    default_claims
    |> Map.delete(claim_key)
    |> then(&Joken.generate_and_sign!(%{}, &1, signer))
  end

  test "verifies a correctly-signed token with valid claims", %{signer: signer} do
    assert {:ok, claims} = Verifier.OIDC.verify(token(%{"sub" => "user-1"}, signer))
    assert claims["sub"] == "user-1"
    assert claims["iss"] == @issuer
  end

  test "rejects a token signed by an unrecognized key", %{signer: _signer} do
    other_jwk = JOSE.JWK.generate_key({:rsa, 2048})

    other_signer =
      Joken.Signer.create("RS256", jwk_map(other_jwk), %{"kid" => "unrecognized-kid"})

    assert {:error, _reason} = Verifier.OIDC.verify(token(%{"sub" => "user-1"}, other_signer))
  end

  test "rejects an expired token", %{signer: signer} do
    expired = token(%{"exp" => System.system_time(:second) - 60}, signer)
    assert {:error, _reason} = Verifier.OIDC.verify(expired)
  end

  test "rejects a token with the wrong issuer", %{signer: signer} do
    wrong_iss = token(%{"iss" => "https://not-the-configured-issuer.example"}, signer)
    assert {:error, _reason} = Verifier.OIDC.verify(wrong_iss)
  end

  test "rejects a token with the wrong audience", %{signer: signer} do
    wrong_aud = token(%{"aud" => "some-other-audience"}, signer)
    assert {:error, _reason} = Verifier.OIDC.verify(wrong_aud)
  end

  test "accepts a token whose audience is a list containing the configured audience", %{
    signer: signer
  } do
    list_aud = token(%{"aud" => ["other-audience", @audience]}, signer)
    assert {:ok, _claims} = Verifier.OIDC.verify(list_aud)
  end

  test "rejects a malformed token instead of raising" do
    assert {:error, _reason} = Verifier.OIDC.verify("not.a.jwt")
  end

  test "rejects a validly-signed token that omits exp entirely", %{signer: signer} do
    assert {:error, _reason} = Verifier.OIDC.verify(token_missing("exp", signer))
  end

  test "rejects a validly-signed token that omits iss entirely", %{signer: signer} do
    assert {:error, _reason} = Verifier.OIDC.verify(token_missing("iss", signer))
  end

  test "rejects a validly-signed token that omits aud entirely", %{signer: signer} do
    assert {:error, _reason} = Verifier.OIDC.verify(token_missing("aud", signer))
  end
end
