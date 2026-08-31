defmodule Riptide.PeriodicSweep do
  @moduledoc """
  Shared "wake up, do a bounded unit of work, reschedule" GenServer
  scaffolding — extracted after `ReplicaHealer` (3d-ii), `BlobStore.Healer`
  (6j), and this phase's own `JobTrigger` all needed the identical shape a
  third time (design spec
  `docs/superpowers/specs/2026-08-31-phase-6l-reactive-job-triggering-design.md`
  §8). The callback is `periodic_sweep/0`, not `sweep/0` — `ReplicaHealer`'s
  own existing public `sweep/0` is intentionally UNGATED (existing tests
  call it directly to bypass the leader check —
  `replica_healer_cluster_test.exs`'s own documented intent) while the
  leader gate lives in `handle_info(:sweep, state)`; reusing the bare name
  `sweep/0` for this shared callback would have silently changed what
  `ReplicaHealer.sweep/0` means to its own existing callers. Deliberately
  owns none of who's allowed to act on a given tick (a global leader-gate,
  no gate, a per-stream leader-gate all vary by consumer) — that stays
  entirely inside each consumer's own `periodic_sweep/0`.

  `handle_sweep/2` is a shared helper each consumer's own `handle_info(:sweep,
  state)` clause delegates to — mirroring `Riptide.SupervisedProcess.
  handle_stop_if_idle/4`'s exact established pattern in this same codebase —
  rather than the macro injecting a competing `def handle_info(:sweep, state)`
  clause directly. That first design was tried and found broken live: `use
  GenServer` marks `handle_info/2` `defoverridable`, and any consumer that
  ALSO needs its own separate `handle_info/2` clause for a different message
  (as `JobTrigger` does, for `{:job_written, stream_id}`) would have that
  later `def` silently REPLACE the whole function — discarding the
  macro-injected `:sweep` clause entirely, not adding to it — confirmed via
  an isolated repro before this fix. `init/1` doesn't have this problem
  (a GenServer's `init/1` is naturally single-clause, so `defoverridable`'s
  own full-replacement semantics are exactly what's wanted there) and stays
  macro-injected with `defoverridable`.
  """
  require Logger

  @callback periodic_sweep() :: :ok

  defmacro __using__(opts) do
    default_interval_ms = Keyword.fetch!(opts, :default_interval_ms)
    interval_env_key = Keyword.fetch!(opts, :interval_env_key)

    quote do
      @behaviour Riptide.PeriodicSweep

      @riptide_periodic_sweep_default_interval_ms unquote(default_interval_ms)
      @riptide_periodic_sweep_interval_env_key unquote(interval_env_key)

      @doc false
      def schedule_sweep do
        interval =
          Application.get_env(
            :riptide,
            @riptide_periodic_sweep_interval_env_key,
            @riptide_periodic_sweep_default_interval_ms
          )

        Process.send_after(self(), :sweep, interval)
      end

      @impl GenServer
      def init(:ok) do
        schedule_sweep()
        {:ok, %{}}
      end

      defoverridable init: 1
    end
  end

  @doc """
  Shared `handle_info(:sweep, state)` body — each consumer's own boilerplate
  clause delegates here, the same way `Riptide.SupervisedProcess`'s own
  consumers delegate their `handle_call({:riptide_supervised_process,
  :stop_if_idle, reason}, from, state)` clause to `handle_stop_if_idle/4`:

      @impl GenServer
      def handle_info(:sweep, state), do: Riptide.PeriodicSweep.handle_sweep(__MODULE__, state)
  """
  @spec handle_sweep(module(), term()) :: {:noreply, term()}
  def handle_sweep(module, state) do
    safe_sweep(module)
    module.schedule_sweep()
    {:noreply, state}
  end

  @doc false
  def safe_sweep(module) do
    module.periodic_sweep()
  rescue
    e ->
      Logger.warning(
        "#{inspect(module)} sweep failed, skipping this tick (#{Exception.message(e)})"
      )
  catch
    :exit, reason ->
      Logger.warning("#{inspect(module)} sweep failed, skipping this tick (#{inspect(reason)})")
  end
end
