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

  describe "find/2 — keyword match" do
    test "a query with partial word overlap, no exact candidate, is found via keyword fallback" do
      scope = unique_tenant()
      on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(Catalog.catalog_stream_id(scope)) end)

      rule = sample_rule("pendingDeploy", 0)
      :ok = Catalog.admit_entry(scope, rule, nil)

      assert {:ok, [{_node, ^rule}]} = Discovery.find(scope, "deploy the service")
    end
  end

  describe "find/2 — no match" do
    test "a query with zero word overlap returns {:ok, []}, not an error" do
      scope = unique_tenant()
      on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(Catalog.catalog_stream_id(scope)) end)

      rule = sample_rule("pendingDeploy", 0)
      :ok = Catalog.admit_entry(scope, rule, nil)

      assert Discovery.find(scope, "unrelated task") == {:ok, []}
    end
  end

  describe "find/2 — specificity tiebreak" do
    test "within the same tier, fewer free variables ranks first" do
      scope = unique_tenant()
      on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(Catalog.catalog_stream_id(scope)) end)

      specific_rule = sample_rule("greeted", 0)
      general_rule = sample_rule("greeted", 1)

      :ok = Catalog.admit_entry(scope, general_rule, nil)
      :ok = Catalog.admit_entry(scope, specific_rule, nil)

      assert {:ok, [{_node1, ^specific_rule}, {_node2, ^general_rule}]} =
               Discovery.find(scope, "greeted")
    end
  end

  describe "find/2 — exact outranks a higher-overlap keyword hit" do
    test "tier is the primary sort key, not raw overlap count" do
      scope = unique_tenant()
      on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(Catalog.catalog_stream_id(scope)) end)

      exact_rule = sample_rule("pendingDeploy", 0)
      keyword_rule = sample_rule("pendingDeployNow", 0)

      :ok = Catalog.admit_entry(scope, keyword_rule, nil)
      :ok = Catalog.admit_entry(scope, exact_rule, nil)

      assert {:ok, [{_node1, ^exact_rule}, {_node2, ^keyword_rule}]} =
               Discovery.find(scope, "pending deploy")
    end
  end

  describe "find/2 — empty Catalog" do
    test "a Tenant scope with no CatalogEntry admitted yet returns {:ok, []}" do
      assert Discovery.find(unique_tenant(), "anything") == {:ok, []}
    end
  end
end
