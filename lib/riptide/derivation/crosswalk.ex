defmodule Riptide.Derivation.Crosswalk do
  @moduledoc """
  An SSSOM-shaped mapping between two predicate IRIs (design spec
  `docs/superpowers/specs/2026-08-30-phase-6i-crosswalks-and-installation-design.md`
  §6). Same-Dialect signature-morphism translation only — see that
  spec's own §3 for why cross-Dialect comorphisms are out of scope.
  Always Hub-scope content (§6.5): a Crosswalk has no `scope()` of its
  own anywhere in this module's API.
  """

  @type match_type :: :exact_match | :close_match | :broad_match | :narrow_match | :related_match

  @enforce_keys [:subject_predicate, :object_predicate, :match_type]
  defstruct [:subject_predicate, :object_predicate, :match_type]

  @type t :: %__MODULE__{
          subject_predicate: RDF.IRI.t(),
          object_predicate: RDF.IRI.t(),
          match_type: match_type()
        }
end
