defmodule Riptide.Derivation.Signature do
  @moduledoc """
  A Rule's typed interface — derived automatically from the parsed Rule
  (design spec §4/Global Constraints), not given its own concrete syntax.
  """

  defstruct [:name, :parameters, :reads, :produces]

  @type t :: %__MODULE__{
          name: RDF.IRI.t(),
          parameters: [Riptide.Derivation.Var.t()],
          reads: [RDF.IRI.t()],
          produces: [RDF.IRI.t()]
        }
end
