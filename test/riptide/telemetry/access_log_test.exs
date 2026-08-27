defmodule Riptide.Telemetry.AccessLogTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Riptide.Telemetry.AccessLog

  # config/test.exs sets the real global Logger level to :warning, which
  # would silently suppress this handler's Logger.info calls entirely.
  # ExUnit.CaptureLog's own :level option does NOT help (it only filters
  # within a capture and does not override a stricter real Logger.level/0),
  # so the real global level must be lowered for the duration of this test.
  setup do
    original_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: original_level) end)
    :ok
  end

  test "logs method, path, status, and duration_ms from a fake conn" do
    conn = %Plug.Conn{method: "GET", request_path: "/health/live", status: 200}
    # Built via a round-trip conversion (not a literal native-unit guess) so
    # the assertion below is correct regardless of this VM's native time
    # unit resolution.
    duration = System.convert_time_unit(3, :millisecond, :native)

    log =
      capture_log(fn ->
        AccessLog.handle_event(
          [:phoenix, :endpoint, :stop],
          %{duration: duration},
          %{conn: conn},
          :ok
        )
      end)

    assert log =~ "GET /health/live 200 (3ms)"
  end
end
