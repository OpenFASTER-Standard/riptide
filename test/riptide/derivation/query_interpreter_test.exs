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
      {:ok, even_base} = Parser.decode(~s|even(X, "yes") :- zeroMarker(X, "yes").|)
      {:ok, even_step} = Parser.decode(~s|even(X, "yes") :- succ(Y, X), odd(Y, "yes").|)
      {:ok, odd_step} = Parser.decode(~s|odd(X, "yes") :- succ(Y, X), even(Y, "yes").|)

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

  describe "evaluate/3 — safety bounds" do
    test "max_iterations tripping via opts returns :iteration_limit_exceeded" do
      {:ok, base} = Parser.decode("ancestor(X, Y) :- parent(X, Y).")
      {:ok, recursive} = Parser.decode("ancestor(X, Z) :- parent(X, Y), ancestor(Y, Z).")

      graph =
        RDF.Graph.new([
          {t("a"), rel("parent"), t("b")},
          {t("b"), rel("parent"), t("c")},
          {t("c"), rel("parent"), t("d")}
        ])

      assert QueryInterpreter.evaluate([base, recursive], graph, max_iterations: 1) ==
               {:error, :iteration_limit_exceeded}
    end

    test "max_fact_count tripping via opts returns :fact_limit_exceeded" do
      {:ok, base} = Parser.decode("ancestor(X, Y) :- parent(X, Y).")
      {:ok, recursive} = Parser.decode("ancestor(X, Z) :- parent(X, Y), ancestor(Y, Z).")

      graph =
        RDF.Graph.new([
          {t("a"), rel("parent"), t("b")},
          {t("b"), rel("parent"), t("c")},
          {t("c"), rel("parent"), t("d")}
        ])

      # The full closure needs 3 parent + 6 ancestor = 9 triples (the
      # transitive-closure test above). Round 1 alone already adds the 3
      # base ancestor facts (a-b, b-c, c-d — derivable straight from the
      # 3 parent facts, no recursion needed yet), taking the graph to 6
      # triples — verified directly via a real Matcher.evaluate/2 call
      # against this exact fixture. 6 > 5, so this trips at the end of
      # round 1, before the recursive clause ever produces anything.
      assert QueryInterpreter.evaluate([base, recursive], graph, max_fact_count: 5) ==
               {:error, :fact_limit_exceeded}
    end

    test "max_iterations from Application config trips the same way as an explicit opt" do
      Riptide.AppEnvTestHelpers.put_env(:riptide, :query_interpreter_max_iterations, 1)

      {:ok, base} = Parser.decode("ancestor(X, Y) :- parent(X, Y).")
      {:ok, recursive} = Parser.decode("ancestor(X, Z) :- parent(X, Y), ancestor(Y, Z).")

      graph =
        RDF.Graph.new([
          {t("a"), rel("parent"), t("b")},
          {t("b"), rel("parent"), t("c")},
          {t("c"), rel("parent"), t("d")}
        ])

      assert QueryInterpreter.evaluate([base, recursive], graph) ==
               {:error, :iteration_limit_exceeded}
    end
  end

  describe "evaluate/3 — Matcher's own errors propagate unchanged" do
    test "an unsafe rule (Head variable absent from the Body) is rejected the same way Matcher.evaluate/2 rejects it" do
      alias Riptide.Derivation.Literal.FactPattern
      alias Riptide.Derivation.{Rule, Signature, Var}

      head = %FactPattern{predicate: rel("bad"), args: [%Var{name: "X"}, %Var{name: "Unbound"}]}
      body = [%FactPattern{predicate: rel("f"), args: [%Var{name: "X"}, %Var{name: "X"}]}]

      rule = %Rule{
        signature: %Signature{
          name: head.predicate,
          parameters: head.args,
          reads: [],
          produces: [head.predicate]
        },
        head: head,
        body: body
      }

      assert QueryInterpreter.evaluate([rule], RDF.Graph.new()) ==
               {:error, {:unsafe_rule, %Var{name: "Unbound"}}}
    end

    test "a Body containing a capability(...) literal is rejected the same way Matcher.evaluate/2 rejects it" do
      alias Riptide.Derivation.Literal.CapabilityReference

      # Head vars (Svc, Target) are both bound by the fact-pattern literal
      # alone, so this Rule is safe — isolating the scope-check failure
      # from the safety check (Outcome is body-only, irrelevant to safety).
      # Matches test/riptide/derivation/matcher_test.exs's own identical
      # fixture for this exact scenario.
      {:ok, rule} =
        Parser.decode(
          "deployed(Svc, Target) :- pendingDeploy(Svc, Target), capability(deployService, Svc, Target, Outcome)."
        )

      assert {:error, {:unsupported_literal, %CapabilityReference{}}} =
               QueryInterpreter.evaluate([rule], RDF.Graph.new())
    end
  end
end
