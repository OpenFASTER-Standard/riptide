defmodule Riptide.Authz.Store.TenantFacts do
  @moduledoc """
  `Riptide.Authz.Store` implementation storing policies as ordinary facts inside each tenant's own
  stream, at a well-known nested path — the same "single stream, folded from its own event history"
  pattern `Riptide.Accounts` already uses for account data (design spec
  `docs/superpowers/specs/2026-09-02-phase-6q-tenant-sovereignty-design.md` §4.3). Reuses the low-level
  write/read primitives directly rather than going through `RiptideWeb.LDP.ResourceController`'s
  generic, Authz-checked HTTP path — same reasoning `Riptide.Accounts` already documents: there's no
  Authz decision to consult here in the first place, since this module *is* the thing `Authz.evaluate/4`
  consults.
  """
  @behaviour Riptide.Authz.Store

  alias Riptide.Authz.{Policy, PolicyRDFCodec}
  alias Riptide.Event
  alias Riptide.RDF.Patch
  alias Riptide.Stream.{StreamServer, StreamSupervisor}
  alias RiptideWeb.LDP.ResourceController

  @impl true
  @spec list_policies(String.t(), [String.t()]) :: [Policy.t()]
  def list_policies(tenant_id, path_prefix) do
    case read_graph(tenant_id) do
      {:ok, graph} ->
        graph
        |> policy_nodes()
        |> Enum.map(&PolicyRDFCodec.from_rdf(&1, graph))
        |> Enum.filter(fn {stored_prefix, _policy} -> stored_prefix == path_prefix end)
        |> Enum.map(fn {_prefix, policy} -> policy end)

      {:error, :not_ready} ->
        []
    end
  end

  @impl true
  @spec add_policy(String.t(), [String.t()], Policy.t()) :: :ok | {:error, :too_many_policies}
  def add_policy(tenant_id, path_prefix, %Policy{} = policy) do
    existing = list_policies(tenant_id, path_prefix)

    cond do
      policy in existing ->
        :ok

      length(existing) >= 1000 ->
        {:error, :too_many_policies}

      true ->
        {_node, graph} = PolicyRDFCodec.to_rdf(policy, path_prefix)
        write_patch(tenant_id, RDF.Graph.triples(graph), [])
    end
  end

  @rdf_type RDF.iri("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
  @riptide_policy RDF.iri("urn:riptide:vocab:Policy")

  defp policy_nodes(graph) do
    graph
    |> RDF.Graph.subjects()
    |> Enum.filter(fn s ->
      RDF.Graph.get(graph, s) |> RDF.Description.first(@rdf_type) == @riptide_policy
    end)
  end

  defp stream_id(tenant_id),
    do: ResourceController.stream_id_for({:tenant, tenant_id}, ["_authz", "policies"])

  defp write_patch(tenant_id, additions, removals) do
    stream_id = stream_id(tenant_id)

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

  defp read_graph(tenant_id) do
    stream_id = stream_id(tenant_id)

    case Riptide.Placement.lookup(stream_id) do
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
