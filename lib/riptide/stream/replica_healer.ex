defmodule Riptide.Stream.ReplicaHealer do
  @moduledoc """
  Fully automatic background repair for a stream's replica set — see Phase
  3d-ii design spec for the full motivation. Runs unconditionally on every
  fleet node (Phase 3e removed the old 3-fixed-ordinal gate) — but only the
  placement cluster's current Raft leader ever acts on a given sweep
  (`RaCluster.Placement.placement_leader?/0`), so it's a no-op everywhere
  except that one node. Reuses that cluster's own existing leader election
  as single-writer safety, rather than a new coordination mechanism. No
  operator action is required in the steady-state case.
  """

  use Riptide.PeriodicSweep,
    default_interval_ms: 30_000,
    interval_env_key: :replica_healer_sweep_interval_ms

  use GenServer
  require Logger

  alias Riptide.Placement
  alias Riptide.RaCluster
  alias Riptide.Stream.RaMachine

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  # Only the placement cluster's actual leader ever performs a real repair
  # (`RaCluster.Placement.placement_leader?/0`) — `sweep/0` below stays
  # public and ungated on purpose: existing tests
  # (`replica_healer_cluster_test.exs`) call it directly to exercise repair
  # logic without needing to be the leader; the gate lives only here.
  @impl Riptide.PeriodicSweep
  def periodic_sweep do
    if RaCluster.Placement.placement_leader?(), do: sweep(), else: :ok
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
      [dead_node] ->
        :telemetry.execute([:riptide, :replica_healer, :dead_replica_detected], %{}, %{})
        repair(stream_id, uid, nodes, dead_node)

      _ ->
        :ok
    end
  end

  # Fences this repair through the placement Ra cluster's own consensus
  # (see Riptide.Placement.PlacementMachine's moduledoc, "Repair claims")
  # rather than trusting `RaCluster.Placement.placement_leader?/0`'s unfenced,
  # point-in-time belief alone — closes a dual-leader race where two
  # placement ordinals both briefly believing they're the leader during a
  # handoff/partition could each fully commit a *different* replacement
  # node for the same dead replica, leaving an untracked, over-replicated
  # extra member with no cleanup path. `release_repair/1` always runs (even
  # if the repair itself raises/fails) so a crash mid-repair doesn't
  # permanently wedge this stream's repair path any longer than the claim's
  # own TTL.
  defp repair(stream_id, uid, nodes, dead_node) do
    case Placement.claim_repair(stream_id, dead_node) do
      :already_claimed ->
        :ok

      :claimed ->
        try do
          do_claimed_repair(stream_id, uid, nodes, dead_node)
        after
          Placement.release_repair(stream_id)
        end
    end
  end

  defp do_claimed_repair(stream_id, uid, nodes, dead_node) do
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
                "survivor (#{inspect(survivor_nodes)}); skipping repair this tick",
              stream_id: stream_id,
              survivor_nodes: inspect(survivor_nodes)
            )

            :telemetry.execute([:riptide, :replica_healer, :repair], %{}, %{result: :error})
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
          "ReplicaHealer repaired #{stream_id}: replaced #{inspect(dead_node)} with #{inspect(new_node)}",
          stream_id: stream_id,
          dead_node: inspect(dead_node),
          new_node: inspect(new_node)
        )

        :telemetry.execute([:riptide, :replica_healer, :repair], %{}, %{result: :ok})

      {:error, reason} ->
        Logger.warning(
          "ReplicaHealer failed to repair #{stream_id} (dead: #{inspect(dead_node)}): #{inspect(reason)}",
          stream_id: stream_id,
          dead_node: inspect(dead_node),
          reason: inspect(reason)
        )

        :telemetry.execute([:riptide, :replica_healer, :repair], %{}, %{result: :error})
    end
  end

  @doc """
  Picks a live fleet node to replace a dead member with — a candidate not
  already among `current_nodes`. Deterministic (sorted, first candidate)
  rather than random, unlike `Riptide.Placement.propose_nodes/2`'s own
  selection for a brand-new stream: two concurrent or retried repair
  attempts for the very same `{stream_id, dead_node}` pair need to always
  compute the same `current_nodes`/`live_nodes` inputs, so that picking
  deterministically means they always converge on the same replacement node
  too — turning a redundant second attempt (e.g. after a partial failure, or
  a leadership handoff mid-sweep — see finding 3, Phase 3d-ii final review)
  into a safe retry of the same repair instead of a competing one that could
  leave the stream over-replicated.

  `live_nodes` defaults to `[node() | Node.list()]`, NOT bare `Node.list()`
  — this matters because `Node.list()` never includes the calling node
  itself, so two different callers (e.g. two different placement ordinals,
  racing across that same leadership handoff) each get a DIFFERENT raw
  `Node.list()`: one that excludes only itself. If the sorted-first pick
  happened to land on one of those excluded callers — a real possibility,
  since a placement ordinal is just as valid a replacement candidate as any
  other fleet node, especially in a small cluster where the fleet is
  essentially just the 3 placement ordinals — the two callers would compute
  DIFFERENT replacements, defeating the determinism this function exists to
  guarantee. Prepending `node()` closes that asymmetry: as long as the
  cluster is fully connected (the normal case), every caller's
  `[node() | Node.list()]` resolves to the exact same full fleet, just in a
  different order — and `pick_replacement/2`'s own sort makes it
  order-independent. Overridable for tests, mirroring `propose_nodes/2`'s
  own `peers \\ Node.list()` pattern.
  """
  @spec pick_replacement([node()], [node()]) :: node() | nil
  def pick_replacement(current_nodes, live_nodes \\ [node() | Node.list()]) do
    case (live_nodes -- current_nodes) |> Enum.uniq() |> Enum.sort() do
      [] -> nil
      [node | _rest] -> node
    end
  end

  # `RaCluster` is the sole module allowed to call `:ra` directly (see its
  # own moduledoc) — this goes through `RaCluster.consistent_query/2`, the
  # existing linearizable-read primitive, rather than reaching into `:ra`
  # itself. Tries every survivor in turn (mirroring `Riptide.Placement`'s own
  # `with_current_members/1` "try the next one on failure" shape) since any
  # single survivor being briefly unreachable shouldn't block discovering a
  # value every survivor's machine state agrees on.
  #
  # Also catches `:exit`, not just `rescue`s: `RaCluster.consistent_query/2`
  # (and the underlying `:ra.consistent_query/2` it wraps) can genuinely
  # *exit* rather than raise or return an `{:error, _}`/`{:timeout, _}` in
  # some failure modes — the same class of failure `RaCluster.Placement.placement_leader?/0`
  # already guards against with its own `catch :exit` (see finding 5, Phase
  # 3d-ii final review). A `rescue` clause alone does not catch an `exit`, so
  # without this a survivor dying exactly during this query would crash this
  # GenServer's synchronous sweep outright instead of just moving on to the
  # next survivor — the same "briefly unreachable shouldn't block discovery"
  # rationale this function already follows for raised errors.
  @spec discover_retention(String.t(), [node()]) :: {:ok, term()} | :error
  defp discover_retention(uid, survivor_nodes) do
    name = String.to_atom(uid)

    Enum.find_value(survivor_nodes, :error, fn node ->
      try do
        {:ok, RaCluster.consistent_query({name, node}, &Map.get(&1, :retention))}
      rescue
        _ -> nil
      catch
        :exit, _ -> nil
      end
    end)
  end
end
