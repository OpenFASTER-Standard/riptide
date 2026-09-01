defmodule Riptide.Derivation.Job do
  @moduledoc """
  An explicit "run this Capability/Rule with these args" request, living in
  the requesting tenant's own stream — see design spec
  `docs/superpowers/specs/2026-08-31-phase-6l-reactive-job-triggering-design.md`
  §5. Plain writes, never reviewed (unlike a `CapabilityCatalogEntry` or
  Rule Catalog admission).

  A Job may declare `resource_key` (see design spec
  `docs/superpowers/specs/2026-09-01-phase-6d-ii-concurrent-effects-design.md`
  §4.3) to mark that it must never execute concurrently with another Job
  for the same Tenant declaring the same key. `nil` (the default) means
  this Job isn't subject to that coordination at all.

  A Job written by the Tenant-scoped Task-submission endpoint (see design spec
  `docs/superpowers/specs/2026-09-01-phase-6m-tenant-execution-surface-design.md`
  §4.3-4.4) additionally carries `resolved_via` (how it was resolved),
  `original_description` (the plain-English Task text), and — only when
  `resolved_via: :llm_fallback` — `trace` (the full ground Rule LLMFallback
  produced, needed by the Tenant-scoped propose endpoint to anti-unify
  against another Job's own trace). All three `nil` for a Job written
  directly, as every pre-6m Job already is.
  """

  alias Riptide.Derivation.Rule

  @enforce_keys [:tenant_id, :status, :reference, :args]
  defstruct [
    :tenant_id,
    :status,
    :reference,
    :args,
    :job_graph,
    :result,
    :error,
    :resource_key,
    :resolved_via,
    :original_description,
    :trace
  ]

  @type reference_t :: {:capability, RDF.IRI.t()} | {:rule, RDF.IRI.t()}
  @type resolved_via :: :discovery | :llm_fallback

  @type t :: %__MODULE__{
          tenant_id: String.t(),
          status: :pending | :done | :failed,
          reference: reference_t(),
          args: [RDF.Term.t()],
          job_graph: String.t() | nil,
          result: RDF.Term.t() | nil,
          error: String.t() | nil,
          resource_key: String.t() | nil,
          resolved_via: resolved_via() | nil,
          original_description: String.t() | nil,
          trace: Rule.t() | nil
        }
end
