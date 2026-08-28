defmodule Riptide.Derivation.Rule do
  @moduledoc """
  A declarative IDB definition over a Signature: given a Body, conclude a
  Head. See design spec §1 for what a Rule actually does under
  QueryInterpretation vs. ExecuteInterpretation (out of scope for this
  phase — this module is the shape both walk).
  """

  alias Riptide.Derivation.Literal.{CapabilityReference, FactPattern, RuleReference}
  alias Riptide.Derivation.Signature

  @enforce_keys [:signature, :head, :body]
  defstruct [:signature, :head, :body]

  @type literal :: FactPattern.t() | CapabilityReference.t() | RuleReference.t()

  @type t :: %__MODULE__{
          signature: Signature.t(),
          head: FactPattern.t(),
          body: [literal()]
        }
end
