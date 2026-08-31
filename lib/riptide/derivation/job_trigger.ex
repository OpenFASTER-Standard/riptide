defmodule Riptide.Derivation.JobTrigger do
  @moduledoc """
  Reactive Job execution — see design spec
  `docs/superpowers/specs/2026-08-31-phase-6l-reactive-job-triggering-design.md`
  §7. Claims nothing: whichever node currently leads a Job's own stream
  (`RaCluster.stream_leader?/1`) is that Job's sole executor, discovered
  reactively via `Riptide.Derivation.Catalog`'s own `{:job_written,
  stream_id}` broadcast and self-healingly via `Riptide.PeriodicSweep`.
  """

  use Riptide.PeriodicSweep,
    default_interval_ms: 30_000,
    interval_env_key: :job_trigger_sweep_interval_ms

  use GenServer
  require Logger

  alias Riptide.{Capability, Event, Placement, RaCluster}
  alias Riptide.Derivation.{CapabilityCatalog, Catalog, ContextResolver, ExecuteInterpreter, Job}
  alias Riptide.RDF.Patch
  alias Riptide.Stream.{StreamServer, StreamSupervisor}

  @jobs_topic "riptide:jobs"
  @execution_supervisor __MODULE__.ExecutionSupervisor

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl GenServer
  def init(:ok) do
    Phoenix.PubSub.subscribe(Riptide.PubSub, @jobs_topic)
    schedule_sweep()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:sweep, state), do: Riptide.PeriodicSweep.handle_sweep(__MODULE__, state)

  def handle_info({:job_written, stream_id}, state) do
    maybe_process_stream(stream_id)
    {:noreply, state}
  end

  @impl Riptide.PeriodicSweep
  def periodic_sweep do
    Placement.list_all()
    |> Enum.filter(fn {stream_id, _nodes} -> String.ends_with?(stream_id, "/jobs") end)
    |> Enum.each(fn {stream_id, _nodes} -> maybe_process_stream(stream_id) end)
  end

  defp maybe_process_stream(stream_id) do
    if RaCluster.stream_leader?(stream_id) do
      process_pending_jobs(stream_id)
    end
  end

  defp process_pending_jobs(stream_id) do
    case Catalog.list_jobs(stream_id) do
      {:ok, jobs} ->
        jobs
        |> Enum.filter(fn {_node, job} -> job.status == :pending end)
        |> Enum.each(fn {node, job} -> spawn_execution(stream_id, node, job) end)

      {:error, :not_ready} ->
        :ok
    end
  end

  defp spawn_execution(stream_id, node, job) do
    Task.Supervisor.start_child(@execution_supervisor, fn -> execute(stream_id, node, job) end)
  end

  defp execute(stream_id, node, %Job{reference: {:capability, iri}} = job) do
    with {:ok, entry} <- capability_not_found(CapabilityCatalog.find_by_name(iri), iri),
         {:ok, definition} <- CapabilityCatalog.materialize(entry) do
      args = Enum.map(job.args, &ExecuteInterpreter.term_to_arg/1)

      case Capability.invoke(definition, job.tenant_id, nil, args) do
        {:ok, result} -> Catalog.mark_job_done(stream_id, node, RDF.literal(result))
        {:error, reason} -> Catalog.mark_job_failed(stream_id, node, inspect(reason))
      end
    else
      {:error, reason} -> Catalog.mark_job_failed(stream_id, node, inspect(reason))
    end
  end

  defp execute(stream_id, node, %Job{reference: {:rule, iri}} = job) do
    with {:ok, graph} <- read_job_graph(job.job_graph),
         {:ok, context} <- ContextResolver.resolve(job.tenant_id, nil, iri) do
      rule = Map.fetch!(context.rules, iri)

      case ExecuteInterpreter.call_template(rule, graph, context) do
        {:ok, triples} -> Catalog.mark_job_done(stream_id, node, RDF.literal(inspect(triples)))
        {:error, reason} -> Catalog.mark_job_failed(stream_id, node, inspect(reason))
      end
    else
      {:error, reason} -> Catalog.mark_job_failed(stream_id, node, inspect(reason))
    end
  end

  defp capability_not_found({:ok, entry}, _iri), do: {:ok, entry}
  defp capability_not_found({:error, :not_found}, iri), do: {:error, {:not_found, iri}}

  # Mirrors LocationIndex.read_graph/0's own fold-from-StreamServer pattern
  # exactly (6j) — a jobRule Job's own graph is real Fact state, not
  # something ContextResolver itself has any business reading.
  defp read_job_graph(nil), do: {:error, :missing_job_graph}

  defp read_job_graph(stream_id) do
    case Placement.lookup(stream_id) do
      nil -> {:ok, RDF.Graph.new()}
      _nodes -> read_existing_job_graph(stream_id)
    end
  end

  defp read_existing_job_graph(stream_id) do
    case stream_id
         |> StreamSupervisor.ensure_ready()
         |> StreamSupervisor.ensure_ready_status() do
      :ok -> read_job_graph_events(stream_id)
      :error -> {:error, :not_ready}
    end
  end

  defp read_job_graph_events(stream_id) do
    case StreamServer.get_since(stream_id, 0) do
      {:ok, events} -> {:ok, fold_events(events)}
      {:gap, _oldest} -> {:ok, RDF.Graph.new()}
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
