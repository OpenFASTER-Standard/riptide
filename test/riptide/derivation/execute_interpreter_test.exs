defmodule Riptide.Derivation.ExecuteInterpreterTest do
  use ExUnit.Case, async: true

  alias Riptide.Derivation.ExecuteInterpreter
  alias Riptide.Derivation.ExecuteInterpreter.Context
  alias Riptide.Derivation.Literal.{CapabilityReference, FactPattern, RuleReference}
  alias Riptide.Derivation.{Rule, Signature, Var}

  defp t(name), do: RDF.iri("urn:test:" <> name)
  defp rel(name), do: RDF.iri("urn:riptide:relation:" <> name)

  defp context(overrides \\ %{}) do
    Map.merge(
      %Context{capabilities: %{}, rules: %{}, tenant_id: "acme", current_subject: nil},
      overrides
    )
  end

  describe "call_template/3 — fact-pattern-only Bodies" do
    test "a single fact-pattern literal concludes one triple per match" do
      head = %FactPattern{predicate: rel("sibling"), args: [%Var{name: "X"}, %Var{name: "Y"}]}
      body = [%FactPattern{predicate: rel("worksAt"), args: [%Var{name: "X"}, %Var{name: "Y"}]}]

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

      graph = RDF.Graph.new([{t("alice"), rel("worksAt"), t("acme")}])

      assert ExecuteInterpreter.call_template(rule, graph, context()) ==
               {:ok, [{t("alice"), rel("sibling"), t("acme")}]}
    end

    test "a fact-pattern run with zero matches returns {:ok, []}, not an error" do
      head = %FactPattern{predicate: rel("sibling"), args: [%Var{name: "X"}, %Var{name: "Y"}]}
      body = [%FactPattern{predicate: rel("worksAt"), args: [%Var{name: "X"}, %Var{name: "Y"}]}]

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

      assert ExecuteInterpreter.call_template(rule, RDF.Graph.new(), context()) == {:ok, []}
    end
  end

  describe "call_template/3 — structural checks" do
    test "an unresolvable capability IRI is rejected before any graph access" do
      head = %FactPattern{predicate: rel("out"), args: [t("x"), %Var{name: "Result"}]}

      body = [
        %CapabilityReference{
          capability: RDF.iri("urn:riptide:capability:notRegistered"),
          args: [t("x")],
          result: %Var{name: "Result"}
        }
      ]

      rule = %Rule{
        signature: %Signature{name: head.predicate, parameters: [], reads: [], produces: [head.predicate]},
        head: head,
        body: body
      }

      assert ExecuteInterpreter.call_template(rule, RDF.Graph.new(), context()) ==
               {:error, {:unresolvable, RDF.iri("urn:riptide:capability:notRegistered")}}
    end

    test "an unresolvable rule IRI is rejected before any graph access" do
      head = %FactPattern{predicate: rel("out"), args: [t("x"), %Var{name: "Result"}]}

      body = [
        %RuleReference{
          rule: RDF.iri("urn:riptide:rule:notRegistered"),
          args: [t("x")],
          result: %Var{name: "Result"}
        }
      ]

      rule = %Rule{
        signature: %Signature{name: head.predicate, parameters: [], reads: [], produces: [head.predicate]},
        head: head,
        body: body
      }

      assert ExecuteInterpreter.call_template(rule, RDF.Graph.new(), context()) ==
               {:error, {:unresolvable, RDF.iri("urn:riptide:rule:notRegistered")}}
    end

    test "a RuleReference with more than one arg is rejected as unsupported arity" do
      nested_iri = RDF.iri("urn:riptide:rule:nested")
      head = %FactPattern{predicate: rel("out"), args: [t("x"), %Var{name: "Result"}]}

      body = [
        %RuleReference{
          rule: nested_iri,
          args: [t("x"), t("y")],
          result: %Var{name: "Result"}
        }
      ]

      rule = %Rule{
        signature: %Signature{name: head.predicate, parameters: [], reads: [], produces: [head.predicate]},
        head: head,
        body: body
      }

      nested_rule = %Rule{
        signature: %Signature{name: nested_iri, parameters: [], reads: [], produces: [nested_iri]},
        head: %FactPattern{predicate: nested_iri, args: [%Var{name: "A"}, %Var{name: "B"}]},
        body: [%FactPattern{predicate: rel("f"), args: [%Var{name: "A"}, %Var{name: "B"}]}]
      }

      ctx = context(%{rules: %{nested_iri => nested_rule}})

      assert ExecuteInterpreter.call_template(rule, RDF.Graph.new(), ctx) ==
               {:error, {:unsupported_arity, nested_iri}}
    end
  end
end
