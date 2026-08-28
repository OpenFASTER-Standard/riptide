defmodule RiptideWeb.LDP.ResourceController do
  use Phoenix.Controller
  require Logger

  alias Riptide.Event
  alias Riptide.Placement
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
        finish_create_child(conn, tenant_id, path_segments, container_stream_id, child_graph)

      {:error, _reason} ->
        send_resp(conn, 400, "")
    end
  end

  defp finish_create_child(conn, tenant_id, path_segments, container_stream_id, child_graph) do
    child_id = Uniq.UUID.uuid4()
    child_stream_id = container_stream_id <> "/" <> child_id

    with :ok <- child_stream_id |> StreamSupervisor.ensure_ready() |> ensure_ready_status(),
         :ok <-
           container_stream_id |> StreamSupervisor.ensure_ready() |> ensure_ready_status() do
      StreamServer.append(child_stream_id, Event.new(child_stream_id, :replace, child_graph))

      containment_triple =
        {RDF.iri(container_stream_id), @ldp_contains, RDF.iri(child_stream_id)}

      containment_patch = %Patch{additions: [containment_triple], removals: []}

      case append_containment_patch(container_stream_id, containment_patch) do
        :ok ->
          location =
            "/tenants/#{tenant_id}/resources/" <> Enum.join(path_segments, "/") <> "/" <> child_id

          conn
          |> put_resp_header("location", location)
          |> send_resp(201, "")

        :error ->
          cleanup_orphaned_child(child_stream_id)
          send_resp(conn, 503, "")
      end
    else
      :error -> send_resp(conn, 503, "")
    end
  end

  @spec ensure_ready_status(:ok | {:error, term()}) :: :ok | :error
  def ensure_ready_status(:ok), do: :ok
  def ensure_ready_status({:error, _reason}), do: :error

  # StreamServer.append/2 can raise if the container's own replicas are all
  # unreachable at this exact moment (e.g. a transient partition after the
  # child's own append already succeeded) — without catching it here, an
  # uncaught exception would leave the child resource durably created and
  # independently readable, but permanently un-referenced by its
  # container's `ldp:contains` listing, with no retry or cleanup.
  @spec append_containment_patch(String.t(), Patch.t()) :: :ok | :error
  defp append_containment_patch(container_stream_id, patch) do
    StreamServer.append(container_stream_id, Event.new(container_stream_id, :patch, patch))
    :ok
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  # Best-effort: append a :delete event for the just-created, now-orphaned
  # child so it stops being independently readable even though it was never
  # linked from its container. If THIS also fails (the child's own replicas
  # are unreachable too), there is no automated reconciliation path today —
  # log loudly so an operator can find and clean it up manually rather than
  # it silently persisting forever.
  @spec cleanup_orphaned_child(String.t()) :: :ok
  defp cleanup_orphaned_child(child_stream_id) do
    StreamServer.append(child_stream_id, Event.new(child_stream_id, :delete, RDF.Graph.new()))
    :ok
  rescue
    e -> log_orphaned_child_cleanup_failure(child_stream_id, Exception.message(e))
  catch
    :exit, reason -> log_orphaned_child_cleanup_failure(child_stream_id, inspect(reason))
  end

  defp log_orphaned_child_cleanup_failure(child_stream_id, reason) do
    Logger.error(
      "create_child: container patch failed AND cleanup of orphaned child " <>
        "#{child_stream_id} also failed (#{reason}) — manual cleanup needed",
      child_stream_id: child_stream_id,
      reason: reason
    )

    :ok
  end

  @stream_id_prefix "https://riptide.example/tenants/"
  @resources_segment "/resources/"

  @spec stream_id_for(String.t(), [String.t()]) :: String.t()
  def stream_id_for(tenant_id, path_segments) do
    @stream_id_prefix <> tenant_id <> @resources_segment <> Enum.join(path_segments, "/")
  end

  # The exact inverse of `stream_id_for/2` — used by Phase 4c's authorization
  # layer (`RiptideWeb.Realtime.SseController`/`ReplicationChannel`, Tasks 7-8)
  # to recover which tenant/resource an opaque, client-supplied `stream_id`
  # addresses, since neither transport constructs one from a path
  # server-side (see Phase 4a design spec §5, Phase 4c design spec §7).
  # `stream_id_for/2`'s format is a pure, deterministic, reversible string —
  # no hashing or randomness — so parsing it back apart needs no new
  # persisted state, at the cost of staying coupled to this exact format:
  # the round-trip tests in `resource_controller_test.exs` exist specifically
  # to catch a future change here breaking that coupling silently.
  @spec parse_stream_id(String.t()) :: {:ok, String.t(), [String.t()]} | :error
  def parse_stream_id(@stream_id_prefix <> rest) do
    case String.split(rest, @resources_segment, parts: 2) do
      [tenant_id, path] when tenant_id != "" -> {:ok, tenant_id, String.split(path, "/")}
      _ -> :error
    end
  end

  def parse_stream_id(_other), do: :error

  # A read must never create anything: StreamSupervisor.ensure_ready/1 mints
  # a permanent BEAM atom and a real Ra cluster for any stream_id it's asked
  # about, so it must only ever run for a stream that's genuinely known.
  # Placement.lookup/1 is a cheap, atom-free existence check against the
  # small fixed placement-metadata cluster — nil means this stream_id has
  # never been assigned, i.e. nobody has ever written to it, so it's a
  # plain 404 with no side effects at all.
  defp current_state(stream_id) do
    case Placement.lookup(stream_id) do
      nil -> :not_found
      _nodes -> current_state_for_existing(stream_id)
    end
  end

  defp current_state_for_existing(stream_id) do
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
