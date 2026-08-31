defmodule Riptide.BlobStoreTest do
  use ExUnit.Case, async: false

  alias Riptide.BlobStore

  setup do
    dir = Path.join(System.tmp_dir!(), "blob_store_test_#{System.unique_integer([:positive])}")
    Riptide.AppEnvTestHelpers.put_env(:riptide, :blob_data_dir, dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    :ok
  end

  test "put/1 then get/1 round-trips the exact bytes" do
    bytes = :crypto.strong_rand_bytes(1024)

    assert {:ok, hash} = BlobStore.put(bytes)
    assert {:ok, ^bytes} = BlobStore.get(hash)
  end

  test "the returned hash is the SHA-256 hex digest of the content" do
    bytes = "hello world"
    expected = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

    assert {:ok, ^expected} = BlobStore.put(bytes)
  end

  test "get/1 for an unknown hash returns :not_found" do
    assert {:error, :not_found} = BlobStore.get(String.duplicate("0", 64))
  end

  test "a blob well over 10MB round-trips correctly" do
    bytes = :crypto.strong_rand_bytes(11 * 1024 * 1024)

    assert {:ok, hash} = BlobStore.put(bytes)
    assert {:ok, ^bytes} = BlobStore.get(hash)
  end
end
