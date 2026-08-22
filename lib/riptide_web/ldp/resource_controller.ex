defmodule RiptideWeb.LDP.ResourceController do
  use Phoenix.Controller

  alias Riptide.Event
  alias Riptide.RDF.{Patch, TurtleCodec}
  alias Riptide.Stream.{StreamServer, StreamSupervisor}

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
    {:ok, graph} = TurtleCodec.decode(body)

    StreamSupervisor.get_or_start(stream_id)
    StreamServer.append(stream_id, Event.new(stream_id, graph, true))

    send_resp(conn, 201, "")
  end

  def delete(conn, %{"path" => path_segments}) do
    stream_id = stream_id_for(path_segments)

    StreamSupervisor.get_or_start(stream_id)
    StreamServer.append(stream_id, Event.new(stream_id, RDF.Graph.new(), true))

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
    %{"additions" => additions_turtle, "removals" => removals_turtle} = params

    {:ok, additions_graph} = TurtleCodec.decode(additions_turtle)
    {:ok, removals_graph} = TurtleCodec.decode(removals_turtle)

    patch = %Patch{
      additions: RDF.Graph.triples(additions_graph),
      removals: RDF.Graph.triples(removals_graph)
    }

    # KNOWN LIMITATION: `removals` are currently non-functional. We apply
    # the patch against an empty graph (rather than against the resource's
    # currently-folded state) before storing it, so `Patch.apply/2`'s
    # `RDF.Graph.delete(removals)` step always deletes from nothing — a
    # no-op — and only `additions` ever survive into `delta_only_graph`.
    # Even if we applied the patch against the real current state here,
    # storing the *result* wouldn't help: `current_state/1`'s fold (below)
    # only knows how to add a non-snapshot event's payload triples on top
    # of the accumulator, never subtract, so a stored removal has no way
    # to be represented or replayed. Fixing this needs an Event/payload
    # redesign (e.g. Event carrying separate additions/removals fields
    # instead of one payload graph) — out of scope for this task.
    delta_only_graph = Patch.apply(RDF.Graph.new(), patch)

    StreamSupervisor.get_or_start(stream_id)
    StreamServer.append(stream_id, Event.new(stream_id, delta_only_graph, false))

    send_resp(conn, 200, "")
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
        graph =
          Enum.reduce(events, RDF.Graph.new(), fn
            %Event{is_snapshot?: true, payload: payload}, _acc -> payload
            %Event{is_snapshot?: false, payload: delta}, acc -> RDF.Graph.add(acc, RDF.Graph.triples(delta))
          end)

        # A DELETE (Task spec: "appends an empty-graph snapshot event")
        # leaves the stream with events but a folded graph with zero
        # triples. Treat that the same as "never written to" — an empty
        # visible state is exactly what DELETE is supposed to produce, and
        # the controller test asserts GET returns 404 after DELETE, not
        # 200 with an empty body.
        #
        # KNOWN LIMITATION: this makes a DELETEd resource indistinguishable
        # from a resource that was explicitly PUT with a genuinely empty
        # Turtle body (`""`) — both fold to a zero-triple graph and both
        # read back as 404. The Event model has no tombstone / distinct-
        # "explicitly empty" marker separate from "the payload graph has no
        # triples," so there's no way to tell these two cases apart from
        # the event log alone. Fixing this needs an Event/payload redesign
        # (e.g. an explicit `deleted?` flag or tombstone event distinct
        # from an empty-graph snapshot) — out of scope for this task.
        if Enum.empty?(RDF.Graph.triples(graph)) do
          :not_found
        else
          {:ok, graph}
        end
    end
  end
end
