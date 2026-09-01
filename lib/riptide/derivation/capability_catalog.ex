defmodule Riptide.Derivation.CapabilityCatalog do
  @moduledoc """
  Resolves a Hub-scope `CapabilityCatalogEntry` into a real, invokable
  `Riptide.Capability.Definition` — see design spec
  `docs/superpowers/specs/2026-08-31-phase-6k-dynamic-capability-registration-design.md`
  §5. Storage/review live in `Riptide.Derivation.Catalog`/`DedupGate`; this
  module only handles turning a `component_hash` into a literal local path
  `Capability.invoke/4` can actually shell out to.
  """

  alias Riptide.BlobStore
  alias Riptide.Capability.Definition
  alias Riptide.Derivation.{CapabilityCatalogEntry, Catalog}

  @doc """
  Finds a Hub-scope Capability by its own `name` IRI. A thin wrapper over
  `Catalog.list_capabilities/0` — shared here (not duplicated at each call
  site) since both this module's own capstone usage and 6l's
  `ContextResolver` need the exact same "resolve by name" lookup.
  """
  @spec find_by_name(RDF.IRI.t()) :: {:ok, CapabilityCatalogEntry.t()} | {:error, :not_found}
  def find_by_name(name) do
    with {:ok, entries} <- Catalog.list_capabilities() do
      find_entry(entries, name)
    end
  end

  defp find_entry(entries, name) do
    case Enum.find(entries, fn {_node, entry} -> entry.name == name end) do
      {_node, entry} -> {:ok, entry}
      nil -> {:error, :not_found}
    end
  end

  @spec materialize(CapabilityCatalogEntry.t()) :: {:ok, Definition.t()} | {:error, term()}
  def materialize(%CapabilityCatalogEntry{} = entry) do
    with {:ok, path} <- ensure_local(entry.component_hash) do
      {:ok,
       %Definition{
         name: entry.name,
         kind: entry.kind,
         component: path,
         function: entry.function,
         fuel_limit: entry.fuel_limit,
         timeout_ms: entry.timeout_ms,
         memory_limits: entry.memory_limits
       }}
    end
  end

  defp ensure_local(hash) do
    local_path = BlobStore.path_for(hash)

    if File.exists?(local_path) do
      {:ok, local_path}
    else
      fetch_and_cache(hash)
    end
  end

  defp fetch_and_cache(hash) do
    with {:ok, bytes} <- safe_get(hash) do
      path = cache_path_for(hash)

      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(path, bytes) do
        {:ok, path}
      end
    end
  end

  # `BlobStore.get/1`'s `GenServer.call` uses the default 5000ms timeout,
  # but the single `BlobStore` process it calls into can itself block far
  # longer internally (up to 30s per remote node it tries, sequentially,
  # once a blob isn't found locally — see `BlobStore.fetch_remote/1`) —
  # e.g. when a `LocationIndex` entry still points at a node that's since
  # torn down (a `:peer`-based test cluster that already stopped). A
  # caller-side timeout there raises/exits the CALLING process, not
  # `BlobStore`'s own — but `materialize/1`'s own contract promises
  # `{:error, term()}` for every failure, never a raise. Confirmed live: a
  # stale `LocationIndex` entry from an earlier test made
  # `ContextResolver.resolve_all/2` (which materializes every Hub
  # capability, not just one) time out and 500 an entirely unrelated
  # Tenant's request.
  defp safe_get(hash) do
    BlobStore.get(hash)
  catch
    :exit, _ -> {:error, :blob_unavailable}
  end

  defp cache_path_for(hash) do
    <<prefix::binary-size(2), rest::binary>> = hash
    Path.join([cache_dir(), prefix, rest])
  end

  defp cache_dir do
    Application.get_env(:riptide, :capability_cache_dir) ||
      System.get_env("RIPTIDE_CAPABILITY_CACHE_DIR") || "priv/capability_cache"
  end
end
