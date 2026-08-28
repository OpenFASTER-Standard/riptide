defmodule Riptide.Placement do
  @moduledoc """
  Client API for Riptide's placement metadata cluster — the durable
  `stream_id -> [replica nodes]` mapping maintained by
  `Riptide.Placement.PlacementMachine` via a small, elastic-membership Ra
  cluster (see `Riptide.PlacementMembership`).

  Every function here addresses the metadata cluster by trying each
  currently-known member in turn (fast path: `Riptide.PlacementMembership`'s
  broadcast-maintained cache; fallback: a live fleet-wide probe when the
  cache is empty or exhausted) until one succeeds — `:ra`'s own
  leader-redirect already means any live member can serve the request
  whether or not it happens to be the current leader. See Phase 3e design
  spec for the full discovery rationale (this replaces the old fixed-3-
  ordinal fallback).
  """

  require Logger

  alias Riptide.Placement.PlacementMachine
  alias Riptide.PlacementMembership
  alias Riptide.RaCluster

  @replication_factor 3

  @spec propose_nodes(pos_integer(), [node()]) :: [node()]
  def propose_nodes(replication_factor \\ @replication_factor, candidate_nodes \\ Node.list()) do
    local = node()
    remaining = max(replication_factor - 1, 0)
    other_candidates = candidate_nodes -- [local]

    [local | select_nodes(other_candidates, remaining)]
  end

  @spec select_nodes([node()], pos_integer()) :: [node()]
  def select_nodes(candidate_nodes, count) do
    candidate_nodes
    |> Enum.uniq()
    |> Enum.shuffle()
    |> Enum.take(count)
  end

  @spec assign(String.t(), [node()]) :: [node()]
  def assign(stream_id, proposed_nodes) do
    :telemetry.span([:riptide, :placement, :assign], %{}, fn ->
      result =
        with_current_members(fn server_id ->
          RaCluster.process_command(server_id, {:assign, stream_id, proposed_nodes})
        end)

      {result, %{}}
    end)
  end

  @spec lookup(String.t()) :: [node()] | nil
  def lookup(stream_id) do
    :telemetry.span([:riptide, :placement, :lookup], %{}, fn ->
      result =
        with_current_members(fn server_id ->
          RaCluster.consistent_query(server_id, &PlacementMachine.get(&1, stream_id))
        end)

      {result, %{}}
    end)
  end

  @spec list_all() :: %{String.t() => [node()]}
  def list_all do
    with_current_members(fn server_id ->
      RaCluster.consistent_query(server_id, &PlacementMachine.list/1)
    end)
  end

  @spec replace_member(String.t(), node(), node()) :: [node()] | nil
  def replace_member(stream_id, dead_node, new_node) do
    with_current_members(fn server_id ->
      RaCluster.process_command(server_id, {:replace_member, stream_id, dead_node, new_node})
    end)
  end

  # See Riptide.Placement.PlacementMachine's own moduledoc ("Repair claims")
  # for the full rationale: fences Riptide.Stream.ReplicaHealer's repair
  # against two nodes both believing they're the leader at once. `now_ts` is
  # computed here (the caller), not inside `apply/3` — reading the wall
  # clock inside a Ra machine callback would break replica determinism.
  @spec claim_repair(String.t(), node()) :: :claimed | :already_claimed
  def claim_repair(stream_id, dead_node) do
    now_ts = System.system_time(:second)

    with_current_members(fn server_id ->
      RaCluster.process_command(
        server_id,
        {:claim_repair, stream_id, dead_node, node(), now_ts}
      )
    end)
  end

  @spec release_repair(String.t()) :: :ok
  def release_repair(stream_id) do
    with_current_members(fn server_id ->
      RaCluster.process_command(server_id, {:release_repair, stream_id, node()})
    end)
  end

  @spec add_policy(String.t(), [String.t()], Riptide.Authz.Policy.t()) ::
          :ok | {:error, :too_many_policies}
  def add_policy(tenant_id, path_prefix, policy) do
    with_current_members(fn server_id ->
      RaCluster.process_command(server_id, {:add_policy, tenant_id, path_prefix, policy})
    end)
  end

  @spec list_policies(String.t(), [String.t()]) :: [Riptide.Authz.Policy.t()]
  def list_policies(tenant_id, path_prefix) do
    with_current_members(fn server_id ->
      RaCluster.consistent_query(
        server_id,
        &PlacementMachine.list_policies(&1, tenant_id, path_prefix)
      )
    end)
  end

  @spec claim_tenant_if_unclaimed(String.t(), String.t()) :: :claimed | :already_claimed
  def claim_tenant_if_unclaimed(tenant_id, subject) do
    with_current_members(fn server_id ->
      RaCluster.process_command(server_id, {:claim_tenant_if_unclaimed, tenant_id, subject})
    end)
  end

  # Tries each currently-known member, in order, until one answers —
  # `RaCluster.process_command/2` and `consistent_query/2` both raise on
  # failure/timeout, so a failing member is caught here and the next one
  # tried instead of the whole call failing outright. If every member from
  # the fast-path cache fails, falls back to a live fleet-wide probe
  # (`RaCluster.Placement.probe_placement_members/1`) before finally raising — a
  # totally unreachable metadata cluster is a genuine, fully-down failure no
  # caller here can paper over.
  #
  # `:placement_members_override` is a narrow, test-only escape hatch (never
  # read outside `mix test`) letting a test simulate "no reachable member"
  # without tearing down the real shared suite-wide placement cluster other
  # tests depend on — see `test/riptide_web/health_test.exs` and
  # `test/riptide_web/realtime/sse_controller_test.exs`.
  @spec with_current_members((:ra.server_id() -> term())) :: term()
  defp with_current_members(fun) do
    case Application.get_env(:riptide, :placement_members_override) do
      nil -> with_current_members_via_discovery(fun)
      override_members -> with_current_members_via_list(override_members, fun)
    end
  end

  defp with_current_members_via_discovery(fun) do
    cached = PlacementMembership.current_members()

    case try_members(cached, fun) do
      {:ok, result} -> result
      :error -> with_current_members_via_probe(fun)
    end
  end

  defp with_current_members_via_probe(fun) do
    case RaCluster.Placement.probe_placement_members([node() | Node.list()]) do
      {:ok, members} -> with_current_members_via_list(members, fun)
      :error -> raise "Riptide.Placement: no placement-cluster members could be discovered"
    end
  end

  defp with_current_members_via_list(members, fun) do
    case try_members(members, fun) do
      {:ok, result} -> result
      :error -> raise "Riptide.Placement: no placement-cluster members could be reached"
    end
  end

  defp try_members([], _fun), do: :error

  defp try_members([node | rest], fun) do
    {:ok, fun.(RaCluster.Placement.placement_server_id(node))}
  rescue
    e ->
      log_member_fallback(node, Exception.message(e))
      try_members(rest, fun)
  catch
    :exit, reason ->
      log_member_fallback(node, inspect(reason))
      try_members(rest, fun)
  end

  # A single member failing over is expected/routine during a rolling
  # restart or a transient network blip — this is intentionally a warning,
  # not swallowed silently, so a *persistently* unreachable member is at
  # least visible in logs even though only total failure is reflected in
  # the `riptide.placement.lookup/assign.errors` metrics.
  defp log_member_fallback(node, reason) do
    Logger.warning(
      "Riptide.Placement: member #{inspect(node)} failed, falling back to the next one " <>
        "(#{reason})",
      node: node,
      reason: reason
    )

    :telemetry.execute([:riptide, :placement, :member_fallback], %{}, %{})
  end
end
