defmodule Riptide.Derivation.Var do
  @moduledoc """
  A variable in a `Riptide.Derivation.Rule`'s Body or Signature parameters.
  See design spec `docs/superpowers/specs/2026-08-28-rule-signature-representation-design.md` §4.
  """

  @enforce_keys [:name]
  defstruct [:name]

  @type t :: %__MODULE__{name: String.t()}
end
