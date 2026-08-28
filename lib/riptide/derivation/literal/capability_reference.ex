defmodule Riptide.Derivation.Literal.CapabilityReference do
  @moduledoc """
  A reference to a Capability that ExecuteInterpretation may invoke. The
  last positional argument in the concrete syntax is always `result`; the
  rest are `args` (design spec §3).
  """

  alias Riptide.Derivation.Var

  @enforce_keys [:capability, :args, :result]
  defstruct [:capability, :args, :result]

  @type t :: %__MODULE__{
          capability: RDF.IRI.t(),
          args: [Var.t() | RDF.Term.t()],
          result: Var.t() | RDF.Term.t()
        }
end
