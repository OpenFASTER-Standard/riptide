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

    test "catalog_stream_id/1 for the Hub scope" do
      assert Catalog.catalog_stream_id(:hub) == "https://riptide.example/hub/resources/catalog"
    end

    test "pending_review_stream_id/1 for a Tenant scope" do
      assert Catalog.pending_review_stream_id({:tenant, "acme"}) ==
               "https://riptide.example/tenants/acme/resources/catalog/pending-review"
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

  describe "Hub vs. Tenant scope isolation" do
    test "admitting into :hub never surfaces in a Tenant's list_entries/1, and vice versa" do
      tenant_scope = unique_tenant()

      # :hub is a single, shared, non-unique stream across the whole test
      # suite (unlike unique_tenant()'s per-test isolation) — force-deleting
      # it here would race any other test concurrently or subsequently
      # writing to :hub (confirmed live: :ra.force_delete_server/2 on a
      # shared stream_id can leave the very next admit_entry/1 against that
      # same stream_id hitting :noproc before the lazy re-create catches
      # up). Tolerate accumulation instead — that's why this test already
      # asserts via Enum.any?/refute Enum.any? rather than an exact list.
      on_exit(fn ->
        Riptide.RaTestHelpers.cleanup_stream(Catalog.catalog_stream_id(tenant_scope))
      end)

      hub_rule = sample_rule("hub-pattern")
      tenant_rule = sample_rule("tenant-pattern")

      :ok = Catalog.admit_entry(:hub, hub_rule, nil)
      :ok = Catalog.admit_entry(tenant_scope, tenant_rule, nil)

      assert {:ok, [{_node, ^tenant_rule}]} = Catalog.list_entries(tenant_scope)
      assert {:ok, hub_entries} = Catalog.list_entries(:hub)
      assert Enum.any?(hub_entries, fn {_node, rule} -> rule == hub_rule end)
      refute Enum.any?(hub_entries, fn {_node, rule} -> rule == tenant_rule end)
    end
  end

  describe "admit_crosswalk/1 + list_crosswalks/0 — real round-trip" do
    test "an admitted Crosswalk is found live by list_crosswalks/0" do
      crosswalk = %Crosswalk{
        subject_predicate:
          rel("crosswalktest-pendingDeploy#{System.unique_integer([:positive])}"),
        object_predicate:
          rel("crosswalktest-deploymentQueued#{System.unique_integer([:positive])}"),
        match_type: :exact_match
      }

      :ok = Catalog.admit_crosswalk(crosswalk)

      assert {:ok, entries} = Catalog.list_crosswalks()
      assert Enum.any?(entries, fn {_node, entry} -> entry == crosswalk end)
    end
  end
end
