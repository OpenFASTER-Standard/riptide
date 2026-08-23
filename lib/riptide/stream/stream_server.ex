defmodule Riptide.Stream.StreamServer do
  @moduledoc """
  Per-stream durable event log. A thin client over a single-node `Ra`
  cluster (see `Riptide.RaCluster`) running `Riptide.Stream.RaMachine` —
  no GenServer of our own; Ra owns the process and its durability.
  """

  alias Riptide.Event
  alias Riptide.RaCluster
  alias Riptide.Stream.RaMachine

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

  @spec get_since(String.t(), non_neg_integer() | nil) ::
          {:ok, [Event.t()]} | {:gap, pos_integer() | nil}
  def get_since(stream_id, cursor) do
    server_id = RaCluster.server_id(stream_id)
    RaCluster.local_query(server_id, &RaMachine.get_since(&1, cursor))
  end
end
