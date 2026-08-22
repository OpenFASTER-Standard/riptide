defmodule Riptide.Stream.StreamSupervisor do
  use DynamicSupervisor

  alias Riptide.Stream.StreamServer

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec get_or_start(String.t()) :: pid()
  def get_or_start(stream_id) do
    case Registry.lookup(Riptide.Stream.Registry, stream_id) do
      [{pid, _}] ->
        pid

      [] ->
        case DynamicSupervisor.start_child(__MODULE__, {StreamServer, stream_id}) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end
    end
  end
end
