defmodule Riptide.Derivation.CatalogTest do
  use ExUnit.Case, async: false

  alias Riptide.Derivation.Catalog
  alias Riptide.Derivation.Crosswalk
  alias Riptide.Derivation.DedupGate.PendingReview
  alias Riptide.Derivation.Literal.FactPattern
  alias Riptide.Derivation.{Rule, Signature}

  defp unique_tenant, do: {:tenant, "acme-#{System.unique_integer([:positive])}"}

  defp t(name), do: RDF.iri("urn:test:" <> name)
  defp rel(name), do: RDF.iri("urn:riptide:relation:" <> name)

  defp sample_rule(subject_name) do
    head = %FactPattern{predicate: rel("greeted"), args: [t(subject_name), RDF.literal("hi")]}

    %Rule{
      signature: %Signature{
        name: head.predicate,
        parameters: [],
        reads: [],
        produces: [head.predicate]
      },
      head: head,
      body: []
    }
  end

  describe "stream_id helpers" do
    test "catalog_stream_id/1 for a Tenant scope" do
      assert Catalog.catalog_stream_id({:tenant, "acme"}) ==
               "https://riptide.example/tenants/acme/resources/catalog"
    end

    test "pending_review_stream_id/1 for a Tenant scope" do
      assert Catalog.pending_review_stream_id({:tenant, "acme"}) ==
               "https://riptide.example/tenants/acme/resources/catalog/pending-review"
    end

    test "capability_stream_id/1 and crosswalk_stream_id/1 are scope-polymorphic" do
      assert Catalog.capability_stream_id({:tenant, "acme"}) ==
               "https://riptide.example/tenants/acme/resources/catalog/capabilities"

      assert Catalog.crosswalk_stream_id({:tenant, "acme"}) ==
               "https://riptide.example/tenants/acme/resources/catalog/crosswalks"
    end
  end

  describe "reads on a never-written stream" do
    test "list_entries/1 returns {:ok, []}, not an error, for a Tenant with no Catalog yet" do
      assert Catalog.list_entries(unique_tenant()) == {:ok, []}
    end

    test "list_pending_reviews/1 returns {:ok, []} for a Tenant with no pending reviews yet" do
      assert Catalog.list_pending_reviews(unique_tenant()) == {:ok, []}
    end
  end

  describe "admit_entry/3 + list_entries/1 — real round-trip" do
    test "an admitted entry (replaces: nil) is found live by list_entries/1" do
      scope = unique_tenant()
      on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(Catalog.catalog_stream_id(scope)) end)

      rule = sample_rule("alice")

      assert :ok == Catalog.admit_entry(scope, rule, nil)
      assert {:ok, [{_node, ^rule}]} = Catalog.list_entries(scope)
    end

    test "admitting two entries returns both, in either order" do
      scope = unique_tenant()
      on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(Catalog.catalog_stream_id(scope)) end)

      rule1 = sample_rule("alice")
      rule2 = sample_rule("bob")

      :ok = Catalog.admit_entry(scope, rule1, nil)
      :ok = Catalog.admit_entry(scope, rule2, nil)

      assert {:ok, entries} = Catalog.list_entries(scope)
      assert MapSet.new(Enum.map(entries, &elem(&1, 1))) == MapSet.new([rule1, rule2])
    end
  end

  describe "supersede_entry/2" do
    test "a superseded entry disappears from list_entries/1; admitting with replaces: writes the supersedes link" do
      scope = unique_tenant()
      on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(Catalog.catalog_stream_id(scope)) end)

      old_rule = sample_rule("alice")
      :ok = Catalog.admit_entry(scope, old_rule, nil)
      {:ok, [{old_node, ^old_rule}]} = Catalog.list_entries(scope)

      new_rule = sample_rule("bob")
      :ok = Catalog.admit_entry(scope, new_rule, old_node)
      :ok = Catalog.supersede_entry(scope, old_node)

      assert {:ok, [{_node, ^new_rule}]} = Catalog.list_entries(scope)
    end
  end

  describe "admit_capability/3 + supersede_capability/2" do
    test "a superseded capability disappears from list_capabilities/1; admitting with replaces: writes the supersedes link" do
      scope = unique_tenant()
      on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(Catalog.capability_stream_id(scope)) end)

      name = RDF.iri("urn:riptide:capability:supersede-cap-#{System.unique_integer([:positive])}")

      old_entry = %Riptide.Derivation.CapabilityCatalogEntry{
        name: name,
        kind: :effect,
        component_hash: String.duplicate("b", 64),
        function: "run",
        fuel_limit: 10_000_000,
        timeout_ms: 5_000,
        memory_limits: %{
          max_memory_size: nil,
          max_table_elements: nil,
          max_instances: nil,
          max_tables: nil
        }
      }

      :ok = Catalog.admit_capability(scope, old_entry, nil)
      {:ok, entries} = Catalog.list_capabilities(scope)
      {old_node, ^old_entry} = Enum.find(entries, fn {_n, e} -> e.name == name end)

      new_entry = %{old_entry | function: "run_v2"}
      :ok = Catalog.admit_capability(scope, new_entry, old_node)
      :ok = Catalog.supersede_capability(scope, old_node)

      {:ok, entries_after} = Catalog.list_capabilities(scope)
      matching = Enum.filter(entries_after, fn {_n, e} -> e.name == name end)
      assert [{_node, ^new_entry}] = matching
    end

    test "capabilities in one tenant's scope are invisible from another tenant's scope" do
      scope_a = unique_tenant()
      scope_b = unique_tenant()

      on_exit(fn ->
        Riptide.RaTestHelpers.cleanup_stream(Catalog.capability_stream_id(scope_a))
        Riptide.RaTestHelpers.cleanup_stream(Catalog.capability_stream_id(scope_b))
      end)

      entry = %Riptide.Derivation.CapabilityCatalogEntry{
        name: RDF.iri("urn:riptide:capability:isolation-cap-#{System.unique_integer([:positive])}"),
        kind: :effect,
        component_hash: String.duplicate("c", 64),
        function: "run",
        fuel_limit: 10_000_000,
        timeout_ms: 5_000,
        memory_limits: %{
          max_memory_size: nil,
          max_table_elements: nil,
          max_instances: nil,
          max_tables: nil
        }
      }

      :ok = Catalog.admit_capability(scope_a, entry, nil)

      assert {:ok, [{_node, ^entry}]} = Catalog.list_capabilities(scope_a)
      assert {:ok, []} = Catalog.list_capabilities(scope_b)
    end
  end

  describe "queue_pending_review/2 + list_pending_reviews/1 — real round-trip" do
    test "a queued PendingReview is found live by list_pending_reviews/1" do
      scope = unique_tenant()

      on_exit(fn ->
        Riptide.RaTestHelpers.cleanup_stream(Catalog.pending_review_stream_id(scope))
      end)

      pending_review = %PendingReview{
        kind: :admit,
        candidate: sample_rule("alice"),
        fidelity_evidence: [:fidelity_pass, :fidelity_pass],
        replaces: nil
      }

      assert {:ok, node} = Catalog.queue_pending_review(scope, pending_review)
      assert {:ok, [{^node, ^pending_review}]} = Catalog.list_pending_reviews(scope)
    end
  end

  describe "resolve_pending_review/3" do
    test "an approved item disappears from list_pending_reviews/1" do
      scope = unique_tenant()

      on_exit(fn ->
        Riptide.RaTestHelpers.cleanup_stream(Catalog.pending_review_stream_id(scope))
      end)

      pending_review = %PendingReview{
        kind: :admit,
        candidate: sample_rule("alice"),
        fidelity_evidence: [:fidelity_pass, :fidelity_pass],
        replaces: nil
      }

      {:ok, node} = Catalog.queue_pending_review(scope, pending_review)
      assert :ok == Catalog.resolve_pending_review(scope, node, :approved)
      assert {:ok, []} = Catalog.list_pending_reviews(scope)
    end

    test "a declined item disappears from list_pending_reviews/1" do
      scope = unique_tenant()

      on_exit(fn ->
        Riptide.RaTestHelpers.cleanup_stream(Catalog.pending_review_stream_id(scope))
      end)

      pending_review = %PendingReview{
        kind: :admit,
        candidate: sample_rule("alice"),
        fidelity_evidence: [:fidelity_pass, :fidelity_pass],
        replaces: nil
      }

      {:ok, node} = Catalog.queue_pending_review(scope, pending_review)
      assert :ok == Catalog.resolve_pending_review(scope, node, :declined)
      assert {:ok, []} = Catalog.list_pending_reviews(scope)
    end
  end

  describe "admit_crosswalk/3 + list_crosswalks/1 — real round-trip" do
    test "an admitted Crosswalk is found live by list_crosswalks/1" do
      scope = unique_tenant()
      on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(Catalog.crosswalk_stream_id(scope)) end)

      crosswalk = %Crosswalk{
        subject_predicate:
          rel("crosswalktest-pendingDeploy#{System.unique_integer([:positive])}"),
        object_predicate:
          rel("crosswalktest-deploymentQueued#{System.unique_integer([:positive])}"),
        match_type: :exact_match
      }

      :ok = Catalog.admit_crosswalk(scope, crosswalk, nil)

      assert {:ok, entries} = Catalog.list_crosswalks(scope)
      assert Enum.any?(entries, fn {_node, entry} -> entry == crosswalk end)
    end
  end

  describe "admit_crosswalk/3 + supersede_crosswalk/2" do
    test "a superseded crosswalk disappears from list_crosswalks/1; admitting with replaces: writes the supersedes link" do
      scope = unique_tenant()
      on_exit(fn -> Riptide.RaTestHelpers.cleanup_stream(Catalog.crosswalk_stream_id(scope)) end)

      subject_predicate =
        rel("supersede-crosswalk-subject-#{System.unique_integer([:positive])}")

      old_crosswalk = %Crosswalk{
        subject_predicate: subject_predicate,
        object_predicate:
          rel("crosswalktest-deploymentQueued#{System.unique_integer([:positive])}"),
        match_type: :exact_match
      }

      :ok = Catalog.admit_crosswalk(scope, old_crosswalk, nil)
      {:ok, entries} = Catalog.list_crosswalks(scope)

      {old_node, ^old_crosswalk} =
        Enum.find(entries, fn {_n, c} -> c.subject_predicate == subject_predicate end)

      new_crosswalk = %{old_crosswalk | match_type: :close_match}
      :ok = Catalog.admit_crosswalk(scope, new_crosswalk, old_node)
      :ok = Catalog.supersede_crosswalk(scope, old_node)

      {:ok, entries_after} = Catalog.list_crosswalks(scope)

      matching =
        Enum.filter(entries_after, fn {_n, c} -> c.subject_predicate == subject_predicate end)

      assert [{_node, ^new_crosswalk}] = matching
    end

    test "crosswalks in one tenant's scope are invisible from another tenant's scope" do
      scope_a = unique_tenant()
      scope_b = unique_tenant()

      on_exit(fn ->
        Riptide.RaTestHelpers.cleanup_stream(Catalog.crosswalk_stream_id(scope_a))
        Riptide.RaTestHelpers.cleanup_stream(Catalog.crosswalk_stream_id(scope_b))
      end)

      crosswalk = %Crosswalk{
        subject_predicate:
          rel("isolation-crosswalk-subject-#{System.unique_integer([:positive])}"),
        object_predicate:
          rel("isolation-crosswalk-object-#{System.unique_integer([:positive])}"),
        match_type: :exact_match
      }

      :ok = Catalog.admit_crosswalk(scope_a, crosswalk, nil)

      assert {:ok, [{_node, ^crosswalk}]} = Catalog.list_crosswalks(scope_a)
      assert {:ok, []} = Catalog.list_crosswalks(scope_b)
    end
  end
end
