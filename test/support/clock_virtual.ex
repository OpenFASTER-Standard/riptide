defmodule Riptide.Clock.Virtual do
  @moduledoc """
  Test-only `Riptide.Clock` implementation: an Agent holding a mutable
  "current time," advanced explicitly via `advance/1` instead of real
  sleeping. Named (`__MODULE__`) rather than referenced by pid, matching
  this codebase's existing convention for singleton test-coordination
  processes in `async: false` suites (e.g. `Riptide.Stream.ReplicaHealer`).
  Only one test process should configure `config :riptide, :clock,
  Riptide.Clock.Virtual` at a time.
  """

  use Agent

  @behaviour Riptide.Clock

  @spec start_link(integer()) :: Agent.on_start()
  def start_link(initial_seconds) do
    Agent.start_link(fn -> initial_seconds end, name: __MODULE__)
  end

  @impl Riptide.Clock
  @spec now() :: integer()
  def now, do: Agent.get(__MODULE__, & &1)

  @spec advance(non_neg_integer()) :: :ok
  def advance(seconds) when is_integer(seconds) and seconds >= 0 do
    Agent.update(__MODULE__, &(&1 + seconds))
  end
end
