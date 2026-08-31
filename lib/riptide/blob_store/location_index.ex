defmodule Riptide.BlobStore.LocationIndex do
  @moduledoc """
  Durable `hash → [nodes holding a verified copy]` tracking for
  `Riptide.BlobStore` (design spec §7). One well-known, fixed stream — not
  per-Tenant scoped, since blobs are inherently cross-tenant-shared at the
  storage layer (spec §9) — reusing the same generic `StreamServer`/`Patch`
  mechanism `Riptide.Derivation.Catalog` already uses for its own dedicated
  streams, rather than a bespoke `:ra_machine`.
  """

  alias Riptide.Event
  alias Riptide.Placement
  alias Riptide.RDF.Patch
  alias Riptide.Stream.{StreamServer, StreamSupervisor}

  @stream_id "https://riptide.example/blob-location-index"
  @rdf_type RDF.iri("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
  @riptide_hash_entry RDF.iri("urn:riptide:vocab:BlobHashEntry")
  @riptide_located_on RDF.iri("urn:riptide:vocab:locatedOn")
  @hash_prefix "urn:riptide-blob:sha256:"
  @node_prefix "urn:riptide:node:"

  @spec stream_id() :: String.t()
  def stream_id, do: @stream_id

  @spec add_location(String.t(), node()) :: :ok | {:error, :not_ready}
  def add_location(hash, node) do
    hash_iri = hash_iri(hash)

    write_patch(
      [
        {hash_iri, @rdf_type, @riptide_hash_entry},
        {hash_iri, @riptide_located_on, node_iri(node)}
      ],
      []
    )
  end

  @spec remove_location(String.t(), node()) :: :ok | {:error, :not_ready}
  def remove_location(hash, node) do
    write_patch([], [{hash_iri(hash), @riptide_located_on, node_iri(node)}])
  end

  @spec list_locations(String.t()) :: {:ok, [node()]} | {:error, :not_ready}
  def list_locations(hash) do
    with {:ok, graph} <- read_graph() do
      nodes =
        graph
        |> RDF.Graph.get(hash_iri(hash))
        |> then(fn
          nil -> []
          description -> RDF.Description.get(description, @riptide_located_on, [])
        end)
        |> Enum.map(&iri_to_node/1)

      {:ok, nodes}
    end
  end

  @spec list_all() :: {:ok, %{String.t() => [node()]}} | {:error, :not_ready}
  def list_all do
    with {:ok, graph} <- read_graph() do
      entries =
        graph
        |> RDF.Graph.subjects()
        |> Enum.filter(fn s ->
          RDF.Graph.get(graph, s) |> RDF.Description.first(@rdf_type) == @riptide_hash_entry
        end)
        |> Map.new(fn hash_iri -> {hash_from_iri(hash_iri), locations_for(graph, hash_iri)} end)

      {:ok, entries}
    end
  end

  defp hash_from_iri(hash_iri),
    do: hash_iri |> RDF.IRI.to_string() |> String.trim_leading(@hash_prefix)

  defp locations_for(graph, hash_iri) do
    graph
    |> RDF.Graph.get(hash_iri)
    |> RDF.Description.get(@riptide_located_on, [])
    |> Enum.map(&iri_to_node/1)
  end

  defp hash_iri(hash), do: RDF.iri(@hash_prefix <> hash)
  defp node_iri(node), do: RDF.iri(@node_prefix <> Atom.to_string(node))

  defp iri_to_node(iri) do
    iri |> RDF.IRI.to_string() |> String.trim_leading(@node_prefix) |> String.to_atom()
  end

  defp write_patch(additions, removals) do
    case @stream_id
         |> StreamSupervisor.ensure_ready()
         |> StreamSupervisor.ensure_ready_status() do
      :ok ->
        StreamServer.append(
          @stream_id,
          Event.new(@stream_id, :patch, %Patch{additions: additions, removals: removals})
        )

        :ok

      :error ->
        {:error, :not_ready}
    end
  end

  defp read_graph do
    case Placement.lookup(@stream_id) do
      nil -> {:ok, RDF.Graph.new()}
      _nodes -> read_existing_graph()
    end
  end

  defp read_existing_graph do
    case @stream_id
         |> StreamSupervisor.ensure_ready()
         |> StreamSupervisor.ensure_ready_status() do
      :ok -> read_events()
      :error -> {:error, :not_ready}
    end
  end

  defp read_events do
    case StreamServer.get_since(@stream_id, 0) do
      {:ok, events} -> {:ok, fold_events(events)}
      {:gap, _oldest} -> {:ok, RDF.Graph.new()}
    end
  end

  defp fold_events(events) do
    Enum.reduce(events, RDF.Graph.new(), fn
      %Event{operation: :patch, payload: %Patch{} = patch}, acc -> Patch.apply(acc, patch)
      %Event{operation: :delete}, _acc -> RDF.Graph.new()
      %Event{operation: :replace, payload: payload}, _acc -> payload
    end)
  end
end
