defmodule RiptideWeb.Hub.DiscoveryController do
  @moduledoc """
  Network-reachable Hub Discovery/entry-fetch — tenant-less, optional
  auth (design spec
  `docs/superpowers/specs/2026-08-29-phase-6h-ii-pattern-hub-deployment-design.md`
  §2, §4, §6). No `:tenant`/`:authz` pipeline: reads are inherently
  cross-tenant, nobody "acts as" a Tenant to search.
  """

  use Phoenix.Controller, formats: [:json]

  alias Riptide.Derivation.{Catalog, Discovery, RuleRDFCodec}
  alias Riptide.RDF.TurtleCodec

  def search(conn, %{"q" => query}) do
    case conn |> rate_limit_key() |> Riptide.HubRateLimit.check_read() do
      :deny ->
        send_resp(conn, 429, "")

      :allow ->
        {:ok, entries} = Discovery.find(:hub, query)
        {:ok, turtle} = entries |> entries_to_graph() |> TurtleCodec.encode()
        send_resp(conn, 200, turtle)
    end
  end

  def show(conn, %{"node_id" => node_id}) do
    case conn |> rate_limit_key() |> Riptide.HubRateLimit.check_read() do
      :deny ->
        send_resp(conn, 429, "")

      :allow ->
        {:ok, entries} = Catalog.list_entries(:hub)

        case Enum.find(entries, fn {node, _rule} -> RDF.BlankNode.value(node) == node_id end) do
          nil ->
            send_resp(conn, 404, "")

          {_node, rule} ->
            {_node, graph} = RuleRDFCodec.to_rdf(rule)
            {:ok, turtle} = TurtleCodec.encode(graph)
            send_resp(conn, 200, turtle)
        end
    end
  end

  defp entries_to_graph(entries) do
    Enum.reduce(entries, RDF.Graph.new(), fn {_node, rule}, graph ->
      {_node, rule_graph} = RuleRDFCodec.to_rdf(rule)
      RDF.Graph.add(graph, rule_graph)
    end)
  end

  defp rate_limit_key(conn) do
    case conn.assigns[:current_subject] do
      %{"sub" => sub} when is_binary(sub) -> sub
      _ -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end
end
