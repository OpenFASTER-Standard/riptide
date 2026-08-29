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

  alias Riptide.Capability
  alias Riptide.Capability.Definition
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

  defp check_body(
         [%CapabilityReference{capability: iri, args: args, result: result} | rest],
         graph,
         context
       ) do
    case Map.fetch(context.capabilities, iri) do
      {:ok, %Definition{kind: :observe}} ->
        check_body(rest, graph, context)

      {:ok, %Definition{kind: :effect} = definition} ->
        resolved_args = Enum.map(args, &term_to_arg/1)

        case Capability.invoke(definition, context.tenant_id, context.current_subject, resolved_args) do
          {:ok, ^result} ->
            check_body(rest, graph, context)

          {:ok, actual} ->
            {:ok, {:fidelity_fail, {:capability_mismatch, iri, result, actual}}}

          {:error, reason} ->
            {:ok, {:fidelity_fail, {:capability_error, iri, reason}}}
        end

      :error ->
        {:error, {:unresolvable, iri}}
    end
  end

  # Capability.invoke/4 requires plain Elixir strings — a ground literal's
  # arg is an RDF.Term.t() (an IRI or Literal), never a bare string on its
  # own. Deliberate small duplication of ExecuteInterpreter's own private
  # helper of the same name/shape (lib/riptide/derivation/execute_interpreter.ex)
  # rather than exporting it across modules — matches this project's
  # established tolerance for that.
  defp term_to_arg(%RDF.IRI{} = iri), do: RDF.IRI.to_string(iri)
  defp term_to_arg(%RDF.Literal{} = literal), do: RDF.Literal.value(literal)
  defp term_to_arg(string) when is_binary(string), do: string

  defp check_body([%RuleReference{rule: iri, args: args} | rest], graph, context) do
    cond do
      not Map.has_key?(context.rules, iri) ->
        {:error, {:unresolvable, iri}}

      length(args) != 1 ->
        {:error, {:unsupported_arity, iri}}

      true ->
        nested_rule = Map.fetch!(context.rules, iri)

        case check(nested_rule, graph, context) do
          {:ok, :fidelity_pass} -> check_body(rest, graph, context)
          {:ok, {:fidelity_fail, reason}} -> {:ok, {:fidelity_fail, {:nested, iri, reason}}}
          {:error, reason} -> {:error, reason}
        end
    end
  end
end
