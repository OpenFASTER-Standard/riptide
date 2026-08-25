defmodule RiptideWeb.Realtime.ReplicationChannel do
  @moduledoc """
  WebSocket replication transport for StreamLD's `binding-websocket` — joins
  `"replication:<stream_id>"` with an `"after"` cursor, replies with a backlog,
  and pushes further events as `"replication_frame"` messages. Mirrors the SSE
  controller's cursor/gap semantics over Phoenix Channels instead of SSE.
  """
  use Phoenix.Channel

  alias Riptide.Event
  alias Riptide.RDF.TurtleCodec
  alias Riptide.Stream.{StreamServer, StreamSupervisor}

  @impl true
  def join("replication:" <> stream_id, %{"after" => cursor}, socket) do
    case stream_id |> StreamSupervisor.ensure_ready() |> ensure_ready_status() do
      :ok ->
        Phoenix.PubSub.subscribe(Riptide.PubSub, "stream:" <> stream_id)

        case StreamServer.get_since(stream_id, cursor) do
          {:gap, oldest} ->
            {:error, %{"oldestAvailable" => oldest}}

          {:ok, events} ->
            socket = assign(socket, :stream_id, stream_id)
            {:ok, %{"backlog" => Enum.map(events, &frame/1)}, socket}
        end

      :error ->
        {:error, %{"reason" => "service_unavailable"}}
    end
  end

  @impl true
  def handle_info({:new_event, %Event{} = event}, socket) do
    push(socket, "replication_frame", frame(event))
    {:noreply, socket}
  end

  @spec ensure_ready_status(:ok | {:error, term()}) :: :ok | :error
  def ensure_ready_status(:ok), do: :ok
  def ensure_ready_status({:error, _reason}), do: :error

  defp frame(%Event{} = event) do
    {:ok, turtle} = TurtleCodec.encode(Event.wire_payload(event))

    %{
      "cursor" => event.sequence,
      "event" => %{
        "sequence" => event.sequence,
        "streamId" => event.stream_id,
        "isSnapshot" => Event.wire_snapshot?(event),
        "payload" => turtle
      }
    }
  end
end
