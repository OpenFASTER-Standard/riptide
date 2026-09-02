defmodule Riptide.Derivation.CapabilityCatalogTest do
  use ExUnit.Case, async: false

  alias Riptide.BlobStore
  alias Riptide.Capability.Definition
  alias Riptide.Derivation.{CapabilityCatalog, CapabilityCatalogEntry}

  setup do
    blob_dir =
      Path.join(System.tmp_dir!(), "cap_catalog_blob_#{System.unique_integer([:positive])}")

    cache_dir =
      Path.join(System.tmp_dir!(), "cap_catalog_cache_#{System.unique_integer([:positive])}")

    Riptide.AppEnvTestHelpers.put_env(:riptide, :blob_data_dir, blob_dir)
    Riptide.AppEnvTestHelpers.put_env(:riptide, :capability_cache_dir, cache_dir)

    on_exit(fn ->
      File.rm_rf!(blob_dir)
      File.rm_rf!(cache_dir)
    end)

    :ok
  end

  defp sample_entry(hash) do
    %CapabilityCatalogEntry{
      name: RDF.iri("urn:riptide:capability:materialize-#{System.unique_integer([:positive])}"),
      kind: :effect,
      component_hash: hash,
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
  end

  defp tenant_id, do: "cap-catalog-test-" <> Uniq.UUID.uuid4()

  test "materialize/2 reuses an already-local BlobStore replica without a network fetch" do
    tenant_id = tenant_id()
    bytes = :crypto.strong_rand_bytes(1024)
    {:ok, hash} = BlobStore.put(tenant_id, bytes)
    entry = sample_entry(hash)

    assert {:ok, %Definition{} = definition} = CapabilityCatalog.materialize(tenant_id, entry)

    assert definition.name == entry.name
    assert definition.kind == entry.kind
    assert definition.function == entry.function
    assert definition.fuel_limit == entry.fuel_limit
    assert definition.timeout_ms == entry.timeout_ms
    assert definition.memory_limits == entry.memory_limits
    # Reused BlobStore's own on-disk path directly — no separate cache copy.
    assert definition.component == BlobStore.path_for(tenant_id, hash)
    assert File.read!(definition.component) == bytes
  end

  test "materialize/2 for a hash that exists nowhere returns an error" do
    entry = sample_entry(String.duplicate("0", 64))

    assert {:error, _reason} = CapabilityCatalog.materialize(tenant_id(), entry)
  end
end
