defmodule Riptide.Derivation.Literal.RuleReference do
  @moduledoc """
  A call to another Rule, with argument bindings — needed for Template
  composability (design spec §3, parent spec §9.2).
  """

  alias Riptide.Derivation.Var

  @enforce_keys [:rule, :args, :result]
  defstruct [:rule, :args, :result]

  @type t :: %__MODULE__{
          rule: RDF.IRI.t(),
          args: [Var.t() | RDF.Term.t()],
          result: Var.t() | RDF.Term.t()
        }
end
