defmodule Riptide.Decade.VolumeSeed do
  @moduledoc """
  Fast-forwards a stream to a realistic decade-scale event count by
  appending in a tight loop against the real `Riptide.Stream.StreamServer`
  — no HTTP, no PropCheck, just raw volume. Records one latency sample per
  10% of progress so a growth-proportional slowdown (the bug Task 1 of
  Phase 7 fixed) shows up directly in the numbers instead of just a
  timeout. See the design spec's "Volume seed layer" section.
  """

  alias Riptide.Event
  alias Riptide.Stream.{StreamServer, StreamSupervisor}

  @spec seed_stream(String.t(), pos_integer()) :: %{
          count: non_neg_integer(),
          latencies_us: [non_neg_integer()]
        }
  def seed_stream(stream_id, event_count) when is_integer(event_count) and event_count > 0 do
    StreamSupervisor.ensure_ready(stream_id)

    sample_every = max(div(event_count, 10), 1)

    {latencies, _} =
      Enum.reduce(1..event_count, {[], 0}, fn i, {samples, running_micros} ->
        {micros, _event} =
          :timer.tc(fn ->
            StreamServer.append(stream_id, Event.new(stream_id, :replace, RDF.Graph.new()))
          end)

        samples =
          if rem(i, sample_every) == 0 and length(samples) < 10 do
            [micros | samples]
          else
            samples
          end

        {samples, running_micros + micros}
      end)

    %{count: event_count, latencies_us: Enum.reverse(latencies)}
  end
end
