defmodule Riptide.Authz.Store.Placement do
  @moduledoc """
  Default `Riptide.Authz.Store` implementation — persists policies through
  the existing shared placement Ra cluster (`Riptide.Placement`), rather
  than a second Ra cluster to bootstrap and operate (see Phase 4c design
  spec §4).
  """
  @behaviour Riptide.Authz.Store

  alias Riptide.Placement

  @impl true
  def list_policies(tenant_id, path_prefix), do: Placement.list_policies(tenant_id, path_prefix)

  @impl true
  def add_policy(tenant_id, path_prefix, policy),
    do: Placement.add_policy(tenant_id, path_prefix, policy)

  @impl true
  def claim_tenant_if_unclaimed(tenant_id, subject),
    do: Placement.claim_tenant_if_unclaimed(tenant_id, subject)
end
