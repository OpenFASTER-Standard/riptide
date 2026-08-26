defmodule RiptideWeb.Realtime.SseController do
  use Phoenix.Controller

  alias Riptide.Event
  alias Riptide.RDF.TurtleCodec
  alias Riptide.Stream.{StreamServer, StreamSupervisor}
  alias RiptideWeb.LDP.ResourceController

  def subscribe(conn, %{"stream_id" => stream_id}) do
    with {:ok, tenant_id, path_segments} <- ResourceController.parse_stream_id(stream_id),
         :allow <-
           Riptide.Authz.evaluate(tenant_id, path_segments, conn.assigns.current_subject, :read) do
      do_subscribe(conn, stream_id)
    else
      _ -> send_resp(conn, 403, "")
    end
  end

  defp do_subscribe(conn, stream_id) do
    case stream_id |> StreamSupervisor.ensure_ready() |> ensure_ready_status() do
      :ok ->
        Phoenix.PubSub.subscribe(Riptide.PubSub, "stream:" <> stream_id)
        cursor = last_event_id(conn)

        case StreamServer.get_since(stream_id, cursor) do
          {:gap, oldest} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(409, Jason.encode!(%{"oldestAvailable" => oldest}))

          {:ok, backlog} ->
            conn =
              conn
              |> put_resp_content_type("text/event-stream", nil)
              |> send_chunked(200)

            conn = Enum.reduce(backlog, conn, &write_event(&2, &1))
            loop(conn)
        end

      :error ->
        send_resp(conn, 503, "")
    end
  end

  @spec ensure_ready_status(:ok | {:error, term()}) :: :ok | :error
  def ensure_ready_status(:ok), do: :ok
  def ensure_ready_status({:error, _reason}), do: :error

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
    {:ok, turtle} = TurtleCodec.encode(Event.wire_payload(event))
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
