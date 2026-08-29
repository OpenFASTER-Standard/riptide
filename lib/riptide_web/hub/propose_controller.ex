defmodule RiptideWeb.Hub.ProposeController do
  @moduledoc """
  Publish-to-Hub — a Tenant's own DedupGate.propose/5 call, `target_scope:
  :hub`, `review_scope: {:tenant, tenant_id}` (design spec
  `docs/superpowers/specs/2026-08-29-phase-6h-ii-pattern-hub-deployment-design.md`
  §2, §5, §6). Scoped to fact-pattern-only candidates — no Capability
  registry exists yet to safely resolve `context.capabilities` from an
  HTTP request (spec §2, §9); `context.capabilities`/`context.rules` are
  always built as empty maps here, never accepted from the request body.
  """

  use Phoenix.Controller, formats: [:json]

  alias Riptide.Derivation.ExecuteInterpreter.Context
  alias Riptide.Derivation.{AntiUnifier, DedupGate, Parser}

  def propose(conn, params) do
    tenant_id = conn.assigns.tenant_id

    case Riptide.HubRateLimit.check_propose(tenant_id) do
      :deny ->
        send_resp(conn, 429, "")

      :allow ->
        handle_propose(conn, tenant_id, params)
    end
  end

  defp handle_propose(
         conn,
         tenant_id,
         %{"trace1" => trace1_text, "trace2" => trace2_text} = params
       ) do
    with {:ok, trace1} <- Parser.decode(trace1_text),
         {:ok, trace2} <- Parser.decode(trace2_text),
         {:ok, candidates} <- AntiUnifier.generalize(trace1, trace2) do
      graph = facts_to_graph(Map.get(params, "facts", []))

      context = %Context{
        capabilities: %{},
        rules: %{},
        tenant_id: tenant_id,
        current_subject: nil
      }

      case DedupGate.propose(:hub, {:tenant, tenant_id}, candidates, graph, context) do
        {:ok, [{:queued, node, kind}]} ->
          body =
            Jason.encode!(%{
              "outcome" => "queued",
              "kind" => Atom.to_string(kind),
              "node_id" => RDF.BlankNode.value(node)
            })

          conn |> put_resp_content_type("application/json") |> send_resp(200, body)

        {:ok, [{:rejected, reason}]} ->
          body = Jason.encode!(%{"outcome" => "rejected", "reason" => inspect(reason)})
          conn |> put_resp_content_type("application/json") |> send_resp(200, body)

        {:ok, [{:fidelity_failed, evidence}]} ->
          body = Jason.encode!(%{"outcome" => "fidelity_failed", "evidence" => inspect(evidence)})
          conn |> put_resp_content_type("application/json") |> send_resp(200, body)

        {:error, _reason} ->
          send_resp(conn, 503, "")
      end
    else
      {:error, _reason} -> send_resp(conn, 400, "")
    end
  end

  defp handle_propose(conn, _tenant_id, _params), do: send_resp(conn, 400, "")

  defp facts_to_graph(facts) do
    Enum.reduce(facts, RDF.Graph.new(), fn %{"subject" => s, "predicate" => p, "object" => o},
                                           graph ->
      RDF.Graph.add(graph, {RDF.iri(s), RDF.iri(p), RDF.literal(o)})
    end)
  end
end
