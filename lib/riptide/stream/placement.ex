defmodule Riptide.Stream.Placement do
  @moduledoc """
  Orchestrates a stream's real, multi-node Ra cluster: resolves which nodes
  should host a stream's replicas (via `Riptide.Placement`, backfilling or
  proposing as needed — see Phase 3c-ii design spec §4), forms/rejoins the
  cluster (via `Riptide.RaCluster.start_or_join_replicated/3`), and caches
  the resolved server IDs locally for the life of this BEAM node — safe to
  cache forever, since a stream's placement never changes once assigned
  (`Riptide.Placement`'s own permanent-once-assigned invariant, Phase 3c-i).

  A tiny `GenServer` only to own the ETS table's lifetime; every other
  function here operates directly on the table, never routing through the
  GenServer process, so concurrent stream lookups never serialize through a
  single bottleneck.
  """

  use GenServer

  alias Riptide.Placement
  alias Riptide.RaCluster

  @table :riptide_stream_placement_cache
  @replication_factor 3
  @max_formation_attempts 3
  @formation_retry_backoff_ms 250

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl GenServer
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @doc """
  Ensures `stream_id`'s real Ra cluster is formed (or already running,
  locally cached) and returns its member server IDs. See Phase 3c-ii design
  spec §4 for the full lookup/backfill/propose decision flow, and §6 for the
  bounded-retry rationale (unlike the placement cluster's own boot-time,
  infinite-retry bootstrap, this happens synchronously on a live request
  path and must not block indefinitely).
  """
  @spec ensure_started(
          String.t(),
          :ra_machine.machine(),
          (String.t(), [node()], :ra_machine.machine() ->
             {:ok, [:ra.server_id()]} | {:error, term()}),
          (pos_integer() -> :ok)
        ) :: {:ok, [:ra.server_id()]} | {:error, :cluster_not_formed}
  def ensure_started(
        stream_id,
        machine,
        formation_fun \\ &RaCluster.start_or_join_replicated/3,
        sleep_fun \\ &Process.sleep/1
      ) do
    case cached(stream_id) do
      {:ok, server_ids} -> {:ok, server_ids}
      :miss -> resolve_and_start(stream_id, machine, formation_fun, sleep_fun)
    end
  end

  @doc """
  Reads a stream's cached server IDs — never triggers resolution or
  formation. Callers (`Riptide.Stream.StreamServer.append/2`/`get_since/2`)
  are only ever reached after `ensure_started/2` has already run once for
  this stream on this node (via `StreamServer.start_link/1`), so a cache
  miss here means a genuine caller bug, not a normal runtime state.
  """
  @spec server_ids!(String.t()) :: [:ra.server_id()]
  def server_ids!(stream_id) do
    case cached(stream_id) do
      {:ok, server_ids} ->
        server_ids

      :miss ->
        raise "Riptide.Stream.Placement.server_ids!/1 called for #{inspect(stream_id)} " <>
                "before ensure_started/2 ever ran for it on this node"
    end
  end

  @spec cached(String.t()) :: {:ok, [:ra.server_id()]} | :miss
  defp cached(stream_id) do
    case :ets.lookup(@table, stream_id) do
      [{^stream_id, server_ids}] -> {:ok, server_ids}
      [] -> :miss
    end
  end

  defp resolve_and_start(stream_id, machine, formation_fun, sleep_fun) do
    nodes = resolve_nodes(stream_id)
    uid = RaCluster.uid_for(stream_id)

    case start_with_retry(uid, nodes, machine, formation_fun, sleep_fun, @max_formation_attempts) do
      {:ok, server_ids} ->
        :ets.insert(@table, {stream_id, server_ids})
        {:ok, server_ids}

      {:error, _} = error ->
        error
    end
  end

  defp resolve_nodes(stream_id) do
    case Placement.lookup(stream_id) do
      nil -> backfill_or_propose(stream_id)
      nodes -> nodes
    end
  end

  # Disambiguates a nil Placement.lookup/2 result: a genuinely new stream
  # (no on-disk data anywhere this node knows about) gets real RF=3
  # placement; a stream that already has on-disk Ra data on THIS node
  # predates this phase (created under the old always-single-node-local
  # scheme, which never wrote anything to the placement store) and gets
  # backfilled to exactly where its real data already lives. Known,
  # inherited limitation (see design spec §4): this only correctly
  # discriminates if a pre-existing stream's requests keep landing on the
  # same node they always have — already an implicit assumption of today's
  # pre-3c-ii code, fully closed only once Phase 3c-iii's real routing
  # ships.
  defp backfill_or_propose(stream_id) do
    if on_disk?(stream_id) do
      Placement.assign(stream_id, [node()])
    else
      Placement.assign(stream_id, Placement.propose_nodes(@replication_factor))
    end
  end

  @spec on_disk?(String.t()) :: boolean()
  defp on_disk?(stream_id) do
    uid = RaCluster.uid_for(stream_id)
    data_dir = RaCluster.data_dir() |> to_string()
    File.dir?(Path.join(data_dir, uid))
  end

  defp start_with_retry(uid, nodes, machine, formation_fun, sleep_fun, attempts_left) do
    case formation_fun.(uid, nodes, machine) do
      {:ok, _server_ids} = ok ->
        ok

      {:error, _} = error when attempts_left <= 1 ->
        error

      {:error, _} ->
        sleep_fun.(@formation_retry_backoff_ms)
        start_with_retry(uid, nodes, machine, formation_fun, sleep_fun, attempts_left - 1)
    end
  end
end
