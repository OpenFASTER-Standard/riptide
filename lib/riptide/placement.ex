defmodule Riptide.Placement do
  @moduledoc """
  Client API for Riptide's placement metadata cluster — the durable
  `stream_id -> [replica nodes]` mapping maintained by
  `Riptide.Placement.PlacementMachine` via a small, fixed-membership Ra
  cluster (see `Riptide.RaCluster.placement_server_id/1,2`).

  `assign/2,3` and `lookup/1,2` address the metadata cluster by trying each
  fixed ordinal in turn (starting from `RaCluster.placement_ordinals()`'s
  first entry) until one succeeds — `:ra`'s own leader-redirect already
  means any live member can serve the request whether or not it happens to
  be the current leader, so falling back to the next ordinal on failure
  needs no extra coordination. This used to hardcode the first ordinal only,
  making it a de-facto single point of failure for the entire placement
  layer on every restart of that one specific pod (confirmed live, Phase
  3d-i HA-proof spike, finding 2) even though the underlying 3-member Raft
  cluster stayed healthy via its other members the whole time.
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
    :telemetry.span([:riptide, :placement, :assign], %{}, fn ->
      result =
        with_ordinal_fallback(resolve_fun, fn server_id ->
          RaCluster.process_command(server_id, {:assign, stream_id, proposed_nodes})
        end)

      {result, %{}}
    end)
  end

  @spec lookup(String.t(), (String.t() -> node())) :: [node()] | nil
  def lookup(stream_id, resolve_fun \\ &RaCluster.default_ordinal_resolver/1) do
    :telemetry.span([:riptide, :placement, :lookup], %{}, fn ->
      result =
        with_ordinal_fallback(resolve_fun, fn server_id ->
          RaCluster.consistent_query(server_id, &PlacementMachine.get(&1, stream_id))
        end)

      {result, %{}}
    end)
  end

  @spec list_all((String.t() -> node())) :: %{String.t() => [node()]}
  def list_all(resolve_fun \\ &RaCluster.default_ordinal_resolver/1) do
    with_ordinal_fallback(resolve_fun, fn server_id ->
      RaCluster.consistent_query(server_id, &PlacementMachine.list/1)
    end)
  end

  @spec replace_member(String.t(), node(), node(), (String.t() -> node())) :: [node()] | nil
  def replace_member(
        stream_id,
        dead_node,
        new_node,
        resolve_fun \\ &RaCluster.default_ordinal_resolver/1
      ) do
    with_ordinal_fallback(resolve_fun, fn server_id ->
      RaCluster.process_command(server_id, {:replace_member, stream_id, dead_node, new_node})
    end)
  end

  @spec add_policy(String.t(), [String.t()], Riptide.Authz.Policy.t(), (String.t() -> node())) ::
          :ok
  def add_policy(
        tenant_id,
        path_prefix,
        policy,
        resolve_fun \\ &RaCluster.default_ordinal_resolver/1
      ) do
    with_ordinal_fallback(resolve_fun, fn server_id ->
      RaCluster.process_command(server_id, {:add_policy, tenant_id, path_prefix, policy})
    end)
  end

  @spec list_policies(String.t(), [String.t()], (String.t() -> node())) :: [
          Riptide.Authz.Policy.t()
        ]
  def list_policies(tenant_id, path_prefix, resolve_fun \\ &RaCluster.default_ordinal_resolver/1) do
    with_ordinal_fallback(resolve_fun, fn server_id ->
      RaCluster.consistent_query(
        server_id,
        &PlacementMachine.list_policies(&1, tenant_id, path_prefix)
      )
    end)
  end

  @spec claim_tenant_if_unclaimed(String.t(), String.t(), (String.t() -> node())) ::
          :claimed | :already_claimed
  def claim_tenant_if_unclaimed(
        tenant_id,
        subject,
        resolve_fun \\ &RaCluster.default_ordinal_resolver/1
      ) do
    with_ordinal_fallback(resolve_fun, fn server_id ->
      RaCluster.process_command(server_id, {:claim_tenant_if_unclaimed, tenant_id, subject})
    end)
  end

  # Tries each placement ordinal, in `RaCluster.placement_ordinals/0`'s own
  # fixed order, until one of them answers — `RaCluster.process_command/2`
  # and `consistent_query/2` both raise on failure/timeout (see their own
  # moduledoc rationale), so a failing ordinal is caught here and the next
  # one tried instead of the whole call failing outright. The very last
  # ordinal's exception is deliberately left to propagate uncaught: if *no*
  # ordinal in the whole fixed set can serve the request, that's a genuine,
  # fully-down metadata cluster, not something a caller here can paper over.
  @spec with_ordinal_fallback((String.t() -> node()), (:ra.server_id() -> term())) :: term()
  defp with_ordinal_fallback(resolve_fun, fun) do
    try_ordinals(RaCluster.placement_ordinals(), resolve_fun, fun)
  end

  defp try_ordinals([ordinal], resolve_fun, fun) do
    fun.(RaCluster.placement_server_id(ordinal, resolve_fun))
  end

  defp try_ordinals([ordinal | rest], resolve_fun, fun) do
    fun.(RaCluster.placement_server_id(ordinal, resolve_fun))
  rescue
    _ -> try_ordinals(rest, resolve_fun, fun)
  end
end
