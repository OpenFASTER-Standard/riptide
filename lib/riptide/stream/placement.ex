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
  require Logger

  alias Riptide.Placement
  alias Riptide.RaCluster

  @table :riptide_stream_placement_cache
  @replication_factor 3
  @max_formation_attempts 3
  @formation_retry_backoff_ms 250

  # Bounds unbounded stream creation — e.g. a POST-to-container loop
  # minting a brand-new 3-replica Ra cluster + placement-map entry + ETS
  # cache entry per call, with no delete path to ever reclaim any of it
  # (a real, confirmed DoS against any authenticated caller — self-service
  # tenant bootstrap grants write access to a fresh tenant to anyone).
  # Applied only to genuinely NEW streams — `backfill_or_propose/1`'s
  # `on_disk?/1` branch is pre-existing legacy data, not new resource
  # creation, and is never quota-limited. Checked before `Placement.assign/2`
  # rather than inside the placement Ra machine itself: `Placement.assign/2`
  # is idempotent-by-construction (Phase 3c-i), so a small burst of
  # concurrent creates right at this boundary can land slightly over quota
  # (TOCTOU — multiple callers can all pass this check before any of them
  # commits their `assign`), a known, accepted soft-bound trade-off rather
  # than the stronger (and substantially more invasive) guarantee a
  # dedicated Ra-consensus-level quota command would provide.
  @max_streams_per_tenant 10_000
  @stream_id_tenant_prefix "https://riptide.example/tenants/"
  @stream_id_resources_segment "/resources/"

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl GenServer
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    Phoenix.PubSub.subscribe(Riptide.PubSub, "stream_placement_changed")
    {:ok, %{}}
  end

  # Corrects this node's cached server ids the moment `Riptide.Stream.ReplicaHealer`
  # (Phase 3d-ii) repairs a stream elsewhere in the fleet — without this, a
  # node that already cached the old (now partially dead) server ids would
  # keep them until it happened to restart, per this module's own
  # cache-forever design (see moduledoc). Overwrites directly rather than
  # evicting, since the correct value is already known from the broadcast —
  # no need to force a re-resolution round-trip through the placement
  # cluster.
  @impl GenServer
  def handle_info({:stream_placement_changed, stream_id, new_nodes}, state)
      when is_list(new_nodes) do
    uid = RaCluster.uid_for(stream_id)
    server_ids = Enum.map(new_nodes, &{String.to_atom(uid), &1})
    :ets.insert(@table, {stream_id, server_ids})
    {:noreply, state}
  end

  # `Placement.replace_member/3` (the only producer of this broadcast) can
  # theoretically return `nil` — if `stream_id` is no longer present in the
  # placement store at all (e.g. a future stream-delete path; currently
  # unreachable since no delete command exists yet). Skipping instead of
  # crashing is cheap insurance against a high-blast-radius crash of this
  # shared, fleet-wide cache subscriber.
  def handle_info({:stream_placement_changed, stream_id, new_nodes}, state) do
    Logger.warning(
      "Riptide.Stream.Placement got a non-list stream_placement_changed broadcast for " <>
        "#{inspect(stream_id)} (#{inspect(new_nodes)}); skipping cache update",
      stream_id: stream_id,
      new_nodes: inspect(new_nodes)
    )

    {:noreply, state}
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
        ) :: {:ok, [:ra.server_id()]} | {:error, :cluster_not_formed | :quota_exceeded}
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
    uid = RaCluster.uid_for(stream_id)

    case resolve_nodes(stream_id) do
      {:error, :quota_exceeded} = error ->
        error

      {:member, nodes} ->
        case start_with_retry(
               uid,
               nodes,
               machine,
               formation_fun,
               sleep_fun,
               @max_formation_attempts
             ) do
          {:ok, server_ids} ->
            :ets.insert(@table, {stream_id, server_ids})
            {:ok, server_ids}

          {:error, _} = error ->
            error
        end

      {:remote, nodes} ->
        server_ids = Enum.map(nodes, &{String.to_atom(uid), &1})
        :ets.insert(@table, {stream_id, server_ids})
        {:ok, server_ids}
    end
  end

  # Distinguishes "this node needs to form/join the cluster" from "this node
  # is just resolving an existing assignment it isn't part of." A genuinely
  # new stream (nil lookup) always lands in {:member, _} — `propose_nodes/2`
  # (Phase 3c-ii) always puts the local node first, and backfill always
  # proposes exactly [node()] — so this node always needs to form it.  An
  # already-assigned stream this node isn't a replica of has nothing to
  # form or join locally: attempting `formation_fun` there would only ever
  # fail (`:ra.start_cluster/2` can't succeed for a node whose id was never
  # in the config), even though the stream is perfectly healthy elsewhere
  # (Phase 3c-iii design spec §1/§4).
  @spec resolve_nodes(String.t()) ::
          {:member, [node()]} | {:remote, [node()]} | {:error, :quota_exceeded}
  defp resolve_nodes(stream_id) do
    case Placement.lookup(stream_id) do
      nil ->
        case backfill_or_propose(stream_id) do
          {:error, :quota_exceeded} = error -> error
          nodes -> {:member, nodes}
        end

      nodes ->
        if node() in nodes do
          {:member, nodes}
        else
          {:remote, nodes}
        end
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
  #
  # The quota check applies only to the genuinely-new (`else`) branch — the
  # `on_disk?/1` backfill branch is pre-existing legacy data, not new
  # resource creation, and is never quota-limited.
  @spec backfill_or_propose(String.t()) :: [node()] | {:error, :quota_exceeded}
  defp backfill_or_propose(stream_id) do
    if on_disk?(stream_id) do
      Placement.assign(stream_id, [node()])
    else
      case check_tenant_quota(stream_id) do
        :ok -> Placement.assign(stream_id, Placement.propose_nodes(@replication_factor))
        {:error, :quota_exceeded} = error -> error
      end
    end
  end

  @spec on_disk?(String.t()) :: boolean()
  defp on_disk?(stream_id) do
    uid = RaCluster.uid_for(stream_id)
    data_dir = RaCluster.data_dir() |> to_string()
    File.dir?(Path.join(data_dir, uid))
  end

  @spec check_tenant_quota(String.t()) :: :ok | {:error, :quota_exceeded}
  defp check_tenant_quota(stream_id) do
    case tenant_id_from_stream_id(stream_id) do
      nil ->
        :ok

      tenant_id ->
        if tenant_stream_count(tenant_id) >= @max_streams_per_tenant do
          :telemetry.execute([:riptide, :stream, :quota_exceeded], %{}, %{})
          {:error, :quota_exceeded}
        else
          :ok
        end
    end
  end

  # Mirrors RiptideWeb.LDP.ResourceController.stream_id_for/2's own format
  # exactly (intentionally duplicated here rather than this domain-layer
  # module depending on that web-layer one) — a stream_id not shaped like
  # an LDP resource (e.g. a plain string used directly by a test) simply
  # isn't quota-checked at all.
  defp tenant_id_from_stream_id(@stream_id_tenant_prefix <> rest) do
    case String.split(rest, @stream_id_resources_segment, parts: 2) do
      [tenant_id, _path] when tenant_id != "" -> tenant_id
      _ -> nil
    end
  end

  defp tenant_id_from_stream_id(_other), do: nil

  defp tenant_stream_count(tenant_id) do
    prefix = @stream_id_tenant_prefix <> tenant_id <> @stream_id_resources_segment

    Placement.list_all()
    |> Map.keys()
    |> Enum.count(&String.starts_with?(&1, prefix))
  end

  defp start_with_retry(uid, nodes, machine, formation_fun, sleep_fun, attempts_left) do
    case formation_fun.(uid, nodes, machine) do
      {:ok, _server_ids} = ok ->
        ok

      {:error, reason} = error when attempts_left <= 1 ->
        # Previously silent: a caller (LDP GET/POST, SSE subscribe, WS join)
        # sees a bare 503 with nothing in Riptide's own logs/metrics
        # explaining that this specific stream's replica formation is what
        # failed, as opposed to any other reason a request can 503.
        Logger.warning(
          "Stream cluster formation exhausted retries for #{inspect(uid)}: #{inspect(reason)}",
          uid: uid,
          reason: inspect(reason)
        )

        :telemetry.execute([:riptide, :stream, :formation_failure], %{}, %{})
        error

      {:error, _} ->
        sleep_fun.(@formation_retry_backoff_ms)
        start_with_retry(uid, nodes, machine, formation_fun, sleep_fun, attempts_left - 1)
    end
  end
end
