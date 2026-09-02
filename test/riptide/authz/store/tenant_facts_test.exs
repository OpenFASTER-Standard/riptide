defmodule Riptide.Authz.Store.TenantFactsTest do
  use ExUnit.Case, async: false

  alias Riptide.Authz.Policy
  alias Riptide.Authz.Store.TenantFacts

  defp unique_tenant, do: "tenant-facts-" <> Uniq.UUID.uuid4()

  test "add_policy/3 then list_policies/2 round-trips a policy at a given prefix" do
    tenant_id = unique_tenant()
    policy = %Policy{effect: :allow, modes: [:read], matcher: :public}

    assert :ok = TenantFacts.add_policy(tenant_id, ["docs"], policy)
    assert TenantFacts.list_policies(tenant_id, ["docs"]) == [policy]
  end

  test "list_policies/2 only returns policies stored at the exact requested prefix" do
    tenant_id = unique_tenant()
    root_policy = %Policy{effect: :allow, modes: [:read, :write], matcher: {:agent, "owner"}}
    docs_policy = %Policy{effect: :allow, modes: [:read], matcher: :public}

    :ok = TenantFacts.add_policy(tenant_id, [], root_policy)
    :ok = TenantFacts.add_policy(tenant_id, ["docs"], docs_policy)

    assert TenantFacts.list_policies(tenant_id, []) == [root_policy]
    assert TenantFacts.list_policies(tenant_id, ["docs"]) == [docs_policy]
    assert TenantFacts.list_policies(tenant_id, ["other"]) == []
  end

  test "list_policies/2 for a tenant with no policies yet returns []" do
    assert TenantFacts.list_policies(unique_tenant(), []) == []
  end

  test "add_policy/3 is idempotent for an identical duplicate" do
    tenant_id = unique_tenant()
    policy = %Policy{effect: :allow, modes: [:read], matcher: :public}

    :ok = TenantFacts.add_policy(tenant_id, [], policy)
    :ok = TenantFacts.add_policy(tenant_id, [], policy)

    assert TenantFacts.list_policies(tenant_id, []) == [policy]
  end
end
