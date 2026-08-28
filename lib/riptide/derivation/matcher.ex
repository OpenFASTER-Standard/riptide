defmodule Riptide.Derivation.Matcher do
  @moduledoc """
  Fact-pattern matching and joins — the fact-pattern-only fragment of
  QueryInterpretation (design spec
  `docs/superpowers/specs/2026-08-28-phase-6c-i-b-fact-pattern-matching-design.md`).

  A thin adapter over `RDF.Query`/`RDF.Query.BGP`: nothing outside this
  module ever references `RDF.Query.BGP` directly. Body variables are
  never turned into atoms via `String.to_atom/1` on their name text —
  `RDF.Query.BGP`'s matcher hardcodes `is_atom/1` as its internal test for
  "this position is a variable" (`rdf` hex package's `bgp/helper.ex`,
  `bgp/query_planner.ex`), and Rule Body text is untrusted/LLM-authorable,
  so deriving atoms from it would reopen the same unbounded-atom-creation
  risk this codebase has already fixed twice (design spec §4). Instead, a
  small, fixed pool of atoms created once at compile time stands in for
  "the Nth distinct variable in this Body" — the mapping from a Rule's
  real `Var.t()` names to pool slots is plain local state, scoped to one
  `bindings/2`/`evaluate/2` call, never persisted.
  """

  alias Riptide.Derivation.{Rule, Var}
  alias Riptide.Derivation.Literal.FactPattern

  @max_variables 64
  @var_pool Enum.map(1..@max_variables, &String.to_atom("$riptide_derivation_var_#{&1}"))

  @doc """
  The raw join: finds every binding of the Body's variables that satisfies
  every fact-pattern literal in `rule.body` against `graph` simultaneously.
  One map per satisfying solution; `{:ok, []}` (not an error) when the
  Body is well-formed but unsatisfiable against `graph`.
  """
  @spec bindings(Rule.t(), RDF.Graph.t()) ::
          {:ok, [%{Var.t() => RDF.Term.t()}]} | {:error, :too_many_variables}
  def bindings(%Rule{body: body}, %RDF.Graph{} = graph) do
    with {:ok, var_to_atom} <- assign_variable_pool(body) do
      triple_patterns = Enum.map(body, &to_triple_pattern(&1, var_to_atom))
      bgp = %RDF.Query.BGP{triple_patterns: triple_patterns}
      {:ok, results} = RDF.Query.execute(bgp, graph)

      atom_to_var = Map.new(var_to_atom, fn {var, atom} -> {atom, var} end)
      {:ok, Enum.map(results, &translate_binding(&1, atom_to_var))}
    end
  end

  defp assign_variable_pool(body) do
    vars =
      body
      |> Enum.flat_map(fn %FactPattern{args: args} -> args end)
      |> Enum.filter(&match?(%Var{}, &1))
      |> Enum.uniq()

    if length(vars) > @max_variables do
      {:error, :too_many_variables}
    else
      {:ok, vars |> Enum.zip(@var_pool) |> Map.new()}
    end
  end

  defp to_triple_pattern(%FactPattern{predicate: predicate, args: [subject, object]}, var_to_atom) do
    {to_pattern_term(subject, var_to_atom), predicate, to_pattern_term(object, var_to_atom)}
  end

  defp to_pattern_term(%Var{} = var, var_to_atom), do: Map.fetch!(var_to_atom, var)
  defp to_pattern_term(term, _var_to_atom), do: term

  defp translate_binding(binding, atom_to_var) do
    Map.new(binding, fn {atom, term} -> {Map.fetch!(atom_to_var, atom), term} end)
  end
end
