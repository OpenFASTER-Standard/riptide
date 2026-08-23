defmodule Riptide.Stream.RaMachineTest do
  use ExUnit.Case, async: true

  alias Riptide.Event
  alias Riptide.Stream.RaMachine

  defp append(state, stream_id) do
    {new_state, event, []} = RaMachine.apply(%{}, {:append, Event.new(stream_id, RDF.Graph.new())}, state)
    {new_state, event}
  end

  test "sequence starts at 1 and increases strictly" do
    state = RaMachine.init(%{retention: :infinity})
    {state, first} = append(state, "s")
    {_state, second} = append(state, "s")

    assert first.sequence == 1
    assert second.sequence == 2
  end

  test "get_since(nil) returns an empty backlog (live-tail semantics)" do
    state = RaMachine.init(%{retention: :infinity})
    assert RaMachine.get_since(state, nil) == {:ok, []}
  end

  test "get_since(cursor) filters to events after the cursor" do
    state = RaMachine.init(%{retention: :infinity})
    {state, _} = append(state, "s")
    {state, second} = append(state, "s")

    assert RaMachine.get_since(state, 1) == {:ok, [second]}
  end

  test "retention trims old events and get_since signals a gap past the window" do
    state = RaMachine.init(%{retention: 2})
    {state, _} = append(state, "s")
    {state, _} = append(state, "s")
    {state, third} = append(state, "s")

    assert RaMachine.get_since(state, 0) == {:gap, 2}
    assert RaMachine.get_since(state, 2) == {:ok, [third]}
  end
end
