defmodule Riptide.Placement.PlacementMachine do
  @moduledoc """
  The `:ra_machine` for Riptide's placement metadata cluster — a small,
  fixed-membership Ra cluster (see `Riptide.RaCluster.placement_server_id/1,2`)
  recording which nodes host each stream's Ra replicas. Pure and process-free
  by design, mirroring `Riptide.Stream.RaMachine`: `init/1`/`apply/3` are the
  only functions Ra itself calls; `get/2` is a plain query function run via
  `Riptide.RaCluster.consistent_query/2`.
  """
  @behaviour :ra_machine

  @type state :: %{String.t() => [node()]}

  @impl :ra_machine
  def init(_config), do: %{}

  # Idempotent by construction — see Phase 3c-i design spec §4. Since every
  # command is serialized through Raft consensus, whichever proposal for a
  # given stream_id lands in the log first wins; a later, different proposal
  # for the same already-assigned stream_id is silently ignored and the
  # caller gets back the existing (winning) assignment instead of an error.
  # This makes concurrent stream-creation races safe with no extra locking.
  @impl :ra_machine
  def apply(_meta, {:assign, stream_id, proposed_nodes}, state) do
    case Map.fetch(state, stream_id) do
      {:ok, existing_nodes} ->
        {state, existing_nodes, []}

      :error ->
        new_state = Map.put(state, stream_id, proposed_nodes)
        {new_state, proposed_nodes, []}
    end
  end

  @spec get(state(), String.t()) :: [node()] | nil
  def get(state, stream_id) do
    Map.get(state, stream_id)
  end
end
