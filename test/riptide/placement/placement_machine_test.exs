defmodule Riptide.Placement.PlacementMachineTest do
  use ExUnit.Case, async: true

  alias Riptide.Placement.PlacementMachine

  test "init/1 starts with empty streams, policies, and repair_claims" do
    assert PlacementMachine.init(%{}) == %{streams: %{}, policies: %{}, repair_claims: %{}}
  end

  test "apply/3 stores a new stream's node list" do
    state = PlacementMachine.init(%{})

    {new_state, reply, effects} =
      PlacementMachine.apply(%{index: 1}, {:assign, "s1", [:a, :b, :c]}, state)

    assert new_state == %{
             streams: %{"s1" => [:a, :b, :c]},
             policies: %{},
             repair_claims: %{}
           }

    assert reply == [:a, :b, :c]
    assert effects == []
  end

  test "apply/3 is idempotent: a second proposal for an already-assigned stream returns the existing assignment" do
    state = PlacementMachine.init(%{})
    {state, _reply, _} = PlacementMachine.apply(%{index: 1}, {:assign, "s1", [:a, :b, :c]}, state)

    {new_state, reply, effects} =
      PlacementMachine.apply(%{index: 2}, {:assign, "s1", [:x, :y, :z]}, state)

    assert new_state == %{
             streams: %{"s1" => [:a, :b, :c]},
             policies: %{},
             repair_claims: %{}
           }

    assert reply == [:a, :b, :c]
    assert effects == []
  end

  test "apply/3 stores two different streams independently" do
    state = PlacementMachine.init(%{})
    {state, _, _} = PlacementMachine.apply(%{index: 1}, {:assign, "s1", [:a, :b, :c]}, state)
    {state, _, _} = PlacementMachine.apply(%{index: 2}, {:assign, "s2", [:d, :e, :f]}, state)

    assert state == %{
             streams: %{"s1" => [:a, :b, :c], "s2" => [:d, :e, :f]},
             policies: %{},
             repair_claims: %{}
           }
  end

  test "get/2 returns the assigned nodes for a known stream" do
    state = %{streams: %{"s1" => [:a, :b, :c]}, policies: %{}, repair_claims: %{}}
    assert PlacementMachine.get(state, "s1") == [:a, :b, :c]
  end

  test "get/2 returns nil for an unknown stream" do
    assert PlacementMachine.get(%{streams: %{}, policies: %{}, repair_claims: %{}}, "unknown") ==
             nil
  end

  test "list/1 returns only the stream_id => nodes map, not the internal policies/repair_claims state" do
    state = %{
      streams: %{"s1" => [:a, :b, :c], "s2" => [:d, :e, :f]},
      policies: %{"acme" => %{}},
      repair_claims: %{"s1" => %{dead_node: :b, claimant: :a, claimed_at: 0}}
    }

    assert PlacementMachine.list(state) == %{"s1" => [:a, :b, :c], "s2" => [:d, :e, :f]}
  end

  test "list/1 returns an empty map when nothing is assigned yet" do
    assert PlacementMachine.list(PlacementMachine.init(%{})) == %{}
  end

  test "apply/3 {:replace_member, ...} swaps a dead node for a new one in an existing assignment" do
    state = %{streams: %{"s1" => [:a, :b, :c]}, policies: %{}, repair_claims: %{}}

    {new_state, reply, effects} =
      PlacementMachine.apply(%{index: 1}, {:replace_member, "s1", :b, :z}, state)

    assert new_state == %{
             streams: %{"s1" => [:a, :z, :c]},
             policies: %{},
             repair_claims: %{}
           }

    assert reply == [:a, :z, :c]
    assert effects == []
  end

  test "apply/3 {:replace_member, ...} is a no-op if the named dead node is no longer present" do
    state = %{streams: %{"s1" => [:a, :z, :c]}, policies: %{}, repair_claims: %{}}

    {new_state, reply, effects} =
      PlacementMachine.apply(%{index: 2}, {:replace_member, "s1", :b, :y}, state)

    assert new_state == %{
             streams: %{"s1" => [:a, :z, :c]},
             policies: %{},
             repair_claims: %{}
           }

    assert reply == [:a, :z, :c]
    assert effects == []
  end

  test "apply/3 {:replace_member, ...} is a no-op for an unknown stream_id" do
    state = %{streams: %{}, policies: %{}, repair_claims: %{}}

    {new_state, reply, effects} =
      PlacementMachine.apply(%{index: 1}, {:replace_member, "unknown", :a, :b}, state)

    assert new_state == %{streams: %{}, policies: %{}, repair_claims: %{}}
    assert reply == nil
    assert effects == []
  end

  test "apply/3 {:add_policy, ...} appends to an empty policy list for a new tenant/prefix" do
    state = PlacementMachine.init(%{})
    policy = %Riptide.Authz.Policy{effect: :allow, modes: [:read], matcher: :public}

    {new_state, reply, effects} =
      PlacementMachine.apply(%{index: 1}, {:add_policy, "acme", [], policy}, state)

    assert new_state == %{
             streams: %{},
             policies: %{"acme" => %{[] => [policy]}},
             repair_claims: %{}
           }

    assert reply == :ok
    assert effects == []
  end

  test "apply/3 {:add_policy, ...} appends to an existing policy list rather than replacing it" do
    state = PlacementMachine.init(%{})
    first = %Riptide.Authz.Policy{effect: :allow, modes: [:read], matcher: :public}
    second = %Riptide.Authz.Policy{effect: :deny, modes: [:write], matcher: :authenticated}

    {state, _, _} = PlacementMachine.apply(%{index: 1}, {:add_policy, "acme", [], first}, state)

    {new_state, reply, effects} =
      PlacementMachine.apply(%{index: 2}, {:add_policy, "acme", [], second}, state)

    assert new_state == %{
             streams: %{},
             policies: %{"acme" => %{[] => [first, second]}},
             repair_claims: %{}
           }

    assert reply == :ok
    assert effects == []
  end

  test "apply/3 {:add_policy, ...} deduplicates an exact-duplicate policy instead of appending it again" do
    state = PlacementMachine.init(%{})
    policy = %Riptide.Authz.Policy{effect: :allow, modes: [:read], matcher: :public}

    {state, _, _} = PlacementMachine.apply(%{index: 1}, {:add_policy, "acme", [], policy}, state)

    {new_state, reply, effects} =
      PlacementMachine.apply(%{index: 2}, {:add_policy, "acme", [], policy}, state)

    assert new_state == state
    assert reply == :ok
    assert effects == []
  end

  test "apply/3 {:add_policy, ...} rejects once a tenant/prefix hits the policy cap" do
    state = PlacementMachine.init(%{})

    state =
      Enum.reduce(1..1000, state, fn n, acc ->
        policy = %Riptide.Authz.Policy{effect: :allow, modes: [:read], matcher: {:agent, "u#{n}"}}
        {acc, _, _} = PlacementMachine.apply(%{index: n}, {:add_policy, "acme", [], policy}, acc)
        acc
      end)

    one_more = %Riptide.Authz.Policy{effect: :allow, modes: [:read], matcher: {:agent, "u1001"}}

    {new_state, reply, effects} =
      PlacementMachine.apply(%{index: 1001}, {:add_policy, "acme", [], one_more}, state)

    assert new_state == state
    assert reply == {:error, :too_many_policies}
    assert effects == []
  end

  test "apply/3 {:add_policy, ...} keeps different path prefixes independent" do
    state = PlacementMachine.init(%{})
    root_policy = %Riptide.Authz.Policy{effect: :allow, modes: [:read], matcher: :public}
    child_policy = %Riptide.Authz.Policy{effect: :deny, modes: [:write], matcher: :authenticated}

    {state, _, _} =
      PlacementMachine.apply(%{index: 1}, {:add_policy, "acme", [], root_policy}, state)

    {new_state, _, _} =
      PlacementMachine.apply(%{index: 2}, {:add_policy, "acme", ["secret"], child_policy}, state)

    assert new_state ==
             %{
               streams: %{},
               policies: %{"acme" => %{[] => [root_policy], ["secret"] => [child_policy]}},
               repair_claims: %{}
             }
  end

  test "apply/3 {:claim_tenant_if_unclaimed, ...} creates a tenant-root owner policy when the tenant has zero policies" do
    state = PlacementMachine.init(%{})

    {new_state, reply, effects} =
      PlacementMachine.apply(%{index: 1}, {:claim_tenant_if_unclaimed, "acme", "user-1"}, state)

    assert new_state == %{
             streams: %{},
             policies: %{
               "acme" => %{
                 [] => [
                   %Riptide.Authz.Policy{
                     effect: :allow,
                     modes: [:read, :write],
                     matcher: {:agent, "user-1"}
                   }
                 ]
               }
             },
             repair_claims: %{}
           }

    assert reply == :claimed
    assert effects == []
  end

  test "apply/3 {:claim_tenant_if_unclaimed, ...} is a no-op if the tenant already has any policy at any prefix" do
    state = PlacementMachine.init(%{})
    existing = %Riptide.Authz.Policy{effect: :allow, modes: [:read], matcher: :public}

    {state, _, _} =
      PlacementMachine.apply(
        %{index: 1},
        {:add_policy, "acme", ["some", "path"], existing},
        state
      )

    {new_state, reply, effects} =
      PlacementMachine.apply(%{index: 2}, {:claim_tenant_if_unclaimed, "acme", "user-2"}, state)

    assert new_state == state
    assert reply == :already_claimed
    assert effects == []
  end

  test "list_policies/3 returns an empty list for a tenant/prefix with no policies" do
    state = PlacementMachine.init(%{})
    assert PlacementMachine.list_policies(state, "acme", []) == []
  end

  test "list_policies/3 returns exactly the policies stored at that tenant/prefix" do
    policy = %Riptide.Authz.Policy{effect: :allow, modes: [:read], matcher: :public}
    state = %{streams: %{}, policies: %{"acme" => %{["docs"] => [policy]}}, repair_claims: %{}}

    assert PlacementMachine.list_policies(state, "acme", ["docs"]) == [policy]
    assert PlacementMachine.list_policies(state, "acme", []) == []
    assert PlacementMachine.list_policies(state, "other-tenant", ["docs"]) == []
  end

  describe "{:claim_repair, ...} / {:release_repair, ...} (audit remediation, 2026-08-27)" do
    test "grants a claim when none exists yet" do
      state = PlacementMachine.init(%{})

      {new_state, reply, effects} =
        PlacementMachine.apply(%{index: 1}, {:claim_repair, "s1", :dead, :node_a, 1000}, state)

      assert reply == :claimed
      assert effects == []

      assert new_state.repair_claims == %{
               "s1" => %{dead_node: :dead, claimant: :node_a, claimed_at: 1000}
             }
    end

    test "denies a claim held by a different claimant" do
      state = PlacementMachine.init(%{})

      {state, :claimed, _} =
        PlacementMachine.apply(%{index: 1}, {:claim_repair, "s1", :dead, :node_a, 1000}, state)

      {new_state, reply, effects} =
        PlacementMachine.apply(%{index: 2}, {:claim_repair, "s1", :dead, :node_b, 1001}, state)

      assert reply == :already_claimed
      assert effects == []
      assert new_state == state
    end

    test "re-granting the same claimant/dead_node pair is idempotent (safe retry)" do
      state = PlacementMachine.init(%{})

      {state, :claimed, _} =
        PlacementMachine.apply(%{index: 1}, {:claim_repair, "s1", :dead, :node_a, 1000}, state)

      {new_state, reply, effects} =
        PlacementMachine.apply(%{index: 2}, {:claim_repair, "s1", :dead, :node_a, 1050}, state)

      assert reply == :claimed
      assert effects == []
      # Refreshes claimed_at on the same claimant's re-claim.
      assert new_state.repair_claims["s1"].claimed_at == 1050
    end

    test "a different claimant can steal an expired claim (TTL exceeded)" do
      state = PlacementMachine.init(%{})

      {state, :claimed, _} =
        PlacementMachine.apply(%{index: 1}, {:claim_repair, "s1", :dead, :node_a, 1000}, state)

      # 1000 + 121 > @claim_ttl_seconds (120) past the original claim.
      {new_state, reply, effects} =
        PlacementMachine.apply(%{index: 2}, {:claim_repair, "s1", :dead, :node_b, 1121}, state)

      assert reply == :claimed
      assert effects == []

      assert new_state.repair_claims == %{
               "s1" => %{dead_node: :dead, claimant: :node_b, claimed_at: 1121}
             }
    end

    test "a different claimant cannot steal a claim still within its TTL" do
      state = PlacementMachine.init(%{})

      {state, :claimed, _} =
        PlacementMachine.apply(%{index: 1}, {:claim_repair, "s1", :dead, :node_a, 1000}, state)

      {new_state, reply, _effects} =
        PlacementMachine.apply(%{index: 2}, {:claim_repair, "s1", :dead, :node_b, 1119}, state)

      assert reply == :already_claimed
      assert new_state == state
    end

    test "release_repair clears the claimant's own claim" do
      state = PlacementMachine.init(%{})

      {state, :claimed, _} =
        PlacementMachine.apply(%{index: 1}, {:claim_repair, "s1", :dead, :node_a, 1000}, state)

      {new_state, reply, effects} =
        PlacementMachine.apply(%{index: 2}, {:release_repair, "s1", :node_a}, state)

      assert reply == :ok
      assert effects == []
      assert new_state.repair_claims == %{}
    end

    test "release_repair from a claimant that doesn't hold the claim is a safe no-op" do
      state = PlacementMachine.init(%{})

      {state, :claimed, _} =
        PlacementMachine.apply(%{index: 1}, {:claim_repair, "s1", :dead, :node_a, 1000}, state)

      {new_state, reply, effects} =
        PlacementMachine.apply(%{index: 2}, {:release_repair, "s1", :node_b}, state)

      assert reply == :ok
      assert effects == []
      # node_a's claim is untouched — a stale/duplicate release from a
      # different claimant never clears someone else's active claim.
      assert new_state == state
    end

    test "release_repair for a stream with no claim at all is a safe no-op" do
      state = PlacementMachine.init(%{})

      {new_state, reply, effects} =
        PlacementMachine.apply(%{index: 1}, {:release_repair, "s1", :node_a}, state)

      assert reply == :ok
      assert effects == []
      assert new_state == state
    end

    test "claims on different streams are independent" do
      state = PlacementMachine.init(%{})

      {state, :claimed, _} =
        PlacementMachine.apply(%{index: 1}, {:claim_repair, "s1", :dead, :node_a, 1000}, state)

      {state, :claimed, _} =
        PlacementMachine.apply(%{index: 2}, {:claim_repair, "s2", :dead, :node_b, 1000}, state)

      assert state.repair_claims == %{
               "s1" => %{dead_node: :dead, claimant: :node_a, claimed_at: 1000},
               "s2" => %{dead_node: :dead, claimant: :node_b, claimed_at: 1000}
             }
    end
  end
end
