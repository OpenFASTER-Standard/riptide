defmodule Riptide.Derivation.Literal.FactPattern do
  @moduledoc """
  A fact-pattern literal — matched against the EDB, classical Datalog.
  Reifies as an `sp:TriplePattern` (design spec §5), which requires
  exactly 2 args (subject, object).
  """

  alias Riptide.Derivation.Var

  @enforce_keys [:predicate, :args]
  defstruct [:predicate, :args]

  @type t :: %__MODULE__{predicate: RDF.IRI.t(), args: [Var.t() | RDF.Term.t()]}
end
