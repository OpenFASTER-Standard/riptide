defmodule Riptide.Derivation.QueryInterpreter do
  @moduledoc """
  QueryInterpretation's own module — a fixpoint evaluator over a ruleset
  (a list of Rules, e.g. a base clause plus a recursive clause sharing one
  head predicate). Iterates `Riptide.Derivation.Matcher.evaluate/2` per
  rule each round, merging newly-derived triples into the graph, until a
  round adds nothing new (the least fixpoint). See design spec
  `docs/superpowers/specs/2026-08-30-phase-6c-ii-recursion-fixpoint-design.md`
  §5 for why this always terminates and needs no stratification: no
  literal type in this codebase expresses negation, so every rule is
  monotonic by construction, and fact-pattern-only rules never synthesize
  new constants, so the Herbrand universe is finite.
  """

  alias Riptide.Derivation.{Matcher, Rule, Var}

  @default_max_iterations 10_000
  @default_max_fact_count 1_000_000

  @spec evaluate([Rule.t()], RDF.Graph.t(), keyword()) ::
          {:ok, RDF.Graph.t()}
          | {:error,
             :too_many_variables
             | {:unsupported_literal, Rule.literal()}
             | {:unsafe_rule, Var.t()}
             | :iteration_limit_exceeded
             | :fact_limit_exceeded}
  def evaluate(rules, %RDF.Graph{} = graph, opts \\ []) when is_list(rules) do
    max_iterations =
      Keyword.get(
        opts,
        :max_iterations,
        Application.get_env(:riptide, :query_interpreter_max_iterations, @default_max_iterations)
      )

    max_fact_count =
      Keyword.get(
        opts,
        :max_fact_count,
        Application.get_env(:riptide, :query_interpreter_max_fact_count, @default_max_fact_count)
      )

    loop(rules, graph, 0, max_iterations, max_fact_count)
  end

  defp loop(_rules, _graph, round, max_iterations, _max_fact_count)
       when round >= max_iterations do
    {:error, :iteration_limit_exceeded}
  end

  defp loop(rules, graph, round, max_iterations, max_fact_count) do
    with {:ok, new_triples} <- evaluate_all_rules(rules, graph) do
      next_graph = RDF.Graph.add(graph, new_triples)

      cond do
        RDF.Graph.triple_count(next_graph) > max_fact_count ->
          {:error, :fact_limit_exceeded}

        RDF.Graph.triple_count(next_graph) == RDF.Graph.triple_count(graph) ->
          {:ok, next_graph}

        true ->
          loop(rules, next_graph, round + 1, max_iterations, max_fact_count)
      end
    end
  end

  defp evaluate_all_rules(rules, graph) do
    Enum.reduce_while(rules, {:ok, []}, fn rule, {:ok, acc} ->
      case Matcher.evaluate(rule, graph) do
        {:ok, triples} -> {:cont, {:ok, acc ++ triples}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
