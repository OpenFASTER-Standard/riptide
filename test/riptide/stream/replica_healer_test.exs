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
  end
end
