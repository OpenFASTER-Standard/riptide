defmodule Riptide.NewStreamRateLimit do
  @moduledoc """
  Rate-limits how many brand-new streams a single subject can cause to be
  created via SSE subscribe (`RiptideWeb.Realtime.SseController`) or
  WebSocket replication join (`RiptideWeb.Realtime.ReplicationChannel`) in
  a time window.

  Both of those entry points intentionally allow subscribing to a stream
  before its first write (a client watching for a soon-to-be-created
  resource), so creation there can't simply be refused the way
  `RiptideWeb.LDP.ResourceController.current_state/1`'s read path refuses
  it. `Riptide.RaCluster.uid_for/server_id` mints a permanent, never-freed
  BEAM atom for every distinct stream_id a caller asks about — capping the
  *rate* of new-stream creation is the mitigation for the paths that must
  still allow creation.

  Deliberately narrow: not a general-purpose rate limiter for every route.
  """

  use Hammer, backend: :ets

  @default_limit 30
  @default_scale_ms :timer.minutes(1)

  @doc """
  Checks whether `subject` may cause one more brand-new stream to be
  created right now. Callers should only invoke this when they've already
  confirmed (via `Riptide.Placement.lookup/1` returning `nil`) that the
  stream in question doesn't exist yet — an already-existing stream must
  never be throttled.
  """
  @spec check_new_stream(String.t()) :: :allow | :deny
  def check_new_stream(subject) do
    limit = Application.get_env(:riptide, :new_stream_rate_limit, @default_limit)
    scale_ms = Application.get_env(:riptide, :new_stream_rate_scale_ms, @default_scale_ms)

    case hit("new_stream:#{subject}", scale_ms, limit) do
      {:allow, _count} -> :allow
      {:deny, _retry_after} -> :deny
    end
  end
end
