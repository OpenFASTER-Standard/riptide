defmodule Riptide.Auth.PasswordTokenConfigTest do
  use ExUnit.Case, async: false

  alias Riptide.Auth.PasswordTokenConfig

  setup do
    Riptide.AppEnvTestHelpers.put_env(
      :riptide,
      :password_auth_signing_key,
      "test-signing-key-fixture"
    )

    :ok
  end

  test "sign/1 + verify_and_validate_required_claims/1 round-trips a valid token" do
    {:ok, token} = PasswordTokenConfig.sign("11111111-1111-1111-1111-111111111111")

    assert {:ok, claims} = PasswordTokenConfig.verify_and_validate_required_claims(token)
    assert claims["sub"] == "11111111-1111-1111-1111-111111111111"
  end

  test "a token signed with a different key fails verification" do
    {:ok, token} = PasswordTokenConfig.sign("11111111-1111-1111-1111-111111111111")

    Riptide.AppEnvTestHelpers.put_env(:riptide, :password_auth_signing_key, "a-different-key")

    assert {:error, _reason} = PasswordTokenConfig.verify_and_validate_required_claims(token)
  end

  test "a token with an expired exp claim fails verification" do
    signer = Joken.Signer.create("HS256", "test-signing-key-fixture")

    {:ok, expired_token, _claims} =
      PasswordTokenConfig.generate_and_sign(
        %{
          "sub" => "11111111-1111-1111-1111-111111111111",
          "exp" => System.system_time(:second) - 10
        },
        signer
      )

    assert {:error, _reason} =
             PasswordTokenConfig.verify_and_validate_required_claims(expired_token)
  end
end
