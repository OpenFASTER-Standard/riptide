defmodule Riptide.Placement.PlacementMachine do
  @moduledoc """
  The `:ra_machine` for Riptide's placement metadata cluster — a small,
  elastic-membership Ra cluster (see `Riptide.PlacementMembership`)
  recording which nodes host each stream's Ra replicas, plus (Phase 4c)
  authorization policies. Pure and process-free by design, mirroring
  `Riptide.Stream.RaMachine`: `init/1`/`apply/3` are the only functions Ra
  itself calls; `get/2`/`list/1`/`list_policies/3` are plain query functions
  run via `Riptide.RaCluster.consistent_query/2`.

  Internal state is `%{streams: %{stream_id() => [node()]}, policies:
  %{tenant_id() => %{path_prefix() => [policy()]}}, repair_claims:
  %{stream_id() => repair_claim()}}` — three independent namespaces in one
  already-hardened, already-bootstrapped Ra cluster, rather than a second
  cluster to operate. `list/1`'s own external contract is deliberately
  unchanged (`%{stream_id() => [node()]}` only): it backs
  `Riptide.Placement.list_all/1`, which `Riptide.Stream.ReplicaHealer.sweep/0`
  iterates expecting *only* `{stream_id, nodes}` entries — mixing a policies
  or repair_claims key into that same flat map would make the healer call
  `RaCluster.uid_for/1` on a non-stream-id key and crash its next sweep.

  ## Repair claims (audit remediation, 2026-08-27)

  `RaCluster.placement_leader?/0` is an unfenced, point-in-time local read
  with no lease — during a leadership handoff or partition, two different
  placement ordinals can both briefly believe they're the leader and both
  run `Riptide.Stream.ReplicaHealer.sweep/0` concurrently for the same dead
  replica. Since `pick_replacement/2`'s own determinism guarantee only holds
  "as long as the cluster is fully connected" (see its own doc) — exactly
  the condition a partition breaks — the two racing healers can pick
  *different* replacement nodes and each fully add/join their own choice to
  the stream's real Ra cluster before either gets to `remove_member`,
  leaving a genuinely over-replicated, untracked extra member with no
  cleanup path.

  `{:claim_repair, ...}`/`{:release_repair, ...}` route the *decision to
  start repairing a given `{stream_id, dead_node}` pair* through this same
  Raft-serialized state machine, so only one committed claim can ever be
  granted at a time for a given stream — not just one leader's point-in-time
  belief. `claimed_at` is a timestamp the CALLER computes and passes in as
  part of the command (never read from the wall clock inside `apply/3`
  itself, which would break replica determinism); a claim older than
  `@claim_ttl_seconds` can be stolen by a fresh claimant, so a claimer that
  crashes or fails to release doesn't permanently wedge that stream's repair
  path — the TTL is generous relative to both the sweep interval and a
  realistic repair's own duration, so it should essentially never fire in
  the normal case where the original claimant successfully releases.
  """
  @behaviour :ra_machine

  @type stream_id :: String.t()
  @type tenant_id :: String.t()
  @type path_prefix :: [String.t()]
  @type policy :: struct()
  @type repair_claim :: %{dead_node: node(), claimant: node(), claimed_at: integer()}

  @type state :: %{
          streams: %{stream_id() => [node()]},
          policies: %{tenant_id() => %{path_prefix() => [policy()]}},
          repair_claims: %{stream_id() => repair_claim()}
        }

  @claim_ttl_seconds 120

  @impl :ra_machine
  def init(_config), do: %{streams: %{}, policies: %{}, repair_claims: %{}}

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

  # Grants exclusive right to repair `{stream_id, dead_node}` to `claimant`,
  # unless: (a) no claim exists yet, (b) the existing claim already belongs
  # to this same claimant/dead_node pair (idempotent retry — e.g. the same
  # leader's sweep running again before it got to release), or (c) the
  # existing claim has aged past `@claim_ttl_seconds` (its holder presumably
  # crashed or otherwise failed to release). Otherwise denies — a DIFFERENT
  # claimant already holds a live claim on this stream.
  @impl :ra_machine
  def apply(_meta, {:claim_repair, stream_id, dead_node, claimant, now_ts}, state) do
    case Map.get(state.repair_claims, stream_id) do
      nil ->
        grant_repair_claim(state, stream_id, dead_node, claimant, now_ts)

      %{claimant: ^claimant, dead_node: ^dead_node} ->
        grant_repair_claim(state, stream_id, dead_node, claimant, now_ts)

      %{claimed_at: claimed_at} when now_ts - claimed_at > @claim_ttl_seconds ->
        grant_repair_claim(state, stream_id, dead_node, claimant, now_ts)

      _held_by_someone_else ->
        {state, :already_claimed, []}
    end
  end

  # Releases `claimant`'s own claim, if it still holds one — a release from
  # a claimant that doesn't currently hold the claim (already expired and
  # stolen by a fresh claimant, or never held one) is a safe no-op rather
  # than an error, so a stale/duplicate release can never clear someone
  # else's active claim.
  @impl :ra_machine
  def apply(_meta, {:release_repair, stream_id, claimant}, state) do
    case Map.get(state.repair_claims, stream_id) do
      %{claimant: ^claimant} ->
        new_state = %{state | repair_claims: Map.delete(state.repair_claims, stream_id)}
        {new_state, :ok, []}

      _not_this_claimant ->
        {state, :ok, []}
    end
  end

  # Bounds unbounded growth from a client (malicious, or merely a buggy
  # retry loop) calling `POST /tenants/:id/policies` with the same or
  # near-identical body repeatedly: `existing ++ [policy]` with no cap would
  # otherwise grow this in-memory, Raft-replicated list forever, and every
  # entry is scanned linearly on every `Riptide.Authz.evaluate/4` call for
  # that tenant, so unbounded growth here also degrades every authorization
  # decision's latency. Deduplicating exact-duplicate policies closes the
  # most common case (identical retries) for free; `@max_policies_per_prefix`
  # bounds the rest. Same idempotent-by-construction shape as {:assign, ...}
  # otherwise: every command is serialized through Raft, so concurrent
  # `add_policy` calls for the same tenant/prefix are safely ordered by the
  # log rather than racing.
  @max_policies_per_prefix 1000

  @impl :ra_machine
  def apply(_meta, {:add_policy, tenant_id, path_prefix, policy}, state) do
    existing = state.policies |> Map.get(tenant_id, %{}) |> Map.get(path_prefix, [])

    cond do
      policy in existing ->
        {state, :ok, []}

      length(existing) >= @max_policies_per_prefix ->
        {state, {:error, :too_many_policies}, []}

      true ->
        new_state =
          put_in(
            state,
            [:policies, Access.key(tenant_id, %{}), path_prefix],
            existing ++ [policy]
          )

        {new_state, :ok, []}
    end
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

  defp grant_repair_claim(state, stream_id, dead_node, claimant, now_ts) do
    claim = %{dead_node: dead_node, claimant: claimant, claimed_at: now_ts}
    new_state = put_in(state, [:repair_claims, stream_id], claim)
    {new_state, :claimed, []}
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
