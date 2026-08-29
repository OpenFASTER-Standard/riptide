defmodule Riptide.Capability.Definition do
  @moduledoc """
  A tenant-invocable Capability: which compiled WASI Preview 2 component to
  run, which of its exported functions to call, and the resource limits
  that bound the invocation. See design spec
  `docs/superpowers/specs/2026-08-28-phase-6b-i-wasi-execution-substrate-design.md`
  §2 (Revision 2) — `function` is a plan-level addition; nothing else in
  this struct's shape needs one.
  """

  @enforce_keys [:name, :kind, :component, :function, :fuel_limit, :timeout_ms, :memory_limits]
  defstruct [:name, :kind, :component, :function, :fuel_limit, :timeout_ms, :memory_limits]

  @type memory_limits :: %{
          max_memory_size: non_neg_integer() | nil,
          max_table_elements: non_neg_integer() | nil,
          max_instances: non_neg_integer() | nil,
          max_tables: non_neg_integer() | nil
        }

  @type t :: %__MODULE__{
          name: RDF.IRI.t(),
          kind: :effect | :observe,
          component: String.t(),
          function: String.t(),
          fuel_limit: pos_integer(),
          timeout_ms: pos_integer(),
          memory_limits: memory_limits()
        }
end
