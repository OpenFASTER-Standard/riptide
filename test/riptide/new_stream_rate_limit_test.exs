defmodule Riptide.NewStreamRateLimitTest do
  use ExUnit.Case, async: false

  # Root cause of a real, recurring CI flake (SseControllerTest/
  # ReplicationChannelTest's rate-limit tests occasionally observing an
  # extra `:allow` where a `:deny` was expected): Hammer's default
  # `:fix_window` algorithm anchors every key's window to the same
  # globally-synchronized wall-clock boundary (multiples of `scale_ms`
  # since the Unix epoch), not to when that subject's own activity began.
  # A burst of hits for one subject can straddle that global boundary
  # purely by chance of what real time it is when the test happens to
  # run — resetting the count mid-burst and allowing more hits than the
  # configured limit. This test deliberately times a burst to straddle a
  # window boundary to reproduce that deterministically, rather than
  # relying on rare CI timing to surface it.
  test "a same-subject burst straddling a window boundary is still correctly rate-limited" do
    scale_ms = 200
    limit = 2
    subject = "boundary-test-" <> Uniq.UUID.uuid4()

    original_limit = Application.get_env(:riptide, :new_stream_rate_limit)
    original_scale = Application.get_env(:riptide, :new_stream_rate_scale_ms)
    Application.put_env(:riptide, :new_stream_rate_limit, limit)
    Application.put_env(:riptide, :new_stream_rate_scale_ms, scale_ms)

    on_exit(fn ->
      Application.put_env(:riptide, :new_stream_rate_limit, original_limit)
      Application.put_env(:riptide, :new_stream_rate_scale_ms, original_scale)
    end)

    # Align so the first hit lands just before the next window boundary,
    # and the remaining hits land just after it.
    until_boundary = scale_ms - rem(System.system_time(:millisecond), scale_ms)

    # Too close to (or just past) a boundary to reliably land the first
    # hit *before* it — wait for the next one instead of risking a flaky
    # alignment.
    until_boundary =
      if until_boundary < 15 do
        Process.sleep(until_boundary + 5)
        scale_ms - rem(System.system_time(:millisecond), scale_ms)
      else
        until_boundary
      end

    Process.sleep(until_boundary - 10)

    results =
      for i <- 1..3 do
        if i > 1, do: Process.sleep(15)
        Riptide.NewStreamRateLimit.check_new_stream(subject)
      end

    assert results == [:allow, :allow, :deny],
           "expected the 3rd hit in a #{limit}-per-#{scale_ms}ms window to be denied " <>
             "regardless of a wall-clock window boundary falling mid-burst, got: #{inspect(results)}"
  end
end
