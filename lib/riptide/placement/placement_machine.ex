defmodule Riptide.Placement.PlacementMachine do
  @moduledoc """
  The `:ra_machine` for Riptide's placement metadata cluster — a small,
  fixed-membership Ra cluster (see `Riptide.RaCluster.placement_server_id/1,2`)
  recording which nodes host each stream's Ra replicas, plus (Phase 4c)
  authorization policies. Pure and process-free by design, mirroring
  `Riptide.Stream.RaMachine`: `init/1`/`apply/3` are the only functions Ra
  itself calls; `get/2`/`list/1`/`list_policies/3` are plain query functions
  run via `Riptide.RaCluster.consistent_query/2`.

  Internal state is `%{streams: %{stream_id() => [node()]}, policies:
  %{tenant_id() => %{path_prefix() => [policy()]}}}` — two independent
  namespaces in one already-hardened, already-bootstrapped Ra cluster,
  rather than a second cluster to operate. `list/1`'s own external contract
  is deliberately unchanged (`%{stream_id() => [node()]}` only): it backs
  `Riptide.Placement.list_all/1`, which `Riptide.Stream.ReplicaHealer.sweep/0`
  iterates expecting *only* `{stream_id, nodes}` entries — mixing a policies
  key into that same flat map would make the healer call
  `RaCluster.uid_for/1` on a non-stream-id key and crash its next sweep.
  """
  @behaviour :ra_machine

  @type stream_id :: String.t()
  @type tenant_id :: String.t()
  @type path_prefix :: [String.t()]
  @type policy :: struct()

  @type state :: %{
          streams: %{stream_id() => [node()]},
          policies: %{tenant_id() => %{path_prefix() => [policy()]}}
        }

  @impl :ra_machine
  def init(_config), do: %{streams: %{}, policies: %{}}

  # Idempotent by construction — see Phase 3c-i design spec §4. Since every
  # command is serialized through Raft consensus, whichever proposal for a
  # given stream_id lands in the log first wins; a later, different proposal
  # for the same already-assigned stream_id is silently ignored and the
  # caller gets back the existing (winning) assignment instead of an error.
  # This makes concurrent stream-creation races safe with no extra locking.
  @impl :ra_machine
  def apply(_meta, {:assign, stream_id, proposed_nodes}, state) do
    case Map.fetch(state.streams, stream_id) do
      {:ok, existing_nodes} ->
        {state, existing_nodes, []}

      :error ->
        new_state = put_in(state, [:streams, stream_id], proposed_nodes)
        {new_state, proposed_nodes, []}
    end
  end

  # Idempotent the same way {:assign, ...} is: if `dead_node` is no longer
  # part of `stream_id`'s stored assignment (e.g. a different placement-
  # cluster leader, from a prior Raft term, already won this exact repair),
  # this is a no-op that returns the current assignment unchanged rather
  # than erroring — safe to call redundantly from a racing leader.
  @impl :ra_machine
  def apply(_meta, {:replace_member, stream_id, dead_node, new_node}, state) do
    case Map.fetch(state.streams, stream_id) do
      {:ok, nodes} ->
        if dead_node in nodes do
          new_nodes = replace_in_list(nodes, dead_node, new_node)
          new_state = put_in(state, [:streams, stream_id], new_nodes)
          {new_state, new_nodes, []}
        else
          {state, nodes, []}
        end

      :error ->
        {state, nil, []}
    end
  end

  # Same idempotent-by-construction shape as {:assign, ...}: every command is
  # serialized through Raft, so concurrent `add_policy` calls for the same
  # tenant/prefix are safely ordered by the log rather than racing.
  @impl :ra_machine
  def apply(_meta, {:add_policy, tenant_id, path_prefix, policy}, state) do
    existing = state.policies |> Map.get(tenant_id, %{}) |> Map.get(path_prefix, [])

    new_state =
      put_in(state, [:policies, Access.key(tenant_id, %{}), path_prefix], existing ++ [policy])

    {new_state, :ok, []}
  end

  # A tenant is "unclaimed" if it has zero policies at every path prefix —
  # see the Phase 4c design spec §6. This must be a single Ra command (not a
  # separate list-then-add pair of calls from the caller) so that two
  # different agents racing to claim the same brand-new tenant resolve to
  # exactly one winner, the same way `{:assign, ...}`'s own idempotency
  # relies on Raft's log ordering rather than a caller-side check-then-act.
  @impl :ra_machine
  def apply(_meta, {:claim_tenant_if_unclaimed, tenant_id, subject}, state) do
    if tenant_claimed?(state, tenant_id) do
      {state, :already_claimed, []}
    else
      owner_policy = %Riptide.Authz.Policy{
        effect: :allow,
        modes: [:read, :write],
        matcher: {:agent, subject}
      }

      new_state = put_in(state, [:policies, tenant_id], %{[] => [owner_policy]})
      {new_state, :claimed, []}
    end
  end

  defp replace_in_list(nodes, dead_node, new_node) do
    Enum.map(nodes, fn n -> if n == dead_node, do: new_node, else: n end)
  end

  defp tenant_claimed?(state, tenant_id) do
    state.policies
    |> Map.get(tenant_id, %{})
    |> Map.values()
    |> Enum.any?(&(&1 != []))
  end

  @spec get(state(), stream_id()) :: [node()] | nil
  def get(state, stream_id) do
    Map.get(state.streams, stream_id)
  end

  @spec list(state()) :: %{stream_id() => [node()]}
  def list(state), do: state.streams

  @spec list_policies(state(), tenant_id(), path_prefix()) :: [policy()]
  def list_policies(state, tenant_id, path_prefix) do
    state.policies
    |> Map.get(tenant_id, %{})
    |> Map.get(path_prefix, [])
  end
end
