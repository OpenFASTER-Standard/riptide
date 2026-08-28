defmodule Riptide.Authz.Store do
  @moduledoc """
  Behaviour for where `Riptide.Authz.Policy` structs are persisted. Selected
  via `Application.get_env(:riptide, :authz_store, Riptide.Authz.Store.Placement)`
  — the same config-driven swap `Riptide.Auth.Verifier`/`Riptide.Tenancy.Resolver`
  already use (Phases 3c-i/4a/4b), so a test can inject a fake store with
  `Application.put_env(:riptide, :authz_store, MyFakeStore)`.
  """

  alias Riptide.Authz.Policy

  @callback list_policies(tenant_id :: String.t(), path_prefix :: [String.t()]) :: [Policy.t()]
  @callback add_policy(tenant_id :: String.t(), path_prefix :: [String.t()], Policy.t()) ::
              :ok | {:error, :too_many_policies}
  @callback claim_tenant_if_unclaimed(tenant_id :: String.t(), subject :: String.t()) ::
              :claimed | :already_claimed
end
