defmodule RiptideWeb.LDP.ResourceController do
  use Phoenix.Controller

  alias Riptide.Event
  alias Riptide.RDF.{Patch, TurtleCodec}
  alias Riptide.Stream.{StreamServer, StreamSupervisor}

  @ldp_contains RDF.iri("http://www.w3.org/ns/ldp#contains")

  def show(conn, %{"path" => path_segments}) do
    stream_id = stream_id_for(conn.assigns.tenant_id, path_segments)

    case current_state(stream_id) do
      {:ok, graph} ->
        {:ok, turtle} = TurtleCodec.encode(graph)
        send_resp(conn, 200, turtle)

      :not_found ->
        send_resp(conn, 404, "")

      :service_unavailable ->
        send_resp(conn, 503, "")
    end
  end

  def replace(conn, %{"path" => path_segments}) do
    stream_id = stream_id_for(conn.assigns.tenant_id, path_segments)
    {:ok, body, conn} = Plug.Conn.read_body(conn)

    case TurtleCodec.decode(body) do
      {:ok, graph} ->
        case stream_id |> StreamSupervisor.ensure_ready() |> ensure_ready_status() do
          :ok ->
            StreamServer.append(stream_id, Event.new(stream_id, :replace, graph))
            send_resp(conn, 201, "")

          :error ->
            send_resp(conn, 503, "")
        end

      {:error, _reason} ->
        send_resp(conn, 400, "")
    end
  end

  def delete(conn, %{"path" => path_segments}) do
    stream_id = stream_id_for(conn.assigns.tenant_id, path_segments)

    case stream_id |> StreamSupervisor.ensure_ready() |> ensure_ready_status() do
      :ok ->
        StreamServer.append(stream_id, Event.new(stream_id, :delete, RDF.Graph.new()))
        send_resp(conn, 204, "")

      :error ->
        send_resp(conn, 503, "")
    end
  end

  def patch(conn, %{"path" => path_segments} = params) do
    stream_id = stream_id_for(conn.assigns.tenant_id, path_segments)

    # NOTE: the endpoint's `Plug.Parsers` (see Task 6's scaffold) already
    # parses and consumes the request body for `content-type:
    # application/json`, merging the decoded fields into `conn.params`
    # before this action runs. Calling `Plug.Conn.read_body/1` here (as an
    # earlier draft did, mirroring the brief's literal example) reads an
    # already-drained body and crashes `Jason.decode!/1` on an empty
    # string. Read the already-decoded fields from `params` instead.
    with {:ok, additions_turtle} <- Map.fetch(params, "additions"),
         {:ok, removals_turtle} <- Map.fetch(params, "removals"),
         {:ok, additions_graph} <- TurtleCodec.decode(additions_turtle),
         {:ok, removals_graph} <- TurtleCodec.decode(removals_turtle) do
      patch = %Patch{
        additions: RDF.Graph.triples(additions_graph),
        removals: RDF.Graph.triples(removals_graph)
      }

      case stream_id |> StreamSupervisor.ensure_ready() |> ensure_ready_status() do
        :ok ->
          StreamServer.append(stream_id, Event.new(stream_id, :patch, patch))
          send_resp(conn, 200, "")

        :error ->
          send_resp(conn, 503, "")
      end
    else
      :error -> send_resp(conn, 400, "")
      {:error, _reason} -> send_resp(conn, 400, "")
    end
  end

  def create_child(conn, %{"path" => path_segments}) do
    tenant_id = conn.assigns.tenant_id
    container_stream_id = stream_id_for(tenant_id, path_segments)
    {:ok, body, conn} = Plug.Conn.read_body(conn)

    case TurtleCodec.decode(body) do
      {:ok, child_graph} ->
        child_id = Uniq.UUID.uuid4()
        child_stream_id = container_stream_id <> "/" <> child_id

        with :ok <- child_stream_id |> StreamSupervisor.ensure_ready() |> ensure_ready_status(),
             :ok <-
               container_stream_id |> StreamSupervisor.ensure_ready() |> ensure_ready_status() do
          StreamServer.append(child_stream_id, Event.new(child_stream_id, :replace, child_graph))

          containment_triple =
            {RDF.iri(container_stream_id), @ldp_contains, RDF.iri(child_stream_id)}

          containment_patch = %Patch{additions: [containment_triple], removals: []}

          StreamServer.append(
            container_stream_id,
            Event.new(container_stream_id, :patch, containment_patch)
          )

          location =
            "/tenants/#{tenant_id}/resources/" <> Enum.join(path_segments, "/") <> "/" <> child_id

          conn
          |> put_resp_header("location", location)
          |> send_resp(201, "")
        else
          :error -> send_resp(conn, 503, "")
        end

      {:error, _reason} ->
        send_resp(conn, 400, "")
    end
  end

  @spec ensure_ready_status(:ok | {:error, term()}) :: :ok | :error
  def ensure_ready_status(:ok), do: :ok
  def ensure_ready_status({:error, _reason}), do: :error

  defp stream_id_for(tenant_id, path_segments) do
    "https://riptide.example/tenants/#{tenant_id}/resources/" <> Enum.join(path_segments, "/")
  end

  defp current_state(stream_id) do
    case stream_id |> StreamSupervisor.ensure_ready() |> ensure_ready_status() do
      :error ->
        :service_unavailable

      :ok ->
        case StreamServer.get_since(stream_id, 0) do
          {:ok, []} ->
            :not_found

          # LDP streams use `:infinity` retention today, so `get_since/2` from
          # cursor 0 can't currently return a gap. Handle it defensively anyway:
          # if a future retention change trims the oldest events, a full-history
          # fold from 0 can no longer be reconstructed, so the resource can't be
          # faithfully rendered — treat it as not-found (404) rather than letting
          # an unmatched `{:gap, _}` crash the request into a 500.
          {:gap, _} ->
            :not_found

          {:ok, events} ->
            resolve_state(events)
        end
    end
  end

  defp resolve_state(events) do
    last_event = List.last(events)

    case last_event do
      %Event{operation: :delete} ->
        :not_found

      _ ->
        # An empty representation is not the same as not-found: only an
        # explicit DELETE reads as not-found. A PUT with an empty body
        # and a PATCH that removes the last remaining triple both leave
        # the resource visible as 200 with an empty body — the fold
        # below already reflects the real accumulated state either way,
        # including a removal actually taking effect (bug 1's fix).
        {:ok, fold_events(events)}
    end
  end

  defp fold_events(events) do
    Enum.reduce(events, RDF.Graph.new(), fn
      %Event{operation: :replace, payload: payload}, _acc ->
        payload

      %Event{operation: :delete}, _acc ->
        RDF.Graph.new()

      %Event{operation: :patch, payload: %Patch{} = patch}, acc ->
        Patch.apply(acc, patch)
    end)
  end
end
