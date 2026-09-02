defmodule RiptideWeb.TenantProposeController do
  @moduledoc """
  Tenant-scoped propose — a direct analogue of `RiptideWeb.Hub.ProposeController`, `target_scope`
  and `review_scope` both `{:tenant, tenant_id}` instead of `:hub` (design spec
  `docs/superpowers/specs/2026-09-01-phase-6m-tenant-execution-surface-design.md` §4.5). Takes two
  Job node references and reads each Job's own recorded `trace` back, rather than raw Turtle text —
  the natural shape now that Traces are already durably recorded as part of Task resolution (§4.4).
  """

  use Phoenix.Controller, formats: [:json]

  alias Riptide.Derivation.{AntiUnifier, Catalog, ContextResolver, DedupGate}

  def propose(conn, %{"job1" => job1_id, "job2" => job2_id} = params) do
    tenant_id = conn.assigns.tenant_id

    case Riptide.WriteRateLimit.check(tenant_id) do
      :deny -> send_resp(conn, 429, "")
      :allow -> handle_propose(conn, tenant_id, job1_id, job2_id, params)
    end
  end

  def propose(conn, _params), do: send_resp(conn, 400, "")

  defp handle_propose(conn, tenant_id, job1_id, job2_id, params) do
    with {:ok, trace1} <- find_job_trace(tenant_id, job1_id),
         {:ok, trace2} <- find_job_trace(tenant_id, job2_id),
         {:ok, candidates} <- AntiUnifier.generalize(trace1, trace2) do
      graph = facts_to_graph(Map.get(params, "facts", []))
      {:ok, context} = ContextResolver.resolve_all(tenant_id, conn.assigns[:current_subject])
      scope = {:tenant, tenant_id}

      case DedupGate.propose(scope, scope, candidates, graph, context) do
        {:ok, [outcome]} -> respond_outcome(conn, outcome)
        {:error, _reason} -> send_resp(conn, 503, "")
      end
    else
      {:error, :job_has_no_trace} ->
        body = Jason.encode!(%{"error" => "job_has_no_trace"})
        conn |> put_resp_content_type("application/json") |> send_resp(422, body)

      {:error, :not_found} ->
        send_resp(conn, 404, "")

      {:error, _reason} ->
        send_resp(conn, 400, "")
    end
  end

  defp respond_outcome(conn, {:queued, node, kind}) do
    body =
      Jason.encode!(%{
        "outcome" => "queued",
        "kind" => Atom.to_string(kind),
        "node_id" => RDF.BlankNode.value(node)
      })

    conn |> put_resp_content_type("application/json") |> send_resp(200, body)
  end

  defp respond_outcome(conn, {:rejected, reason}) do
    body = Jason.encode!(%{"outcome" => "rejected", "reason" => inspect(reason)})
    conn |> put_resp_content_type("application/json") |> send_resp(200, body)
  end

  defp respond_outcome(conn, {:fidelity_failed, evidence}) do
    body = Jason.encode!(%{"outcome" => "fidelity_failed", "evidence" => inspect(evidence)})
    conn |> put_resp_content_type("application/json") |> send_resp(200, body)
  end

  defp find_job_trace(tenant_id, job_id) do
    with {:ok, jobs} <- Catalog.list_jobs(Catalog.job_stream_id(tenant_id)) do
      jobs
      |> Enum.find(fn {node, _job} -> RDF.BlankNode.value(node) == job_id end)
      |> trace_from_found_job()
    end
  end

  defp trace_from_found_job(nil), do: {:error, :not_found}
  defp trace_from_found_job({_node, %{trace: nil}}), do: {:error, :job_has_no_trace}
  defp trace_from_found_job({_node, %{trace: trace}}), do: {:ok, trace}

  defp facts_to_graph(facts) do
    Enum.reduce(facts, RDF.Graph.new(), fn %{"subject" => s, "predicate" => p, "object" => o},
                                           graph ->
      RDF.Graph.add(graph, {RDF.iri(s), RDF.iri(p), RDF.literal(o)})
    end)
  end
end
