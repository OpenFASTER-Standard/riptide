defmodule Riptide.Derivation.InstallTest do
  use ExUnit.Case, async: false

  alias Riptide.Derivation.Catalog
  alias Riptide.Derivation.{Crosswalk, Install, Provenance, Rule, Signature}
  alias Riptide.Derivation.Literal.FactPattern

  defp t(name), do: RDF.iri("urn:test:" <> name)
  defp rel(name), do: RDF.iri("urn:riptide:relation:" <> name)
  defp unique_tenant, do: "acme-#{System.unique_integer([:positive])}"

  defp sample_rule(predicate_name, reads) do
    predicate = rel(predicate_name)

    %Rule{
      signature: %Signature{name: predicate, parameters: [], reads: reads, produces: [predicate]},
      head: %FactPattern{predicate: predicate, args: [t("x"), RDF.literal("y")]},
      body: Enum.map(reads, &%FactPattern{predicate: &1, args: [t("x"), RDF.literal("y")]}),
      provenance: nil
    }
  end

  describe "tenant_vocabulary/1" do
    test "returns the union of reads/produces across a Tenant's own admitted Catalog entries" do
      tenant_id = unique_tenant()

      on_exit(fn ->
        Riptide.RaTestHelpers.cleanup_stream(Catalog.catalog_stream_id({:tenant, tenant_id}))
      end)

      :ok =
        Catalog.admit_entry({:tenant, tenant_id}, sample_rule("produced1", [rel("read1")]), nil)

      :ok =
        Catalog.admit_entry({:tenant, tenant_id}, sample_rule("produced2", [rel("read2")]), nil)

      vocabulary = Install.tenant_vocabulary(tenant_id)

      assert MapSet.subset?(
               MapSet.new([rel("produced1"), rel("read1"), rel("produced2"), rel("read2")]),
               vocabulary
             )
    end

    test "an unregistered Tenant has an empty vocabulary" do
      assert Install.tenant_vocabulary(unique_tenant()) == MapSet.new()
    end
  end

  describe "install/3" do
    test "a predicate already in the Tenant's vocabulary is left unchanged, no field binding recorded" do
      tenant_id = unique_tenant()

      on_exit(fn ->
        Riptide.RaTestHelpers.cleanup_stream(Catalog.catalog_stream_id({:tenant, tenant_id}))
      end)

      shared_predicate = rel("shared#{System.unique_integer([:positive])}")
      pattern_predicate_name = "pattern#{System.unique_integer([:positive])}"
      pattern_predicate = rel(pattern_predicate_name)

      :ok =
        Catalog.admit_entry(
          {:tenant, tenant_id},
          sample_rule("existing", [shared_predicate]),
          nil
        )

      :ok =
        Catalog.admit_entry({:tenant, tenant_id}, sample_rule(pattern_predicate_name, []), nil)

      pattern = %Rule{
        signature: %Signature{
          name: pattern_predicate,
          parameters: [],
          reads: [shared_predicate],
          produces: [pattern_predicate]
        },
        head: %FactPattern{predicate: pattern_predicate, args: [t("x"), RDF.literal("y")]},
        body: [%FactPattern{predicate: shared_predicate, args: [t("x"), RDF.literal("y")]}],
        provenance: nil
      }

      hub_entry_node = RDF.BlankNode.new("hub-entry")
      {installed_rule, field_bindings} = Install.install(hub_entry_node, pattern, tenant_id)

      assert field_bindings == []
      assert installed_rule.body == pattern.body

      assert installed_rule.provenance == %Provenance{
               origin: {:installed_from, hub_entry_node, []}
             }
    end

    test "a predicate mapped by an existing Crosswalk is rewritten; an unmatched predicate is left native" do
      tenant_id = unique_tenant()

      on_exit(fn ->
        Riptide.RaTestHelpers.cleanup_stream(Catalog.catalog_stream_id({:tenant, tenant_id}))
        Riptide.RaTestHelpers.cleanup_stream(Catalog.crosswalk_stream_id({:tenant, tenant_id}))
      end)

      source_predicate = rel("pendingDeploy#{System.unique_integer([:positive])}")
      target_predicate = rel("deploymentQueued#{System.unique_integer([:positive])}")
      unmatched_predicate = rel("notifyChannel#{System.unique_integer([:positive])}")

      :ok =
        Catalog.admit_entry(
          {:tenant, tenant_id},
          sample_rule("existing", [target_predicate]),
          nil
        )

      crosswalk = %Crosswalk{
        subject_predicate: source_predicate,
        object_predicate: target_predicate,
        match_type: :exact_match
      }

      :ok = Catalog.admit_crosswalk({:tenant, tenant_id}, crosswalk, nil)
      {:ok, crosswalks} = Catalog.list_crosswalks({:tenant, tenant_id})
      {crosswalk_node, ^crosswalk} = Enum.find(crosswalks, fn {_node, c} -> c == crosswalk end)

      pattern = %Rule{
        signature: %Signature{
          name: rel("pattern"),
          parameters: [],
          reads: [source_predicate, unmatched_predicate],
          produces: [rel("pattern")]
        },
        head: %FactPattern{predicate: rel("pattern"), args: [t("x"), RDF.literal("y")]},
        body: [
          %FactPattern{predicate: source_predicate, args: [t("x"), RDF.literal("y")]},
          %FactPattern{predicate: unmatched_predicate, args: [t("x"), RDF.literal("y")]}
        ],
        provenance: nil
      }

      hub_entry_node = RDF.BlankNode.new("hub-entry")
      {installed_rule, field_bindings} = Install.install(hub_entry_node, pattern, tenant_id)

      rewritten_predicates = Enum.map(installed_rule.body, & &1.predicate)
      assert target_predicate in rewritten_predicates
      assert unmatched_predicate in rewritten_predicates
      refute source_predicate in rewritten_predicates

      assert Enum.any?(field_bindings, fn
               %{predicate: ^source_predicate, binding: {:crosswalk, ^crosswalk_node}} -> true
               _other -> false
             end)

      assert Enum.any?(field_bindings, fn
               %{predicate: ^unmatched_predicate, binding: :manual} -> true
               _other -> false
             end)
    end
  end
end
