defmodule Riptide.BlobStore.Healer do
  @moduledoc """
  Background repair for under-replicated blobs — mirrors
  `Riptide.Stream.ReplicaHealer`'s exact shape (periodic sweep, no new
  coordination primitive) applied to blob replicas instead of Ra cluster
  membership (design spec §7), now swept per tenant since blob storage is
  fully tenant-scoped (design spec
  `docs/superpowers/specs/2026-09-02-phase-6q-tenant-sovereignty-design.md` §4.3). Runs on every
  fleet node; over-replicating a blob briefly (two nodes both repairing the same under-replicated
  hash in the same tick) is harmless — unlike a Ra cluster's own membership, extra blob copies cost
  only a little disk, never correctness — so, unlike `ReplicaHealer`'s own repair, no
  claim/consensus fencing is needed here.
  """

  use Riptide.PeriodicSweep,
    default_interval_ms: 30_000,
    interval_env_key: :blob_healer_sweep_interval_ms

  use GenServer
  require Logger

  alias Riptide.BlobStore
  alias Riptide.BlobStore.LocationIndex

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl GenServer
  def handle_info(:sweep, state), do: Riptide.PeriodicSweep.handle_sweep(__MODULE__, state)

  # No gate — every node sweeps unconditionally (§7: over-replicating a
  # blob briefly is harmless, unlike a Ra cluster's own membership).
  @impl Riptide.PeriodicSweep
  def periodic_sweep, do: sweep()

  @doc "One full pass over every known tenant: drop dead locations, re-replicate anything under the configured factor."
  @spec sweep() :: :ok
  def sweep do
    Enum.each(known_tenant_ids(), &sweep_tenant/1)
  end

  # Every tenant that exists has, by construction (design spec §4.4's signup sequencing),
  # successfully claimed a name — the name registry doubles as a complete tenant directory for
  # this purpose.
  defp known_tenant_ids do
    Riptide.Placement.list_all_names() |> Map.values()
  end

  defp sweep_tenant(tenant_id) do
    case LocationIndex.list_all(tenant_id) do
      {:ok, entries} -> Enum.each(entries, &heal_entry(tenant_id, &1))
      {:error, :not_ready} -> :ok
    end
  end

  defp heal_entry(tenant_id, {hash, nodes}) do
    {live, dead} = Enum.split_with(nodes, &node_alive?/1)
    Enum.each(dead, &LocationIndex.remove_location(tenant_id, hash, &1))

    rf = Application.get_env(:riptide, :blob_replication_factor, 3)
    missing = rf - length(live)

    if missing > 0 and live != [] do
      # Computed here, not inside re_replicate/5, so a hash with no actual
      # candidate node to repair onto (Node.list() has nothing new to
      # offer) skips fetching its bytes entirely — re_replicate/5's own
      # empty-candidates clause short-circuits before any disk read, so a
      # sweep never wastes I/O re-reading every under-replicated blob's
      # full bytes on every tick when there's nowhere to send them.
      candidates = (Node.list() -- live) |> Enum.sort() |> Enum.take(missing)
      re_replicate(tenant_id, hash, live, missing, candidates)
    end
  end

  # Blob replicas are plain fleet nodes, not Ra cluster members — liveness
  # is a plain distributed-Erlang connectivity check, not
  # `RaCluster.member_alive?/1` (that function checks a specific named `:ra`
  # server process, which no blob replica runs).
  defp node_alive?(n) when n == node(), do: true
  defp node_alive?(n), do: n in Node.list()

  defp re_replicate(_tenant_id, _hash, _live_nodes, _missing, [] = _candidates), do: :ok

  defp re_replicate(tenant_id, hash, live_nodes, _missing, candidates) do
    with [source | _] <- live_nodes,
         {:ok, bytes} <- fetch_from(tenant_id, source, hash) do
      Enum.each(candidates, &replicate_to(tenant_id, &1, hash, bytes))
    end
  end

  defp replicate_to(tenant_id, target, hash, bytes) do
    case :rpc.call(target, BlobStore, :receive_replica, [tenant_id, hash, bytes], 30_000) do
      :ok -> LocationIndex.add_location(tenant_id, hash, target)
      _other -> :ok
    end
  end

  defp fetch_from(tenant_id, node, hash) when node == node(),
    do: BlobStore.receive_replica_bytes(tenant_id, hash)

  defp fetch_from(tenant_id, node, hash),
    do: :rpc.call(node, BlobStore, :receive_replica_bytes, [tenant_id, hash], 30_000)
end
