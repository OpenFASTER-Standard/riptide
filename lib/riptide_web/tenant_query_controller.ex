defmodule RiptideWeb.TenantQueryController do
  @moduledoc """
  `POST /tenants/:tenant_id/query` — the first HTTP surface anywhere for
  `Riptide.Derivation.QueryInterpreter`'s recursive/fixpoint evaluation
  (design spec
  `docs/superpowers/specs/2026-09-01-phase-6p-i-demo-backend-additions-design.md`
  §4.3). Reuses existing storage entirely: the ruleset is the Tenant's own
  already-admitted Catalog, the starting facts come from one caller-named
  existing Tenant resource.
  """

  use Phoenix.Controller, formats: [:json]

  alias Riptide.Derivation.{Catalog, QueryInterpreter}
  alias Riptide.Event
  alias Riptide.RDF.{Patch, TurtleCodec}
  alias Riptide.Stream.{StreamServer, StreamSupervisor}
  alias RiptideWeb.LDP.ResourceController

  def create(conn, %{"starting_resource_path" => path_segments})
      when is_list(path_segments) and path_segments != [] do
    tenant_id = conn.assigns.tenant_id

    with {:ok, entries} <- Catalog.list_entries({:tenant, tenant_id}),
         {:ok, starting_graph} <- read_starting_graph(tenant_id, path_segments),
         {:ok, result_graph} <-
           QueryInterpreter.evaluate(
             Enum.map(entries, fn {_node, rule} -> rule end),
             starting_graph
           ) do
      {:ok, turtle} = TurtleCodec.encode(result_graph)
      conn |> put_resp_content_type("text/turtle") |> send_resp(200, turtle)
    else
      {:error, :not_ready} ->
        send_resp(conn, 503, "")

      {:error, reason} ->
        body = Jason.encode!(%{"error" => "query_evaluation_failed", "reason" => inspect(reason)})
        conn |> put_resp_content_type("application/json") |> send_resp(422, body)
    end
  rescue
    _ -> send_resp(conn, 503, "")
  catch
    :exit, _ -> send_resp(conn, 503, "")
  end

  def create(conn, _params), do: send_resp(conn, 400, "")

  # Deliberately different from RiptideWeb.LDP.ResourceController.show/2's own
  # "never written" semantics (a 404) — a starting resource that's never been
  # written is a legitimate query input here (the rules alone may or may not
  # derive anything from nothing), not a broken request. Mirrors
  # Riptide.Accounts's own read_graph/1 shape from 6o.
  defp read_starting_graph(tenant_id, path_segments) do
    stream_id = ResourceController.stream_id_for({:tenant, tenant_id}, path_segments)

    case Riptide.Placement.lookup(stream_id) do
      nil -> {:ok, RDF.Graph.new()}
      _nodes -> read_existing_starting_graph(stream_id)
    end
  end

  defp read_existing_starting_graph(stream_id) do
    case stream_id |> StreamSupervisor.ensure_ready() |> StreamSupervisor.ensure_ready_status() do
      :ok ->
        case StreamServer.get_since(stream_id, 0) do
          {:ok, events} -> {:ok, fold_events(events)}
          {:gap, _oldest} -> {:ok, RDF.Graph.new()}
        end

      :error ->
        {:error, :not_ready}
    end
  end

  defp fold_events(events) do
    Enum.reduce(events, RDF.Graph.new(), fn
      %Event{operation: :replace, payload: payload}, _acc -> payload
      %Event{operation: :delete}, _acc -> RDF.Graph.new()
      %Event{operation: :patch, payload: %Patch{} = patch}, acc -> Patch.apply(acc, patch)
    end)
  end
end
