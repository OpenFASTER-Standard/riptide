defmodule Riptide.Auth.Verifier.CompositeTest do
  use ExUnit.Case, async: false

  alias Riptide.Auth.PasswordTokenConfig
  alias Riptide.Auth.Verifier.Composite

  defmodule AlwaysFails do
    @behaviour Riptide.Auth.Verifier
    @impl true
    def verify(_token), do: {:error, :always_fails}
  end

  defmodule AlwaysExits do
    @behaviour Riptide.Auth.Verifier
    @impl true
    def verify(_token), do: exit(:simulated_unreachable_dependency)
  end

  setup do
    Riptide.AppEnvTestHelpers.put_env(
      :riptide,
      :password_auth_signing_key,
      "test-signing-key-fixture"
    )

    :ok
  end

  test "verify/1 succeeds via the first configured verifier that accepts the token" do
    Riptide.AppEnvTestHelpers.put_env(:riptide, :auth_verifiers, [
      AlwaysFails,
      Riptide.Auth.Verifier.Password
    ])

    {:ok, token} = PasswordTokenConfig.sign("11111111-1111-1111-1111-111111111111")

    assert {:ok, claims} = Composite.verify(token)
    assert claims["sub"] == "11111111-1111-1111-1111-111111111111"
  end

  test "verify/1 tolerates an earlier verifier raising :exit instead of returning {:error, _}" do
    Riptide.AppEnvTestHelpers.put_env(:riptide, :auth_verifiers, [
      AlwaysExits,
      Riptide.Auth.Verifier.Password
    ])

    {:ok, token} = PasswordTokenConfig.sign("11111111-1111-1111-1111-111111111111")

    assert {:ok, _claims} = Composite.verify(token)
  end

  test "verify/1 fails with the last verifier's own error when none succeed" do
    Riptide.AppEnvTestHelpers.put_env(:riptide, :auth_verifiers, [AlwaysFails, AlwaysFails])

    assert {:error, :always_fails} = Composite.verify("any-token")
  end
end
