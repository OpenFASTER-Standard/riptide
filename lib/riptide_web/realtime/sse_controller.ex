defmodule RiptideWeb.Realtime.SseController do
  use Phoenix.Controller, formats: [:json]
  require Logger

  alias Riptide.Event
  alias Riptide.{NewStreamRateLimit, Placement}
  alias Riptide.RDF.TurtleCodec
  alias Riptide.Stream.{StreamServer, StreamSupervisor}
  alias RiptideWeb.LDP.ResourceController

  def subscribe(conn, %{"stream_id" => stream_id}) do
    case ResourceController.parse_stream_id(stream_id) do
      {:ok, {:tenant, tenant_id}, path_segments} ->
        Logger.metadata(tenant_id: tenant_id)

        case Riptide.Authz.evaluate_with_matcher(
               {:tenant, tenant_id},
               path_segments,
               conn.assigns.current_subject,
               :read
             ) do
          {:allow, :public} -> check_public_read_then_subscribe(conn, stream_id)
          {:allow, _other} -> do_subscribe(conn, stream_id)
          :deny -> send_resp(conn, 403, "")
        end

      _ ->
        send_resp(conn, 403, "")
    end
  rescue
    e ->
      Logger.warning(
        "SseController.subscribe/2 rescued: #{Exception.format(:error, e, __STACKTRACE__)}"
      )

      send_resp(conn, 503, "")
  catch
    # Riptide.Authz.evaluate_with_matcher/4 can raise/exit if the placement
    # cluster backing the policy store is fully unreachable — this transport
    # calls it directly rather than through RiptideWeb.Plugs.Authorize (see
    # that plug's own rescue/catch on this same failure mode), so needs the
    # same protection here.
    :exit, reason ->
      Logger.warning("SseController.subscribe/2 caught exit: #{inspect(reason)}")
      send_resp(conn, 503, "")
  end

  defp check_public_read_then_subscribe(conn, stream_id) do
    case conn |> rate_limit_key() |> Riptide.PublicReadRateLimit.check() do
      :allow -> do_subscribe(conn, stream_id)
      :deny -> send_resp(conn, 429, "")
    end
  end

  defp rate_limit_key(conn) do
    case conn.assigns.current_subject do
      %{"sub" => sub} when is_binary(sub) -> sub
      _ -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end

  defp do_subscribe(conn, stream_id) do
    case last_event_id(conn) do
      {:ok, cursor} -> do_subscribe(conn, stream_id, cursor)
      :error -> send_resp(conn, 400, "")
    end
  end

  defp do_subscribe(conn, stream_id, cursor) do
    case Placement.lookup(stream_id) do
      nil -> do_subscribe_new_stream(conn, stream_id, cursor)
      _nodes -> do_subscribe_existing_stream(conn, stream_id, cursor)
    end
  end

  # Subscribing before a stream's first write is intentional (a client
  # watching for a soon-to-be-created resource), so — unlike
  # RiptideWeb.LDP.ResourceController's read path — creation can't simply
  # be refused here. Cap the RATE of new-stream creation instead: each one
  # permanently mints a BEAM atom (RaCluster.uid_for/server_id) that's
  # never freed, so this is the mitigation for the one entry point that
  # must keep allowing it. An already-existing stream (the common case) is
  # never rate-limited — only genuinely brand-new ones consume the quota.
  defp do_subscribe_new_stream(conn, stream_id, cursor) do
    case NewStreamRateLimit.check_new_stream(rate_limit_subject(conn)) do
      :allow -> do_subscribe_existing_stream(conn, stream_id, cursor)
      :deny -> send_resp(conn, 429, "")
    end
  end

  defp rate_limit_subject(conn) do
    case conn.assigns.current_subject do
      %{"sub" => sub} -> sub
      _ -> "anonymous"
    end
  end

  defp do_subscribe_existing_stream(conn, stream_id, cursor) do
    case stream_id |> StreamSupervisor.ensure_ready() |> StreamSupervisor.ensure_ready_status() do
      :ok ->
        # Subscribing before reading the backlog avoids ever missing an event
        # (Plug.Conn.chunk order: below), but opens a duplicate-delivery
        # window instead — a concurrent StreamServer.append/2 that commits
        # between this subscribe and the get_since read below can land in
        # both the backlog AND a live {:new_event, ...} broadcast. `loop/1`
        # drops any live event whose sequence isn't strictly greater than the
        # highest one already delivered, closing that window.
        Phoenix.PubSub.subscribe(Riptide.PubSub, "stream:" <> stream_id)

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
            last_sequence = backlog |> List.last() |> then(&(&1 && &1.sequence)) || cursor || 0
            loop(conn, last_sequence)
        end

      :error ->
        send_resp(conn, 503, "")
    end
  end

  defp loop(conn, last_sequence) do
    receive do
      {:new_event, event} when event.sequence > last_sequence ->
        conn = write_event(conn, event)
        loop(conn, event.sequence)

      {:new_event, _already_delivered} ->
        loop(conn, last_sequence)
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

  @spec last_event_id(Plug.Conn.t()) :: {:ok, integer() | nil} | :error
  defp last_event_id(conn) do
    case Plug.Conn.get_req_header(conn, "last-event-id") do
      [id] ->
        case Integer.parse(id) do
          {n, ""} -> {:ok, n}
          _ -> :error
        end

      [] ->
        {:ok, nil}
    end
  end
end
