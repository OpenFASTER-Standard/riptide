defmodule Riptide.Authz.Policy do
  @moduledoc """
  One ACP-inspired access policy: grants (`effect: :allow`) or denies
  (`effect: :deny`) some set of `modes` to whoever `matcher` matches. See
  `Riptide.Authz.evaluate/4` for how a set of policies attached to a
  resource's ancestor path prefixes is combined into a single allow/deny
  decision (deny always overrides allow).
  """

  @type effect :: :allow | :deny
  @type mode :: :read | :write | :invoke
  @type matcher :: :public | :authenticated | {:agent, String.t()}

  @type t :: %__MODULE__{effect: effect(), modes: [mode()], matcher: matcher()}

  @enforce_keys [:effect, :modes, :matcher]
  defstruct [:effect, :modes, :matcher]
end
