defmodule Riptide.Derivation.CatalogTest do
  use ExUnit.Case, async: false

  alias Riptide.Derivation.Catalog

  defp unique_tenant, do: {:tenant, "acme-#{System.unique_integer([:positive])}"}

  describe "stream_id helpers" do
    test "catalog_stream_id/1 for a Tenant scope" do
      assert Catalog.catalog_stream_id({:tenant, "acme"}) ==
               "https://riptide.example/tenants/acme/catalog"
    end

    test "catalog_stream_id/1 for the Hub scope" do
      assert Catalog.catalog_stream_id(:hub) == "https://riptide.example/hub/catalog"
    end

    test "pending_review_stream_id/1 for a Tenant scope" do
      assert Catalog.pending_review_stream_id({:tenant, "acme"}) ==
               "https://riptide.example/tenants/acme/catalog/pending-review"
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
end
