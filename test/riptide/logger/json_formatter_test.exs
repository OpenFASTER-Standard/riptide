defmodule Riptide.Logger.JSONFormatterTest do
  use ExUnit.Case, async: true

  alias Riptide.Logger.JSONFormatter

  @timestamp {{2026, 8, 27}, {12, 34, 56, 789}}

  test "produces valid JSON with timestamp, level, and message" do
    output = JSONFormatter.format(:info, "hello", @timestamp, [])
    decoded = Jason.decode!(IO.iodata_to_binary(output))

    assert decoded["level"] == "info"
    assert decoded["message"] == "hello"
    assert decoded["timestamp"] == "2026-08-27T12:34:56.789Z"
  end

  test "includes metadata keys in the output" do
    output =
      JSONFormatter.format(:info, "hello", @timestamp, request_id: "abc123", tenant_id: "acme")

    decoded = Jason.decode!(IO.iodata_to_binary(output))

    assert decoded["request_id"] == "abc123"
    assert decoded["tenant_id"] == "acme"
  end

  test "normalizes an iodata message to a string" do
    output = JSONFormatter.format(:warning, ["parts ", "of ", "a ", "message"], @timestamp, [])
    decoded = Jason.decode!(IO.iodata_to_binary(output))

    assert decoded["message"] == "parts of a message"
  end

  test "falls back to inspect-based plain text instead of crashing on a non-JSON-encodable metadata value" do
    output = JSONFormatter.format(:info, "hello", @timestamp, pid: self())

    # Must not raise, and must still mention the message text somewhere in the fallback output.
    assert IO.iodata_to_binary(output) =~ "hello"
  end
end
