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
  @stream_machine {:module, RaMachine, %{retention: :infinity}}

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
        case RaCluster.replace_member(uid, survivor_nodes, dead_node, new_node, @stream_machine) do
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
  end

  @doc """
  Picks a live fleet node to replace a dead member with — a candidate not
  already among `current_nodes`, chosen the same random-selection way
  `Riptide.Placement.propose_nodes/2` already picks a new stream's initial
  replicas. `live_nodes` defaults to `Node.list()` but is overridable for
  tests, mirroring `propose_nodes/2`'s own `peers \\ Node.list()` pattern.
  """
  @spec pick_replacement([node()], [node()]) :: node() | nil
  def pick_replacement(current_nodes, live_nodes \\ Node.list()) do
    case Placement.select_nodes(live_nodes -- current_nodes, 1) do
      [node] -> node
      [] -> nil
    end
  end
end
