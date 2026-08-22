defmodule RiptideWeb.Realtime.SseControllerTest do
  use ExUnit.Case, async: true
  use Plug.Test

  alias Riptide.Event
  alias Riptide.Stream.{StreamServer, StreamSupervisor}

  @opts RiptideWeb.Endpoint.init([])

  defp unique_stream_id, do: "sse-test-#{System.unique_integer([:positive])}"

  test "subscribing with no Last-Event-ID and then appending pushes one SSE frame" do
    stream_id = unique_stream_id()
    StreamSupervisor.get_or_start(stream_id)

    task =
      Task.async(fn ->
        :get
        |> conn("/streams/#{URI.encode_www_form(stream_id)}/subscribe")
        |> RiptideWeb.Endpoint.call(@opts)
      end)

    Process.sleep(300)
    StreamServer.append(stream_id, Event.new(stream_id, RDF.Graph.new()))

    conn = Task.await(task, 3_000)

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["text/event-stream"]
    assert conn.resp_body =~ "id: 1\n"
  end
end
