defmodule Riptide.Stream.RaMachine do
  @moduledoc """
  The `:ra_machine` for a single stream's durable event log. Pure and
  process-free by design — `init/1`/`apply/3` are the only functions Ra
  itself calls; `get_since/2` is a plain query function run via
  `Riptide.RaCluster.local_query/2`, never a Ra command (reads don't need
  to go through consensus).
  """
  @behaviour :ra_machine

  alias Riptide.Event

  @type state :: %{
          next_sequence: pos_integer(),
          events: [Event.t()],
          retention: :infinity | pos_integer()
        }

  @impl :ra_machine
  def init(%{retention: retention}) do
    %{next_sequence: 1, events: [], retention: retention}
  end

  @impl :ra_machine
  def apply(_meta, {:append, %Event{} = event}, state) do
    stamped = Event.with_sequence(event, state.next_sequence)
    events = trim(state.events ++ [stamped], state.retention)
    new_state = %{state | next_sequence: state.next_sequence + 1, events: events}
    {new_state, stamped, []}
  end

  @spec get_since(state(), non_neg_integer() | nil) ::
          {:ok, [Event.t()]} | {:gap, pos_integer() | nil}
  def get_since(_state, nil), do: {:ok, []}

  def get_since(state, cursor) do
    oldest = List.first(state.events) |> then(&(&1 && &1.sequence))

    if oldest != nil and cursor < oldest - 1 do
      {:gap, oldest}
    else
      {:ok, Enum.filter(state.events, &(&1.sequence > cursor))}
    end
  end

  defp trim(events, :infinity), do: events

  defp trim(events, retention) when is_integer(retention) do
    count = length(events)
    if count > retention, do: Enum.drop(events, count - retention), else: events
  end
end
