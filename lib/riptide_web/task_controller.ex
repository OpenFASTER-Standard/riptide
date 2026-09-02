defmodule RiptideWeb.TaskController do
  @moduledoc """
  Task submission — Discovery-first, `LLMFallback` fallback, writes a `Job` (design spec
  `docs/superpowers/specs/2026-09-01-phase-6m-tenant-execution-surface-design.md` §4.4). Never
  returns a Job's final result inline — the caller watches it execute live via the existing
  generic `GET /tenants/:tenant_id/resources/jobs` + SSE subscription (§3), the same way any other
  live Riptide surface is watched.
  """

  use Phoenix.Controller, formats: [:json]

  alias Riptide.Derivation.{Catalog, ContextResolver, Discovery, ExecuteInterpreter, Job, LLMFallback, Rule}
  alias Riptide.Derivation.Literal.CapabilityReference
  alias Riptide.{Event, Stream.StreamServer, Stream.StreamSupervisor}

  def create(conn, %{"description" => description} = params) do
    tenant_id = conn.assigns.tenant_id

    case Riptide.WriteRateLimit.check(tenant_id) do
      :deny -> send_resp(conn, 429, "")
      :allow -> handle_create(conn, tenant_id, description, params)
    end
  end

  def create(conn, _params), do: send_resp(conn, 400, "")

  defp handle_create(conn, tenant_id, description, params) do
    facts = Map.get(params, "facts", [])
    mutex_key = Map.get(params, "mutex_key")
    current_subject = conn.assigns[:current_subject]

    case Discovery.find({:tenant, tenant_id}, description) do
      {:ok, entries} ->
        # Not just the top-ranked match: a Rule generalized purely from Capability-invocation
        # Traces (no FactPattern literal anywhere in its own body — the shape
        # AntiUnifier.generalize/2 produces when the two source Traces were themselves bare
        # CapabilityReference calls) has a free Var no caller-supplied facts could ever bind —
        # confirmed live, routing a Task to it via Discovery reliably fails the resulting Job with
        # {:unbound_variable, _} every time, silently (a 202 that looks successful). Skip past any
        # such unsafe match to the next-ranked one, exactly like finding no match at all.
        case Enum.find(entries, fn {_node, rule} -> ExecuteInterpreter.invokable_via_facts?(rule) end) do
          {_node, rule} ->
            write_discovery_job(conn, tenant_id, description, rule, facts, mutex_key)

          nil ->
            resolve_via_llm_fallback(conn, tenant_id, description, facts, current_subject, mutex_key)
        end

      {:error, :not_ready} ->
        send_resp(conn, 503, "")
    end
  end

  defp resolve_via_llm_fallback(conn, tenant_id, description, facts, current_subject, mutex_key) do
    graph = facts_to_graph(facts)
    {:ok, context} = ContextResolver.resolve_all(tenant_id, current_subject)

    case LLMFallback.run(description, graph, context) do
      {:ok, trace} ->
        write_llm_fallback_job(conn, tenant_id, description, trace, mutex_key)

      {:error, reason} ->
        body = Jason.encode!(%{"error" => "llm_fallback_failed", "reason" => inspect(reason)})
        conn |> put_resp_content_type("application/json") |> send_resp(422, body)
    end
  end

  defp write_discovery_job(conn, tenant_id, description, rule, facts, mutex_key) do
    case write_task_facts(tenant_id, facts) do
      {:ok, job_graph_stream_id} ->
        job = %Job{
          tenant_id: tenant_id,
          status: :pending,
          reference: {:rule, rule.signature.name},
          args: [],
          job_graph: job_graph_stream_id,
          result: nil,
          error: nil,
          mutex_key: mutex_key,
          resolved_via: :discovery,
          original_description: description,
          trace: nil
        }

        finish_write(conn, tenant_id, job)

      {:error, :not_ready} ->
        send_resp(conn, 503, "")
    end
  end

  defp write_llm_fallback_job(
         conn,
         tenant_id,
         description,
         %Rule{body: [%CapabilityReference{capability: capability_iri, args: args}]} = trace,
         mutex_key
       ) do
    job = %Job{
      tenant_id: tenant_id,
      status: :pending,
      reference: {:capability, capability_iri},
      args: args,
      job_graph: nil,
      result: nil,
      error: nil,
      mutex_key: mutex_key,
      resolved_via: :llm_fallback,
      original_description: description,
      trace: trace
    }

    finish_write(conn, tenant_id, job)
  end

  defp finish_write(conn, tenant_id, job) do
    case Catalog.write_job(tenant_id, job) do
      {:ok, node} ->
        body =
          Jason.encode!(%{
            "job_node" => RDF.BlankNode.value(node),
            "resolved_via" => Atom.to_string(job.resolved_via)
          })

        conn |> put_resp_content_type("application/json") |> send_resp(202, body)

      {:error, :not_ready} ->
        send_resp(conn, 503, "")
    end
  end

  # Mirrors job_trigger_cluster_test.exs's own established "seed a dedicated job_graph stream
  # before writing the Job" pattern exactly (6l), just server-driven from the Task's own submitted
  # facts instead of hand-written in a test. A per-submission stream (not one shared, accumulating
  # stream per Tenant) so two concurrent Task submissions against the same predicate never see each
  # other's facts.
  defp write_task_facts(tenant_id, facts) do
    stream_id = Catalog.job_stream_id(tenant_id) <> "/task-graphs/" <> Uniq.UUID.uuid4()
    graph = facts_to_graph(facts)

    case stream_id |> StreamSupervisor.ensure_ready() |> StreamSupervisor.ensure_ready_status() do
      :ok ->
        StreamServer.append(stream_id, Event.new(stream_id, :replace, graph))
        {:ok, stream_id}

      :error ->
        {:error, :not_ready}
    end
  end

  defp facts_to_graph(facts) do
    Enum.reduce(facts, RDF.Graph.new(), fn %{"subject" => s, "predicate" => p, "object" => o},
                                           graph ->
      RDF.Graph.add(graph, {RDF.iri(s), RDF.iri(p), RDF.literal(o)})
    end)
  end
end
