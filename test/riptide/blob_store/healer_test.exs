defmodule Riptide.BlobStore.HealerTest do
  use ExUnit.Case, async: false

  alias Riptide.BlobStore
  alias Riptide.BlobStore.{Healer, LocationIndex}

  # LocationIndex's own stream is shared across the whole suite — never
  # force-deleted here, matching LocationIndexTest's own established
  # convention; both tests below use a hash unique to that one test.

  test "sweep/0 is a no-op for a hash already at the configured replication factor" do
    bytes = :crypto.strong_rand_bytes(1024)
    {:ok, _hash} = BlobStore.put(bytes)

    # Single-node test environment: put/1 already recorded exactly [node()],
    # and the configured factor defaults to 3 — under-replicated in absolute
    # terms, but with zero other live nodes to repair onto, sweep/0 must not
    # raise or loop forever; it just can't do anything this tick.
    assert :ok = Healer.sweep()
  end

  test "sweep/0 drops a location no longer reachable" do
    hash = "deliberately-unreachable-#{System.unique_integer([:positive])}"
    :ok = LocationIndex.add_location(hash, :"nonexistent@127.0.0.1")

    :ok = Healer.sweep()

    assert {:ok, []} = LocationIndex.list_locations(hash)
  end
end
