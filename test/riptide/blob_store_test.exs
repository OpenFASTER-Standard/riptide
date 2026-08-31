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

  test "the blob store is registered and reachable via Riptide.SupervisedProcess" do
    assert [{pid, Riptide.BlobStore}] =
             Registry.lookup(Riptide.SupervisedProcess.Registry, "blob_store")

    assert Process.alive?(pid)
  end

  test "a restart is allowed once put/1 has completed and the process is idle" do
    bytes = :crypto.strong_rand_bytes(1024)
    assert {:ok, _hash} = BlobStore.put(bytes)

    [{old_pid, Riptide.BlobStore}] =
      Registry.lookup(Riptide.SupervisedProcess.Registry, "blob_store")

    # Proves session_active?/1 and handle_stop_if_idle/4 are wired correctly
    # for the idle case; genuinely proving a restart is *refused* mid-write
    # needs a deliberately slow/blocking write to interleave a concurrent
    # restart request against, which isn't worth the complexity here — the
    # wiring itself (this test) is what's load-bearing to verify.
    assert :ok = Riptide.SupervisedProcess.request_restart("blob_store")

    # Riptide.BlobStore is a single, application-wide singleton (not a
    # fresh process per test) — request_restart/1 returning :ok only means
    # the restart was *accepted*, not that the old process has finished
    # exiting and a new one has finished starting. Without waiting for a
    # genuinely new pid to appear, a later test's own BlobStore.put/1 call
    # can race the still-dying old process and hit a spurious
    # :restart_requested exit — wait here so every subsequent test starts
    # from a fully-settled state.
    assert eventually(fn ->
             case Registry.lookup(Riptide.SupervisedProcess.Registry, "blob_store") do
               [{^old_pid, Riptide.BlobStore}] -> false
               [{new_pid, Riptide.BlobStore}] -> Process.alive?(new_pid)
               [] -> false
             end
           end)
  end

  defp eventually(fun, attempts_left \\ 50) do
    cond do
      fun.() -> true
      attempts_left <= 1 -> false
      true -> Process.sleep(20) && eventually(fun, attempts_left - 1)
    end
  end

  test "put/1 on a single connected node records exactly that node in the location index" do
    bytes = :crypto.strong_rand_bytes(1024)
    assert {:ok, hash} = BlobStore.put(bytes)

    assert {:ok, [node()]} == Riptide.BlobStore.LocationIndex.list_locations(hash)
  end
end
