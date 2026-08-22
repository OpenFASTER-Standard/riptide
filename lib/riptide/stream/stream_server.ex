defmodule Riptide.Stream.StreamServer do
  @moduledoc """
  One GenServer per stream. Owns sequence assignment (serializing writes
  without external locking) and holds the in-memory event log for that
  stream.
  """
  use GenServer

  alias Riptide.Event

  def start_link(stream_id) do
    GenServer.start_link(__MODULE__, stream_id, name: via(stream_id))
  end

  def via(stream_id) do
    {:via, Registry, {Riptide.Stream.Registry, stream_id}}
  end

  @spec append(String.t(), Event.t()) :: Event.t()
  def append(stream_id, %Event{} = event) do
    GenServer.call(via(stream_id), {:append, event})
  end

  @spec get_since(String.t(), non_neg_integer() | nil) ::
          {:ok, [Event.t()]} | {:gap, pos_integer() | nil}
  def get_since(stream_id, cursor) do
    GenServer.call(via(stream_id), {:get_since, cursor})
  end

  @impl true
  def init(stream_id) do
    {:ok, %{stream_id: stream_id, next_sequence: 1, events: []}}
  end

  @impl true
  def handle_call({:append, event}, _from, state) do
    stamped = Event.with_sequence(event, state.next_sequence)
    new_state = %{state | next_sequence: state.next_sequence + 1, events: state.events ++ [stamped]}
    {:reply, stamped, new_state}
  end

  def handle_call({:get_since, nil}, _from, state) do
    {:reply, {:ok, []}, state}
  end

  def handle_call({:get_since, cursor}, _from, state) do
    oldest = List.first(state.events) |> then(&(&1 && &1.sequence))

    if oldest != nil and cursor < oldest - 1 do
      {:reply, {:gap, oldest}, state}
    else
      matching = Enum.filter(state.events, &(&1.sequence > cursor))
      {:reply, {:ok, matching}, state}
    end
  end
end
