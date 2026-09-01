defmodule Riptide.Derivation.JobTrigger do
  @moduledoc """
  Reactive Job execution — see design spec
  `docs/superpowers/specs/2026-08-31-phase-6l-reactive-job-triggering-design.md`
  §7. Claims nothing: whichever node currently leads a Job's own stream
  (`RaCluster.stream_leader?/1`) is that Job's sole executor, discovered
  reactively via `Riptide.Derivation.Catalog`'s own `{:job_written,
  stream_id}` broadcast and self-healingly via `Riptide.PeriodicSweep`.

  A Job may declare `resource_key` — see design spec
  `docs/superpowers/specs/2026-09-01-phase-6d-ii-concurrent-effects-design.md`
  §4 — to mark that it must never execute concurrently with another Job for
  the same Tenant declaring the same key. Because every Job for a Tenant is
  already guaranteed to be evaluated by this same, uniquely Ra-elected
  process (the property `RaCluster.stream_leader?/1` already gives, §4.1),
  enforcing that is purely local, in-memory bookkeeping — two `:ets` tables
  owned by this process (`@resource_locks_table` for the currently-in-flight
  set, `@resource_monitors_table` to map a monitored Task's `reference()`
  back to the resource it holds, for crash-safe release) — not a new
  distributed primitive. Both tables die with this process, by design: on
  crash or planned leadership handover, whatever they held stops mattering
  (§4.4), and the newly-started/newly-leading process begins with an empty
  set — the same at-least-once contract Job execution already has,
  `resource_key` or not.
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

  # :public, not :protected — deliberately readable AND writable from
  # outside this process. Every real write still only ever happens from
  # within this process (run_exclusively/2 and the :DOWN handler below both
  # execute here — see test_run_exclusively/2's own comment for how tests
  # preserve that), so this doesn't weaken the actual guarantee; it only
  # lets tests assert against table contents directly
  # (`:ets.lookup(@resource_locks_table, ...)`) without a bespoke
  # inspection API.
  @resource_locks_table :job_trigger_resource_locks
  @resource_monitors_table :job_trigger_resource_monitors

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl GenServer
  def init(:ok) do
    :ets.new(@resource_locks_table, [:set, :public, :named_table])
    :ets.new(@resource_monitors_table, [:set, :public, :named_table])
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

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case :ets.lookup(@resource_monitors_table, ref) do
      [{^ref, resource}] ->
        :ets.delete(@resource_monitors_table, ref)
        :ets.delete(@resource_locks_table, resource)

      [] ->
        :ok
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:run_exclusively, resource, fun}, _from, state) do
    {:reply, run_exclusively(resource, fun), state}
  end

  @impl Riptide.PeriodicSweep
  def periodic_sweep do
    Placement.list_all()
    |> Enum.filter(fn {stream_id, _nodes} -> String.ends_with?(stream_id, "/jobs") end)
    |> Enum.each(fn {stream_id, _nodes} -> maybe_process_stream(stream_id) end)
  end

  # Test-only entry point. `run_exclusively/2` below calls `Process.monitor/1`
  # against whatever process calls IT — correct in production, since
  # try_spawn_execution/3 always calls it from within this GenServer's own
  # process (handle_info and periodic_sweep both execute here already,
  # unchanged from before this module gained resource-key exclusion). A
  # test calling run_exclusively/2 directly would instead make the TEST
  # process own the monitor, so the crash-safe cleanup in
  # handle_info({:DOWN, ...}) above — which only ever runs inside THIS
  # process — would never fire for it. Routing through a real (non-self)
  # GenServer.call makes handle_call/3 above execute run_exclusively/2 from
  # within this process instead, exactly like the production path. Can't
  # make the production path itself go through GenServer.call: it's always
  # invoked from within this same process already (see above), and a
  # process calling GenServer.call on itself deadlocks.
  @doc false
  @spec test_run_exclusively({String.t(), String.t()} | nil, (-> term())) :: :ok | :skipped
  def test_run_exclusively(resource, fun) do
    GenServer.call(__MODULE__, {:run_exclusively, resource, fun})
  end

  # Runs `fun` under `@execution_supervisor`, exclusively for `resource` (a
  # `{tenant_id, resource_key}` pair) if given — `nil` skips exclusion
  # entirely (most Jobs don't declare a resource_key, design spec §4.3).
  # `:ets.insert_new/2` is the whole reservation: an atomic "claim this key
  # only if nobody already holds it," so there's no separate
  # check-then-claim race. Returns `:skipped` (not an error) when the
  # resource is already held — the caller is expected to just retry on its
  # own next sweep, the same as any other transient condition already is.
  @doc false
  @spec run_exclusively({String.t(), String.t()} | nil, (-> term())) :: :ok | :skipped
  def run_exclusively(nil, fun) do
    Task.Supervisor.start_child(@execution_supervisor, fun)
    :ok
  end

  def run_exclusively(resource, fun) do
    if :ets.insert_new(@resource_locks_table, {resource}) do
      {:ok, pid} = Task.Supervisor.start_child(@execution_supervisor, fun)
      ref = Process.monitor(pid)
      :ets.insert(@resource_monitors_table, {ref, resource})
      :ok
    else
      :skipped
    end
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
        |> Enum.each(fn {node, job} -> try_spawn_execution(stream_id, node, job) end)

      {:error, :not_ready} ->
        :ok
    end
  end

  defp try_spawn_execution(stream_id, node, %Job{resource_key: nil} = job) do
    run_exclusively(nil, fn -> execute(stream_id, node, job) end)
  end

  defp try_spawn_execution(stream_id, node, %Job{tenant_id: tenant_id, resource_key: key} = job) do
    run_exclusively({tenant_id, key}, fn -> execute(stream_id, node, job) end)
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
