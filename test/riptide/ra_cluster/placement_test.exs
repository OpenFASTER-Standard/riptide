defmodule Riptide.RaCluster.PlacementTest do
  use ExUnit.Case, async: true

  alias Riptide.RaCluster.Placement

  describe "placement_server_id/1" do
    test "combines the placement cluster name with the given node" do
      assert Placement.placement_server_id(:"riptide@10.0.0.5") ==
               {:riptide_placement, :"riptide@10.0.0.5"}
    end
  end

  describe "placement_leader?/0" do
    test "returns true for this node's own already-running (collapsed) placement cluster" do
      assert Placement.placement_leader?()
    end
  end

  # This file is async: true and shares one live resource across the whole
  # suite: test_helper.exs bootstraps {:riptide_placement, node()} once,
  # before any test runs, and every async: true test anywhere in the suite
  # that touches Riptide.Placement/Riptide.Stream.Placement depends on that
  # ONE shared instance staying alive for the whole `mix test` run. None of
  # the tests below kill that process or force_delete_server it — each one
  # either makes a provably-safe redundant/no-op call against the shared
  # instance, or doesn't touch it at all. restart_local_placement_member/0's
  # own real "kill it and recover" behavior is exercised safely instead in
  # test/riptide/placement_membership_test.exs, which is async: false.
  describe "local_placement_members/0 and probe_placement_members/1" do
    test "local_placement_members/0 returns the real, already-running shared membership" do
      assert Placement.local_placement_members() == {:ok, [node()]}
    end

    test "probe_placement_members/1 finds the live shared member among unreachable candidates" do
      assert Placement.probe_placement_members([
               :nonexistent1@nowhere,
               node(),
               :nonexistent2@nowhere
             ]) == {:ok, [node()]}
    end

    test "probe_placement_members/1 returns :error when no candidate has a live member" do
      assert Placement.probe_placement_members([:nonexistent1@nowhere, :nonexistent2@nowhere]) ==
               :error
    end
  end

  describe "start_genesis_placement_cluster/1" do
    test "self-corrects on a redundant call against the already-running shared instance" do
      assert Placement.start_genesis_placement_cluster([node()]) == :ok
      assert Placement.start_genesis_placement_cluster([node(), node(), node()]) == :ok
    end
  end

  describe "join_placement_cluster/1 and remove_placement_member/2" do
    test "join_placement_cluster/1 is idempotent when this node is already a member" do
      assert Placement.join_placement_cluster([node()]) == :ok
    end

    test "remove_placement_member/2 removing a node that was never a member is a safe no-op" do
      # Shares RaCluster.remove_member/2's existing disambiguation logic with
      # RaCluster.replace_member/5 (used for real by ReplicaHealer): "not in
      # the survivors' current membership" is treated as :ok whether that's
      # because the node was already removed, or because it was never a
      # member in the first place — replace_member/5's real callers only
      # ever pass a genuine prior member, so this ambiguity never manifests
      # in practice; documented here rather than asserting a stricter
      # contract the shared helper doesn't actually provide.
      assert Placement.remove_placement_member([node()], :"riptide@10.0.0.9") == :ok
    end
  end
end
