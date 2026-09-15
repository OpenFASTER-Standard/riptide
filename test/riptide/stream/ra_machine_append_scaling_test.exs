defmodule Riptide.Stream.RaMachineAppendScalingTest do
  use ExUnit.Case, async: true

  alias Riptide.Event
  alias Riptide.Stream.RaMachine

  @moduletag :benchmark
  @moduletag timeout: 120_000

  defp append_n(state, stream_id, count, start_index) do
    Enum.reduce(1..count, state, fn i, acc ->
      {new_state, _event, _effects} =
        RaMachine.apply(
          %{index: start_index + i},
          {:append, Event.encode(Event.new(stream_id, :replace, RDF.Graph.new()))},
          acc
        )

      new_state
    end)
  end

  defp time_appends(state, stream_id, count, start_index) do
    {micros, _state} =
      :timer.tc(fn -> append_n(state, stream_id, count, start_index) end)

    micros
  end

  test "append throughput does not degrade as an :infinity-retention stream accumulates events" do
    # A stream with only a small prior history.
    small = RaMachine.init(%{retention: :infinity})
    small = append_n(small, "scaling-small", 2_000, 0)
    small_micros = time_appends(small, "scaling-small", 500, 2_000)

    # The same shape of work, but against a stream with 20x the prior
    # history. A per-append cost proportional to total history size (the
    # `events ++ [x]` bug) makes this take roughly 20x as long; O(1)
    # amortized append keeps it close to the small case regardless of
    # prior history.
    large = RaMachine.init(%{retention: :infinity})
    large = append_n(large, "scaling-large", 40_000, 0)
    large_micros = time_appends(large, "scaling-large", 500, 40_000)

    ratio = large_micros / small_micros

    assert ratio < 5,
           "appending 500 events after 40,000 prior events took #{ratio}x as long as " <>
             "after 2,000 prior events (#{large_micros}us vs #{small_micros}us) — append " <>
             "cost looks proportional to total history size, not O(1)"
  end
end
