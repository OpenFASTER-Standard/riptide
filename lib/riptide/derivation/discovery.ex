defmodule Riptide.Derivation.Discovery do
  @moduledoc """
  Exact/keyword lookup over CatalogEntry — the walking skeleton's own final
  step. See design spec
  `docs/superpowers/specs/2026-08-29-phase-6g-i-exact-keyword-discovery-design.md`.
  Word-set equality between the query and a found entry's predicate local
  name ranks above any partial-overlap keyword match; free-variable count
  (specificity) breaks ties within either tier.
  """

  alias Riptide.Derivation.{Catalog, Rule, Var}
  alias Riptide.Derivation.Literal.{CapabilityReference, FactPattern, RuleReference}

  @spec find(Catalog.scope(), String.t()) ::
          {:ok, [{RDF.BlankNode.t(), Rule.t()}]} | {:error, :not_ready}
  def find(scope, query_text) do
    with {:ok, entries} <- Catalog.list_entries(scope) do
      query_words = MapSet.new(tokenize(query_text))

      ranked =
        entries
        |> Enum.map(fn {node, rule} -> {node, rule, score(rule, query_words)} end)
        |> Enum.reject(fn {_node, _rule, score} -> score == :no_match end)
        |> Enum.sort_by(fn {_node, rule, score} -> sort_key(score, rule) end)
        |> Enum.map(fn {node, rule, _score} -> {node, rule} end)

      {:ok, ranked}
    end
  end

  defp score(rule, query_words) do
    predicate_words = MapSet.new(camel_words(local_name(rule.signature.name)))
    overlap = MapSet.intersection(predicate_words, query_words)

    cond do
      MapSet.equal?(predicate_words, query_words) -> {:exact}
      MapSet.size(overlap) > 0 -> {:keyword, MapSet.size(overlap)}
      true -> :no_match
    end
  end

  defp sort_key({:exact}, rule), do: {0, 0, specificity(rule)}
  defp sort_key({:keyword, overlap}, rule), do: {1, -overlap, specificity(rule)}

  defp specificity(%Rule{head: head, body: body}) do
    count_vars(head.args) + Enum.reduce(body, 0, &(count_vars(literal_terms(&1)) + &2))
  end

  defp literal_terms(%FactPattern{args: args}), do: args
  defp literal_terms(%CapabilityReference{args: args, result: result}), do: [result | args]
  defp literal_terms(%RuleReference{args: args, result: result}), do: [result | args]

  defp count_vars(terms), do: Enum.count(terms, &match?(%Var{}, &1))

  defp local_name(iri) do
    iri
    |> RDF.IRI.to_string()
    |> String.split(":")
    |> List.last()
  end

  defp camel_words(name) do
    name
    |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1 \\2")
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
  end

  defp tokenize(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
  end
end
