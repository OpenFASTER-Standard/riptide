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

    test "always includes the local node first, even with other candidates and RF > 1" do
      result = Placement.propose_nodes(3, [:peer_a, :peer_b, :peer_c])

      assert hd(result) == node()
      assert length(result) == 3
      assert Enum.uniq(result) == result
    end

    test "never duplicates the local node if it's already present in the given peer list" do
      result = Placement.propose_nodes(3, [node(), :peer_a, :peer_b])

      assert result == [node() | Enum.sort(result -- [node()])] or
               Enum.sort(result) == Enum.sort([node(), :peer_a, :peer_b])

      assert Enum.uniq(result) == result
      assert hd(result) == node()
    end

    test "returns just the local node when replication_factor is 1, regardless of peers" do
      assert Placement.propose_nodes(1, [:peer_a, :peer_b]) == [node()]
    end
  end

  describe "assign/2 and lookup/2 against the real metadata cluster" do
    test "a real assignment round-trips through the real placement cluster, using default arguments" do
      stream_id = "placement-roundtrip-" <> Uniq.UUID.uuid4()
      assigned = Placement.assign(stream_id, [node()])

      assert assigned == [node()]
      assert Placement.lookup(stream_id) == [node()]
    end
  end
end
