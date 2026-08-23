defmodule RiptideWeb.LDP.ResourceController do
  use Phoenix.Controller

  alias Riptide.Event
  alias Riptide.RDF.{Patch, TurtleCodec}
  alias Riptide.Stream.{StreamServer, StreamSupervisor}

  @ldp_contains RDF.iri("http://www.w3.org/ns/ldp#contains")

  def show(conn, %{"path" => path_segments}) do
    stream_id = stream_id_for(path_segments)

    case current_state(stream_id) do
      {:ok, graph} ->
        {:ok, turtle} = TurtleCodec.encode(graph)
        send_resp(conn, 200, turtle)

      :not_found ->
        send_resp(conn, 404, "")
    end
  end

  def replace(conn, %{"path" => path_segments}) do
    stream_id = stream_id_for(path_segments)
    {:ok, body, conn} = Plug.Conn.read_body(conn)

    case TurtleCodec.decode(body) do
      {:ok, graph} ->
        StreamSupervisor.get_or_start(stream_id)
        StreamServer.append(stream_id, Event.new(stream_id, :replace, graph))

        send_resp(conn, 201, "")

      {:error, _reason} ->
        send_resp(conn, 400, "")
    end
  end

  def delete(conn, %{"path" => path_segments}) do
    stream_id = stream_id_for(path_segments)

    StreamSupervisor.get_or_start(stream_id)
    StreamServer.append(stream_id, Event.new(stream_id, :delete, RDF.Graph.new()))

    send_resp(conn, 204, "")
  end

  def patch(conn, %{"path" => path_segments} = params) do
    stream_id = stream_id_for(path_segments)

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

      StreamSupervisor.get_or_start(stream_id)
      StreamServer.append(stream_id, Event.new(stream_id, :patch, patch))

      send_resp(conn, 200, "")
    else
      :error -> send_resp(conn, 400, "")
      {:error, _reason} -> send_resp(conn, 400, "")
    end
  end

  def create_child(conn, %{"path" => path_segments}) do
    container_stream_id = stream_id_for(path_segments)
    {:ok, body, conn} = Plug.Conn.read_body(conn)

    case TurtleCodec.decode(body) do
      {:ok, child_graph} ->
        child_id = Uniq.UUID.uuid4()
        child_stream_id = container_stream_id <> "/" <> child_id

        StreamSupervisor.get_or_start(child_stream_id)
        StreamServer.append(child_stream_id, Event.new(child_stream_id, :replace, child_graph))

        containment_triple =
          {RDF.iri(container_stream_id), @ldp_contains, RDF.iri(child_stream_id)}

        containment_patch = %Patch{additions: [containment_triple], removals: []}

        StreamSupervisor.get_or_start(container_stream_id)

        StreamServer.append(
          container_stream_id,
          Event.new(container_stream_id, :patch, containment_patch)
        )

        location = "/resources/" <> Enum.join(path_segments, "/") <> "/" <> child_id

        conn
        |> put_resp_header("location", location)
        |> send_resp(201, "")

      {:error, _reason} ->
        send_resp(conn, 400, "")
    end
  end

  defp stream_id_for(path_segments) do
    "https://riptide.example/resources/" <> Enum.join(path_segments, "/")
  end

  defp current_state(stream_id) do
    StreamSupervisor.get_or_start(stream_id)

    case StreamServer.get_since(stream_id, 0) do
      {:ok, []} ->
        :not_found

      {:ok, events} ->
        last_event = List.last(events)

        case last_event do
          %Event{operation: :delete} ->
            :not_found

          _ ->
            graph =
              Enum.reduce(events, RDF.Graph.new(), fn
                %Event{operation: :replace, payload: payload}, _acc ->
                  payload

                %Event{operation: :delete}, _acc ->
                  RDF.Graph.new()

                %Event{operation: :patch, payload: %Patch{} = patch}, acc ->
                  Patch.apply(acc, patch)
              end)

            # An empty result is only a visible ("found") state when the
            # most recent event explicitly asserted the full state as-is
            # (a :replace, i.e. PUT — including an intentionally-empty PUT
            # body: that's bug 2, distinguishing PUT-empty from DELETE).
            # An empty result produced by a :patch removing the last
            # triple(s) is not itself a state-defining assertion — treat it
            # the same as "never written to", consistent with how any other
            # empty state has always read back here. This is what makes
            # bug 1's fix (removals actually taking effect) observable via
            # a GET: the triple is actually gone, so the resource reads as
            # not found rather than merely losing its content.
            if Enum.empty?(RDF.Graph.triples(graph)) and last_event.operation != :replace do
              :not_found
            else
              {:ok, graph}
            end
        end
    end
  end
end
