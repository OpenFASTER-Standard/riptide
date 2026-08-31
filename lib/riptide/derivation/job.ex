defmodule Riptide.Derivation.Job do
  @moduledoc """
  An explicit "run this Capability/Rule with these args" request, living in
  the requesting tenant's own stream — see design spec
  `docs/superpowers/specs/2026-08-31-phase-6l-reactive-job-triggering-design.md`
  §5. Plain writes, never reviewed (unlike a `CapabilityCatalogEntry` or
  Rule Catalog admission).
  """

  @enforce_keys [:tenant_id, :status, :reference, :args]
  defstruct [:tenant_id, :status, :reference, :args, :job_graph, :result, :error]

  @type reference_t :: {:capability, RDF.IRI.t()} | {:rule, RDF.IRI.t()}

  @type t :: %__MODULE__{
          tenant_id: String.t(),
          status: :pending | :done | :failed,
          reference: reference_t(),
          args: [RDF.Term.t()],
          job_graph: String.t() | nil,
          result: RDF.Term.t() | nil,
          error: String.t() | nil
        }
end
