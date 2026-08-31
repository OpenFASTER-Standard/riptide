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

      @impl GenServer
      def handle_info(:sweep, state) do
        Riptide.PeriodicSweep.safe_sweep(__MODULE__)
        schedule_sweep()
        {:noreply, state}
      end

      defoverridable init: 1
    end
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
