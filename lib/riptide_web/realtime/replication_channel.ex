defmodule RiptideWeb.Realtime.ReplicationChannel do
  @moduledoc """
  WebSocket replication transport for StreamLD's `binding-websocket` — joins
  `"replication:<stream_id>"` with an `"after"` cursor, replies with a backlog,
  and pushes further events as `"replication_frame"` messages. Mirrors the SSE
  controller's cursor/gap semantics over Phoenix Channels instead of SSE.

  Authorization (Phase 4c) recovers the joining topic's tenant/path via
  `RiptideWeb.LDP.ResourceController.parse_stream_id/1` and checks it against
  `socket.assigns.current_subject` (established once at `connect/3` time,
  per Phase 4b) — a channel `join/3` never re-verifies *identity*, but it
  does check *authorization* per topic, since one socket can join many
  different topics over its lifetime and each may have different policies.
  """
  use Phoenix.Channel
  require Logger

  alias Riptide.Event
  alias Riptide.RDF.TurtleCodec
  alias Riptide.Stream.{StreamServer, StreamSupervisor}
  alias RiptideWeb.LDP.ResourceController

  @impl true
  def join("replication:" <> stream_id, %{"after" => cursor}, socket) do
    case ResourceController.parse_stream_id(stream_id) do
      {:ok, tenant_id, path_segments} ->
        Logger.metadata(tenant_id: tenant_id)
        maybe_set_subject_metadata(socket.assigns.current_subject)

        case Riptide.Authz.evaluate(
               tenant_id,
               path_segments,
               socket.assigns.current_subject,
               :read
             ) do
          :allow -> do_join(stream_id, cursor, socket)
          _ -> {:error, %{"reason" => "unauthorized"}}
        end

      _ ->
        {:error, %{"reason" => "unauthorized"}}
    end
  rescue
    _ -> {:error, %{"reason" => "service_unavailable"}}
  catch
    # Riptide.Authz.evaluate/4 can raise/exit if the placement cluster
    # backing the policy store is fully unreachable — this transport calls
    # it directly rather than through RiptideWeb.Plugs.Authorize (see that
    # plug's own rescue/catch on this same failure mode), so needs the same
    # protection here.
    :exit, _ -> {:error, %{"reason" => "service_unavailable"}}
  end

  # Mirrors Authenticate/Socket.connect's own guard: subject stays genuinely
  # absent from metadata (not present-but-nil) for an anonymous socket or a
  # token whose claims lack `sub`.
  defp maybe_set_subject_metadata(nil), do: :ok

  defp maybe_set_subject_metadata(claims) do
    if sub = claims["sub"], do: Logger.metadata(subject: sub)
  end

  defp do_join(stream_id, cursor, socket) do
    case stream_id |> StreamSupervisor.ensure_ready() |> ensure_ready_status() do
      :ok ->
        # Same subscribe-before-read ordering (and the same duplicate-delivery
        # window it opens) as RiptideWeb.Realtime.SseController.do_subscribe/3
        # — see its own comment. `handle_info/2` below drops any live event
        # whose sequence isn't strictly greater than the highest one already
        # sent in the backlog.
        Phoenix.PubSub.subscribe(Riptide.PubSub, "stream:" <> stream_id)

        case StreamServer.get_since(stream_id, cursor) do
          {:gap, oldest} ->
            {:error, %{"oldestAvailable" => oldest}}

          {:ok, events} ->
            last_sequence = events |> List.last() |> then(&(&1 && &1.sequence)) || cursor || 0

            socket =
              socket
              |> assign(:stream_id, stream_id)
              |> assign(:last_sequence, last_sequence)

            {:ok, %{"backlog" => Enum.map(events, &frame/1)}, socket}
        end

      :error ->
        {:error, %{"reason" => "service_unavailable"}}
    end
  end

  @impl true
  def handle_info({:new_event, %Event{sequence: sequence} = event}, socket)
      when sequence > socket.assigns.last_sequence do
    push(socket, "replication_frame", frame(event))
    {:noreply, assign(socket, :last_sequence, sequence)}
  end

  @impl true
  def handle_info({:new_event, %Event{}}, socket) do
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
