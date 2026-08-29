defmodule Riptide.Derivation.MatcherTest do
  use ExUnit.Case, async: true

  alias Riptide.Derivation.Literal.FactPattern
  alias Riptide.Derivation.{Matcher, Parser, Rule, Signature, Var}

  defp t(name), do: RDF.iri("urn:test:" <> name)
  defp rel(name), do: RDF.iri("urn:riptide:relation:" <> name)

  defp plain(bindings) do
    Map.new(bindings, fn {%Var{name: name}, term} -> {name, term} end)
  end

  describe "bindings/2 — joins" do
    test "a two-literal shared-variable join" do
      {:ok, rule} = Parser.decode("sibling(X, Y) :- parent(P, X), parent(P, Y).")

      graph =
        RDF.Graph.new([
          {t("alice"), rel("parent"), t("bob")},
          {t("alice"), rel("parent"), t("carol")}
        ])

      assert {:ok, results} = Matcher.bindings(rule, graph)
      plain_sets = results |> Enum.map(&plain/1) |> MapSet.new()

      expected =
        MapSet.new([
          %{"P" => t("alice"), "X" => t("bob"), "Y" => t("bob")},
          %{"P" => t("alice"), "X" => t("bob"), "Y" => t("carol")},
          %{"P" => t("alice"), "X" => t("carol"), "Y" => t("bob")},
          %{"P" => t("alice"), "X" => t("carol"), "Y" => t("carol")}
        ])

      assert plain_sets == expected
    end

    test "a chained multi-hop join" do
      {:ok, rule} = Parser.decode("path(X, Y) :- edge(X, Z), edge(Z, Y).")

      graph =
        RDF.Graph.new([
          {t("a"), rel("edge"), t("b")},
          {t("b"), rel("edge"), t("c")},
          {t("c"), rel("edge"), t("d")}
        ])

      assert {:ok, results} = Matcher.bindings(rule, graph)
      plain_sets = results |> Enum.map(&plain/1) |> MapSet.new()

      expected =
        MapSet.new([
          %{"X" => t("a"), "Z" => t("b"), "Y" => t("c")},
          %{"X" => t("b"), "Z" => t("c"), "Y" => t("d")}
        ])

      assert plain_sets == expected
    end

    test "a self-join — the same variable used twice in one literal" do
      {:ok, rule} = Parser.decode("loop(X, X) :- edge(X, X).")

      graph =
        RDF.Graph.new([
          {t("a"), rel("edge"), t("a")},
          {t("a"), rel("edge"), t("b")}
        ])

      assert {:ok, results} = Matcher.bindings(rule, graph)
      assert [binding] = results
      assert plain(binding) == %{"X" => t("a")}
    end

    test "a well-formed Body that matches nothing returns an empty list, not an error" do
      {:ok, rule} = Parser.decode("sibling(X, Y) :- parent(P, X), parent(P, Y).")

      assert Matcher.bindings(rule, RDF.Graph.new()) == {:ok, []}
    end

    test "a Rule with more than 64 distinct Body variables is rejected" do
      body =
        for i <- 1..33 do
          %FactPattern{predicate: rel("f"), args: [%Var{name: "V#{i}"}, %Var{name: "W#{i}"}]}
        end

      head = %FactPattern{predicate: rel("g"), args: [%Var{name: "V1"}, %Var{name: "W1"}]}

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

      assert Matcher.bindings(rule, RDF.Graph.new()) == {:error, :too_many_variables}
    end
  end

  describe "bindings/2 — scope enforcement" do
    alias Riptide.Derivation.Literal.CapabilityReference

    test "a Body containing a capability(...) literal is rejected" do
      {:ok, rule} =
        Parser.decode(
          "deployed(Svc, Outcome) :- pendingDeploy(Svc, Target), capability(deployService, Svc, Target, Outcome)."
        )

      assert {:error, {:unsupported_literal, %CapabilityReference{}}} =
               Matcher.bindings(rule, RDF.Graph.new())
    end

    test "a Body containing a rule(...) literal is rejected" do
      {:ok, rule} =
        Parser.decode(
          "notified(Svc, Result) :- capability(deployService, Svc, Svc, Outcome), rule(notifyTeam, Svc, Outcome, Result)."
        )

      assert {:error, {:unsupported_literal, _}} = Matcher.bindings(rule, RDF.Graph.new())
    end
  end

  describe "evaluate/2 — concluding the Head" do
    test "substitutes each binding into the Head to produce concluded triples" do
      {:ok, rule} = Parser.decode("sibling(X, Y) :- parent(P, X), parent(P, Y).")

      graph =
        RDF.Graph.new([
          {t("alice"), rel("parent"), t("bob")},
          {t("alice"), rel("parent"), t("carol")}
        ])

      assert {:ok, triples} = Matcher.evaluate(rule, graph)

      assert MapSet.new(triples) ==
               MapSet.new([
                 {t("bob"), rel("sibling"), t("bob")},
                 {t("bob"), rel("sibling"), t("carol")},
                 {t("carol"), rel("sibling"), t("bob")},
                 {t("carol"), rel("sibling"), t("carol")}
               ])
    end

    test "a well-formed Body that matches nothing concludes no triples" do
      {:ok, rule} = Parser.decode("sibling(X, Y) :- parent(P, X), parent(P, Y).")

      assert Matcher.evaluate(rule, RDF.Graph.new()) == {:ok, []}
    end

    test "a Head variable absent from the Body is rejected as unsafe, before any graph access" do
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

      assert Matcher.evaluate(rule, RDF.Graph.new()) ==
               {:error, {:unsafe_rule, %Var{name: "Unbound"}}}
    end

    test "evaluate/2 also enforces fact-pattern-only scope" do
      # Head vars (Svc, Target) are both bound by the fact-pattern literal
      # alone, so this Rule is safe — isolating the scope-check failure
      # from the safety check (Outcome is body-only, irrelevant to safety).
      {:ok, rule} =
        Parser.decode(
          "deployed(Svc, Target) :- pendingDeploy(Svc, Target), capability(deployService, Svc, Target, Outcome)."
        )

      assert {:error, {:unsupported_literal, _}} = Matcher.evaluate(rule, RDF.Graph.new())
    end
  end

  describe "bindings/3 — seeded joins" do
    test "a variable already in the seed is substituted as a constant, not left free" do
      {:ok, rule} = Parser.decode("colleague(X, Y) :- worksAt(X, Y).")
      [works_at_literal] = rule.body

      graph =
        RDF.Graph.new([
          {t("alice"), rel("worksAt"), t("acme")},
          {t("bob"), rel("worksAt"), t("acme")}
        ])

      seed = %{%Var{name: "X"} => t("alice")}

      assert {:ok, results} = Matcher.bindings([works_at_literal], graph, seed)
      assert Enum.map(results, &plain/1) == [%{"X" => t("alice"), "Y" => t("acme")}]
    end

    test "an empty seed behaves exactly like bindings/2" do
      {:ok, rule} = Parser.decode("colleague(X, Y) :- worksAt(X, Y).")

      graph = RDF.Graph.new([{t("alice"), rel("worksAt"), t("acme")}])

      assert Matcher.bindings(rule.body, graph, %{}) == Matcher.bindings(rule, graph)
    end

    test "seeded variables don't count against the 64-variable cap" do
      body =
        for i <- 1..33 do
          %FactPattern{predicate: rel("f"), args: [%Var{name: "V#{i}"}, %Var{name: "W#{i}"}]}
        end

      seed = Map.new(1..33, fn i -> {%Var{name: "V#{i}"}, t("bound")} end)

      assert {:ok, []} = Matcher.bindings(body, RDF.Graph.new(), seed)
    end
  end
end
