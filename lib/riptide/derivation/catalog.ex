defmodule Riptide.Derivation.Catalog do
  @moduledoc """
  Catalog storage: a `CatalogEntry`/`PendingReview` is just more RDF Facts,
  living in a dedicated resource stream — the same `StreamServer`/`Event`/
  `Patch` mechanism `RiptideWeb.LDP.ResourceController` already uses for LDP
  resources. See design spec
  `docs/superpowers/specs/2026-08-29-phase-6e-iii-dedupgate-orchestration-design.md`
  §4.
  """

  alias Riptide.Derivation.{
    CapabilityCatalogEntry,
    CapabilityCatalogRDFCodec,
    Crosswalk,
    CrosswalkRDFCodec,
    DedupGate,
    Job,
    JobRDFCodec,
    Matcher,
    Rule,
    RuleRDFCodec,
    Var
  }

  alias Riptide.Derivation.Literal.FactPattern
  alias Riptide.Event
  alias Riptide.Placement
  alias Riptide.RDF.Patch
  alias Riptide.Stream.{StreamServer, StreamSupervisor}

  @stream_id_prefix "https://riptide.example/"
  @rdf_type RDF.iri("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
  @riptide_catalog_entry RDF.iri("urn:riptide:vocab:CatalogEntry")
  @riptide_superseded_catalog_entry RDF.iri("urn:riptide:vocab:SupersededCatalogEntry")
  @riptide_supersedes RDF.iri("urn:riptide:vocab:supersedes")
  @riptide_crosswalk RDF.iri("urn:riptide:vocab:Crosswalk")
  @riptide_superseded_crosswalk RDF.iri("urn:riptide:vocab:SupersededCrosswalk")
  @riptide_pending_crosswalk_review RDF.iri("urn:riptide:vocab:PendingCrosswalkReview")
  @riptide_resolved_pending_crosswalk_review RDF.iri(
                                               "urn:riptide:vocab:ResolvedPendingCrosswalkReview"
                                             )
  @jobs_topic "riptide:jobs"
  @riptide_job RDF.iri("urn:riptide:vocab:Job")
  @riptide_job_status RDF.iri("urn:riptide:vocab:jobStatus")
  @riptide_job_result RDF.iri("urn:riptide:vocab:jobResult")
  @riptide_job_error RDF.iri("urn:riptide:vocab:jobError")
  @riptide_capability_catalog_entry RDF.iri("urn:riptide:vocab:CapabilityCatalogEntry")
  @riptide_superseded_capability_catalog_entry RDF.iri(
                                                 "urn:riptide:vocab:SupersededCapabilityCatalogEntry"
                                               )
  @riptide_pending_capability_review RDF.iri("urn:riptide:vocab:PendingCapabilityReview")
  @riptide_resolved_pending_capability_review RDF.iri(
                                                "urn:riptide:vocab:ResolvedPendingCapabilityReview"
                                              )

  @type scope :: {:tenant, String.t()}

  @spec catalog_stream_id(scope()) :: String.t()
  def catalog_stream_id({:tenant, tenant_id}),
    do: @stream_id_prefix <> "tenants/" <> tenant_id <> "/resources/catalog"

  @spec pending_review_stream_id(scope()) :: String.t()
  def pending_review_stream_id(scope), do: catalog_stream_id(scope) <> "/pending-review"

  @spec crosswalk_stream_id(scope()) :: String.t()
  def crosswalk_stream_id(scope), do: catalog_stream_id(scope) <> "/crosswalks"

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

  @spec admit_crosswalk(scope(), Crosswalk.t(), RDF.BlankNode.t() | nil) ::
          :ok | {:error, :not_ready}
  def admit_crosswalk(scope, %Crosswalk{} = crosswalk, replaces) do
    {node, crosswalk_graph} = CrosswalkRDFCodec.to_rdf(crosswalk)
    graph = maybe_add_supersedes(crosswalk_graph, node, replaces)
    write_patch(crosswalk_stream_id(scope), RDF.Graph.triples(graph), [])
  end

  @spec supersede_crosswalk(scope(), RDF.BlankNode.t()) :: :ok | {:error, :not_ready}
  def supersede_crosswalk(scope, node) do
    write_patch(
      crosswalk_stream_id(scope),
      [{node, @rdf_type, @riptide_superseded_crosswalk}],
      [{node, @rdf_type, @riptide_crosswalk}]
    )
  end

  @spec list_crosswalks(scope()) :: {:ok, [{RDF.BlankNode.t(), Crosswalk.t()}]} | {:error, :not_ready}
  def list_crosswalks(scope) do
    with {:ok, graph} <- read_graph(crosswalk_stream_id(scope)) do
      nodes = nodes_of_type(graph, @riptide_crosswalk)
      {:ok, Enum.map(nodes, &{&1, CrosswalkRDFCodec.from_rdf(&1, graph)})}
    end
  end

  @spec queue_crosswalk_review(scope(), DedupGate.PendingCrosswalkReview.t()) ::
          {:ok, RDF.BlankNode.t()} | {:error, :not_ready}
  def queue_crosswalk_review(scope, %DedupGate.PendingCrosswalkReview{} = pending) do
    {node, graph} = DedupGate.PendingCrosswalkReview.to_rdf(pending)

    case write_patch(pending_review_stream_id(scope), RDF.Graph.triples(graph), []) do
      :ok -> {:ok, node}
      {:error, _reason} = error -> error
    end
  end

  @spec list_crosswalk_pending_reviews(scope()) ::
          {:ok, [{RDF.BlankNode.t(), DedupGate.PendingCrosswalkReview.t()}]}
          | {:error, :not_ready}
  def list_crosswalk_pending_reviews(scope) do
    with {:ok, graph} <- read_graph(pending_review_stream_id(scope)) do
      nodes = nodes_of_type(graph, @riptide_pending_crosswalk_review)
      {:ok, Enum.map(nodes, &{&1, DedupGate.PendingCrosswalkReview.from_rdf(&1, graph)})}
    end
  end

  @spec resolve_crosswalk_review(scope(), RDF.BlankNode.t()) :: :ok | {:error, :not_ready}
  def resolve_crosswalk_review(scope, node) do
    write_patch(
      pending_review_stream_id(scope),
      [{node, @rdf_type, @riptide_resolved_pending_crosswalk_review}],
      [{node, @rdf_type, @riptide_pending_crosswalk_review}]
    )
  end

  @spec capability_stream_id(scope()) :: String.t()
  def capability_stream_id(scope), do: catalog_stream_id(scope) <> "/capabilities"

  @spec admit_capability(scope(), CapabilityCatalogEntry.t(), RDF.BlankNode.t() | nil) ::
          :ok | {:error, :not_ready}
  def admit_capability(scope, %CapabilityCatalogEntry{} = entry, replaces) do
    {node, entry_graph} = CapabilityCatalogRDFCodec.to_rdf(entry)
    graph = maybe_add_supersedes(entry_graph, node, replaces)
    write_patch(capability_stream_id(scope), RDF.Graph.triples(graph), [])
  end

  @spec supersede_capability(scope(), RDF.BlankNode.t()) :: :ok | {:error, :not_ready}
  def supersede_capability(scope, node) do
    write_patch(
      capability_stream_id(scope),
      [{node, @rdf_type, @riptide_superseded_capability_catalog_entry}],
      [{node, @rdf_type, @riptide_capability_catalog_entry}]
    )
  end

  @spec list_capabilities(scope()) ::
          {:ok, [{RDF.BlankNode.t(), CapabilityCatalogEntry.t()}]} | {:error, :not_ready}
  def list_capabilities(scope) do
    with {:ok, graph} <- read_graph(capability_stream_id(scope)) do
      nodes = nodes_of_type(graph, @riptide_capability_catalog_entry)
      {:ok, Enum.map(nodes, &{&1, CapabilityCatalogRDFCodec.from_rdf(&1, graph)})}
    end
  end

  @spec queue_capability_review(scope(), DedupGate.PendingCapabilityReview.t()) ::
          {:ok, RDF.BlankNode.t()} | {:error, :not_ready}
  def queue_capability_review(scope, %DedupGate.PendingCapabilityReview{} = pending) do
    {node, graph} = DedupGate.PendingCapabilityReview.to_rdf(pending)

    case write_patch(pending_review_stream_id(scope), RDF.Graph.triples(graph), []) do
      :ok -> {:ok, node}
      {:error, _reason} = error -> error
    end
  end

  @spec list_capability_pending_reviews(scope()) ::
          {:ok, [{RDF.BlankNode.t(), DedupGate.PendingCapabilityReview.t()}]}
          | {:error, :not_ready}
  def list_capability_pending_reviews(scope) do
    with {:ok, graph} <- read_graph(pending_review_stream_id(scope)) do
      nodes = nodes_of_type(graph, @riptide_pending_capability_review)
      {:ok, Enum.map(nodes, &{&1, DedupGate.PendingCapabilityReview.from_rdf(&1, graph)})}
    end
  end

  @spec resolve_capability_review(scope(), RDF.BlankNode.t()) :: :ok | {:error, :not_ready}
  def resolve_capability_review(scope, node) do
    write_patch(
      pending_review_stream_id(scope),
      [{node, @rdf_type, @riptide_resolved_pending_capability_review}],
      [{node, @rdf_type, @riptide_pending_capability_review}]
    )
  end

  @spec job_stream_id(String.t()) :: String.t()
  def job_stream_id(tenant_id),
    do: @stream_id_prefix <> "tenants/" <> tenant_id <> "/resources/jobs"

  @spec write_job(String.t(), Job.t()) :: {:ok, RDF.BlankNode.t()} | {:error, :not_ready}
  def write_job(tenant_id, %Job{} = job) do
    stream_id = job_stream_id(tenant_id)
    {node, graph} = JobRDFCodec.to_rdf(job)

    case write_patch(stream_id, RDF.Graph.triples(graph), []) do
      :ok ->
        Phoenix.PubSub.broadcast(Riptide.PubSub, @jobs_topic, {:job_written, stream_id})
        {:ok, node}

      {:error, _reason} = error ->
        error
    end
  end

  @spec list_jobs(String.t()) :: {:ok, [{RDF.BlankNode.t(), Job.t()}]} | {:error, :not_ready}
  def list_jobs(stream_id) do
    with {:ok, graph} <- read_graph(stream_id) do
      nodes = nodes_of_type(graph, @riptide_job)
      {:ok, Enum.map(nodes, &{&1, JobRDFCodec.from_rdf(&1, graph)})}
    end
  end

  @spec mark_job_done(String.t(), RDF.BlankNode.t(), RDF.Term.t()) :: :ok | {:error, :not_ready}
  def mark_job_done(stream_id, node, result) do
    write_patch(
      stream_id,
      [
        {node, @riptide_job_status, RDF.literal("done")},
        {node, @riptide_job_result, result}
      ],
      [{node, @riptide_job_status, RDF.literal("pending")}]
    )
  end

  @spec mark_job_failed(String.t(), RDF.BlankNode.t(), String.t()) :: :ok | {:error, :not_ready}
  def mark_job_failed(stream_id, node, reason) do
    write_patch(
      stream_id,
      [
        {node, @riptide_job_status, RDF.literal("failed")},
        {node, @riptide_job_error, RDF.literal(reason)}
      ],
      [{node, @riptide_job_status, RDF.literal("pending")}]
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

  @riptide_pending_review RDF.iri("urn:riptide:vocab:PendingReview")
  @riptide_approved_pending_review RDF.iri("urn:riptide:vocab:ApprovedPendingReview")
  @riptide_declined_pending_review RDF.iri("urn:riptide:vocab:DeclinedPendingReview")

  @spec queue_pending_review(scope(), DedupGate.PendingReview.t()) ::
          {:ok, RDF.BlankNode.t()} | {:error, :not_ready}
  def queue_pending_review(scope, %DedupGate.PendingReview{} = pending_review) do
    {node, graph} = DedupGate.PendingReview.to_rdf(pending_review)

    case write_patch(pending_review_stream_id(scope), RDF.Graph.triples(graph), []) do
      :ok -> {:ok, node}
      {:error, _reason} = error -> error
    end
  end

  @spec list_pending_reviews(scope()) ::
          {:ok, [{RDF.BlankNode.t(), DedupGate.PendingReview.t()}]} | {:error, :not_ready}
  def list_pending_reviews(scope) do
    with {:ok, graph} <- read_graph(pending_review_stream_id(scope)) do
      nodes = nodes_of_type(graph, @riptide_pending_review)
      {:ok, Enum.map(nodes, &{&1, DedupGate.PendingReview.from_rdf(&1, graph)})}
    end
  end

  @spec resolve_pending_review(scope(), RDF.BlankNode.t(), :approved | :declined) ::
          :ok | {:error, :not_ready}
  def resolve_pending_review(scope, node, :approved),
    do: retag_pending(scope, node, @riptide_approved_pending_review)

  def resolve_pending_review(scope, node, :declined),
    do: retag_pending(scope, node, @riptide_declined_pending_review)

  defp retag_pending(scope, node, new_type) do
    write_patch(
      pending_review_stream_id(scope),
      [{node, @rdf_type, new_type}],
      [{node, @rdf_type, @riptide_pending_review}]
    )
  end

  defp read_graph(stream_id) do
    case Placement.lookup(stream_id) do
      nil -> {:ok, RDF.Graph.new()}
      _nodes -> read_existing_graph(stream_id)
    end
  end

  defp read_existing_graph(stream_id) do
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
