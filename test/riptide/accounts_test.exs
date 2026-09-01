defmodule Riptide.AccountsTest do
  use ExUnit.Case, async: false

  alias Riptide.Accounts

  setup do
    Riptide.AppEnvTestHelpers.put_env(
      :riptide,
      :password_auth_signing_key,
      "test-signing-key-fixture"
    )

    :ok
  end

  defp unique_tenant, do: "acct-tenant-#{System.unique_integer([:positive])}"

  describe "sign_up/3" do
    test "creates a brand-new Tenant and its first account, returning a usable token" do
      tenant_id = unique_tenant()

      assert {:ok, %{token: token, sub: sub}} =
               Accounts.sign_up(tenant_id, "alice", String.duplicate("a", 64))

      assert is_binary(token)
      assert is_binary(sub)

      assert {:ok, claims} = Riptide.Auth.Verifier.Password.verify(token)
      assert claims["sub"] == sub
    end

    test "a second sign_up against the same tenant_id returns :already_claimed" do
      tenant_id = unique_tenant()

      assert {:ok, _} = Accounts.sign_up(tenant_id, "alice", String.duplicate("a", 64))

      assert {:error, :already_claimed} =
               Accounts.sign_up(tenant_id, "mallory", String.duplicate("b", 64))
    end
  end

  describe "log_in/3" do
    test "correct credentials succeed and return a token bound to the account's own sub" do
      tenant_id = unique_tenant()
      password_hash = String.duplicate("c", 64)

      {:ok, %{sub: sub}} = Accounts.sign_up(tenant_id, "alice", password_hash)

      assert {:ok, token} = Accounts.log_in(tenant_id, "alice", password_hash)
      assert {:ok, claims} = Riptide.Auth.Verifier.Password.verify(token)
      assert claims["sub"] == sub
    end

    test "wrong password_hash returns :invalid_credentials" do
      tenant_id = unique_tenant()
      {:ok, _} = Accounts.sign_up(tenant_id, "alice", String.duplicate("c", 64))

      assert {:error, :invalid_credentials} =
               Accounts.log_in(tenant_id, "alice", String.duplicate("d", 64))
    end

    test "nonexistent username under an existing tenant returns :invalid_credentials" do
      tenant_id = unique_tenant()
      {:ok, _} = Accounts.sign_up(tenant_id, "alice", String.duplicate("c", 64))

      assert {:error, :invalid_credentials} =
               Accounts.log_in(tenant_id, "nobody", String.duplicate("c", 64))
    end

    test "nonexistent tenant_id returns :invalid_credentials" do
      assert {:error, :invalid_credentials} =
               Accounts.log_in(unique_tenant(), "alice", String.duplicate("c", 64))
    end
  end
end
