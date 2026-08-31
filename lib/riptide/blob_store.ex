defmodule Riptide.BlobStore do
  @moduledoc """
  Privileged, content-addressed blob storage — see design spec
  `docs/superpowers/specs/2026-08-30-phase-6j-large-object-blob-storage-design.md`.
  Outside the WASI sandbox by design (§4/§9): performs no authorization of its
  own, every caller is responsible for that. A single, well-known
  `Riptide.SupervisedProcess` instance (id `"blob_store"`) per node — `put/1`'s
  own write is real I/O (a blob can be >10MB), so `session_active?/1` refuses a
  restart mid-write rather than risk a truncated local copy.
  """

  @behaviour Riptide.SupervisedProcess
  use GenServer

  alias Riptide.BlobStore.LocationIndex

  @id "blob_store"

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_arg), do: Riptide.SupervisedProcess.start(@id, __MODULE__, [])

  @spec put(binary()) :: {:ok, String.t()} | {:error, term()}
  def put(bytes) when is_binary(bytes), do: GenServer.call(pid!(), {:put, bytes}, :infinity)

  @spec get(String.t()) :: {:ok, binary()} | {:error, :not_found}
  def get(hash), do: GenServer.call(pid!(), {:get, hash})

  # Mirrors Riptide.SupervisedProcess's own private `control/2` lookup
  # exactly (Registry.lookup/2 -> match the registered {pid, module} pair
  # -> call the pid directly) rather than reconstructing a `:via` tuple by
  # hand for outbound calls too.
  defp pid! do
    [{pid, __MODULE__}] = Registry.lookup(Riptide.SupervisedProcess.Registry, @id)
    pid
  end

  @impl GenServer
  def init([]), do: {:ok, %{writing: false}}

  @impl GenServer
  def handle_call({:put, bytes}, _from, state) do
    result = do_put(%{state | writing: true}, bytes)
    {:reply, result, %{state | writing: false}}
  end

  def handle_call({:get, hash}, _from, state) do
    {:reply, do_get(hash), state}
  end

  def handle_call({:riptide_supervised_process, :stop_if_idle, reason}, from, state) do
    Riptide.SupervisedProcess.handle_stop_if_idle(__MODULE__, state, reason, from)
  end

  @impl Riptide.SupervisedProcess
  def session_active?(state), do: state.writing

  defp do_put(_state, bytes) do
    hash = hash_of(bytes)
    path = path_for(hash)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, bytes) do
      LocationIndex.add_location(hash, node())
      replicate(hash, bytes, other_nodes())
      {:ok, hash}
    end
  end

  # RF - 1 other nodes, deterministically picked (sorted, first N) so a
  # concurrent put/1 for the same content from a different caller converges
  # on the same replica set rather than scattering copies unnecessarily —
  # mirrors Riptide.Stream.ReplicaHealer.pick_replacement/2's own
  # determinism rationale.
  defp other_nodes do
    rf = Application.get_env(:riptide, :blob_replication_factor, 3)
    Node.list() |> Enum.sort() |> Enum.take(rf - 1)
  end

  defp replicate(hash, bytes, nodes) do
    Enum.each(nodes, fn n ->
      case :rpc.call(n, __MODULE__, :receive_replica, [hash, bytes], 30_000) do
        :ok -> LocationIndex.add_location(hash, n)
        _other -> :ok
      end
    end)
  end

  @doc false
  @spec receive_replica(String.t(), binary()) :: :ok | {:error, term()}
  def receive_replica(hash, bytes) do
    if hash_of(bytes) == hash do
      path = path_for(hash)

      with :ok <- File.mkdir_p(Path.dirname(path)) do
        File.write(path, bytes)
      end
    else
      {:error, :hash_mismatch}
    end
  end

  defp do_get(hash) do
    case File.read(path_for(hash)) do
      {:ok, bytes} -> verify(bytes, hash)
      {:error, _reason} -> fetch_remote(hash)
    end
  end

  defp fetch_remote(hash) do
    case LocationIndex.list_locations(hash) do
      {:ok, nodes} -> try_remote_nodes(hash, nodes -- [node()])
      {:error, :not_ready} -> {:error, :not_found}
    end
  end

  defp try_remote_nodes(_hash, []), do: {:error, :not_found}

  defp try_remote_nodes(hash, [n | rest]) do
    case :rpc.call(n, __MODULE__, :receive_replica_bytes, [hash], 30_000) do
      {:ok, bytes} -> verify(bytes, hash)
      _other -> try_remote_nodes(hash, rest)
    end
  end

  @doc false
  @spec receive_replica_bytes(String.t()) :: {:ok, binary()} | {:error, :not_found}
  def receive_replica_bytes(hash) do
    case File.read(path_for(hash)) do
      {:ok, bytes} -> verify(bytes, hash)
      {:error, _reason} -> {:error, :not_found}
    end
  end

  # A locally-stored blob whose bytes don't match their own claimed hash is
  # corruption, not a valid result (spec §5) — never served silently.
  defp verify(bytes, hash) do
    if hash_of(bytes) == hash, do: {:ok, bytes}, else: {:error, :not_found}
  end

  defp hash_of(bytes),
    do: bytes |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  # Two-level directory prefix (matching git's own object-store layout) so a
  # single directory never accumulates an unbounded number of entries.
  defp path_for(hash) do
    <<prefix::binary-size(2), rest::binary>> = hash
    Path.join([data_dir(), prefix, rest])
  end

  defp data_dir do
    Application.get_env(:riptide, :blob_data_dir) || System.get_env("RIPTIDE_BLOB_DATA_DIR") ||
      "priv/blob_data"
  end
end
