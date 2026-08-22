defmodule RiptideWeb.Realtime.SseController do
  use Phoenix.Controller

  alias Riptide.RDF.TurtleCodec
  alias Riptide.Stream.{StreamServer, StreamSupervisor}

  def subscribe(conn, %{"stream_id" => stream_id}) do
    StreamSupervisor.get_or_start(stream_id)
    Phoenix.PubSub.subscribe(Riptide.PubSub, "stream:" <> stream_id)

    cursor = last_event_id(conn)

    conn =
      conn
      |> put_resp_content_type("text/event-stream", nil)
      |> send_chunked(200)

    conn =
      case StreamServer.get_since(stream_id, cursor) do
        {:ok, backlog} -> Enum.reduce(backlog, conn, &write_event(&2, &1))
        {:gap, _oldest} -> conn
      end

    loop(conn)
  end

  defp loop(conn) do
    receive do
      {:new_event, event} ->
        conn = write_event(conn, event)
        loop(conn)
    after
      1_000 -> conn
    end
  end

  defp write_event(conn, event) do
    {:ok, turtle} = TurtleCodec.encode(event.payload)
    frame = "id: #{event.sequence}\ndata: #{String.replace(turtle, "\n", "\ndata: ")}\n\n"
    {:ok, conn} = Plug.Conn.chunk(conn, frame)
    conn
  end

  defp last_event_id(conn) do
    case Plug.Conn.get_req_header(conn, "last-event-id") do
      [id] -> String.to_integer(id)
      [] -> nil
    end
  end
end
