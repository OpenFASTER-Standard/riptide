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
    stream_id = "decade-volume-seed-trend-" <> Uniq.UUID.uuid4()
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id) end)

    %{latencies_us: samples} = VolumeSeed.seed_stream(stream_id, 20_000)

    first_half_avg = samples |> Enum.take(5) |> Enum.sum() |> Kernel./(5)
    second_half_avg = samples |> Enum.take(-5) |> Enum.sum() |> Kernel./(5)

    ratio = second_half_avg / first_half_avg

    assert ratio < 3,
           "later append-latency samples averaged #{ratio}x the earlier ones " <>
             "(#{inspect(samples)}) — looks like a growth-proportional slowdown"
  end
end
