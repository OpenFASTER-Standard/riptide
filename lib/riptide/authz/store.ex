defmodule Riptide.Authz.Store do
  @moduledoc """
  Behaviour for where `Riptide.Authz.Policy` structs are persisted. Selected via
  `Application.get_env(:riptide, :authz_store, Riptide.Authz.Store.TenantFacts)`.
  """

  alias Riptide.Authz.Policy

  @callback list_policies(tenant_id :: String.t(), path_prefix :: [String.t()]) :: [Policy.t()]
  @callback add_policy(tenant_id :: String.t(), path_prefix :: [String.t()], Policy.t()) ::
              :ok | {:error, :too_many_policies}
end
