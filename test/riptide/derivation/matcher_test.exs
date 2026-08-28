defmodule Riptide.Derivation.MatcherTest do
  use ExUnit.Case, async: true

  alias Riptide.Derivation.{Matcher, Parser, Rule, Signature, Var}
  alias Riptide.Derivation.Literal.FactPattern

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
end
