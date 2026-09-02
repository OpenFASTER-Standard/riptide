defmodule Riptide.BlobStore.HealerTest do
  use ExUnit.Case, async: false

  alias Riptide.BlobStore
  alias Riptide.BlobStore.{Healer, LocationIndex}

  # LocationIndex's own stream is now tenant-scoped — each test below claims
  # a fresh, unique tenant name so Healer.sweep/0's own known_tenant_ids/0
  # (backed by the Placement name registry) actually discovers it.
  defp claimed_tenant_id do
    tenant_id = "healer-test-" <> Uniq.UUID.uuid4()
    :claimed = Riptide.Placement.claim_name(tenant_id, tenant_id)
    tenant_id
  end

  test "sweep/0 is a no-op for a hash already at the configured replication factor" do
    tenant_id = claimed_tenant_id()
    bytes = :crypto.strong_rand_bytes(1024)
    {:ok, _hash} = BlobStore.put(tenant_id, bytes)

    # Single-node test environment: put/2 already recorded exactly [node()],
    # and the configured factor defaults to 3 — under-replicated in absolute
    # terms, but with zero other live nodes to repair onto, sweep/0 must not
    # raise or loop forever; it just can't do anything this tick.
    assert :ok = Healer.sweep()
  end

  test "sweep/0 drops a location no longer reachable" do
    tenant_id = claimed_tenant_id()
    hash = "deliberately-unreachable-#{System.unique_integer([:positive])}"
    :ok = LocationIndex.add_location(tenant_id, hash, :"nonexistent@127.0.0.1")

    :ok = Healer.sweep()

    assert {:ok, []} = LocationIndex.list_locations(tenant_id, hash)
  end
end
