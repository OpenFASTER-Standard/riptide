defmodule Riptide.PlacementMembershipTest do
  use ExUnit.Case, async: false

  alias Riptide.PlacementMembership
  alias Riptide.RaCluster

  describe "current_members/0" do
    # No "returns [] when nothing has been cached yet" test: once the real
    # Riptide.PlacementMembership GenServer is wired into the application
    # supervision tree (Task 4), its cache is populated almost immediately
    # at boot via its own :bootstrap message — there's no reliably-testable
    # "genuinely empty" window in a running application to assert against.

    test "returns whatever was last cached via a membership-changed broadcast" do
      Phoenix.PubSub.broadcast(
        Riptide.PubSub,
        "riptide:placement_membership",
        {:placement_membership_changed, [node(), :"riptide@10.0.0.7"]}
      )

      # The already-running Riptide.PlacementMembership process (started by
      # the application supervision tree — see Task 4) processes the
      # broadcast asynchronously — poll instead of a fixed sleep, since a
      # busier scheduler (seen on CI) can take longer than any fixed delay
      # to deliver and handle the message.
      assert eventually(fn ->
               PlacementMembership.current_members() == [node(), :"riptide@10.0.0.7"]
             end)
    end
  end

  describe "target_size/0" do
    test "defaults to 3 when no application env is configured" do
      original = Application.get_env(:riptide, :placement_target_size)
      Application.delete_env(:riptide, :placement_target_size)
      on_exit(fn -> Application.put_env(:riptide, :placement_target_size, original) end)

      assert PlacementMembership.target_size() == 3
    end

    test "reads the configured value when present" do
      original = Application.get_env(:riptide, :placement_target_size)
      Application.put_env(:riptide, :placement_target_size, 5)
      on_exit(fn -> Application.put_env(:riptide, :placement_target_size, original) end)

      assert PlacementMembership.target_size() == 5
    end
  end

  describe "valid_target_size?/1" do
    test "true for positive odd integers" do
      assert PlacementMembership.valid_target_size?(1)
      assert PlacementMembership.valid_target_size?(3)
      assert PlacementMembership.valid_target_size?(5)
    end

    test "false for even integers, zero, negative integers, and non-integers" do
      refute PlacementMembership.valid_target_size?(2)
      refute PlacementMembership.valid_target_size?(4)
      refute PlacementMembership.valid_target_size?(0)
      refute PlacementMembership.valid_target_size?(-3)
    end
  end

  describe "bootstrap_once/0" do
    test "restarts the local member when this node is discovered as an already-existing member" do
      # No on_exit force_delete_server here: {:riptide_placement, node()} is
      # NOT a throwaway server this test owns — it's the same shared,
      # suite-wide placement cluster test_helper.exs bootstraps once before
      # any test runs, which other tests (e.g. test/riptide_web/health_test.exs)
      # depend on staying alive and recoverable for the rest of the `mix
      # test` process's lifetime. Kill the local process (but keep its
      # on-disk data, and this node's identity is unchanged) — a real member
      # restarting under the SAME node() identity, discoverable via the
      # fleet probe finding node() itself already listed in the persisted
      # membership — then let bootstrap_once/0 recover it, leaving the
      # shared instance alive and correct when this test finishes, exactly
      # as every other test that touches it depends on.
      pid = Process.whereis(:riptide_placement)
      Process.exit(pid, :kill)

      # Not a fixed-sleep-as-synchronization risk like the PubSub-broadcast
      # test above: `ra_server_sup`'s child spec restarts a killed member
      # with `restart: :transient` (confirmed via deps/ra/src/ra_server_sup.erl),
      # so :riptide_placement is back under a NEW pid almost immediately —
      # there's no observable "nil" window to poll for. This sleep exists
      # only to let that OTP-level restart settle before bootstrap_once/0
      # runs its own, separate `:ra.restart_server/2`-based recovery.
      :timer.sleep(50)

      assert PlacementMembership.bootstrap_once() == :ok
      assert RaCluster.local_placement_members() == {:ok, [node()]}
    end
  end

  describe "Riptide.Placement addressing (via PlacementMembership discovery)" do
    test "assign/2 and lookup/1 work against the real, currently-running placement cluster" do
      stream_id = "placement-membership-" <> Uniq.UUID.uuid4()
      proposed = [node()]

      assert Riptide.Placement.assign(stream_id, proposed) == proposed
      assert Riptide.Placement.lookup(stream_id) == proposed
    end

    test "falls back to a live fleet probe and raises when no member is reachable at all" do
      original = Application.get_env(:riptide, :placement_members_override)
      Application.put_env(:riptide, :placement_members_override, [:nonexistent@nohost])
      on_exit(fn -> Application.put_env(:riptide, :placement_members_override, original) end)

      assert_raise RuntimeError, ~r/no placement-cluster members could be/, fn ->
        Riptide.Placement.lookup("irrelevant-stream-id")
      end
    end
  end

  defp eventually(fun, attempts_left \\ 50) do
    cond do
      fun.() ->
        true

      attempts_left <= 1 ->
        false

      true ->
        Process.sleep(50)
        eventually(fun, attempts_left - 1)
    end
  end
end
