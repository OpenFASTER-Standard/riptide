defmodule Riptide.Stream.StreamServer do
  @moduledoc """
  Per-stream durable event log. A thin client over a single-node `Ra`
  cluster (see `Riptide.RaCluster`) running `Riptide.Stream.RaMachine` —
  no GenServer of our own; Ra owns the process and its durability.
  """

  alias Riptide.Event
  alias Riptide.RaCluster
  alias Riptide.Stream.RaMachine

  # NOTE: `retention` is only applied when a stream's Ra cluster is first
  # created. On any later call for an existing stream this just restarts the
  # already-persisted server from disk (via `RaCluster.start_or_restart/2`),
  # which keeps its original machine config — so passing a *different*
  # `retention:` here for a stream that already exists is silently ignored.
  # Changing a live stream's retention would need an explicit reconfiguration
  # path (not in scope for Phase 1).
  @spec start_link({String.t(), keyword()}) :: {:ok, pid()} | {:error, term()}
  def start_link({stream_id, opts}) do
    retention = Keyword.get(opts, :retention, :infinity)
    machine = {:module, RaMachine, %{retention: retention}}
    {name, _node} = RaCluster.start_or_restart(stream_id, machine)

    case Process.whereis(name) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> {:error, :not_started}
    end
  end

  @spec start_link(String.t()) :: {:ok, pid()} | {:error, term()}
  def start_link(stream_id) when is_binary(stream_id) do
    start_link({stream_id, []})
  end

  @spec append(String.t(), Event.t()) :: Event.t()
  def append(stream_id, %Event{} = event) do
    server_id = RaCluster.server_id(stream_id)
    stamped = RaCluster.process_command(server_id, {:append, event})
    Phoenix.PubSub.broadcast(Riptide.PubSub, "stream:" <> stream_id, {:new_event, stamped})
    stamped
  end

  # Uses `consistent_query/2`, not `local_query/2` — see issue #8. At
  # Riptide's current cluster size of 1, this closes a real post-restart
  # staleness window (`local_query` could observe a not-yet-fully-replayed
  # state right after a restart) essentially for free: `:ra` skips its
  # peer-heartbeat step entirely when there are zero peers, so
  # `consistent_query` costs no network round-trip here, only ~14% on an
  # already-sub-4-microsecond local read (measured against the pinned `:ra`
  # version). Revisit if/when a future Clustering/HA sub-project makes
  # cluster size > 1 the norm, since the heartbeat-round-trip cost this
  # avoided only exists once there are real peers to contact.
  #
  # This is called exactly once per connection/request by every caller (LDP
  # GET, SSE subscribe, WebSocket replication join) — live delivery after
  # that point is `Phoenix.PubSub`-only (see `append/2`), not repeated
  # `get_since/2` polling. So the cost above is paid once per connection,
  # never per event, and a stale backlog here wouldn't just be a freshness
  # blip — it would permanently omit events from that connection's history.
  @spec get_since(String.t(), non_neg_integer() | nil) ::
          {:ok, [Event.t()]} | {:gap, pos_integer() | nil}
  def get_since(stream_id, cursor) do
    server_id = RaCluster.server_id(stream_id)
    RaCluster.consistent_query(server_id, &RaMachine.get_since(&1, cursor))
  end
end
