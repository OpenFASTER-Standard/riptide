defmodule Riptide.PlacementTest do
  use ExUnit.Case, async: true

  alias Riptide.Placement

  describe "select_nodes/2" do
    test "returns exactly `count` distinct nodes when enough candidates exist" do
      result = Placement.select_nodes([:a, :b, :c, :d, :e], 3)

      assert length(result) == 3
      assert Enum.uniq(result) == result
      assert Enum.all?(result, &(&1 in [:a, :b, :c, :d, :e]))
    end

    test "deduplicates candidate nodes before selecting" do
      result = Placement.select_nodes([:a, :a, :b, :b, :c], 3)
      assert Enum.sort(result) == [:a, :b, :c]
    end

    test "returns all candidates if fewer than `count` are available" do
      result = Placement.select_nodes([:a, :b], 3)
      assert Enum.sort(result) == [:a, :b]
    end
  end

  describe "propose_nodes/1" do
    test "always includes the local node, even alone" do
      # Node.list() is empty on a non-distributed test node, so with
      # replication_factor 1 the only possible candidate is node() itself.
      assert Placement.propose_nodes(1) == [node()]
    end
  end

  describe "assign/2 and lookup/2 against the real metadata cluster" do
    test "a real assignment round-trips through the real placement cluster" do
      stream_id = "placement-roundtrip-" <> Uniq.UUID.uuid4()
      resolve_fun = fn _ordinal -> node() end
      assigned = Placement.assign(stream_id, [node()], resolve_fun)

      assert assigned == [node()]
      assert Placement.lookup(stream_id, resolve_fun) == [node()]
    end
  end
end
