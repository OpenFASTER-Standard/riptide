defmodule Riptide.Stream.ReplicaHealerTest do
  use ExUnit.Case, async: true

  alias Riptide.Stream.ReplicaHealer

  describe "pick_replacement/2" do
    test "picks a live node not already among the current members" do
      result = ReplicaHealer.pick_replacement([:a, :b], [:a, :b, :c, :d])
      assert result in [:c, :d]
    end

    test "returns nil when every live node is already a current member" do
      assert ReplicaHealer.pick_replacement([:a, :b, :c], [:a, :b, :c]) == nil
    end

    test "returns nil when there are no live candidate nodes at all" do
      assert ReplicaHealer.pick_replacement([:a, :b], []) == nil
    end

    test "two different racing callers converge on the same pick once each includes its own identity" do
      # Simulates the actual race this function exists to close: two DIFFERENT
      # placement ordinals (e.g. :c and :d) retry the very same repair across
      # a leadership handoff (finding 3). Each one's raw `Node.list()` excludes
      # only ITSELF, so caller :c's raw view is `full_fleet -- [:c]` and caller
      # :d's raw view is `full_fleet -- [:d]` -- two DIFFERENT sets ({a,b,d} vs
      # {a,b,c}), which is exactly the asymmetry that broke determinism. The
      # fix is prepending each caller's own identity back on
      # (`[node() | Node.list()]`), simulated explicitly here as
      # `[caller | full_fleet -- [caller]]`: once BOTH callers do that, both
      # end up looking at the identical full fleet (just reordered), so
      # `pick_replacement/2`'s existing sort-then-take-first logic is
      # guaranteed to compute the same candidate for either one.
      current_nodes = [:a, :b]
      full_fleet = [:a, :b, :c, :d]

      caller_c_view = [:c | full_fleet -- [:c]]
      caller_d_view = [:d | full_fleet -- [:d]]

      assert Enum.sort(caller_c_view) == Enum.sort(full_fleet)
      assert Enum.sort(caller_d_view) == Enum.sort(full_fleet)

      assert ReplicaHealer.pick_replacement(current_nodes, caller_c_view) ==
               ReplicaHealer.pick_replacement(current_nodes, caller_d_view)
    end

    test "default live_nodes includes this node's own identity, not just Node.list()" do
      # `Node.list()` never includes the calling node itself, so setting
      # `current_nodes` to exactly what THIS node currently sees as its live
      # peers means node() is, by construction, the one candidate a correct
      # default must still find -- it can only come from the default itself
      # adding the caller's own identity back in (`[node() | Node.list()]`),
      # not from `live_nodes` alone. Before the fix (bare `Node.list()` as
      # the default), `live_nodes` would equal `current_nodes` exactly here,
      # so the candidate set would be empty and this would return `nil`
      # instead of `node()`.
      current_nodes = Node.list()
      assert ReplicaHealer.pick_replacement(current_nodes) == node()
    end
  end
end
