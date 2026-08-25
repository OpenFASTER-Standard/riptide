defmodule Riptide.Stream.ReplicaHealer do
  @moduledoc """
  Fully automatic background repair for a stream's replica set — see Phase
  3d-ii design spec for the full motivation. Runs only on the 3 placement
  ordinals (wired in `Riptide.Application`, same gating as
  `Riptide.RaCluster.ensure_placement_cluster_started/0`), and only the
  placement cluster's current Raft leader ever acts on a given sweep
  (`RaCluster.placement_leader?/0`) — reusing that cluster's own existing
  leader election as single-writer safety, rather than a new coordination
  mechanism. No operator action is required in the steady-state case.
  """

  use GenServer
  require Logger

  alias Riptide.Placement
  alias Riptide.RaCluster
  alias Riptide.Stream.RaMachine

  @sweep_interval_ms 30_000

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl GenServer
  def init(:ok) do
    schedule_sweep()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    if RaCluster.placement_leader?() do
      sweep()
    end

    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep do
    interval =
      Application.get_env(:riptide, :replica_healer_sweep_interval_ms, @sweep_interval_ms)

    Process.send_after(self(), :sweep, interval)
  end

  @doc """
  One full pass over every known stream: find any with exactly one dead
  member and repair it. Public (not just reachable via the timer) so tests
  can invoke it directly rather than waiting on a real interval.
  """
  @spec sweep() :: :ok
  def sweep do
    Placement.list_all()
    |> Enum.each(&maybe_repair/1)
  end

  defp maybe_repair({stream_id, nodes}) do
    uid = RaCluster.uid_for(stream_id)
    name = String.to_atom(uid)
    dead_nodes = Enum.reject(nodes, &RaCluster.member_alive?({name, &1}))

    case dead_nodes do
      [dead_node] -> repair(stream_id, uid, nodes, dead_node)
      _ -> :ok
    end
  end

  defp repair(stream_id, uid, nodes, dead_node) do
    survivor_nodes = nodes -- [dead_node]

    case pick_replacement(nodes) do
      nil ->
        :ok

      new_node ->
        case discover_retention(uid, survivor_nodes) do
          {:ok, retention} ->
            do_repair(stream_id, uid, survivor_nodes, dead_node, new_node, retention)

          :error ->
            Logger.warning(
              "ReplicaHealer could not discover #{stream_id}'s current retention from any " <>
                "survivor (#{inspect(survivor_nodes)}); skipping repair this tick"
            )
        end
    end
  end

  defp do_repair(stream_id, uid, survivor_nodes, dead_node, new_node, retention) do
    machine = {:module, RaMachine, %{retention: retention}}

    case RaCluster.replace_member(uid, survivor_nodes, dead_node, new_node, machine) do
      :ok ->
        new_nodes = Placement.replace_member(stream_id, dead_node, new_node)

        Phoenix.PubSub.broadcast(
          Riptide.PubSub,
          "stream_placement_changed",
          {:stream_placement_changed, stream_id, new_nodes}
        )

        Logger.info(
          "ReplicaHealer repaired #{stream_id}: replaced #{inspect(dead_node)} with #{inspect(new_node)}"
        )

      {:error, reason} ->
        Logger.warning(
          "ReplicaHealer failed to repair #{stream_id} (dead: #{inspect(dead_node)}): #{inspect(reason)}"
        )
    end
  end

  @doc """
  Picks a live fleet node to replace a dead member with — a candidate not
  already among `current_nodes`. Deterministic (sorted, first candidate)
  rather than random, unlike `Riptide.Placement.propose_nodes/2`'s own
  selection for a brand-new stream: two concurrent or retried repair
  attempts for the very same `{stream_id, dead_node}` pair always compute
  the same `current_nodes`/`live_nodes` inputs, so picking deterministically
  means they always converge on the same replacement node too — turning a
  redundant second attempt (e.g. after a partial failure, or a leadership
  handoff mid-sweep — see finding 3, Phase 3d-ii final review) into a safe
  retry of the same repair instead of a competing one that could leave the
  stream over-replicated. `live_nodes` defaults to `Node.list()` but is
  overridable for tests, mirroring `propose_nodes/2`'s own
  `peers \\ Node.list()` pattern.
  """
  @spec pick_replacement([node()], [node()]) :: node() | nil
  def pick_replacement(current_nodes, live_nodes \\ Node.list()) do
    case (live_nodes -- current_nodes) |> Enum.uniq() |> Enum.sort() do
      [] -> nil
      [node | _rest] -> node
    end
  end

  # `RaCluster` is the sole module allowed to call `:ra` directly (see its
  # own moduledoc) — this goes through `RaCluster.consistent_query/2`, the
  # existing linearizable-read primitive, rather than reaching into `:ra`
  # itself. Tries every survivor in turn (mirroring `Riptide.Placement`'s own
  # `with_ordinal_fallback/2` "try the next one on failure" shape) since any
  # single survivor being briefly unreachable shouldn't block discovering a
  # value every survivor's machine state agrees on.
  @spec discover_retention(String.t(), [node()]) :: {:ok, term()} | :error
  defp discover_retention(uid, survivor_nodes) do
    name = String.to_atom(uid)

    Enum.find_value(survivor_nodes, :error, fn node ->
      try do
        {:ok, RaCluster.consistent_query({name, node}, &Map.get(&1, :retention))}
      rescue
        _ -> nil
      end
    end)
  end
end
