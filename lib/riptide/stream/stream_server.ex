defmodule Riptide.Stream.StreamServer do
  @moduledoc """
  Per-stream durable event log. A thin client over a real, placement-driven
  `Ra` cluster (see `Riptide.Stream.Placement`, `Riptide.RaCluster`) — no
  GenServer of our own; Ra owns the process(es) and their durability.
  """

  alias Riptide.Event
  alias Riptide.RaCluster
  alias Riptide.Stream.Placement
  alias Riptide.Stream.RaMachine

  # NOTE: `retention` is only applied when a stream's Ra cluster is first
  # created. On any later call for an existing stream this just resumes the
  # already-persisted server(s) from disk (via `Placement.ensure_started/2`,
  # which keeps whatever machine config the cluster was originally formed
  # with) — so passing a *different* `retention:` here for a stream that
  # already exists is silently ignored. Changing a live stream's retention
  # would need an explicit reconfiguration path (not in scope for Phase 1).
  @spec start_link({String.t(), keyword()}) :: {:ok, pid()} | {:error, term()}
  def start_link({stream_id, opts}) do
    retention = Keyword.get(opts, :retention, :infinity)
    machine = {:module, RaMachine, %{retention: retention}}

    case Placement.ensure_started(stream_id, machine) do
      {:ok, server_ids} ->
        {name, _node} = hd(server_ids)

        case wait_for_process(name) do
          {:ok, pid} -> {:ok, pid}
          :timeout -> {:error, :not_started}
        end

      {:error, _reason} = error ->
        error
    end
  end

  @spec start_link(String.t()) :: {:ok, pid()} | {:error, term()}
  def start_link(stream_id) when is_binary(stream_id) do
    start_link({stream_id, []})
  end

  @spec append(String.t(), Event.t()) :: Event.t()
  def append(stream_id, %Event{} = event) do
    server_id = hd(Placement.server_ids!(stream_id))
    stamped = RaCluster.process_command(server_id, {:append, Event.encode(event)})
    Phoenix.PubSub.broadcast(Riptide.PubSub, "stream:" <> stream_id, {:new_event, stamped})
    stamped
  end

  # Uses `consistent_query/2`, not `local_query/2` — see issue #8. Reads
  # deterministically observe the fully recovered log even immediately after
  # a restart, at the cost of a leader round-trip once the cluster has real
  # peers (Phase 3c-ii onward) — acceptable here since this is called once
  # per connection/request (LDP GET, SSE subscribe, WebSocket replication
  # join), never per event; live delivery after that point is
  # `Phoenix.PubSub`-only (see `append/2`).
  @spec get_since(String.t(), non_neg_integer() | nil) ::
          {:ok, [Event.t()]} | {:gap, pos_integer() | nil}
  def get_since(stream_id, cursor) do
    server_id = hd(Placement.server_ids!(stream_id))
    RaCluster.consistent_query(server_id, &RaMachine.get_since(&1, cursor))
  end

  # Bridges a liveness gap that only exists because `Placement.ensure_started/2`
  # can return via its cache-hit path (Task 4), which is just an ETS lookup —
  # no fresh `:ra` call at all. The old `RaCluster.start_or_restart/2` this
  # replaced always made a blocking `:ra.start_cluster`/`:ra.restart_server`
  # call, which incidentally gave Ra's supervisor time to finish
  # re-registering a just-killed process's name before returning. Without
  # that, `start_link/1` on a stream that's cached but whose process was just
  # killed (e.g. `Process.exit(pid, :kill)` in this file's own tests) can hit
  # `Process.whereis/1` in the ~1-2ms window after Ra's supervisor notices
  # the exit but before it re-registers the restarted process under the same
  # name — confirmed by reproducing the race 30/30 times. This directly
  # matters for `StreamServerTest`'s "events and sequence numbers survive
  # killing and restarting the Ra process" and the 100-trial issue #8 test,
  # both of which kill and immediately restart a stream's process. The 100 x
  # 10ms = ~1s bound here is generous relative to the observed ~1-2ms gap;
  # it's a belt-and-suspenders ceiling, not a tuned timeout.
  @spec wait_for_process(term(), non_neg_integer()) :: {:ok, pid()} | :timeout
  defp wait_for_process(name, attempts \\ 100) do
    case Process.whereis(name) do
      pid when is_pid(pid) -> {:ok, pid}
      nil when attempts > 0 ->
        Process.sleep(10)
        wait_for_process(name, attempts - 1)
      nil -> :timeout
    end
  end
end
