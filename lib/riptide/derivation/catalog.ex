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
  alias Riptide.Derivation.Literal.FactPattern
  alias Riptide.Derivation.{Matcher, RuleRDFCodec, Var}

  @stream_id_prefix "https://riptide.example/"
  @rdf_type RDF.iri("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
  @riptide_catalog_entry RDF.iri("urn:riptide:vocab:CatalogEntry")
  @riptide_superseded_catalog_entry RDF.iri("urn:riptide:vocab:SupersededCatalogEntry")
  @riptide_supersedes RDF.iri("urn:riptide:vocab:supersedes")

  @type scope :: {:tenant, String.t()} | :hub

  @spec catalog_stream_id(scope()) :: String.t()
  def catalog_stream_id({:tenant, tenant_id}),
    do: @stream_id_prefix <> "tenants/" <> tenant_id <> "/catalog"

  def catalog_stream_id(:hub), do: @stream_id_prefix <> "hub/catalog"

  @spec pending_review_stream_id(scope()) :: String.t()
  def pending_review_stream_id(scope), do: catalog_stream_id(scope) <> "/pending-review"

  @spec list_entries(scope()) :: {:ok, [{RDF.BlankNode.t(), Rule.t()}]} | {:error, :not_ready}
  def list_entries(scope) do
    with {:ok, graph} <- read_graph(catalog_stream_id(scope)) do
      nodes = nodes_of_type(graph, @riptide_catalog_entry)
      {:ok, Enum.map(nodes, &{&1, RuleRDFCodec.from_rdf(&1, graph)})}
    end
  end

  @spec admit_entry(scope(), Rule.t(), RDF.BlankNode.t() | nil) :: :ok | {:error, :not_ready}
  def admit_entry(scope, %Rule{} = rule, replaces) do
    {node, rule_graph} = RuleRDFCodec.to_rdf(rule)

    graph =
      rule_graph
      |> RDF.Graph.add({node, @rdf_type, @riptide_catalog_entry})
      |> maybe_add_supersedes(node, replaces)

    write_patch(catalog_stream_id(scope), RDF.Graph.triples(graph), [])
  end

  defp maybe_add_supersedes(graph, _node, nil), do: graph

  defp maybe_add_supersedes(graph, node, replaces),
    do: RDF.Graph.add(graph, {node, @riptide_supersedes, replaces})

  @spec supersede_entry(scope(), RDF.BlankNode.t()) :: :ok | {:error, :not_ready}
  def supersede_entry(scope, node) do
    write_patch(
      catalog_stream_id(scope),
      [{node, @rdf_type, @riptide_superseded_catalog_entry}],
      [{node, @rdf_type, @riptide_catalog_entry}]
    )
  end

  defp nodes_of_type(graph, type_iri) do
    fact_pattern = %FactPattern{predicate: @rdf_type, args: [%Var{name: "Node"}, type_iri]}
    {:ok, bindings} = Matcher.bindings([fact_pattern], graph, %{})
    Enum.map(bindings, &Map.fetch!(&1, %Var{name: "Node"}))
  end

  defp write_patch(stream_id, additions, removals) do
    case stream_id |> StreamSupervisor.ensure_ready() |> StreamSupervisor.ensure_ready_status() do
      :ok ->
        StreamServer.append(
          stream_id,
          Event.new(stream_id, :patch, %Patch{additions: additions, removals: removals})
        )

        :ok

      :error ->
        {:error, :not_ready}
    end
  end

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
