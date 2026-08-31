defmodule Riptide.Derivation.CapabilityCatalogEntry do
  @moduledoc """
  A Hub-scope, reviewed Capability, addressable by IRI. Identical field set to
  `Riptide.Capability.Definition` except `component` (a literal local path,
  meaningless outside the node that happened to receive it) is replaced by
  `component_hash` (a content hash, resolvable to real bytes on any node via
  `Riptide.BlobStore` — see `Riptide.Derivation.CapabilityCatalog.materialize/1`).
  See design spec
  `docs/superpowers/specs/2026-08-31-phase-6k-dynamic-capability-registration-design.md`
  §4.
  """

  @enforce_keys [
    :name,
    :kind,
    :component_hash,
    :function,
    :fuel_limit,
    :timeout_ms,
    :memory_limits
  ]
  defstruct [:name, :kind, :component_hash, :function, :fuel_limit, :timeout_ms, :memory_limits]

  @type t :: %__MODULE__{
          name: RDF.IRI.t(),
          kind: :effect | :observe,
          component_hash: String.t(),
          function: String.t(),
          fuel_limit: pos_integer(),
          timeout_ms: pos_integer(),
          memory_limits: Riptide.Capability.Definition.memory_limits()
        }
end
