defmodule Riptide.Derivation.Provenance do
  @moduledoc """
  The dependency edge back to what a Rule was generalized or installed
  from (design spec `docs/superpowers/specs/2026-08-27-derivation-and-execution-layer-design.md`
  §5). A general, reusable concept from the start: `AntiUnifier.generalize/2`
  stamps `:generalized_from`; Install (`Riptide.Derivation.Install`) stamps
  `:installed_from`. See design spec
  `docs/superpowers/specs/2026-08-30-phase-6i-crosswalks-and-installation-design.md`
  §4 for why this lives directly on `Rule.t()` rather than a separate store.
  """

  alias Riptide.Derivation.Rule

  @type field_binding :: %{
          predicate: RDF.IRI.t(),
          binding: {:crosswalk, crosswalk_node :: RDF.BlankNode.t()} | :manual
        }

  @type origin ::
          {:generalized_from, source1 :: Rule.t(), source2 :: Rule.t()}
          | {:installed_from, source_entry :: RDF.BlankNode.t(),
             field_bindings :: [field_binding()]}

  @enforce_keys [:origin]
  defstruct [:origin]

  @type t :: %__MODULE__{origin: origin()}
end
