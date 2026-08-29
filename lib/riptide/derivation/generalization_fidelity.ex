defmodule Riptide.Derivation.GeneralizationFidelity do
  @moduledoc """
  Checks whether a ground Trace (a `Rule.t()` whose Signature has no free
  parameters, per parent spec §5) replays faithfully: FactPattern presence
  in the graph, `:effect` Capabilities re-invoked and compared, `:observe`
  Capabilities trusted from their recorded result, RuleReference recursed
  through `context.rules`. See design spec
  `docs/superpowers/specs/2026-08-29-phase-6e-ii-generalization-fidelity-design.md`.

  Never touches `AntiUnifier`/Generalization/substitution — operates on one
  ground `Rule.t()` + graph + `ExecuteInterpreter.Context.t()`, reused as-is.
  """

  alias Riptide.Derivation.ExecuteInterpreter.Context
  alias Riptide.Derivation.Literal.{CapabilityReference, FactPattern, RuleReference}
  alias Riptide.Derivation.{Rule, Var}

  @type reason ::
          {:fact_not_present, {RDF.Term.t(), RDF.IRI.t(), RDF.Term.t()}}
          | {:capability_mismatch, RDF.IRI.t(), term(), term()}
          | {:capability_error, RDF.IRI.t(), term()}
          | {:nested, RDF.IRI.t(), reason()}

  @doc """
  Replays `rule` (a ground Trace) against `graph`/`context` and reports
  fidelity. `{:error, _}` only for a structural problem (not fully ground,
  or the same unresolvable-IRI/unsupported-arity shapes `ExecuteInterpreter`
  already reports for the identical situations).
  """
  @spec check(Rule.t(), RDF.Graph.t(), Context.t()) ::
          {:ok, :fidelity_pass}
          | {:ok, {:fidelity_fail, reason()}}
          | {:error, :not_ground | {:unresolvable, RDF.IRI.t()} | {:unsupported_arity, RDF.IRI.t()}}
  def check(%Rule{} = rule, %RDF.Graph{} = graph, %Context{} = context) do
    if ground?(rule) do
      check_body(rule.body, graph, context)
    else
      {:error, :not_ground}
    end
  end

  defp ground?(%Rule{head: head, body: body}), do: Enum.all?([head | body], &literal_ground?/1)

  defp literal_ground?(%FactPattern{args: args}), do: Enum.all?(args, &term_ground?/1)

  defp literal_ground?(%CapabilityReference{args: args, result: result}),
    do: Enum.all?([result | args], &term_ground?/1)

  defp literal_ground?(%RuleReference{args: args, result: result}),
    do: Enum.all?([result | args], &term_ground?/1)

  defp term_ground?(%Var{}), do: false
  defp term_ground?(_term), do: true

  defp check_body([], _graph, _context), do: {:ok, :fidelity_pass}

  defp check_body(
         [%FactPattern{predicate: predicate, args: [subject, object]} | rest],
         graph,
         context
       ) do
    if RDF.Graph.include?(graph, {subject, predicate, object}) do
      check_body(rest, graph, context)
    else
      {:ok, {:fidelity_fail, {:fact_not_present, {subject, predicate, object}}}}
    end
  end
end
