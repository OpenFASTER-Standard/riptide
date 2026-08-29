defmodule Riptide.Derivation.GeneralizationFidelityTest do
  use ExUnit.Case, async: true

  alias Riptide.Derivation.GeneralizationFidelity
  alias Riptide.Derivation.ExecuteInterpreter.Context
  alias Riptide.Derivation.Literal.FactPattern
  alias Riptide.Derivation.{Rule, Signature, Var}

  defp t(name), do: RDF.iri("urn:test:" <> name)
  defp rel(name), do: RDF.iri("urn:riptide:relation:" <> name)

  defp context(overrides \\ %{}) do
    Map.merge(
      %Context{capabilities: %{}, rules: %{}, tenant_id: "acme", current_subject: nil},
      overrides
    )
  end

  describe "check/3 — groundness precondition" do
    test "a fully ground Rule with an empty Body passes trivially" do
      head = %FactPattern{predicate: rel("greeted"), args: [t("alice"), RDF.literal("hi")]}

      rule = %Rule{
        signature: %Signature{
          name: head.predicate,
          parameters: [],
          reads: [],
          produces: [head.predicate]
        },
        head: head,
        body: []
      }

      assert GeneralizationFidelity.check(rule, RDF.Graph.new(), context()) ==
               {:ok, :fidelity_pass}
    end

    test "a Var anywhere in the Head is rejected as not_ground, even with an empty Body" do
      head = %FactPattern{predicate: rel("greeted"), args: [%Var{name: "X"}, RDF.literal("hi")]}

      rule = %Rule{
        signature: %Signature{
          name: head.predicate,
          parameters: [],
          reads: [],
          produces: [head.predicate]
        },
        head: head,
        body: []
      }

      assert GeneralizationFidelity.check(rule, RDF.Graph.new(), context()) ==
               {:error, :not_ground}
    end

    test "a Var anywhere in the Body is rejected as not_ground" do
      head = %FactPattern{predicate: rel("greeted"), args: [t("alice"), RDF.literal("hi")]}
      body = [%FactPattern{predicate: rel("worksAt"), args: [%Var{name: "X"}, t("acme")]}]

      rule = %Rule{
        signature: %Signature{
          name: head.predicate,
          parameters: [],
          reads: [],
          produces: [head.predicate]
        },
        head: head,
        body: body
      }

      assert GeneralizationFidelity.check(rule, RDF.Graph.new(), context()) ==
               {:error, :not_ground}
    end
  end
end
