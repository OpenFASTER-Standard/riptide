defmodule Riptide.BlobStore.LocationIndexTest do
  use ExUnit.Case, async: false

  alias Riptide.BlobStore.LocationIndex

  # LocationIndex's own stream is now tenant-scoped — each test below uses
  # its own unique tenant_id, so there's no shared-stream accumulation
  # concern to work around anymore.
  defp tenant_id, do: "location-index-test-" <> Uniq.UUID.uuid4()
  defp unique_hash, do: "hash#{System.unique_integer([:positive])}"

  test "add_location/3 then list_locations/2 finds the node" do
    tenant_id = tenant_id()
    hash = unique_hash()

    :ok = LocationIndex.add_location(tenant_id, hash, :"node_a@127.0.0.1")

    assert {:ok, [:"node_a@127.0.0.1"]} = LocationIndex.list_locations(tenant_id, hash)
  end

  test "a hash with no recorded location returns {:ok, []}" do
    assert {:ok, []} = LocationIndex.list_locations(tenant_id(), unique_hash())
  end

  test "multiple add_location/3 calls accumulate distinct nodes" do
    tenant_id = tenant_id()
    hash = unique_hash()

    :ok = LocationIndex.add_location(tenant_id, hash, :"node_a@127.0.0.1")
    :ok = LocationIndex.add_location(tenant_id, hash, :"node_b@127.0.0.1")

    assert {:ok, nodes} = LocationIndex.list_locations(tenant_id, hash)
    assert Enum.sort(nodes) == Enum.sort([:"node_a@127.0.0.1", :"node_b@127.0.0.1"])
  end

  test "remove_location/3 drops exactly that node" do
    tenant_id = tenant_id()
    hash = unique_hash()
    :ok = LocationIndex.add_location(tenant_id, hash, :"node_a@127.0.0.1")
    :ok = LocationIndex.add_location(tenant_id, hash, :"node_b@127.0.0.1")

    :ok = LocationIndex.remove_location(tenant_id, hash, :"node_a@127.0.0.1")

    assert {:ok, [:"node_b@127.0.0.1"]} = LocationIndex.list_locations(tenant_id, hash)
  end

  test "list_all/1 returns every tracked hash with its current node set" do
    tenant_id = tenant_id()
    hash1 = unique_hash()
    hash2 = unique_hash()
    :ok = LocationIndex.add_location(tenant_id, hash1, :"node_a@127.0.0.1")
    :ok = LocationIndex.add_location(tenant_id, hash2, :"node_b@127.0.0.1")

    assert {:ok, all} = LocationIndex.list_all(tenant_id)
    assert all[hash1] == [:"node_a@127.0.0.1"]
    assert all[hash2] == [:"node_b@127.0.0.1"]
  end
end
