defmodule Riptide.RaTestHelpers do
  @moduledoc """
  Ra persists to disk under a UID derived from stream_id (see
  `Riptide.RaCluster.uid_for/1`) — unlike the old in-memory GenServer,
  `start_supervised!`'s automatic teardown does NOT clean this up. Every
  test that starts a stream through `StreamServer`/`StreamSupervisor` must
  call this in `on_exit/1`, or a later test reusing the same stream_id will
  see stale data from a previous run.
  """

  alias Riptide.RaCluster

  @spec cleanup_stream(String.t()) :: :ok
  def cleanup_stream(stream_id), do: RaCluster.force_delete(stream_id)
end
