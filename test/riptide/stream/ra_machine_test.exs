defmodule Riptide.Stream.RaMachineTest do
  use ExUnit.Case, async: true

  alias Riptide.Event
  alias Riptide.Stream.RaMachine

  # Real Ra always passes a `%{index: ...}` meta into `apply/3`; supply one so
  # the release_cursor path (which reads `meta.index` when retention trims an
  # event) has what it needs. Effects are ignored here — the pure-state-machine
  # tests below assert on state/reply, not on Ra effects; the release_cursor
  # effect's actual on-disk consequence is covered in `RaClusterTest`.
  defp append(state, stream_id, index \\ 1) do
    {new_state, event, _effects} =
      RaMachine.apply(
        %{index: index},
        {:append, Event.new(stream_id, :replace, RDF.Graph.new())},
        state
      )

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
