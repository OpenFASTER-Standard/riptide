defmodule Riptide.SupervisedProcess.SessionTracker do
  @moduledoc """
  Owns the ETS table `Riptide.SupervisedProcess` uses for crash-session
  legibility — a complement to (not the same guarantee as) the voluntary
  restart/revoke gating `Riptide.SupervisedProcess.handle_stop_if_idle/4`
  implements: detects that a process was mid-session when it died, with
  no resumption logic. See design spec
  `docs/superpowers/specs/2026-08-29-phase-6b-ii-supervised-process-design.md`
  §2, §4. A tiny GenServer only to own the table's lifetime, mirroring
  `Riptide.Stream.Placement`'s own established pattern — every read/write
  operates directly on the table, never routing through this process.
  """

  use GenServer

  @table :riptide_supervised_process_sessions

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl GenServer
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @spec mark_session_active(term()) :: :ok
  def mark_session_active(id) do
    :ets.insert(@table, {id, :active})
    :ok
  end

  @spec mark_session_idle(term()) :: :ok
  def mark_session_idle(id) do
    :ets.insert(@table, {id, :idle})
    :ok
  end

  @spec was_active_at_crash?(term()) :: boolean()
  def was_active_at_crash?(id) do
    case :ets.lookup(@table, id) do
      [{^id, :active}] -> true
      _ -> false
    end
  end
end
