defmodule RiptideWeb.Realtime.ReplicationChannel do
  use Phoenix.Channel

  alias Riptide.Event
  alias Riptide.RDF.TurtleCodec
  alias Riptide.Stream.{StreamServer, StreamSupervisor}

  @impl true
  def join("replication:" <> stream_id, %{"after" => cursor}, socket) do
    StreamSupervisor.get_or_start(stream_id)
    Phoenix.PubSub.subscribe(Riptide.PubSub, "stream:" <> stream_id)

    case StreamServer.get_since(stream_id, cursor) do
      {:gap, oldest} ->
        {:error, %{"gap" => oldest}}

      {:ok, events} ->
        socket = assign(socket, :stream_id, stream_id)
        {:ok, %{"backlog" => Enum.map(events, &frame/1)}, socket}
    end
  end

  @impl true
  def handle_info({:new_event, %Event{} = event}, socket) do
    push(socket, "replication_frame", frame(event))
    {:noreply, socket}
  end

  defp frame(%Event{} = event) do
    {:ok, turtle} = TurtleCodec.encode(event.payload)
    %{"cursor" => event.sequence, "event" => %{"sequence" => event.sequence, "payload" => turtle}}
  end
end
