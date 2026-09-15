defmodule Riptide.Clock.System do
  @moduledoc "The real wall clock — `Riptide.Clock`'s default implementation."

  @behaviour Riptide.Clock

  @impl Riptide.Clock
  def now, do: System.system_time(:second)
end
