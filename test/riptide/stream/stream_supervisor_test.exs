defmodule Riptide.Stream.StreamSupervisorTest do
  use ExUnit.Case, async: true

  alias Riptide.Event
  alias Riptide.Stream.{StreamServer, StreamSupervisor}

  test "ensure_ready/1 returns :ok for an unseen stream id" do
    stream_id = "stream-#{System.unique_integer([:positive])}"
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id) end)

    assert StreamSupervisor.ensure_ready(stream_id) == :ok
  end

  test "ensure_ready/1 is idempotent for the same stream id" do
    stream_id = "stream-#{System.unique_integer([:positive])}"
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id) end)

    assert StreamSupervisor.ensure_ready(stream_id) == :ok
    assert StreamSupervisor.ensure_ready(stream_id) == :ok
  end

  test "ensure_ready/1 isolates state between different streams" do
    stream_a = "stream-#{System.unique_integer([:positive])}"
    stream_b = "stream-#{System.unique_integer([:positive])}"
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_a) end)
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_b) end)
    StreamSupervisor.ensure_ready(stream_a)
    StreamSupervisor.ensure_ready(stream_b)

    StreamServer.append(
      stream_a,
      Event.new(stream_a, :replace, RDF.Graph.new())
    )

    {:ok, events_b} = StreamServer.get_since(stream_b, 0)
    assert events_b == []
  end
end
