defmodule Riptide.Placement do
  @moduledoc """
  Client API for Riptide's placement metadata cluster — the durable
  `stream_id -> [replica nodes]` mapping maintained by
  `Riptide.Placement.PlacementMachine` via a small, fixed-membership Ra
  cluster (see `Riptide.RaCluster.placement_server_id/1,2`).

  `assign/2,3` and `lookup/1,2` currently always address the metadata cluster
  via its first fixed ordinal (`RaCluster.placement_ordinals() |> hd()`) —
  `:ra`'s own leader-redirect means this works whether or not that specific
  ordinal happens to be the current leader, but if that one ordinal's own pod
  is unreachable, these calls fail outright rather than falling back to a
  different ordinal. Acceptable for this phase's narrow scope; revisit if it
  proves to matter in practice.
  """

  alias Riptide.Placement.PlacementMachine
  alias Riptide.RaCluster

  @replication_factor 3

  @spec propose_nodes(pos_integer(), [node()]) :: [node()]
  def propose_nodes(replication_factor \\ @replication_factor, peers \\ Node.list()) do
    local = node()
    remaining = max(replication_factor - 1, 0)
    other_candidates = peers -- [local]

    [local | select_nodes(other_candidates, remaining)]
  end

  @spec select_nodes([node()], pos_integer()) :: [node()]
  def select_nodes(candidate_nodes, count) do
    candidate_nodes
    |> Enum.uniq()
    |> Enum.shuffle()
    |> Enum.take(count)
  end

  @spec assign(String.t(), [node()], (String.t() -> node())) :: [node()]
  def assign(stream_id, proposed_nodes, resolve_fun \\ &RaCluster.default_ordinal_resolver/1) do
    RaCluster.process_command(
      placement_server_id(resolve_fun),
      {:assign, stream_id, proposed_nodes}
    )
  end

  @spec lookup(String.t(), (String.t() -> node())) :: [node()] | nil
  def lookup(stream_id, resolve_fun \\ &RaCluster.default_ordinal_resolver/1) do
    RaCluster.consistent_query(
      placement_server_id(resolve_fun),
      &PlacementMachine.get(&1, stream_id)
    )
  end

  defp placement_server_id(resolve_fun) do
    RaCluster.placement_server_id(hd(RaCluster.placement_ordinals()), resolve_fun)
  end
end
