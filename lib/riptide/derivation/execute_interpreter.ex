defmodule Riptide.Derivation.ExecuteInterpreter.Context do
  @moduledoc """
  The caller-supplied resolvers `Riptide.Derivation.ExecuteInterpreter.call_template/3`
  needs — no Capability/Rule catalog exists yet (design spec
  `docs/superpowers/specs/2026-08-29-phase-6d-i-mechanical-wiring-design.md`
  §1/§2), so IRI resolution is a plain caller-supplied map, mirroring
  `Riptide.Derivation.Matcher`'s own caller-supplied-graph precedent.
  """

  @enforce_keys [:capabilities, :rules, :tenant_id, :current_subject]
  defstruct [:capabilities, :rules, :tenant_id, :current_subject]

  @type t :: %__MODULE__{
          capabilities: %{RDF.IRI.t() => Riptide.Capability.Definition.t()},
          rules: %{RDF.IRI.t() => Riptide.Derivation.Rule.t()},
          tenant_id: String.t(),
          current_subject: map() | nil
        }
end

defmodule Riptide.Derivation.ExecuteInterpreter do
  @moduledoc """
  ExecuteInterpretation: ties 6b-i's `Riptide.Capability.invoke/4` and
  6c-i-b's `Riptide.Derivation.Matcher` together into one recursive walk
  over a Rule's Body. See design spec
  `docs/superpowers/specs/2026-08-29-phase-6d-i-mechanical-wiring-design.md`
  §3 — a direct generalization of `Matcher.evaluate/2`, not a parallel
  algorithm: fact-pattern runs resolve via a real join
  (`Matcher.bindings/3`), `CapabilityReference`/`RuleReference` literals
  invoke once per branch.
  """

  require Logger

  alias Riptide.Capability
  alias Riptide.Derivation.ExecuteInterpreter.Context
  alias Riptide.Derivation.Literal.{CapabilityReference, FactPattern, RuleReference}
  alias Riptide.Derivation.{Matcher, Rule, Var}

  @doc """
  Invokes `rule` end-to-end: resolves every fact-pattern run against
  `graph`, invokes every Capability/Rule-reference literal via `context`'s
  resolvers, and concludes the Head once per surviving branch. Returns
  `{:error, _}` only for a structural problem (an unresolvable IRI, or a
  `RuleReference` with other than one arg) — a well-formed Template that
  simply produces no Outcomes returns `{:ok, []}`.
  """
  @spec call_template(Rule.t(), RDF.Graph.t(), Context.t()) ::
          {:ok, [RDF.Triple.t()]}
          | {:error, {:unresolvable, RDF.IRI.t()} | {:unsupported_arity, RDF.IRI.t()}}
  def call_template(%Rule{} = rule, %RDF.Graph{} = graph, %Context{} = context) do
    call_template(rule, %{}, graph, context)
  end

  defp call_template(%Rule{} = rule, seed, %RDF.Graph{} = graph, %Context{} = context) do
    with :ok <- check_resolvable(rule.body, context) do
      bindings_list = execute_body(rule.body, seed, graph, context)
      {:ok, Enum.map(bindings_list, &conclude(rule.head, &1))}
    end
  end

  defp check_resolvable(body, context) do
    Enum.reduce_while(body, :ok, fn literal, :ok ->
      case check_literal_resolvable(literal, context) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp check_literal_resolvable(%FactPattern{}, _context), do: :ok

  defp check_literal_resolvable(%CapabilityReference{capability: iri}, context) do
    if Map.has_key?(context.capabilities, iri) do
      :ok
    else
      {:error, {:unresolvable, iri}}
    end
  end

  defp check_literal_resolvable(%RuleReference{rule: iri, args: args}, context) do
    cond do
      not Map.has_key?(context.rules, iri) -> {:error, {:unresolvable, iri}}
      length(args) != 1 -> {:error, {:unsupported_arity, iri}}
      true -> :ok
    end
  end

  defp execute_body([], bindings, _graph, _context), do: [bindings]

  defp execute_body([%FactPattern{} | _] = literals, bindings, graph, context) do
    {fact_run, rest} = Enum.split_while(literals, &match?(%FactPattern{}, &1))

    case Matcher.bindings(fact_run, graph, bindings) do
      {:ok, extended_bindings_list} ->
        Enum.flat_map(extended_bindings_list, &execute_body(rest, &1, graph, context))

      {:error, reason} ->
        Logger.warning("ExecuteInterpreter: fact-pattern run failed: #{inspect(reason)}")
        []
    end
  end

  defp execute_body([%CapabilityReference{} = literal | rest], bindings, graph, context) do
    case invoke_capability(literal, bindings, context) do
      {:ok, new_bindings} -> execute_body(rest, new_bindings, graph, context)
      :drop -> []
    end
  end

  defp execute_body([%RuleReference{} = literal | rest], bindings, graph, context) do
    literal
    |> invoke_rule(bindings, graph, context)
    |> Enum.flat_map(&execute_body(rest, &1, graph, context))
  end

  defp conclude(%FactPattern{predicate: predicate, args: [subject, object]}, bindings) do
    {substitute(subject, bindings), predicate, substitute(object, bindings)}
  end

  defp substitute(%Var{} = var, bindings), do: Map.fetch!(bindings, var)
  defp substitute(term, _bindings), do: term

  defp invoke_capability(
         %CapabilityReference{capability: iri, args: args, result: result},
         bindings,
         context
       ) do
    definition = Map.fetch!(context.capabilities, iri)
    resolved_args = args |> Enum.map(&substitute(&1, bindings)) |> Enum.map(&term_to_arg/1)

    case Capability.invoke(definition, context.tenant_id, context.current_subject, resolved_args) do
      {:ok, value} ->
        {:ok, bind_result(bindings, result, value)}

      {:error, reason} ->
        Logger.warning(
          "ExecuteInterpreter: capability #{inspect(iri)} invocation failed: #{inspect(reason)}"
        )

        :drop
    end
  end

  defp invoke_rule(
         %RuleReference{rule: iri, args: [input_arg], result: result},
         bindings,
         graph,
         context
       ) do
    nested_rule = Map.fetch!(context.rules, iri)
    input_value = substitute(input_arg, bindings)
    [head_subject | _] = nested_rule.head.args

    seed =
      case head_subject do
        %Var{} = var -> %{var => input_value}
        _constant -> %{}
      end

    case call_template(nested_rule, seed, graph, context) do
      {:ok, triples} ->
        Enum.map(triples, fn {_subject, _predicate, object} ->
          bind_result(bindings, result, object)
        end)

      {:error, _reason} ->
        []
    end
  end

  # Capability.invoke/4 requires plain Elixir strings (they get inspect/1'd
  # into wasmtime's --invoke wave-syntax call) — a bound Var's value is an
  # RDF.Term.t() (an IRI or Literal from a fact-pattern match, or a literal
  # constant straight from the Rule text), never a bare string on its own,
  # so this conversion is mandatory, not a convenience. Passing an
  # unconverted %RDF.IRI{}/%RDF.Literal{} through inspect/1 would produce
  # invalid wave syntax (e.g. `~I<urn:test:alice>`), not a string literal.
  defp term_to_arg(%RDF.IRI{} = iri), do: RDF.IRI.to_string(iri)
  defp term_to_arg(%RDF.Literal{} = literal), do: RDF.Literal.value(literal)
  defp term_to_arg(string) when is_binary(string), do: string

  defp bind_result(bindings, %Var{} = var, value), do: Map.put(bindings, var, value)
  defp bind_result(bindings, _constant, _value), do: bindings
end
