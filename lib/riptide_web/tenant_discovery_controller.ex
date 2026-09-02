defmodule RiptideWeb.TenantDiscoveryController do
  @moduledoc """
  Tenant-scoped Discovery search — a direct analogue of
  `RiptideWeb.Hub.DiscoveryController.search/2`, searching the caller's own Tenant catalog instead
  of Hub's (design spec
  `docs/superpowers/specs/2026-09-01-phase-6m-tenant-execution-surface-design.md` §4.5). Unlike the
  Hub version, this lives on the ordinary `[:api, :tenant, :auth, :authz]` pipeline — reads here are
  already gated by the caller's own Tenant authorization, so this reuses that instead of Hub's
  separate public-surface rate limiter.
  """

  use Phoenix.Controller, formats: [:json]

  alias Riptide.Derivation.{Catalog, Discovery, RuleRDFCodec}
  alias Riptide.RDF.TurtleCodec

  def search(conn, %{"q" => query}) do
    tenant_id = conn.assigns.tenant_id
    {:ok, entries} = Discovery.find({:tenant, tenant_id}, query)
    {:ok, turtle} = entries |> entries_to_graph() |> TurtleCodec.encode()
    send_resp(conn, 200, turtle)
  end

  def show(conn, %{"node_id" => node_id}) do
    tenant_id = conn.assigns.tenant_id
    {:ok, entries} = Catalog.list_entries({:tenant, tenant_id})
    found = Enum.find(entries, fn {node, _rule} -> RDF.BlankNode.value(node) == node_id end)

    case found do
      nil ->
        send_resp(conn, 404, "")

      {_node, rule} ->
        {_node, graph} = RuleRDFCodec.to_rdf(rule)
        {:ok, turtle} = TurtleCodec.encode(graph)
        send_resp(conn, 200, turtle)
    end
  end

  defp entries_to_graph(entries) do
    Enum.reduce(entries, RDF.Graph.new(), fn {_node, rule}, graph ->
      {_node, rule_graph} = RuleRDFCodec.to_rdf(rule)
      RDF.Graph.add(graph, rule_graph)
    end)
  end
end
