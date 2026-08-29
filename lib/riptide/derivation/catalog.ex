defmodule Riptide.Derivation.Catalog do
  @moduledoc """
  Catalog storage: a `CatalogEntry`/`PendingReview` is just more RDF Facts,
  living in a dedicated resource stream — the same `StreamServer`/`Event`/
  `Patch` mechanism `RiptideWeb.LDP.ResourceController` already uses for LDP
  resources. See design spec
  `docs/superpowers/specs/2026-08-29-phase-6e-iii-dedupgate-orchestration-design.md`
  §4.
  """

  alias Riptide.Event
  alias Riptide.Placement
  alias Riptide.RDF.Patch
  alias Riptide.Stream.{StreamServer, StreamSupervisor}
  alias Riptide.Derivation.{DedupGate, Rule}

  @stream_id_prefix "https://riptide.example/"

  @type scope :: {:tenant, String.t()} | :hub

  @spec catalog_stream_id(scope()) :: String.t()
  def catalog_stream_id({:tenant, tenant_id}),
    do: @stream_id_prefix <> "tenants/" <> tenant_id <> "/catalog"

  def catalog_stream_id(:hub), do: @stream_id_prefix <> "hub/catalog"

  @spec pending_review_stream_id(scope()) :: String.t()
  def pending_review_stream_id(scope), do: catalog_stream_id(scope) <> "/pending-review"

  @spec list_entries(scope()) :: {:ok, [{RDF.BlankNode.t(), Rule.t()}]} | {:error, :not_ready}
  def list_entries(_scope), do: {:ok, []}

  @spec list_pending_reviews(scope()) ::
          {:ok, [{RDF.BlankNode.t(), DedupGate.PendingReview.t()}]} | {:error, :not_ready}
  def list_pending_reviews(_scope), do: {:ok, []}

  defp read_graph(stream_id) do
    case Placement.lookup(stream_id) do
      nil ->
        {:ok, RDF.Graph.new()}

      _nodes ->
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
  end

  defp fold_events(events) do
    Enum.reduce(events, RDF.Graph.new(), fn
      %Event{operation: :replace, payload: payload}, _acc -> payload
      %Event{operation: :delete}, _acc -> RDF.Graph.new()
      %Event{operation: :patch, payload: %Patch{} = patch}, acc -> Patch.apply(acc, patch)
    end)
  end
end
