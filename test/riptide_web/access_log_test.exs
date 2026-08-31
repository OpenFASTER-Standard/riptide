defmodule RiptideWeb.AccessLogTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import ExUnit.CaptureLog

  @opts RiptideWeb.Endpoint.init([])

  # Same real-global-level override as Riptide.Telemetry.AccessLogTest —
  # see that file's own comment for why ExUnit.CaptureLog's :level option
  # alone does not suffice here.
  setup do
    original_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: original_level) end)
    :ok
  end

  test "a request produces exactly one structured access-log line, not Phoenix's default two" do
    log =
      capture_log(fn ->
        :get
        |> conn("/health/live")
        |> RiptideWeb.Endpoint.call(@opts)
      end)

    lines = log |> String.trim() |> String.split("\n") |> Enum.reject(&(&1 == ""))

    assert length(lines) == 1
    assert log =~ "GET /health/live 200"
  end
end
