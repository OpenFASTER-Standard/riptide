defmodule Riptide.BlobStore.Healer do
  @moduledoc """
  Background repair for under-replicated blobs — mirrors
  `Riptide.Stream.ReplicaHealer`'s exact shape (periodic sweep, no new
  coordination primitive) applied to blob replicas instead of Ra cluster
  membership (design spec §7). Runs on every fleet node; over-replicating a
  blob briefly (two nodes both repairing the same under-replicated hash in
  the same tick) is harmless — unlike a Ra cluster's own membership, extra
  blob copies cost only a little disk, never correctness — so, unlike
  `ReplicaHealer`'s own repair, no claim/consensus fencing is needed here.
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

  # No gate — every node sweeps unconditionally (§7: over-replicating a
  # blob briefly is harmless, unlike a Ra cluster's own membership).
  @impl Riptide.PeriodicSweep
  def periodic_sweep, do: sweep()

  @doc "One full pass: drop dead locations, re-replicate anything under the configured factor."
  @spec sweep() :: :ok
  def sweep do
    case LocationIndex.list_all() do
      {:ok, entries} -> Enum.each(entries, &heal_entry/1)
      {:error, :not_ready} -> :ok
    end
  end

  defp heal_entry({hash, nodes}) do
    {live, dead} = Enum.split_with(nodes, &node_alive?/1)
    Enum.each(dead, &LocationIndex.remove_location(hash, &1))

    rf = Application.get_env(:riptide, :blob_replication_factor, 3)
    missing = rf - length(live)

    if missing > 0 and live != [] do
      # Computed here, not inside re_replicate/4, so a hash with no actual
      # candidate node to repair onto (Node.list() has nothing new to
      # offer) skips fetching its bytes entirely — re_replicate/4's own
      # empty-candidates clause short-circuits before any disk read, so a
      # sweep never wastes I/O re-reading every under-replicated blob's
      # full bytes on every tick when there's nowhere to send them.
      candidates = (Node.list() -- live) |> Enum.sort() |> Enum.take(missing)
      re_replicate(hash, live, missing, candidates)
    end
  end

  # Blob replicas are plain fleet nodes, not Ra cluster members — liveness
  # is a plain distributed-Erlang connectivity check, not
  # `RaCluster.member_alive?/1` (that function checks a specific named `:ra`
  # server process, which no blob replica runs).
  defp node_alive?(n) when n == node(), do: true
  defp node_alive?(n), do: n in Node.list()

  defp re_replicate(_hash, _live_nodes, _missing, [] = _candidates), do: :ok

  defp re_replicate(hash, live_nodes, _missing, candidates) do
    with [source | _] <- live_nodes,
         {:ok, bytes} <- fetch_from(source, hash) do
      Enum.each(candidates, &replicate_to(&1, hash, bytes))
    end
  end

  defp replicate_to(target, hash, bytes) do
    case :rpc.call(target, BlobStore, :receive_replica, [hash, bytes], 30_000) do
      :ok -> LocationIndex.add_location(hash, target)
      _other -> :ok
    end
  end

  defp fetch_from(node, hash) when node == node(), do: BlobStore.receive_replica_bytes(hash)

  defp fetch_from(node, hash),
    do: :rpc.call(node, BlobStore, :receive_replica_bytes, [hash], 30_000)
end
