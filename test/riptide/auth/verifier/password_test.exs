defmodule Riptide.Auth.Verifier.PasswordTest do
  use ExUnit.Case, async: false

  alias Riptide.Auth.PasswordTokenConfig
  alias Riptide.Auth.Verifier.Password

  setup do
    Riptide.AppEnvTestHelpers.put_env(
      :riptide,
      :password_auth_signing_key,
      "test-signing-key-fixture"
    )

    :ok
  end

  test "verify/1 succeeds for a token PasswordTokenConfig itself signed" do
    {:ok, token} = PasswordTokenConfig.sign("11111111-1111-1111-1111-111111111111")

    assert {:ok, claims} = Password.verify(token)
    assert claims["sub"] == "11111111-1111-1111-1111-111111111111"
  end

  test "verify/1 fails for garbage input" do
    assert {:error, _reason} = Password.verify("not-a-real-token")
  end
end
