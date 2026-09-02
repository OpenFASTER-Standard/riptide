defmodule Riptide.Placement.PlacementMachineTest do
  use ExUnit.Case, async: true

  alias Riptide.Placement.PlacementMachine

  test "init/1 starts with empty streams, names, and repair_claims" do
    assert PlacementMachine.init(%{}) == %{streams: %{}, names: %{}, repair_claims: %{}}
  end

  test "apply/3 stores a new stream's node list" do
    state = PlacementMachine.init(%{})

    {new_state, reply, effects} =
      PlacementMachine.apply(%{index: 1}, {:assign, "s1", [:a, :b, :c]}, state)

    assert new_state == %{
             streams: %{"s1" => [:a, :b, :c]},
             names: %{},
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
             names: %{},
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
             names: %{},
             repair_claims: %{}
           }
  end

  test "get/2 returns the assigned nodes for a known stream" do
    state = %{streams: %{"s1" => [:a, :b, :c]}, names: %{}, repair_claims: %{}}
    assert PlacementMachine.get(state, "s1") == [:a, :b, :c]
  end

  test "get/2 returns nil for an unknown stream" do
    assert PlacementMachine.get(%{streams: %{}, names: %{}, repair_claims: %{}}, "unknown") ==
             nil
  end

  test "list/1 returns only the stream_id => nodes map, not the internal names/repair_claims state" do
    state = %{
      streams: %{"s1" => [:a, :b, :c], "s2" => [:d, :e, :f]},
      names: %{"guild-a" => "tenant-1"},
      repair_claims: %{"s1" => %{dead_node: :b, claimant: :a, claimed_at: 0}}
    }

    assert PlacementMachine.list(state) == %{"s1" => [:a, :b, :c], "s2" => [:d, :e, :f]}
  end

  test "list/1 returns an empty map when nothing is assigned yet" do
    assert PlacementMachine.list(PlacementMachine.init(%{})) == %{}
  end

  test "apply/3 {:replace_member, ...} swaps a dead node for a new one in an existing assignment" do
    state = %{streams: %{"s1" => [:a, :b, :c]}, names: %{}, repair_claims: %{}}

    {new_state, reply, effects} =
      PlacementMachine.apply(%{index: 1}, {:replace_member, "s1", :b, :z}, state)

    assert new_state == %{
             streams: %{"s1" => [:a, :z, :c]},
             names: %{},
             repair_claims: %{}
           }

    assert reply == [:a, :z, :c]
    assert effects == []
  end

  test "apply/3 {:replace_member, ...} is a no-op if the named dead node is no longer present" do
    state = %{streams: %{"s1" => [:a, :z, :c]}, names: %{}, repair_claims: %{}}

    {new_state, reply, effects} =
      PlacementMachine.apply(%{index: 2}, {:replace_member, "s1", :b, :y}, state)

    assert new_state == %{
             streams: %{"s1" => [:a, :z, :c]},
             names: %{},
             repair_claims: %{}
           }

    assert reply == [:a, :z, :c]
    assert effects == []
  end

  test "apply/3 {:replace_member, ...} is a no-op for an unknown stream_id" do
    state = %{streams: %{}, names: %{}, repair_claims: %{}}

    {new_state, reply, effects} =
      PlacementMachine.apply(%{index: 1}, {:replace_member, "unknown", :a, :b}, state)

    assert new_state == %{streams: %{}, names: %{}, repair_claims: %{}}
    assert reply == nil
    assert effects == []
  end

  test "apply/3 {:claim_name, ...} claims an unclaimed name" do
    state = PlacementMachine.init(%{})

    {new_state, reply, effects} =
      PlacementMachine.apply(%{index: 1}, {:claim_name, "guild-a", "tenant-uuid-1"}, state)

    assert new_state == %{
             streams: %{},
             names: %{"guild-a" => "tenant-uuid-1"},
             repair_claims: %{}
           }

    assert reply == :claimed
    assert effects == []
  end

  test "apply/3 {:claim_name, ...} rejects a second claim of the same name" do
    state = PlacementMachine.init(%{})

    {state, :claimed, []} =
      PlacementMachine.apply(%{index: 1}, {:claim_name, "guild-a", "tenant-uuid-1"}, state)

    {new_state, reply, effects} =
      PlacementMachine.apply(%{index: 2}, {:claim_name, "guild-a", "tenant-uuid-2"}, state)

    assert new_state == state
    assert reply == :already_claimed
    assert effects == []
  end

  test "apply/3 {:claim_name, ...} keeps different names independent" do
    state = PlacementMachine.init(%{})

    {state, :claimed, []} =
      PlacementMachine.apply(%{index: 1}, {:claim_name, "guild-a", "tenant-uuid-1"}, state)

    {new_state, reply, effects} =
      PlacementMachine.apply(%{index: 2}, {:claim_name, "guild-b", "tenant-uuid-2"}, state)

    assert new_state == %{
             streams: %{},
             names: %{"guild-a" => "tenant-uuid-1", "guild-b" => "tenant-uuid-2"},
             repair_claims: %{}
           }

    assert reply == :claimed
    assert effects == []
  end

  test "get_name/2 returns the claimed tenant_id, or nil for an unclaimed name" do
    state = PlacementMachine.init(%{})
    assert PlacementMachine.get_name(state, "guild-a") == nil

    {state, :claimed, []} =
      PlacementMachine.apply(%{index: 1}, {:claim_name, "guild-a", "tenant-uuid-1"}, state)

    assert PlacementMachine.get_name(state, "guild-a") == "tenant-uuid-1"
    assert PlacementMachine.get_name(state, "guild-b") == nil
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
