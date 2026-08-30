defmodule Riptide.Derivation.QueryInterpreterTest do
  use ExUnit.Case, async: true

  alias Riptide.Derivation.{Parser, QueryInterpreter}

  defp t(name), do: RDF.iri("urn:test:" <> name)
  defp rel(name), do: RDF.iri("urn:riptide:relation:" <> name)

  describe "evaluate/2 — transitive closure" do
    test "a base clause plus a recursive clause reach the correct least fixpoint" do
      {:ok, base} = Parser.decode("ancestor(X, Y) :- parent(X, Y).")
      {:ok, recursive} = Parser.decode("ancestor(X, Z) :- parent(X, Y), ancestor(Y, Z).")

      graph =
        RDF.Graph.new([
          {t("a"), rel("parent"), t("b")},
          {t("b"), rel("parent"), t("c")},
          {t("c"), rel("parent"), t("d")}
        ])

      assert {:ok, result} = QueryInterpreter.evaluate([base, recursive], graph)

      ancestor_pairs =
        result
        |> RDF.Graph.triples()
        |> Enum.filter(fn {_s, p, _o} -> p == rel("ancestor") end)
        |> Enum.map(fn {s, _p, o} -> {s, o} end)
        |> MapSet.new()

      assert ancestor_pairs ==
               MapSet.new([
                 {t("a"), t("b")},
                 {t("a"), t("c")},
                 {t("a"), t("d")},
                 {t("b"), t("c")},
                 {t("b"), t("d")},
                 {t("c"), t("d")}
               ])

      # The original EDB is still present — evaluate/2 returns EDB ∪ IDB, not just the delta.
      assert RDF.Graph.include?(result, {t("a"), rel("parent"), t("b")})
    end
  end

  describe "evaluate/2 — mutual recursion across two predicates" do
    test "even/odd via a successor chain, proving the algorithm isn't limited to self-recursion" do
      {:ok, even_base} = Parser.decode("even(X, \"yes\") :- zeroMarker(X, \"yes\").")
      {:ok, even_step} = Parser.decode("even(X, \"yes\") :- succ(Y, X), odd(Y, \"yes\").")
      {:ok, odd_step} = Parser.decode("odd(X, \"yes\") :- succ(Y, X), even(Y, \"yes\").")

      graph =
        RDF.Graph.new([
          {t("zero"), rel("zeroMarker"), RDF.literal("yes")},
          {t("zero"), rel("succ"), t("one")},
          {t("one"), rel("succ"), t("two")},
          {t("two"), rel("succ"), t("three")},
          {t("three"), rel("succ"), t("four")}
        ])

      assert {:ok, result} = QueryInterpreter.evaluate([even_base, even_step, odd_step], graph)

      even_subjects =
        result
        |> RDF.Graph.triples()
        |> Enum.filter(fn {_s, p, _o} -> p == rel("even") end)
        |> Enum.map(fn {s, _p, _o} -> s end)
        |> MapSet.new()

      odd_subjects =
        result
        |> RDF.Graph.triples()
        |> Enum.filter(fn {_s, p, _o} -> p == rel("odd") end)
        |> Enum.map(fn {s, _p, _o} -> s end)
        |> MapSet.new()

      assert even_subjects == MapSet.new([t("zero"), t("two"), t("four")])
      assert odd_subjects == MapSet.new([t("one"), t("three")])
    end
  end

  describe "evaluate/2 — immediate fixpoint" do
    test "an EDB with no matching facts reaches fixpoint on the first round, unchanged" do
      {:ok, base} = Parser.decode("ancestor(X, Y) :- parent(X, Y).")
      {:ok, recursive} = Parser.decode("ancestor(X, Z) :- parent(X, Y), ancestor(Y, Z).")

      graph = RDF.Graph.new()

      assert {:ok, result} = QueryInterpreter.evaluate([base, recursive], graph)
      assert RDF.Graph.triple_count(result) == 0
    end
  end
end
