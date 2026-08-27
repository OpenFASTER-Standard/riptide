defmodule Riptide.PlacementMembership do
  @moduledoc """
  Replaces the old `HOSTNAME`-matches-one-of-3-fixed-ordinals gate — see
  Phase 3e design spec. Started unconditionally on every fleet node (see
  `Riptide.Application`). Owns:

  - The ETS-cached "who are the current placement-cluster members" fast
    path every `Riptide.Placement` client call reads (`current_members/0`).
  - Genesis: on boot, discovers whether a placement cluster already exists
    (locally or across the fleet); if this node turns out to already be a
    member per that discovery, recovers its own local member; if a cluster
    exists but this node isn't in it, leaves joining to the ambient
    reconcile loop; if none exists anywhere, attempts to form one (after a
    short settle window) from a deterministically-computed member list. A
    node whose `node()` identity has drifted since its last run (a real
    Kubernetes pod restart under a new IP) is deliberately NOT treated as
    "already a member" by this discovery — it falls through to an ordinary
    join, with the stale old identity evicted by the leader-only repair
    loop below. No special-casing for identity drift: it's just the
    dead-member-replacement case, handled by machinery that already exists
    for that reason.
  - Reconciliation: an ambient join loop (any non-member node tries to join
    when under target size) and a leader-only repair/shrink loop (removes a
    confirmed-dead member, or shrinks toward a lowered target size).
  - Graceful drain: `terminate/2` proactively removes this node from the
    placement cluster on shutdown, closing the reactive-repair window for
    planned removals.
  """

  use GenServer
  require Logger

  alias Riptide.RaCluster

  @table __MODULE__.Cache
  @topic "riptide:placement_membership"
  @reconcile_interval_ms 5_000
  @genesis_settle_ms 3_000

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @spec current_members() :: [node()]
  def current_members do
    case :ets.lookup(@table, :members) do
      [{:members, members}] -> members
      [] -> []
    end
  end

  @spec target_size() :: pos_integer()
  def target_size do
    Application.get_env(:riptide, :placement_target_size, 3)
  end

  @doc """
  Whether a configured target size is valid — a positive odd integer. An
  even-sized Raft cluster doesn't improve fault tolerance over the
  next-lower odd size and risks tie votes. Extracted as a small, pure,
  directly-testable function so `config/runtime.exs` (which itself isn't
  unit-tested anywhere else in this codebase) can validate at boot without
  needing its own dedicated test — see Task 5.
  """
  @spec valid_target_size?(integer()) :: boolean()
  def valid_target_size?(size) when is_integer(size) and size > 0, do: rem(size, 2) == 1
  def valid_target_size?(_size), do: false

  @impl GenServer
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    Phoenix.PubSub.subscribe(Riptide.PubSub, @topic)
    Process.flag(:trap_exit, true)
    send(self(), :bootstrap)
    schedule_reconcile()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:bootstrap, state) do
    case bootstrap_once() do
      :ok -> :ok
      {:error, _reason} -> :ok
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:reconcile, state) do
    safe_reconcile()
    schedule_reconcile()
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:placement_membership_changed, members}, state) do
    cache_members(members)
    {:noreply, state}
  end

  # Closes the reactive-repair window for planned removals: rather than
  # waiting for the reconcile loop's next tick to notice this node is gone,
  # proactively hand off before the BEAM process actually exits. Needs
  # `Process.flag(:trap_exit, true)` in init/1 — without it, a supervisor's
  # `:shutdown` exit signal kills this process outright and terminate/2 never
  # runs at all (a non-trapping process doesn't get a chance to run any
  # callback on a non-:normal exit signal).
  @impl GenServer
  def terminate(_reason, _state) do
    case RaCluster.local_placement_members() do
      {:ok, members} when length(members) > 1 ->
        survivors = members -- [node()]
        _ = RaCluster.remove_placement_member(survivors, node())
        :ok

      _ ->
        :ok
    end
  end

  @doc """
  One attempt at "get this node into a working placement cluster" — the
  `attempt_fun` `RaCluster.ensure_placement_cluster_started/2` retries
  indefinitely. Public so `RaCluster`'s own default argument can reference
  it, and so tests can invoke it directly.

  Checks DISCOVERED CONSENSUS membership, not local disk, to decide what
  this node should do — `node()` is IP-based and changes on every real pod
  restart (see `RaCluster.data_dir/0`'s own doc), so "do I have local
  on-disk data" is the wrong signal for "am I still a member": a drifted
  node's OLD on-disk data exists, but that data's own persisted config
  still names the OLD, now-meaningless node() identity, not this run's
  fresh one. Recovering via `:ra.restart_server/2` only ever makes sense
  when the CURRENT node() is already listed in the CURRENT, live consensus
  membership — checked here directly, not inferred from disk state.
  """
  @spec bootstrap_once() :: :ok | {:error, term()}
  def bootstrap_once do
    case RaCluster.local_placement_members() do
      {:ok, members} ->
        cache_members(members)
        :ok

      :error ->
        join_or_form_genesis()
    end
  end

  defp join_or_form_genesis do
    case RaCluster.probe_placement_members([node() | Node.list()]) do
      {:ok, members} ->
        cache_members(members)

        if node() in members do
          # Already a member per live consensus, just not running locally
          # right now — a restart under the SAME node() identity (no IP
          # change), or this BEAM simply hasn't started its own member yet.
          # Recover from this node's own persisted log.
          RaCluster.restart_local_placement_member()
        else
          # A cluster exists, but this node isn't (or is no longer) part of
          # it — including the identity-drift case, where the membership
          # still names this node's OLD, now-dead identity, not this fresh
          # node(). Nothing to do here: the ambient join loop (reconcile/0)
          # picks this up on its next tick if membership is under target,
          # and the leader's repair loop evicts the stale old identity.
          :ok
        end

      :error ->
        attempt_genesis()
    end
  end

  defp attempt_genesis do
    Process.sleep(@genesis_settle_ms)

    # Re-probe after settling, in case another node already formed the
    # cluster while this one waited.
    case RaCluster.probe_placement_members([node() | Node.list()]) do
      {:ok, members} ->
        cache_members(members)
        :ok

      :error ->
        form_genesis_if_selected()
    end
  end

  defp form_genesis_if_selected do
    candidates = [node() | Node.list()] |> Enum.uniq() |> Enum.sort()
    genesis_members = Enum.take(candidates, target_size())

    if node() in genesis_members do
      do_form_genesis(genesis_members)
    else
      # Not among the computed genesis members this round — the reconcile
      # loop's ambient join path picks this node up once the actual genesis
      # members finish forming.
      :ok
    end
  end

  defp do_form_genesis(genesis_members) do
    case RaCluster.start_genesis_placement_cluster(genesis_members) do
      :ok ->
        broadcast_members(genesis_members)
        :ok

      {:error, :cluster_not_formed} = error ->
        error
    end
  end

  defp safe_reconcile do
    reconcile()
  rescue
    e ->
      Logger.warning(
        "PlacementMembership reconcile failed, skipping this tick (#{Exception.message(e)})",
        reason: Exception.message(e)
      )
  catch
    :exit, reason ->
      Logger.warning(
        "PlacementMembership reconcile failed, skipping this tick (#{inspect(reason)})",
        reason: inspect(reason)
      )
  end

  defp reconcile do
    case RaCluster.local_placement_members() do
      {:ok, members} ->
        cache_members(members)
        if RaCluster.placement_leader?(), do: reconcile_as_leader(members)

      :error ->
        reconcile_as_non_member()
    end
  end

  defp reconcile_as_non_member do
    case RaCluster.probe_placement_members([node() | Node.list()]) do
      {:ok, members} ->
        cache_members(members)
        if length(members) < target_size(), do: try_join(members)

      :error ->
        attempt_genesis()
    end
  end

  defp try_join(existing_members) do
    case RaCluster.join_placement_cluster(existing_members) do
      :ok -> broadcast_members(Enum.uniq([node() | existing_members]))
      {:error, _reason} -> :ok
    end
  end

  defp reconcile_as_leader(members) do
    dead =
      Enum.reject(members, &RaCluster.member_alive?(RaCluster.placement_server_id(&1)))

    cond do
      dead != [] ->
        [dead_node | _] = dead
        survivors = members -- [dead_node]

        case RaCluster.remove_placement_member(survivors, dead_node) do
          :ok -> broadcast_members(survivors)
          {:error, _reason} -> :ok
        end

      length(members) > target_size() ->
        to_remove = Enum.max(members)
        survivors = members -- [to_remove]

        case RaCluster.remove_placement_member(survivors, to_remove) do
          :ok -> broadcast_members(survivors)
          {:error, _reason} -> :ok
        end

      true ->
        :ok
    end
  end

  defp cache_members(members) do
    :ets.insert(@table, {:members, members})
  end

  defp broadcast_members(members) do
    cache_members(members)
    Phoenix.PubSub.broadcast(Riptide.PubSub, @topic, {:placement_membership_changed, members})
  end

  defp schedule_reconcile do
    interval =
      Application.get_env(:riptide, :placement_reconcile_interval_ms, @reconcile_interval_ms)

    Process.send_after(self(), :reconcile, interval)
  end
end
