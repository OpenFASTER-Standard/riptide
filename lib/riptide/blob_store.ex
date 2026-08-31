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
    {:reply, do_put(bytes), state}
  end

  def handle_call({:get, hash}, _from, state) do
    {:reply, do_get(hash), state}
  end

  def handle_call({:riptide_supervised_process, :stop_if_idle, reason}, from, state) do
    Riptide.SupervisedProcess.handle_stop_if_idle(__MODULE__, state, reason, from)
  end

  @impl Riptide.SupervisedProcess
  def session_active?(state), do: state.writing

  defp do_put(bytes) do
    hash = hash_of(bytes)
    path = path_for(hash)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, bytes) do
      {:ok, hash}
    end
  end

  defp do_get(hash) do
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
