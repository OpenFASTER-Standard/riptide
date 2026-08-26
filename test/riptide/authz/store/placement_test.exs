defmodule Riptide.Authz.Store.PlacementTest do
  use ExUnit.Case, async: true

  alias Riptide.Authz.{Policy, Store}

  test "add_policy/3 then list_policies/2 round-trips through the real placement cluster" do
    tenant_id = "authz-store-test-" <> Uniq.UUID.uuid4()
    policy = %Policy{effect: :deny, modes: [:write], matcher: :authenticated}

    assert Store.Placement.add_policy(tenant_id, ["docs"], policy) == :ok
    assert Store.Placement.list_policies(tenant_id, ["docs"]) == [policy]
  end

  test "claim_tenant_if_unclaimed/2 claims a brand-new tenant exactly once" do
    tenant_id = "authz-store-claim-test-" <> Uniq.UUID.uuid4()

    assert Store.Placement.claim_tenant_if_unclaimed(tenant_id, "user-1") == :claimed
    assert Store.Placement.claim_tenant_if_unclaimed(tenant_id, "user-2") == :already_claimed
  end
end
