defmodule Riptide.Derivation.DiscoveryTest do
  use ExUnit.Case, async: false

  alias Riptide.Derivation.Catalog
  alias Riptide.Derivation.Discovery
  alias Riptide.Derivation.Literal.FactPattern
  alias Riptide.Derivation.{Rule, Signature, Var}

  defp unique_tenant, do: {:tenant, "acme-#{System.unique_integer([:positive])}"}

  defp t(name), do: RDF.iri("urn:test:" <> name)
  defp rel(name), do: RDF.iri("urn:riptide:relation:" <> name)

  # free_var_count: 0, 1, or 2 — controls how many of the Head's two
  # FactPattern args are free `Var`s (a FactPattern always has exactly 2
  # args, subject + object), giving each test control over specificity
  # without needing a real Body.
  defp sample_rule(predicate_local_name, free_var_count) do
    predicate = rel(predicate_local_name)

    head_args =
      case free_var_count do
        0 -> [t("subject"), RDF.literal("object")]
        1 -> [%Var{name: "X"}, RDF.literal("object")]
        2 -> [%Var{name: "X"}, %Var{name: "Y"}]
      end

    head = %FactPattern{predicate: predicate, args: head_args}

    %Rule{
      signature: %Signature{
        name: predicate,
        parameters: Enum.filter(head_args, &match?(%Var{}, &1)),
        reads: [],
        produces: [predicate]
      },
      head: head,
      body: []
    }
  end

  describe "find/2 — exact match" do
    test "a query whose words exactly match a found entry's predicate is ranked" do
      scope = unique_tenant()
      on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(Catalog.catalog_stream_id(scope)) end)

      rule = sample_rule("pendingDeploy", 0)
      :ok = Catalog.admit_entry(scope, rule, nil)

      assert {:ok, [{_node, ^rule}]} = Discovery.find(scope, "pending deploy")
    end
  end
end
