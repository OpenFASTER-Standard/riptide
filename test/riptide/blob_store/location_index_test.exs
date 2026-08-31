defmodule Riptide.BlobStore.LocationIndexTest do
  use ExUnit.Case, async: false

  alias Riptide.BlobStore.LocationIndex

  # LocationIndex's own stream is a single, shared stream across the whole
  # test suite (like :hub's own catalog — see catalog_test.exs's "Hub vs.
  # Tenant scope isolation" test for why) — never force-deleted here, since
  # that can leave the very next writer hitting :noproc before the lazy
  # re-create catches up. Every test below queries only its own unique
  # hash, so accumulation across runs is harmless.
  defp unique_hash, do: "hash#{System.unique_integer([:positive])}"

  test "add_location/2 then list_locations/1 finds the node" do
    hash = unique_hash()

    :ok = LocationIndex.add_location(hash, :"node_a@127.0.0.1")

    assert {:ok, [:"node_a@127.0.0.1"]} = LocationIndex.list_locations(hash)
  end

  test "a hash with no recorded location returns {:ok, []}" do
    assert {:ok, []} = LocationIndex.list_locations(unique_hash())
  end

  test "multiple add_location/2 calls accumulate distinct nodes" do
    hash = unique_hash()

    :ok = LocationIndex.add_location(hash, :"node_a@127.0.0.1")
    :ok = LocationIndex.add_location(hash, :"node_b@127.0.0.1")

    assert {:ok, nodes} = LocationIndex.list_locations(hash)
    assert Enum.sort(nodes) == Enum.sort([:"node_a@127.0.0.1", :"node_b@127.0.0.1"])
  end

  test "remove_location/2 drops exactly that node" do
    hash = unique_hash()
    :ok = LocationIndex.add_location(hash, :"node_a@127.0.0.1")
    :ok = LocationIndex.add_location(hash, :"node_b@127.0.0.1")

    :ok = LocationIndex.remove_location(hash, :"node_a@127.0.0.1")

    assert {:ok, [:"node_b@127.0.0.1"]} = LocationIndex.list_locations(hash)
  end

  test "list_all/0 returns every tracked hash with its current node set" do
    hash1 = unique_hash()
    hash2 = unique_hash()
    :ok = LocationIndex.add_location(hash1, :"node_a@127.0.0.1")
    :ok = LocationIndex.add_location(hash2, :"node_b@127.0.0.1")

    assert {:ok, all} = LocationIndex.list_all()
    assert all[hash1] == [:"node_a@127.0.0.1"]
    assert all[hash2] == [:"node_b@127.0.0.1"]
  end
end
