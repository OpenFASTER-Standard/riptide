defmodule RiptideWeb.Realtime.SseControllerTest do
  use ExUnit.Case, async: true
  use Plug.Test

  alias Riptide.Event
  alias Riptide.Stream.{StreamServer, StreamSupervisor}

  @opts RiptideWeb.Endpoint.init([])

  defp unique_stream_id, do: "sse-test-#{System.unique_integer([:positive])}"

  test "subscribing with no Last-Event-ID and then appending pushes one SSE frame" do
    stream_id = unique_stream_id()
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id) end)
    StreamSupervisor.get_or_start(stream_id)

    task =
      Task.async(fn ->
        :get
        |> conn("/streams/#{URI.encode_www_form(stream_id)}/subscribe")
        |> RiptideWeb.Endpoint.call(@opts)
      end)

    Process.sleep(300)
    StreamServer.append(stream_id, Event.new(stream_id, :replace, RDF.Graph.new()))

    conn = Task.await(task, 3_000)

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["text/event-stream"]
    assert conn.resp_body =~ "id: 1\n"
  end

  test "subscribing with a cursor older than the retention window returns 409 with a gap signal" do
    stream_id = "sse-gap-test-#{System.unique_integer([:positive])}"
    on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(stream_id) end)
    {:ok, _pid} = Riptide.Stream.StreamServer.start_link({stream_id, retention: 1})

    Riptide.Stream.StreamServer.append(
      stream_id,
      Riptide.Event.new(stream_id, :replace, RDF.Graph.new())
    )

    Riptide.Stream.StreamServer.append(
      stream_id,
      Riptide.Event.new(stream_id, :replace, RDF.Graph.new())
    )

    conn =
      :get
      |> conn("/streams/#{URI.encode_www_form(stream_id)}/subscribe")
      |> put_req_header("last-event-id", "0")
      |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 409
    assert Jason.decode!(conn.resp_body) == %{"oldestAvailable" => 2}
  end
end
