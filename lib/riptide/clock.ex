defmodule Riptide.Clock do
  @moduledoc """
  Indirection over "what time is it," swappable via `config :riptide, :clock`
  — lets tests (e.g. Phase 7's decade simulation) advance time without real
  sleeping. Defaults to `Riptide.Clock.System`, which is what every non-test
  environment uses. Returns the same `:second`-granularity integer
  `System.system_time(:second)` already produced, so adopting this at any
  call site is a pure refactor.
  """

  @callback now() :: integer()

  @spec now() :: integer()
  def now do
    Application.get_env(:riptide, :clock, Riptide.Clock.System).now()
  end
end
