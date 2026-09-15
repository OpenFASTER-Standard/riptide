defmodule Riptide.Decade.VolumeSeedTest do
  use ExUnit.Case, async: true

  alias Riptide.Decade.VolumeSeed
  alias Riptide.Stream.StreamServer

  @moduletag :benchmark
  @moduletag timeout: 120_000

  test "seeds the requested number of events and reports one latency sample per decile" do
    stream_id = "decade-volume-seed-" <> Uniq.UUID.uuid4()
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id) end)

    result = VolumeSeed.seed_stream(stream_id, 5_000)

    assert result.count == 5_000
    assert length(result.latencies_us) == 10

    {:ok, events} = StreamServer.get_since(stream_id, 0)
    assert length(events) == 5_000
    assert List.last(events).sequence == 5_000
  end

  test "append latency does not trend upward across the run (regression guard for the RaMachine fix)" do
    small_stream = "decade-volume-seed-small-" <> Uniq.UUID.uuid4()
    large_stream = "decade-volume-seed-large-" <> Uniq.UUID.uuid4()
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(small_stream) end)
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(large_stream) end)

    VolumeSeed.seed_stream(small_stream, 2_000)
    %{latencies_us: small_batch} = VolumeSeed.seed_stream(small_stream, 500)

    VolumeSeed.seed_stream(large_stream, 20_000)
    %{latencies_us: large_batch} = VolumeSeed.seed_stream(large_stream, 500)

    small_avg = Enum.sum(small_batch) / length(small_batch)
    large_avg = Enum.sum(large_batch) / length(large_batch)

    ratio = large_avg / small_avg

    assert ratio < 5,
           "appending 500 events after 20,000 prior events averaged #{ratio}x the latency " <>
             "of appending 500 events after 2,000 prior events (#{large_avg}us vs " <>
             "#{small_avg}us) — looks like a growth-proportional slowdown"
  end
end
